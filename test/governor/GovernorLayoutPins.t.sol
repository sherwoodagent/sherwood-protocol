// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";

/// @notice Raw-slot pins for `SyndicateGovernor`'s proxy-upgraded storage layout
///         — the in-`forge test` layer of the golden-layout guard (the full
///         field-by-field JSON diff lives in `script/check-layout-goldens.sh`
///         against `script/syndicate-governor-layout.golden.json`, mirroring the
///         LeveragedAero parity harness). Slot numbers below are FROZEN: a
///         reorder/insert/retype in `ProposalLifecycle` / `GovernorParameters` /
///         `GovernorEmergency` / `SyndicateGovernor` moves a sentinel and fails
///         an assert here even when the shell script isn't run. New fields are
///         APPEND-ONLY (carved from the FRONT of a __gap): extend the pins,
///         never edit them.
///
///         RE-BASELINED ONCE (proposal-lifecycle refactor): extracting the state
///         machine into the `ProposalLifecycle` base put its storage FIRST in the
///         C3 linearization, shifting every governor field down 15 words
///         (`vault` 0 -> 15, `_guardianRegistry` 43 -> 0, `_tierRegistry`
///         48 -> 58). That is a deliberate break, legitimate only because this
///         stack is a FRESH deployment with no live proxy to stay compatible
///         with (same fresh-deploy note as `GuardianRegistry`). Do NOT
///         cherry-pick the fold onto a deployed beacon: every live governor
///         would read garbage. From here the append-only rule applies again.
///
///         Layout map (linear, inheritance order ProposalLifecycle ->
///         GovernorParameters -> GovernorEmergency -> SyndicateGovernor; OZ
///         Initializable is ERC-7201 namespaced and holds no linear slot):
///           0  _guardianRegistry         15 vault
///           1  _proposals                16 protocolConfig
///           2  _openProposalCount        17 factory
///           3  _lastSettledAt            18..26 _params (9 words)
///           4  collaborationDeadline     27 _bootstrapOwner
///           5..14 __lifecycleGap[10]     28 _maxCapitalBps (finding 3)
///                                        29..35 __paramsGap[7]
///                                        36..45 __emergencyGap[10]
///                                        46 _proposalCount ... 58 _tierRegistry
///                                        59..91 __gap[33]
contract GovernorLayoutPinsTest is Test {
    SyndicateGovernor governor;
    MockRegistryMinimal guardianRegistry;

    address constant VAULT_SENTINEL = address(0xA1);
    address constant PROTOCOL_CONFIG_SENTINEL = address(0xA2);
    address constant TIER_REGISTRY_SENTINEL = address(0xB1);
    address owner = makeAddr("owner");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 2 days;

    function setUp() public {
        guardianRegistry = new MockRegistryMinimal();
        SyndicateGovernor impl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory init = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                VAULT_SENTINEL,
                address(guardianRegistry),
                PROTOCOL_CONFIG_SENTINEL,
                address(this), // factory (this test) — may call setTierRegistry
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(impl), init)));

        // The vault sentinel has no code — mock owner() so onlyVaultOwner works.
        vm.mockCall(VAULT_SENTINEL, abi.encodeWithSignature("owner()"), abi.encode(owner));
    }

    function _slot(uint256 index) internal view returns (bytes32) {
        return vm.load(address(governor), bytes32(index));
    }

    /// @notice GovernorParameters prefix: init-written fields land at their
    ///         frozen words.
    function test_layout_paramsPrefixPinned() public view {
        assertEq(_slot(15), bytes32(uint256(uint160(VAULT_SENTINEL))), "slot 15: vault");
        assertEq(_slot(16), bytes32(uint256(uint160(PROTOCOL_CONFIG_SENTINEL))), "slot 16: protocolConfig");
        assertEq(_slot(17), bytes32(uint256(uint160(address(this)))), "slot 17: factory");
        assertEq(_slot(18), bytes32(VOTING_PERIOD), "slot 18: _params.votingPeriod");
        assertEq(_slot(19), bytes32(EXECUTION_WINDOW), "slot 19: _params.executionWindow");
        assertEq(_slot(26), bytes32(uint256(30 days)), "slot 26: _params.maxStrategyDuration");
    }

    /// @notice The `ProposalLifecycle` base now occupies the first 15 words.
    ///         `_guardianRegistry` at slot 0 is the anchor: if the base ever
    ///         stops linearizing first, this is the assert that catches it.
    function test_layout_lifecycleBasePrefixPinned() public view {
        assertEq(_slot(0), bytes32(uint256(uint160(address(guardianRegistry)))), "slot 0: _guardianRegistry");
        assertEq(_slot(2), bytes32(0), "slot 2: _openProposalCount starts at zero");
    }

    /// @notice Finding 3's `_maxCapitalBps` was carved from the FRONT of
    ///         `__paramsGap` (8 -> 7): it sits immediately after
    ///         `_bootstrapOwner` (27), leaving every pre-existing slot intact
    ///         within the GovernorParameters region.
    function test_layout_maxCapitalBpsPinnedToSlot28() public {
        assertEq(_slot(28), bytes32(0), "slot 28 starts unset (sentinel 0 = 100% default)");
        vm.prank(owner);
        governor.setMaxCapitalBps(4_321);
        assertEq(_slot(28), bytes32(uint256(4_321)), "slot 28: _maxCapitalBps");
        assertEq(governor.maxCapitalBps(), 4_321);
    }

    /// @notice Appended-region anchor: `_tierRegistry` (58, Task-5 append), the
    ///         last field before `__gap`. `_guardianRegistry` moved into the
    ///         lifecycle base and is pinned by
    ///         `test_layout_lifecycleBasePrefixPinned` instead.
    function test_layout_appendedFieldsPinned() public {
        assertEq(_slot(58), bytes32(0), "slot 58 starts unset");
        governor.setTierRegistry(TIER_REGISTRY_SENTINEL); // this test is the factory
        assertEq(_slot(58), bytes32(uint256(uint160(TIER_REGISTRY_SENTINEL))), "slot 58: _tierRegistry");
        assertEq(governor.tierRegistry(), TIER_REGISTRY_SENTINEL);
    }
}
