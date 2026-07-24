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
///         LeveragedAero parity harness). Slot numbers below are FROZEN: live
///         beacon-upgraded governors store state at exactly these words, so a
///         reorder/insert/retype in `GovernorParameters` / `GovernorEmergency` /
///         `SyndicateGovernor` moves a sentinel and fails an assert here even
///         when the shell script isn't run. New fields are APPEND-ONLY (carved
///         from the FRONT of a __gap): extend the pins, never edit them.
///
///         Layout map (linear, inheritance order GovernorParameters →
///         GovernorEmergency → SyndicateGovernor; OZ Initializable is ERC-7201
///         namespaced and holds no linear slot):
///           0  vault                     13 _maxCapitalBps (finding 3)
///           1  protocolConfig            14..20 __paramsGap[7]
///           2  factory                   21..30 __emergencyGap[10]
///           3..11 _params (9 words)      31 _proposalCount ... 43 _guardianRegistry
///           12 _bootstrapOwner           48 _tierRegistry, 49..81 __gap[33]
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
        assertEq(_slot(0), bytes32(uint256(uint160(VAULT_SENTINEL))), "slot 0: vault");
        assertEq(_slot(1), bytes32(uint256(uint160(PROTOCOL_CONFIG_SENTINEL))), "slot 1: protocolConfig");
        assertEq(_slot(2), bytes32(uint256(uint160(address(this)))), "slot 2: factory");
        assertEq(_slot(3), bytes32(VOTING_PERIOD), "slot 3: _params.votingPeriod");
        assertEq(_slot(4), bytes32(EXECUTION_WINDOW), "slot 4: _params.executionWindow");
        assertEq(_slot(11), bytes32(uint256(30 days)), "slot 11: _params.maxStrategyDuration");
    }

    /// @notice Finding 3's `_maxCapitalBps` was carved from the FRONT of
    ///         `__paramsGap` (8 → 7): it must sit at slot 13, immediately after
    ///         `_bootstrapOwner` (12), leaving every pre-existing slot intact.
    function test_layout_maxCapitalBpsPinnedToSlot13() public {
        assertEq(_slot(13), bytes32(0), "slot 13 starts unset (sentinel 0 = 100% default)");
        vm.prank(owner);
        governor.setMaxCapitalBps(4_321);
        assertEq(_slot(13), bytes32(uint256(4_321)), "slot 13: _maxCapitalBps");
        assertEq(governor.maxCapitalBps(), 4_321);
    }

    /// @notice Appended-region anchors: `_guardianRegistry` (43, written at
    ///         initialize) and `_tierRegistry` (48, Task-5 append). If either
    ///         moved, an upgrade would read garbage for every live governor.
    function test_layout_appendedFieldsPinned() public {
        assertEq(_slot(43), bytes32(uint256(uint160(address(guardianRegistry)))), "slot 43: _guardianRegistry");

        assertEq(_slot(48), bytes32(0), "slot 48 starts unset");
        governor.setTierRegistry(TIER_REGISTRY_SENTINEL); // this test is the factory
        assertEq(_slot(48), bytes32(uint256(uint160(TIER_REGISTRY_SENTINEL))), "slot 48: _tierRegistry");
        assertEq(governor.tierRegistry(), TIER_REGISTRY_SENTINEL);
    }
}
