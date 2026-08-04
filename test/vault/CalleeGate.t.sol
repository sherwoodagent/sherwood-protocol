// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";

/// @notice Governor stand-in WITHOUT a `tierRegistry()` getter — mirrors
///         `SelectorGuard.t.sol`'s fixture of the same name; models a
///         pre-tier-registry governor for the degrade-open branch.
contract MockGovernorNoTierGetterCG {
    function getActiveProposal() external pure returns (uint256) {
        return 0;
    }
}

/// @notice issue #166 — target-based batch callee gate (`_guardBatchCalls`
///         PART 2a, design.md "target-based-batch-gating"). Proves the NEW
///         outer boundary in isolation: any batch call whose `target` is
///         neither `asset()` nor a TierRegistry-allowlisted adapter is
///         refused with `DisallowedBatchCallee(target)`, regardless of
///         selector or calldata shape/length — including calls the retained
///         selector switch (`SelectorGuard.t.sol`'s subject) never
///         recognizes at all. `SelectorGuard.t.sol` continues to pin the
///         INNER (selector) layer on already-allowlisted callees; this suite
///         is the outer layer's dedicated coverage.
contract CalleeGateTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockProposalStatus governor;
    TierRegistry tierRegistry;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address adapter = makeAddr("adapter");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        tierRegistry = new TierRegistry(address(this));

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        governor = new MockProposalStatus();
        governor.setTierRegistry(address(tierRegistry));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        tierRegistry.setAdapterAllowed(adapter, true);

        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    function _one(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _oneWithValue(address target, bytes memory data, uint256 value)
        internal
        pure
        returns (BatchExecutorLib.Call[] memory calls)
    {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: target, data: data, value: value});
    }

    function _exec(BatchExecutorLib.Call[] memory calls) internal {
        vm.prank(address(governor));
        vault.executeGovernorBatch(calls, new uint256[](0), type(uint256).max);
    }

    function _expectCalleeDisallowed(address target) internal {
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchCallee.selector, target));
    }

    // ── unknown/unenumerated selector on a non-allowlisted token ──

    /// @notice The whole point of the callee gate: a selector the retained
    ///         switch has NEVER enumerated (legacy `increaseApproval`, an
    ///         approve-lineage selector no round of the old selector-list
    ///         patching ever added) is refused by TARGET before its calldata
    ///         is examined at all — closing the "just one more selector"
    ///         class rather than extending the list once more.
    function test_unknownSelectorOnNonAllowlistedTokenReverts() public {
        bytes4 selIncreaseApproval = 0xd73dd623; // increaseApproval(address,uint256) — never guarded by the selector switch
        ERC20Mock otherToken = new ERC20Mock("Other", "OTH", 18);
        _expectCalleeDisallowed(address(otherToken));
        _exec(_one(address(otherToken), abi.encodeWithSelector(selIncreaseApproval, attacker, type(uint256).max)));
    }

    // ── issue #18 witness: exotic-asset selector on a non-allowlisted NFT ──

    /// @notice The issue #18 scenario this change subsumes (design.md
    ///         Decision 4): `setApprovalForAll(attacker, true)` on an
    ///         ERC-721-shaped contract the selector switch has never
    ///         recognized (it only knows ERC-20-family shapes). Refused as a
    ///         CALLEE outright — the exact class closure #18 asked for,
    ///         covering every non-allowlisted exotic-asset contract by
    ///         default rather than needing its selectors enumerated. A bare
    ///         address stand-in suffices: the guard reverts before the batch
    ///         ever delegatecalls into the target (same technique
    ///         `SelectorGuard.t.sol` uses for Permit2/DSToken/ERC1363).
    function test_setApprovalForAllOnNonAllowlistedNftReverts() public {
        address nft = makeAddr("mockErc721");
        bytes4 selSetApprovalForAll = 0xa22cb465; // setApprovalForAll(address,bool)
        _expectCalleeDisallowed(nft);
        _exec(_one(nft, abi.encodeWithSelector(selSetApprovalForAll, attacker, true)));
    }

    // ── previously-open ETH route: empty calldata + native value ──

    /// @notice Design.md's headline residual being closed: an empty-calldata
    ///         call carrying `value > 0` moves native ETH and was invisible
    ///         to every selector check (the old guard's Part 2 loop began
    ///         with `if (data.length < 4) continue;`, skipping straight past
    ///         a value-only call). The callee gate runs BEFORE that
    ///         short-calldata continue, so this route is now closed too.
    function test_emptyCalldataNativeValueCallToRandomAddressReverts() public {
        address randomTarget = makeAddr("ethSink");
        vm.deal(address(vault), 1 ether);
        _expectCalleeDisallowed(randomTarget);
        _exec(_oneWithValue(randomTarget, "", 1 ether));
    }

    // ── asset() exemption: exempt from the callee gate, still recipient-guarded ──

    /// @notice Decision 2 (design.md): `asset()` is the sole exemption from
    ///         the callee gate itself, but that is NOT a blanket exemption
    ///         from the vault's fund-safety checks as a whole — the retained
    ///         inner (selector) layer still inspects `asset()` calls exactly
    ///         as before. `asset().approve(attacker, max)` must still revert
    ///         `DisallowedTransferTarget`, not pass merely because the callee
    ///         gate lets `asset()` through.
    function test_assetCalleeExemptButStillRecipientGuarded() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, address(usdc), bytes4(0x095ea7b3), attacker
            )
        );
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (attacker, type(uint256).max))));
    }

    /// @notice Companion positive case: an `asset()` call with no guarded
    ///         selector at all (a harmless read) still passes — the callee
    ///         gate's exemption is unconditional on `target == asset()`,
    ///         independent of calldata.
    function test_assetCalleeExemptPassesForNonGuardedSelector() public {
        _exec(_one(address(usdc), abi.encodeCall(usdc.balanceOf, (attacker))));
    }

    // ── allowlisted callee passes through to the (still-live) selector checks ──

    function test_allowlistedCalleePasses() public {
        // Unrecognized selector on an ALLOWLISTED callee: the callee gate
        // passes and the selector switch has nothing to say, so the call
        // proceeds (no revert expected).
        _exec(_one(adapter, abi.encodeWithSelector(bytes4(0x12345678), attacker)));
    }

    /// @notice The retained inner layer is still load-bearing on an
    ///         allowlisted callee: `token.approve(attacker, max)` on a token
    ///         that IS an allowlisted callee still must refuse a
    ///         non-allowlisted recipient — the callee gate alone would wave
    ///         this through, since the target itself is consented.
    function test_allowlistedTokenNonAllowlistedRecipientStillRefused() public {
        ERC20Mock allowlistedToken = new ERC20Mock("Allowlisted", "ALW", 18);
        tierRegistry.setAdapterAllowed(address(allowlistedToken), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector,
                address(allowlistedToken),
                bytes4(0x095ea7b3),
                attacker
            )
        );
        _exec(_one(address(allowlistedToken), abi.encodeCall(allowlistedToken.approve, (attacker, 1e18))));
    }

    // ── degrade-open: unset registry / no tierRegistry() getter ──

    /// @notice Mirrors `SelectorGuard.t.sol`'s
    ///         `test_targetGate_bitesEvenWithNoTierRegistryWired` companions:
    ///         with the registry unset, PART 2 (both 2a and 2b) is skipped
    ///         entirely by design — a batch to an arbitrary, non-allowlisted
    ///         target still executes. Part 1/1b are unaffected by this
    ///         change and are not re-tested here (already pinned elsewhere).
    function test_degradeOpen_registryUnset_calleeGateSkipped() public {
        governor.setTierRegistry(address(0));
        address randomTarget = makeAddr("degradeOpenTarget1");
        _exec(_one(randomTarget, abi.encodeWithSelector(bytes4(0xdeadbeef), attacker)));
    }

    /// @notice Companion degrade-open branch: a governor predating the
    ///         `tierRegistry()` getter entirely resolves identically to an
    ///         unset registry — the callee gate is skipped, not hard-reverted.
    function test_degradeOpen_governorWithoutTierGetter_calleeGateSkipped() public {
        MockGovernorNoTierGetterCG legacy = new MockGovernorNoTierGetterCG();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(legacy)));

        address randomTarget = makeAddr("degradeOpenTarget2");
        vm.prank(address(legacy));
        vault.executeGovernorBatch(
            _one(randomTarget, abi.encodeWithSelector(bytes4(0xdeadbeef), attacker)),
            new uint256[](0),
            type(uint256).max
        );
    }

    // ── codehash drift and demotion sever callability ──

    /// @notice issue #137's self-heal, now also load-bearing for callability
    ///         itself (not only fund-destination consent): an allowlisted
    ///         adapter backed by a real contract has its bytecode swapped at
    ///         the same address post-grant. `isAdapterAllowed`'s lazy
    ///         self-heal closes the funds path AND the callee gate on the
    ///         very next read — no `poke`/`demote` call runs.
    function test_codehashDrift_severeCalleeAfterEtch() public {
        ERC20Mock swappedAdapter = new ERC20Mock("Adapter", "ADP", 18);
        tierRegistry.setAdapterAllowed(address(swappedAdapter), true);

        // Sanity: passes before the swap. Uses a real, harmless selector
        // (`balanceOf`) rather than a made-up one — the guard's revert-path
        // assertions below never reach delegatecall (the guard runs before
        // `BatchExecutorLib.executeBatch`), but a PASSING call is actually
        // delegatecalled through to `swappedAdapter`, and a real ERC20Mock
        // has no fallback: an unrecognized selector would revert for a
        // reason unrelated to this guard entirely.
        _exec(_one(address(swappedAdapter), abi.encodeCall(swappedAdapter.balanceOf, (attacker))));

        vm.etch(address(swappedAdapter), hex"6001600101");

        _expectCalleeDisallowed(address(swappedAdapter));
        _exec(_one(address(swappedAdapter), abi.encodeWithSelector(bytes4(0x12345678), attacker)));
    }

    /// @notice Demotion severs callability too, not only fund-destination
    ///         consent: `_demote`'s allowlist clear (deliberately over-broad
    ///         per its own natspec) means an owner `demote` of a CERTIFIED
    ///         (target, selector) pair also revokes that target's standing as
    ///         a batch callee at all, even for calls unrelated to the
    ///         demoted selector.
    function test_demotionSeveresCallee() public {
        ERC20Mock demotedAdapter = new ERC20Mock("Demoted", "DMT", 18);
        bytes4 sel = bytes4(0x12345678);
        tierRegistry.setAdapterAllowed(address(demotedAdapter), true);

        // Certify (target, selector) so `demote` (which requires an existing
        // certification, mirroring `poke`'s NotCertified guard) is reachable.
        tierRegistry.proposeCertification(
            address(demotedAdapter), sel, 0, 50, address(0), address(demotedAdapter).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certify(address(demotedAdapter), sel);
        assertTrue(tierRegistry.isAdapterAllowed(address(demotedAdapter)), "sanity: allowlisted before demotion");

        // Sanity: callable before demotion. Uses a real, harmless selector
        // (`balanceOf`) for the same reason as `test_codehashDrift_severeCalleeAfterEtch`
        // above — this call actually executes via delegatecall, unlike the
        // expected-revert calls below (which never reach delegatecall). `sel`
        // stays reserved for the propose/certify/demote bookkeeping only.
        _exec(_one(address(demotedAdapter), abi.encodeCall(demotedAdapter.balanceOf, (attacker))));

        tierRegistry.demote(address(demotedAdapter), sel);
        assertFalse(tierRegistry.isAdapterAllowed(address(demotedAdapter)), "demotion clears the allowlist flag too");

        _expectCalleeDisallowed(address(demotedAdapter));
        _exec(_one(address(demotedAdapter), abi.encodeWithSelector(sel, attacker)));
    }
}
