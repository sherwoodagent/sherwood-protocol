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

/// @notice Governor stand-in WITHOUT a `tierRegistry()` getter — models a
///         pre-tier-registry governor. The vault must treat it exactly like an
///         unset registry (guard off) instead of bricking every batch.
contract MockGovernorNoTierGetter {
    function getActiveProposal() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Findings 1+7 — value-moving-selector allowlist gate. The net-outflow
///         meter only sees the vault's own asset() balance delta, so a batch
///         call like `token.approve(attacker, max)` metered zero and let the
///         attacker drain via transferFrom in a later tx. `executeGovernorBatch`
///         now decodes the spender/recipient of approve / increaseAllowance /
///         transfer / transferFrom calls and requires it to be the vault itself
///         or an adapter allowlisted in the TierRegistry (resolved through the
///         calling governor). Applies to every batch path — execute, settle,
///         and both emergency paths all flow through `executeGovernorBatch`.
contract SelectorGuardTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    ERC20Mock otherToken;
    MockAgentRegistry agentRegistry;
    MockProposalStatus governor;
    TierRegistry tierRegistry;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address adapter = makeAddr("adapter");

    bytes4 constant SEL_APPROVE = 0x095ea7b3;
    bytes4 constant SEL_INCREASE_ALLOWANCE = 0x39509351;
    bytes4 constant SEL_TRANSFER = 0xa9059cbb;
    bytes4 constant SEL_TRANSFER_FROM = 0x23b872dd;

    // Alternate-signature "pull via delegated allowance" selectors — see the
    // PR #157 audit remediation (issue #115). `cast sig`-verified in
    // design.md; the guard now recognizes these alongside the four legacy
    // selectors above.
    bytes4 constant SEL_PERMIT2_TRANSFER_FROM = 0x36c78516; // Permit2 AllowanceTransfer.transferFrom(address,address,uint160,address)
    bytes4 constant SEL_PERMIT2_APPROVE = 0x87517c45; // Permit2 AllowanceTransfer.approve(address,address,uint160,uint48)
    bytes4 constant SEL_DSTOKEN_PULL = 0xf2d5d56b; // DSToken pull(address,uint256)
    bytes4 constant SEL_DSTOKEN_MOVE = 0xbb35783b; // DSToken move(address,address,uint256)

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        otherToken = new ERC20Mock("Other", "OTH", 18);
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
        // issue #166: the new callee gate (`_guardBatchCalls` PART 2a) refuses
        // ANY non-asset(), non-allowlisted target outright, before the
        // selector switch below (PART 2b) ever runs. Every router/token
        // fixture this suite drives as a batch CALL TARGET must be
        // allowlisted here so existing assertions keep pinning the INNER
        // (selector) layer they were written for, rather than being masked by
        // the new outer layer's DisallowedBatchCallee. No assertion is
        // weakened: recipients/spenders meant to stay non-allowlisted
        // (attacker, third-party victim sources) are untouched, and
        // test_calleeGateBitesForNonAllowlistedTarget below keeps at least
        // one un-allowlisted-target case pinning the new error's ordering.
        tierRegistry.setAdapterAllowed(permit2, true);
        tierRegistry.setAdapterAllowed(dstoken, true);
        tierRegistry.setAdapterAllowed(erc1363Token, true);
        tierRegistry.setAdapterAllowed(erc4626Token, true);
        tierRegistry.setAdapterAllowed(address(otherToken), true);

        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    // ── issue #166: callee-gate ordering pin (kept un-allowlisted on purpose) ──

    /// @notice Task 4.2: at least one un-allowlisted-target case must stay in
    ///         this suite so the NEW outer boundary's ordering is pinned here
    ///         too, not only in the dedicated CalleeGate.t.sol suite. A target
    ///         that is neither asset() nor allowlisted is refused before the
    ///         selector switch ever inspects its calldata.
    function test_calleeGateBitesForNonAllowlistedTarget() public {
        address randomTarget = makeAddr("randomTargetNotAllowlisted");
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchCallee.selector, randomTarget));
        _exec(_one(randomTarget, abi.encodeCall(usdc.approve, (adapter, 1e6))));
    }

    function _one(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _exec(BatchExecutorLib.Call[] memory calls) internal {
        vm.prank(address(governor));
        vault.executeGovernorBatch(calls, new uint256[](0), type(uint256).max);
    }

    function _expectDisallowed(address target, bytes4 sel, address recipient) internal {
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferTarget.selector, target, sel, recipient)
        );
    }

    // ── approve / increaseAllowance ──

    /// @notice THE core exfiltration vector: approve moves no balance, so the
    ///         net-outflow meter passes it — the selector guard must not.
    function test_approveToNonAllowlistedReverts() public {
        _expectDisallowed(address(usdc), SEL_APPROVE, attacker);
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (attacker, type(uint256).max))));
    }

    function test_approveToAllowlistedAdapterPasses() public {
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (adapter, 500e6))));
        assertEq(usdc.allowance(address(vault), adapter), 500e6);
    }

    function test_increaseAllowanceToNonAllowlistedReverts() public {
        _expectDisallowed(address(usdc), SEL_INCREASE_ALLOWANCE, attacker);
        _exec(_one(address(usdc), abi.encodeWithSelector(SEL_INCREASE_ALLOWANCE, attacker, type(uint256).max)));
    }

    /// @notice Guard covers EVERY token the vault holds, not just asset() —
    ///         the meter never sees non-asset balances at all.
    function test_approveNonAssetTokenToNonAllowlistedReverts() public {
        otherToken.mint(address(vault), 1_000e18);
        _expectDisallowed(address(otherToken), SEL_APPROVE, attacker);
        _exec(_one(address(otherToken), abi.encodeCall(otherToken.approve, (attacker, type(uint256).max))));
    }

    // ── transfer / transferFrom ──

    function test_transferToNonAllowlistedReverts() public {
        _expectDisallowed(address(usdc), SEL_TRANSFER, attacker);
        _exec(_one(address(usdc), abi.encodeCall(usdc.transfer, (attacker, 1e6))));
    }

    function test_transferToAllowlistedAdapterPasses() public {
        _exec(_one(address(usdc), abi.encodeCall(usdc.transfer, (adapter, 1e6))));
        assertEq(usdc.balanceOf(adapter), 1e6);
    }

    /// @notice issue #115 (LP-allowance confiscation). This test used to be
    ///         `test_transferFromIntoVaultPasses` and pinned "pull into the
    ///         vault always passes" as INTENDED behaviour: it minted `sink`
    ///         100e6, had `sink` approve the vault, then asserted a batch
    ///         `transferFrom(sink, vault, 100e6)` succeeded because `to ==
    ///         vault` reads as an inflow. That is exactly the confiscation
    ///         primitive — a governor batch runs under delegatecall, so
    ///         `msg.sender == vault` on every sub-call, and `transferFrom`
    ///         only needs `allowance[from][vault]` to be set. Any LP's deposit
    ///         allowance (routinely `type(uint256).max`) qualifies; net-outflow
    ///         reads 0 because the vault's OWN balance rises, so no other meter
    ///         sees it. The old assertion was deliberately removed and replaced
    ///         with this regression: the source (`from`) must equal the vault
    ///         itself, unconditionally, or the batch reverts.
    function test_transferFromThirdPartySourceReverts_LPAllowanceConfiscation() public {
        address sink = makeAddr("sink");
        usdc.mint(sink, 100e6);
        vm.prank(sink);
        usdc.approve(address(vault), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, address(usdc), sink)
        );
        _exec(_one(address(usdc), abi.encodeCall(usdc.transferFrom, (sink, address(vault), 100e6))));

        assertEq(usdc.balanceOf(sink), 100e6);
        assertEq(usdc.allowance(sink, address(vault)), type(uint256).max);
    }

    /// @notice Decision 1 (design.md): destination allowlisting confers no
    ///         source consent. `adapter` is allowlisted as a RECIPIENT
    ///         (`isAdapterAllowed`), which says nothing about whether a batch
    ///         may pull FROM it — guards against a future "symmetric" refactor
    ///         that reuses the destination allowlist as a source allowlist.
    function test_transferFromFromAllowlistedAdapterReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, address(usdc), adapter)
        );
        _exec(_one(address(usdc), abi.encodeCall(usdc.transferFrom, (adapter, address(vault), 1e6))));
    }

    /// @notice Decision 4 (design.md): `from == address(this)` stays permitted
    ///         — `transferFrom(vault, x, amt)` is semantically `transfer(x,
    ///         amt)`. The self-approve creates `allowance[vault][vault]`
    ///         (guarded by Part 2, recipient == vault); the pull then spends it
    ///         and lands on an allowlisted adapter.
    function test_vaultSourcedTransferFromToAllowlistedAdapterPasses() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(vault), 1e6)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transferFrom, (address(vault), adapter, 1e6)), value: 0
        });
        _exec(calls);
        assertEq(usdc.balanceOf(adapter), 1e6);
    }

    /// @notice Decision 4 companion: the source guard permits `from == vault`,
    ///         but Part 2's destination guard is untouched — a vault-sourced
    ///         pull to a non-allowlisted recipient still reverts
    ///         `DisallowedTransferTarget`. Also doubles as task 2.4's pinned
    ///         scenario (vault-sourced-to-non-allowlisted-recipient).
    function test_transferFromToNonAllowlistedReverts() public {
        _expectDisallowed(address(usdc), SEL_TRANSFER_FROM, attacker);
        _exec(_one(address(usdc), abi.encodeCall(usdc.transferFrom, (address(vault), attacker, 1e6))));
    }

    /// @notice Self-targets are harmless: approving/transferring to the vault
    ///         itself moves nothing out of custody.
    function test_approveToVaultItselfPasses() public {
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (address(vault), 1e6))));
    }

    // ── malformed calldata ──

    function test_guardedSelectorWithShortCalldataReverts() public {
        // approve selector + 8 bytes of args — cannot hold a full address word.
        vm.expectRevert(ISyndicateVault.MalformedCall.selector);
        _exec(_one(address(usdc), abi.encodePacked(SEL_APPROVE, uint64(0xdead))));
    }

    /// @notice transferFrom selector + a single 32-byte word — no `to`
    ///         argument. Now caught by the SOURCE guard's own length check in
    ///         PART 1 (`data.length < 68`), before Part 2 ever runs — still
    ///         `MalformedCall`, same as before this change, just from a
    ///         different (earlier, unconditional) site.
    function test_transferFromWithOnlyOneArgReverts() public {
        vm.expectRevert(ISyndicateVault.MalformedCall.selector);
        _exec(_one(address(usdc), abi.encodePacked(SEL_TRANSFER_FROM, uint256(uint160(attacker)))));
    }

    /// @notice Registry-less twin of the test above. Decision 2 (design.md)
    ///         accepted side effect: short `transferFrom` calldata now reverts
    ///         `MalformedCall` UNCONDITIONALLY, including with the registry
    ///         unset — previously this calldata was never inspected when the
    ///         registry was unset (Part 2 returned early) and the batch would
    ///         have proceeded to execute.
    function test_transferFromWithOnlyOneArgReverts_RegistryUnset() public {
        governor.setTierRegistry(address(0));
        vm.expectRevert(ISyndicateVault.MalformedCall.selector);
        _exec(_one(address(usdc), abi.encodePacked(SEL_TRANSFER_FROM, uint256(uint160(attacker)))));
    }

    // ── unset registry / legacy governor: guard fails CLOSED (Part 2 only) ──

    /// @notice THIS IS THE FINDING (pashov #1), now inverted. Registry unset on
    ///         the governor used to run the batch UNguarded on the premise that
    ///         "an unset registry already means tier-2/full-notional pricing" —
    ///         but pricing is not a capability gate, and the exact call below,
    ///         `usdc.approve(attacker, 1e6)`, moves zero balance, so the
    ///         net-outflow meter, the per-call caps and `requiredCoverage` all
    ///         read zero while the attacker walks away with a live allowance to
    ///         pull in a later, unmetered transaction.
    function test_unsetRegistry_batchRefused() public {
        governor.setTierRegistry(address(0));
        vm.expectRevert(ISyndicateVault.TierRegistryUnresolved.selector);
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 1e6))));
        assertEq(usdc.allowance(address(vault), attacker), 0, "no allowance was granted");
    }

    /// @notice A governor without the `tierRegistry()` getter (pre-registry
    ///         deployment) resolves like an unset registry — and is refused the
    ///         same way, through the staticcall's `!ok` arm.
    function test_governorWithoutTierGetter_batchRefused() public {
        MockGovernorNoTierGetter legacy = new MockGovernorNoTierGetter();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(legacy)));

        vm.prank(address(legacy));
        vm.expectRevert(ISyndicateVault.TierRegistryUnresolved.selector);
        vault.executeGovernorBatch(
            _one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 1e6))), new uint256[](0), type(uint256).max
        );
        assertEq(usdc.allowance(address(vault), attacker), 0, "no allowance was granted");
    }

    // ── transferFrom source guard (PART 1b) is unconditional — degrade-open coverage ──

    /// @notice Decision 2 (design.md): the source check is UNCONDITIONAL, so it
    ///         must still bite with the registry unset — mirrors the #93
    ///         pattern (`test_targetGate_bitesEvenWithNoTierRegistryWired`).
    ///         The audit-diff placement (inside Part 2) would have let this
    ///         pass; this test pins that it doesn't.
    function test_transferFromSourceGuard_bitesEvenWithNoTierRegistryWired() public {
        governor.setTierRegistry(address(0));
        address sink = makeAddr("sink2");
        usdc.mint(sink, 50e6);
        vm.prank(sink);
        usdc.approve(address(vault), 50e6);

        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, address(usdc), sink)
        );
        _exec(_one(address(usdc), abi.encodeCall(usdc.transferFrom, (sink, address(vault), 50e6))));
    }

    /// @notice Decision 2 companion: same, but for a governor predating the
    ///         `tierRegistry()` getter entirely (mirrors
    ///         `test_targetGate_bitesEvenWhenGovernorHasNoTierGetter`).
    function test_transferFromSourceGuard_bitesEvenWhenGovernorHasNoTierGetter() public {
        MockGovernorNoTierGetter legacy = new MockGovernorNoTierGetter();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(legacy)));

        address sink = makeAddr("sink3");
        usdc.mint(sink, 50e6);
        vm.prank(sink);
        usdc.approve(address(vault), 50e6);

        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, address(usdc), sink)
        );
        vm.prank(address(legacy));
        vault.executeGovernorBatch(
            _one(address(usdc), abi.encodeCall(usdc.transferFrom, (sink, address(vault), 50e6))),
            new uint256[](0),
            type(uint256).max
        );
    }

    // ── non-guarded selectors stay unrestricted ──

    function test_nonGuardedSelectorPassesUntouched() public {
        // balanceOf(address) — harmless read selector routed through the batch.
        _exec(_one(address(usdc), abi.encodeCall(usdc.balanceOf, (attacker))));
    }

    // ── issue #137: metamorphic adapter swap dies in the guard ──

    /// @notice The issue's exact attack path, end to end: an allowlisted
    ///         adapter backed by a REAL contract (not the codeless `adapter`
    ///         fixture at `:44`) has its bytecode swapped at the same address
    ///         after the grant. `isAdapterAllowed`'s lazy self-heal
    ///         (`TierRegistry`, issue #137) closes the funds path on the very
    ///         next read — no `poke`/`demote` call of any kind runs here, and
    ///         the swapped-in bytecode's spender/recipient standing is
    ///         rejected by the vault's batch guard. The adapter is never
    ///         certified (uncertified/tier-2 the whole time), so no
    ///         `TierRegressed` path is even reachable — this suite drives
    ///         `vault.executeGovernorBatch` directly rather than through
    ///         `SyndicateGovernor.executeProposal`.
    function test_metamorphicAdapterSwap_diesInGuard() public {
        ERC20Mock swappedAdapter = new ERC20Mock("Adapter", "ADP", 18);
        tierRegistry.setAdapterAllowed(address(swappedAdapter), true);

        // Sanity: the allowlisted contract adapter passes before the swap.
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (address(swappedAdapter), 1e6))));
        assertEq(usdc.allowance(address(vault), address(swappedAdapter)), 1e6);

        vm.etch(address(swappedAdapter), hex"6001600101");

        _expectDisallowed(address(usdc), SEL_APPROVE, address(swappedAdapter));
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (address(swappedAdapter), 500e6))));
    }

    // ── PR #157 audit remediation: alternate-signature allowance routers ──
    //
    // Finding 1 [90, 3-agent convergence]: `_guardBatchCalls` matched ONLY the
    // four legacy-ERC20 selectors, so Permit2's AllowanceTransfer singleton
    // and DSToken-lineage pull/move exposed the identical "move tokens via
    // delegated allowance" capability under different selectors — completely
    // invisible to both the Part 1b source guard and the Part 2 destination
    // guard. The guard reverts inside `_guardBatchCalls`, BEFORE the batch
    // ever delegatecalls into its targets, so these tests use a bare address
    // stand-in for Permit2/DSToken (no mock contract needed) — the assertion
    // is purely about the guard's own selector/offset decoding.
    address permit2 = makeAddr("permit2");
    address dstoken = makeAddr("dstoken");

    /// @notice Mirrors the audit's own trace verbatim: a governor batch calls
    ///         `Permit2.transferFrom(victimLP, attacker, amount, token)`. The
    ///         legacy guard's selector match (`_SEL_TRANSFER_FROM`) never
    ///         fires — `0x36c78516 != 0x23b872dd` — so before this fix the
    ///         call passed both Part 1b and Part 2 with zero inspection,
    ///         reproducing the exact single-tx LP-allowance-confiscation bug
    ///         PR #157 exists to close, just routed through Permit2.
    function test_permit2TransferFromThirdPartySourceReverts_LPAllowanceConfiscation() public {
        address victimLP = makeAddr("victimLP");
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, permit2, victimLP)
        );
        _exec(
            _one(
                permit2,
                abi.encodeWithSelector(SEL_PERMIT2_TRANSFER_FROM, victimLP, attacker, uint160(1_000e6), address(usdc))
            )
        );
    }

    /// @notice Companion to the trace above: `from == vault` via Permit2 is
    ///         still permitted, exactly like legacy `transferFrom` (Decision 4,
    ///         design.md) — the guard's Permit2 recognition is symmetric with
    ///         the legacy selector it stands in for, not a one-sided
    ///         restriction.
    function test_permit2TransferFromVaultSourceToAllowlistedAdapterPasses() public {
        _exec(
            _one(
                permit2,
                abi.encodeWithSelector(
                    SEL_PERMIT2_TRANSFER_FROM, address(vault), adapter, uint160(1_000e6), address(usdc)
                )
            )
        );
    }

    /// @notice Second confirmed attack shape from the audit: a governor batch
    ///         calls `Permit2.approve(token, attacker, max, max)` — invisible
    ///         to the legacy guard's selector match (`0x87517c45 !=
    ///         0x095ea7b3`), reopening the pre-existing two-tx
    ///         poison-then-drain bug Part 2 exists to close, just routed
    ///         through Permit2. Permit2's `approve` carries an extra leading
    ///         `token` arg vs legacy `approve`, shifting the guarded `spender`
    ///         to arg 2 (bytes 36:68) — this test also pins that offset.
    function test_permit2ApproveToNonAllowlistedSpenderReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, permit2, SEL_PERMIT2_APPROVE, attacker
            )
        );
        _exec(
            _one(
                permit2,
                abi.encodeWithSelector(
                    SEL_PERMIT2_APPROVE, address(usdc), attacker, uint160(type(uint160).max), uint48(type(uint48).max)
                )
            )
        );
    }

    function test_permit2ApproveToAllowlistedAdapterPasses() public {
        _exec(
            _one(
                permit2,
                abi.encodeWithSelector(SEL_PERMIT2_APPROVE, address(usdc), adapter, uint160(1_000e6), uint48(0))
            )
        );
    }

    /// @notice DSToken `pull(usr, wad)` always pulls TO msg.sender (the vault,
    ///         under delegatecall) — same class of bypass as Permit2's
    ///         transferFrom, just a two-argument selector with no explicit
    ///         `to`.
    function test_dstokenPullThirdPartySourceReverts() public {
        address victim = makeAddr("dstokenVictim");
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, dstoken, victim));
        _exec(_one(dstoken, abi.encodeWithSelector(SEL_DSTOKEN_PULL, victim, 1_000e18)));
    }

    /// @notice DSToken `move(src, dst, wad)` — source at bytes 4:36 like
    ///         `transferFrom`; Part 1b must catch a non-vault `src`
    ///         regardless of `dst`.
    function test_dstokenMoveThirdPartySourceReverts() public {
        address victim = makeAddr("dstokenVictim2");
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, dstoken, victim));
        _exec(_one(dstoken, abi.encodeWithSelector(SEL_DSTOKEN_MOVE, victim, attacker, 1_000e18)));
    }

    /// @notice Vault-sourced DSToken `move` to a non-allowlisted destination
    ///         still hits the Part 2 destination guard (dst at bytes 36:68) —
    ///         same shape as the legacy `test_transferFromToNonAllowlistedReverts`.
    function test_dstokenMoveVaultSourceToNonAllowlistedReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, dstoken, SEL_DSTOKEN_MOVE, attacker
            )
        );
        _exec(_one(dstoken, abi.encodeWithSelector(SEL_DSTOKEN_MOVE, address(vault), attacker, 1_000e18)));
    }

    // ── PR #157 audit remediation: self-transfer fast-path scoped to asset() ──
    //
    // Finding 2 [80]: Part 2's `recipient == address(this) -> continue`
    // exempted ANY token whose destination decoded to the vault, not only
    // `asset()` — the one token the outer `netOutflow` balance-diff meter in
    // `executeGovernorBatch` actually verifies. A non-standard token the
    // vault holds as a strategy position could execute arbitrary logic under
    // `transferFrom(vault, vault, amount)` with zero verification anywhere in
    // the pipeline.

    /// @notice The audit's exact attack shape: `EvilToken.transferFrom(vault,
    ///         vault, amount)` on a token that is neither `asset()` nor
    ///         allowlisted in the TierRegistry. Before this fix, `recipient ==
    ///         vault` short-circuited straight past the registry check
    ///         regardless of which token — this must now revert.
    function test_nonAssetSelfTransferFastPathNoLongerExempt() public {
        otherToken.mint(address(vault), 1_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector,
                address(otherToken),
                SEL_TRANSFER_FROM,
                address(vault)
            )
        );
        _exec(
            _one(
                address(otherToken), abi.encodeCall(otherToken.transferFrom, (address(vault), address(vault), 1_000e18))
            )
        );
    }

    /// @notice `asset()` itself keeps the fast-path: it is the one token the
    ///         outer net-outflow meter independently verifies via a balance
    ///         diff, so a vault-to-vault self-transfer of `asset()` is still
    ///         exempt from the registry check (same self-approve pattern as
    ///         `test_vaultSourcedTransferFromToAllowlistedAdapterPasses`).
    function test_assetSelfTransferFastPathStillExempt() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(vault), 1e6)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({
            target: address(usdc),
            data: abi.encodeCall(usdc.transferFrom, (address(vault), address(vault), 1e6)),
            value: 0
        });
        _exec(calls);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
    }

    // ── PR #157 audit ROUND 3: four more sibling selectors missed by round
    // 2's own remediation, on the exact routers/standards it claimed to
    // cover (Permit2, DSToken) plus one it didn't touch at all (ERC1363).
    // Same reasoning as the round-2 tests above: the guard reverts inside
    // `_guardBatchCalls` before ever delegatecalling into its targets, so
    // these use bare address stand-ins — no mock router contract needed.

    bytes4 constant SEL_DSTOKEN_PUSH = 0xb753a98c; // DSToken push(address,uint256)
    bytes4 constant SEL_ERC1363_TRANSFER_FROM_AND_CALL = 0xd8fbe994; // ERC1363 transferFromAndCall(address,address,uint256)
    bytes4 constant SEL_ERC1363_TRANSFER_FROM_AND_CALL_DATA = 0xc1d34b89; // ERC1363 transferFromAndCall(address,address,uint256,bytes)
    bytes4 constant SEL_ERC1363_APPROVE_AND_CALL = 0x3177029f; // ERC1363 approveAndCall(address,uint256)
    bytes4 constant SEL_ERC1363_APPROVE_AND_CALL_DATA = 0xcae9ca51; // ERC1363 approveAndCall(address,uint256,bytes)
    bytes4 constant SEL_PERMIT2_BATCH_TRANSFER_FROM = 0x0d58b1db; // Permit2 AllowanceTransfer.transferFrom(AllowanceTransferDetails[])

    address erc1363Token = makeAddr("erc1363Token");

    /// @dev Test-side mirror of Permit2's `AllowanceTransferDetails` — only
    ///      used to `abi.encode` a batch selector's calldata, never to call
    ///      Permit2 itself.
    struct PermitBatchDetail {
        address from;
        address to;
        uint160 amount;
        address token;
    }

    /// @notice DSToken `push(dst, wad)` is `transfer`'s sibling — dst at
    ///         bytes 4:36, same offset as `_SEL_TRANSFER`, missed by round 2
    ///         even though `pull`/`move` were added for the same lineage.
    function test_dstokenPushToNonAllowlistedReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, dstoken, SEL_DSTOKEN_PUSH, attacker
            )
        );
        _exec(_one(dstoken, abi.encodeWithSelector(SEL_DSTOKEN_PUSH, attacker, 1_000e18)));
    }

    function test_dstokenPushToAllowlistedAdapterPasses() public {
        _exec(_one(dstoken, abi.encodeWithSelector(SEL_DSTOKEN_PUSH, adapter, 1_000e18)));
    }

    /// @notice Round-3 audit's most severe finding: ERC1363
    ///         `transferFromAndCall(from, to, amount)` has the identical
    ///         `from`/`to` layout as legacy `transferFrom` but a different
    ///         selector — reproduces the exact LP-allowance-confiscation
    ///         shape as `test_permit2TransferFromThirdPartySourceReverts_LPAllowanceConfiscation`,
    ///         just on a third router.
    function test_erc1363TransferFromAndCallThirdPartySourceReverts_LPAllowanceConfiscation() public {
        address victimLP = makeAddr("erc1363VictimLP");
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, erc1363Token, victimLP)
        );
        _exec(
            _one(erc1363Token, abi.encodeWithSelector(SEL_ERC1363_TRANSFER_FROM_AND_CALL, victimLP, attacker, 1_000e18))
        );
    }

    /// @notice The 4-arg `bytes` overload's trailing `data` parameter must
    ///         not shift the `from`/`to` offsets — same source guard must
    ///         fire.
    function test_erc1363TransferFromAndCallDataOverloadThirdPartySourceReverts() public {
        address victimLP = makeAddr("erc1363VictimLP2");
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, erc1363Token, victimLP)
        );
        _exec(
            _one(
                erc1363Token,
                abi.encodeWithSelector(SEL_ERC1363_TRANSFER_FROM_AND_CALL_DATA, victimLP, attacker, 1_000e18, bytes(""))
            )
        );
    }

    function test_erc1363TransferFromAndCallVaultSourceToAllowlistedAdapterPasses() public {
        _exec(
            _one(
                erc1363Token,
                abi.encodeWithSelector(SEL_ERC1363_TRANSFER_FROM_AND_CALL, address(vault), adapter, 1_000e18)
            )
        );
    }

    /// @notice ERC1363 `approveAndCall(spender, amount)` reopens the exact
    ///         poison-then-drain shape `test_permit2ApproveToNonAllowlistedSpenderReverts`
    ///         closes for Permit2's `approve` — same `[4:36]` spender offset
    ///         as legacy `approve`.
    function test_erc1363ApproveAndCallToNonAllowlistedSpenderReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, erc1363Token, SEL_ERC1363_APPROVE_AND_CALL, attacker
            )
        );
        _exec(_one(erc1363Token, abi.encodeWithSelector(SEL_ERC1363_APPROVE_AND_CALL, attacker, type(uint256).max)));
    }

    function test_erc1363ApproveAndCallDataOverloadToNonAllowlistedSpenderReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector,
                erc1363Token,
                SEL_ERC1363_APPROVE_AND_CALL_DATA,
                attacker
            )
        );
        _exec(
            _one(
                erc1363Token,
                abi.encodeWithSelector(SEL_ERC1363_APPROVE_AND_CALL_DATA, attacker, type(uint256).max, bytes(""))
            )
        );
    }

    function test_erc1363ApproveAndCallToAllowlistedAdapterPasses() public {
        _exec(_one(erc1363Token, abi.encodeWithSelector(SEL_ERC1363_APPROVE_AND_CALL, adapter, 1_000e18)));
    }

    // ── Permit2 batch `transferFrom(AllowanceTransferDetails[])` ──
    //
    // Worse than the round-2-fixed single-transfer overload: with zero fix,
    // this selector skipped BOTH the source AND destination guard entirely
    // (fell to Part 2's unconditional `else { continue; }`), so funds never
    // needed to transit the vault at all to evade `netOutflow`. The fix
    // must check EVERY element of the dynamic array, not just the first.

    function test_permit2BatchTransferFromThirdPartySourceReverts_LPAllowanceConfiscation() public {
        address victimLP = makeAddr("permit2BatchVictimLP");
        PermitBatchDetail[] memory details = new PermitBatchDetail[](1);
        details[0] = PermitBatchDetail({from: victimLP, to: attacker, amount: uint160(1_000e6), token: address(usdc)});
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, permit2, victimLP)
        );
        _exec(_one(permit2, abi.encodeWithSelector(SEL_PERMIT2_BATCH_TRANSFER_FROM, details)));
    }

    /// @notice A batch with one vault-sourced element and one third-party
    ///         element must still revert on the bad element — the fix loops
    ///         every array entry rather than stopping at the first.
    function test_permit2BatchTransferFromSecondElementThirdPartySourceReverts() public {
        address victimLP = makeAddr("permit2BatchVictimLP2");
        PermitBatchDetail[] memory details = new PermitBatchDetail[](2);
        details[0] =
            PermitBatchDetail({from: address(vault), to: adapter, amount: uint160(500e6), token: address(usdc)});
        details[1] = PermitBatchDetail({from: victimLP, to: attacker, amount: uint160(500e6), token: address(usdc)});
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, permit2, victimLP)
        );
        _exec(_one(permit2, abi.encodeWithSelector(SEL_PERMIT2_BATCH_TRANSFER_FROM, details)));
    }

    function test_permit2BatchTransferFromVaultSourceToNonAllowlistedDestinationReverts() public {
        PermitBatchDetail[] memory details = new PermitBatchDetail[](1);
        details[0] =
            PermitBatchDetail({from: address(vault), to: attacker, amount: uint160(1_000e6), token: address(usdc)});
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, permit2, SEL_PERMIT2_BATCH_TRANSFER_FROM, attacker
            )
        );
        _exec(_one(permit2, abi.encodeWithSelector(SEL_PERMIT2_BATCH_TRANSFER_FROM, details)));
    }

    function test_permit2BatchTransferFromVaultSourceToAllowlistedAdapterPasses() public {
        PermitBatchDetail[] memory details = new PermitBatchDetail[](2);
        details[0] =
            PermitBatchDetail({from: address(vault), to: adapter, amount: uint160(500e6), token: address(usdc)});
        details[1] =
            PermitBatchDetail({from: address(vault), to: adapter, amount: uint160(500e6), token: address(usdc)});
        _exec(_one(permit2, abi.encodeWithSelector(SEL_PERMIT2_BATCH_TRANSFER_FROM, details)));
    }

    /// @notice A malformed batch call whose calldata is too short to even
    ///         contain the dynamic array's offset/length words must revert
    ///         `MalformedCall`, not decode garbage or panic.
    function test_permit2BatchTransferFromMalformedCallReverts() public {
        vm.expectRevert(ISyndicateVault.MalformedCall.selector);
        _exec(_one(permit2, abi.encodeWithSelector(SEL_PERMIT2_BATCH_TRANSFER_FROM)));
    }

    // ── PR #157 audit ROUND 4: two more gaps found in the direct manual
    // re-audit of round 3 — ERC4626 withdraw/redeem (a third allowance-pull
    // shape, source at arg 2 not arg 0) and ERC1363 transferAndCall (the
    // push-with-callback sibling of transfer/push/approveAndCall, missed
    // the same way DSToken push was missed in round 3).

    bytes4 constant SEL_ERC4626_WITHDRAW = 0xb460af94; // withdraw(uint256,address,address)
    bytes4 constant SEL_ERC4626_REDEEM = 0xba087652; // redeem(uint256,address,address)
    bytes4 constant SEL_ERC1363_TRANSFER_AND_CALL = 0x1296ee62; // transferAndCall(address,uint256)
    bytes4 constant SEL_ERC1363_TRANSFER_AND_CALL_DATA = 0x4000aea0; // transferAndCall(address,uint256,bytes)

    address erc4626Token = makeAddr("erc4626Token");

    /// @notice `withdraw(assets, receiver, owner)` pulls from `owner` via the
    ///         same allowance-spend mechanism as `transferFrom`, but `owner`
    ///         sits at arg 2 (bytes 68:100) — a shape none of round 1-3's
    ///         source-check branches recognized, so this fell through
    ///         completely unguarded. Reproduces the same LP-allowance-
    ///         confiscation shape as the transferFrom/Permit2/DSToken tests
    ///         above, on a fourth (and structurally distinct) offset layout.
    function test_erc4626WithdrawThirdPartyOwnerReverts_LPAllowanceConfiscation() public {
        address victimLP = makeAddr("erc4626VictimLP");
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, erc4626Token, victimLP)
        );
        _exec(_one(erc4626Token, abi.encodeWithSelector(SEL_ERC4626_WITHDRAW, 1_000e18, attacker, victimLP)));
    }

    function test_erc4626RedeemThirdPartyOwnerReverts_LPAllowanceConfiscation() public {
        address victimLP = makeAddr("erc4626VictimLP2");
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, erc4626Token, victimLP)
        );
        _exec(_one(erc4626Token, abi.encodeWithSelector(SEL_ERC4626_REDEEM, 1_000e18, attacker, victimLP)));
    }

    function test_erc4626WithdrawVaultOwnerToNonAllowlistedReceiverReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, erc4626Token, SEL_ERC4626_WITHDRAW, attacker
            )
        );
        _exec(_one(erc4626Token, abi.encodeWithSelector(SEL_ERC4626_WITHDRAW, 1_000e18, attacker, address(vault))));
    }

    function test_erc4626RedeemVaultOwnerToAllowlistedAdapterPasses() public {
        _exec(_one(erc4626Token, abi.encodeWithSelector(SEL_ERC4626_REDEEM, 1_000e18, adapter, address(vault))));
    }

    function test_erc4626WithdrawMalformedCallReverts() public {
        vm.expectRevert(ISyndicateVault.MalformedCall.selector);
        _exec(_one(erc4626Token, abi.encodeWithSelector(SEL_ERC4626_WITHDRAW, 1_000e18, attacker)));
    }

    /// @notice `transferAndCall(to, value)` moves the VAULT's own funds
    ///         (push, not pull) with the same `[4:36]` recipient offset as
    ///         `transfer`/`push`/`approveAndCall` — missed the same way
    ///         `push` was missed by round 2, on a router round 3 already
    ///         partially covers.
    function test_erc1363TransferAndCallToNonAllowlistedReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, erc1363Token, SEL_ERC1363_TRANSFER_AND_CALL, attacker
            )
        );
        _exec(_one(erc1363Token, abi.encodeWithSelector(SEL_ERC1363_TRANSFER_AND_CALL, attacker, 1_000e18)));
    }

    function test_erc1363TransferAndCallDataOverloadToNonAllowlistedReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector,
                erc1363Token,
                SEL_ERC1363_TRANSFER_AND_CALL_DATA,
                attacker
            )
        );
        _exec(
            _one(
                erc1363Token, abi.encodeWithSelector(SEL_ERC1363_TRANSFER_AND_CALL_DATA, attacker, 1_000e18, bytes(""))
            )
        );
    }

    function test_erc1363TransferAndCallToAllowlistedAdapterPasses() public {
        _exec(_one(erc1363Token, abi.encodeWithSelector(SEL_ERC1363_TRANSFER_AND_CALL, adapter, 1_000e18)));
    }
}
