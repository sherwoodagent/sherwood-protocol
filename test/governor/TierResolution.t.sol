// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @notice Task 5 — propose-time tier resolution (spec 2026-07-22 §3.2). The
///         proposal's tier is the MAX tier across its execute calls (resolved
///         through the TierRegistry) and `requiredCoverage` is the
///         extractable-value figure Plan B's aggregate exposure cap consumes.
///         With no registry wired everything is tier 2 / full notional — the
///         safe default.
contract TierResolutionTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public mockAdapter;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;
    TierRegistry public tierRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant MAX_CAPITAL = 1_000e6;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        // Any contract works as the certified target; certify snapshots its
        // EXTCODEHASH, so the target must have code.
        mockAdapter = new ERC20Mock("Adapter", "ADP", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        tierRegistry = new TierRegistry(address(this));

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 50
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
                address(this), // factory (test contract)
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
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        vm.startPrank(owner);
        vault.registerAgent(agentRegistry.mint(agent), agent);
        vm.stopPrank();

        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Wires the TierRegistry into the governor (test contract is factory)
    ///      and allowlists the harness targets so the vault's value-moving-
    ///      selector guard (findings 1+7) passes their approve calls — with a
    ///      wired registry, onboarding an adapter now means certify + allowlist.
    function _wireTierRegistry() internal {
        governor.setTierRegistry(address(tierRegistry));
        tierRegistry.setAdapterAllowed(address(mockAdapter), true);
        tierRegistry.setAdapterAllowed(address(usdc), true);
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(mockAdapter), 0)), value: 0
        });
    }

    function _propose(BatchExecutorLib.Call[] memory executeCalls) internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://tier-resolution",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            executeCalls,
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @dev A call hitting the certified (mockAdapter, approve) pair.
    function _certifiedCall() internal view returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.approve, (address(usdc), 1)), value: 0
        });
    }

    /// @notice Every call (execute AND settlement — finding 5 counts both)
    ///         certified at tier 0 with a 50 bps bound → proposal tier 0,
    ///         coverage = Σ per-call bounds = 150 bps of maxCapital.
    function test_allCertifiedTier0CallsYieldTier0Coverage() public {
        _wireTierRegistry();
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));
        tierRegistry.certify(address(usdc), usdc.approve.selector, 0, 50, address(0)); // the settle call

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = _certifiedCall();
        calls[1] = _certifiedCall();
        uint256 pid = _propose(calls);

        assertEq(governor.getProposalTier(pid), 0);
        // (50 + 50 exec) + (50 settle) = 150 bps of 1_000e6
        assertEq(governor.getRequiredCoverage(pid), 15e6);
    }

    /// @notice One certified tier-0 call plus one uncertified selector → the MAX
    ///         tier wins: proposal is tier 2, and the uncertified calls each
    ///         contribute full notional (10_000 bps) to the coverage sum.
    function test_oneUncertifiedCallMakesProposalTier2() public {
        _wireTierRegistry();
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = _certifiedCall();
        calls[1] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.transfer, (address(usdc), 1)), value: 0
        });
        uint256 pid = _propose(calls);

        assertEq(governor.getProposalTier(pid), 2);
        // 50 (certified exec) + 10_000 (uncertified exec) + 10_000 (uncertified
        // settle) = 20_050 bps of 1_000e6
        assertEq(governor.getRequiredCoverage(pid), 2_005e6);
    }

    /// @notice Registry unset (address(0)) → everything defaults to tier 2 /
    ///         full notional, even for calls a registry would have certified.
    function test_zeroTierRegistryAddressDefaultsAllToTier2() public {
        // Deliberately NOT wired; certification alone must not matter.
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);

        assertEq(governor.getProposalTier(pid), 2);
        assertEq(governor.getRequiredCoverage(pid), MAX_CAPITAL);
    }

    /// @notice Calldata shorter than 4 bytes cannot carry a selector — it
    ///         resolves as selector 0, which is uncertified → tier 2.
    function test_shortCalldataResolvesAsUncertifiedTier2() public {
        _wireTierRegistry();
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: address(mockAdapter), data: hex"aabb", value: 0});
        uint256 pid = _propose(calls);

        assertEq(governor.getProposalTier(pid), 2);
        // 10_000 (short-calldata exec) + 10_000 (uncertified settle) bps
        assertEq(governor.getRequiredCoverage(pid), 2 * MAX_CAPITAL);
    }

    /// @notice Finding 5(a): mixed tier-0 (50 bps) + tier-1 (200 bps) calls →
    ///         proposal tier is the MAX (1, not 2), and coverage is the SUM of
    ///         per-call bounds — 50 + 200 + 50 (settle) = 300 bps — NOT the
    ///         single max bound (200 bps). Two adapters can each extract their
    ///         own bound; a max under-counts multi-adapter batches.
    function test_mixedTier0AndTier1CoverageIsSumNotMax() public {
        _wireTierRegistry();
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));
        tierRegistry.certify(address(mockAdapter), mockAdapter.transfer.selector, 1, 200, address(0));
        tierRegistry.certify(address(usdc), usdc.approve.selector, 0, 50, address(0)); // the settle call

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = _certifiedCall(); // tier 0, 50 bps
        calls[1] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.transfer, (address(usdc), 1)), value: 0
        }); // tier 1, 200 bps
        uint256 pid = _propose(calls);

        assertEq(governor.getProposalTier(pid), 1); // max(0, 1)
        assertEq(governor.getRequiredCoverage(pid), 30e6); // Σ = 300 bps of 1_000e6, not max(200)
    }

    // ── Task 6: execute-time tier regression fail-safe (spec §3.2) ──

    /// @dev Advance a freshly proposed single-proposer proposal past its voting
    ///      window. With `reviewPeriod == 0` (MockRegistryMinimal), the vote
    ///      window closing maps straight to Approved — the executable state.
    function _advancePastVoting() internal {
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    /// @notice A proposal priced at tier 0 whose adapter demotes (codehash
    ///         change) between propose and execute is now under-covered. The
    ///         execute-time re-resolve sees liveTier 2 > envelopeTier 0 and
    ///         reverts TierRegressed rather than running the batch at the
    ///         stale bounded-tier coverage price.
    function test_executeRevertsWhenTierRegressedSincePropose() public {
        _wireTierRegistry();
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 0); // envelopeTier snapshotted at propose

        _advancePastVoting();

        // Adapter's live codehash changes (proxy upgrade / etch) → the lazy
        // fail-safe in TierRegistry.tierOf now reports tier 2 for the call.
        vm.etch(address(mockAdapter), address(executorLib).code);
        (uint8 liveTier,) = tierRegistry.tierOf(address(mockAdapter), mockAdapter.approve.selector);
        assertEq(liveTier, 2); // demoted since propose

        vm.expectRevert(ISyndicateGovernor.TierRegressed.selector);
        governor.executeProposal(pid);
    }

    /// @notice Finding 5(b): a demoted-then-RE-certified adapter at the SAME
    ///         tier but with a HIGHER extractableBoundBps passes the tier-only
    ///         check (liveTier == envelopeTier) while the stored
    ///         requiredCoverage is stale-low. The execute-time re-resolve must
    ///         catch the coverage regression.
    function test_executeRevertsWhenCoverageRegressedAtSameTier() public {
        _wireTierRegistry();
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));
        tierRegistry.certify(address(usdc), usdc.approve.selector, 0, 50, address(0)); // the settle call

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 0);
        assertEq(governor.getRequiredCoverage(pid), 10e6); // (50 + 50) bps of 1_000e6

        _advancePastVoting();

        // Same tier 0, 10x the extractable bound → tier check passes, the
        // coverage check must not.
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 500, address(0));
        (uint8 liveTier,) = tierRegistry.tierOf(address(mockAdapter), mockAdapter.approve.selector);
        assertEq(liveTier, 0); // NOT a tier regression

        vm.expectRevert(ISyndicateGovernor.CoverageRegressed.selector);
        governor.executeProposal(pid);
    }

    /// @notice Same tier-0 proposal, adapter untouched between propose and
    ///         execute: the live tier still resolves to 0 (== envelopeTier), so
    ///         execution proceeds normally to Executed.
    function test_executeSucceedsWhenTierUnchanged() public {
        _wireTierRegistry();
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 0);

        _advancePastVoting();

        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    // ── ADR 2026-07-27: protocol tier ceiling (ProtocolConfig.maxEnvelopeTier) ──

    /// @dev Seats the protocol-wide ceiling. `governor.protocolConfig()` is read
    ///      BEFORE `vm.prank` on purpose — a call in ARGUMENT position consumes
    ///      the pending one-shot prank, which has bitten this repo repeatedly.
    function _setCeiling(uint8 ceiling) internal {
        ProtocolConfig cfg = ProtocolConfig(governor.protocolConfig());
        vm.prank(owner);
        cfg.setMaxEnvelopeTier(ceiling);
    }

    /// @dev Certifies the settlement call (usdc.approve) at `tier`, so a test can
    ///      control the proposal's MAX tier purely through its execute calls.
    function _certifySettleAt(uint8 tier) internal {
        tierRegistry.certify(address(usdc), usdc.approve.selector, tier, 50, address(0));
    }

    /// @notice A proposal resolving to tier 2 is refused AT PROPOSE under the
    ///         launch ceiling of 1. Tier 2 is what `TierRegistry` reports for an
    ///         uncertified `(target, selector)`, so this is the load-bearing
    ///         consequence of the ADR: no proposal may execute an uncertified
    ///         call, and certification becomes a launch prerequisite.
    function test_tier2ProposalRefusedAtProposeUnderLaunchCeiling() public {
        _wireTierRegistry();
        _setCeiling(1);
        _certifySettleAt(0);

        // Deliberately uncertified selector → tier 2.
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.transfer, (address(usdc), 1)), value: 0
        });

        vm.expectRevert(ISyndicateGovernor.EnvelopeTierTooHigh.selector);
        _propose(calls);
    }

    /// @notice THE test that earns the second check site. A proposal is tier 1
    ///         at propose — comfortably under the ceiling — and the adapter
    ///         DEMOTES to tier 2 before execute (codehash change, exactly as the
    ///         `TierRegressed` test models it). A ceiling enforced only at
    ///         propose would run this batch at tier 2, the tier the ADR exists
    ///         to refuse.
    ///
    ///         The revert is `EnvelopeTierTooHigh`, not `TierRegressed`: both
    ///         conditions hold, and the ceiling is the more informative one —
    ///         its remedy is "certify this adapter", whereas re-proposing (the
    ///         `TierRegressed` remedy) would now fail at propose too.
    function test_tier1DemotedToTier2IsRefusedAtExecute() public {
        _wireTierRegistry();
        _setCeiling(1);
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 1, 200, address(0));
        _certifySettleAt(0);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 1); // within the ceiling at propose

        _advancePastVoting();

        // Lazy demotion: live codehash no longer matches the certified one.
        vm.etch(address(mockAdapter), address(executorLib).code);
        (uint8 liveTier,) = tierRegistry.tierOf(address(mockAdapter), mockAdapter.approve.selector);
        assertEq(liveTier, 2);

        vm.expectRevert(ISyndicateGovernor.EnvelopeTierTooHigh.selector);
        governor.executeProposal(pid);
    }

    /// @dev Certifies the execute call at `tier`, proposes, and asserts the
    ///      proposal both resolves to that tier and executes. Kept as a helper
    ///      so tier 0 and tier 1 get one INDEPENDENT proposal lifecycle each —
    ///      chaining two through one governor drags in settle/cooldown gating
    ///      that has nothing to do with the ceiling.
    function _assertTierProposesAndExecutes(uint8 tier) internal {
        _wireTierRegistry();
        _setCeiling(1);
        _certifySettleAt(0);
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, tier, 200, address(0));

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), tier);

        _advancePastVoting();
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice Tier 0 proposes AND executes normally under the launch ceiling of
    ///         1 — the ceiling refuses tier 2 without narrowing what the ADR
    ///         intends to admit.
    function test_tier0ProposesAndExecutesUnderCeiling1() public {
        _assertTierProposesAndExecutes(0);
    }

    /// @notice Tier 1 — the ceiling value itself — proposes and executes. `>` not
    ///         `>=`: the ceiling is inclusive.
    function test_tier1ProposesAndExecutesUnderCeiling1() public {
        _assertTierProposesAndExecutes(1);
    }

    /// @notice The sentinel means NO ceiling: with `maxEnvelopeTier` left at its
    ///         default `NO_ENVELOPE_TIER_CEILING`, a tier-2 proposal still
    ///         proposes and executes. This is the pre-ADR behaviour every other
    ///         test in this file relies on, pinned explicitly so a future change
    ///         to the default cannot pass silently.
    function test_sentinelDefaultMeansNoCeiling() public {
        _wireTierRegistry();
        ProtocolConfig cfg = ProtocolConfig(governor.protocolConfig());
        assertEq(cfg.maxEnvelopeTier(), cfg.NO_ENVELOPE_TIER_CEILING());
        assertEq(cfg.NO_ENVELOPE_TIER_CEILING(), type(uint8).max);

        // Never certified → tier 2. `approve` (rather than `transfer`) so the
        // batch is actually executable: the point is that tier 2 RUNS here.
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 2);

        _advancePastVoting();
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice THE TRAP TEST. A ceiling of **0** must mean "tier-0 adapters
    ///         only" — the strictest setting — NOT "unset / no ceiling" the way
    ///         `maxStrategyDuration`'s 0 does. If the sentinel were 0 this test
    ///         would fail open: the tier-1 proposal would sail through and
    ///         nothing else in the suite would notice.
    function test_ceilingOfZeroAdmitsTier0() public {
        _wireTierRegistry();
        _setCeiling(0);
        _certifySettleAt(0);
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();

        // 0 is a real ceiling, not a disabled one: tier 0 still goes through.
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 0);
        _advancePastVoting();
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice The other half of the trap: a ceiling of 0 REFUSES tier 1. Under a
    ///         0-means-unset convention this proposal would sail through and
    ///         nothing in the suite would notice — the failure mode is silent,
    ///         which is exactly why the sentinel is `type(uint8).max`.
    function test_ceilingOfZeroRefusesTier1() public {
        _wireTierRegistry();
        _setCeiling(0);
        _certifySettleAt(0);
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 1, 200, address(0));

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();

        vm.expectRevert(ISyndicateGovernor.EnvelopeTierTooHigh.selector);
        _propose(calls);
    }

    /// @notice Lowering the ceiling strands an in-flight proposal whose tier now
    ///         breaches it, with no demotion involved. The second check site
    ///         covers this independently of the codehash path above.
    function test_loweringCeilingRefusesInFlightProposalAtExecute() public {
        _wireTierRegistry();
        _setCeiling(1);
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 1, 200, address(0));
        _certifySettleAt(0);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 1);

        _advancePastVoting();
        _setCeiling(0); // governance tightens while the proposal is Approved

        vm.expectRevert(ISyndicateGovernor.EnvelopeTierTooHigh.selector);
        governor.executeProposal(pid);
    }

    /// @notice Below the ceiling, `TierRegressed` still fires as before — the
    ///         new check does not swallow the condition it sits in front of.
    ///         Adapter is tier 0 at propose and demotes to tier 1; the ceiling
    ///         (1) admits tier 1, so only the snapshot-relative check can catch it.
    function test_tierRegressedStillFiresBelowTheCeiling() public {
        _wireTierRegistry();
        _setCeiling(1);
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50, address(0));
        _certifySettleAt(0);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 0);

        _advancePastVoting();

        // Re-certify at tier 1: still within the ceiling, but WORSE than the snapshot.
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 1, 50, address(0));
        (uint8 liveTier,) = tierRegistry.tierOf(address(mockAdapter), mockAdapter.approve.selector);
        assertEq(liveTier, 1);

        vm.expectRevert(ISyndicateGovernor.TierRegressed.selector);
        governor.executeProposal(pid);
    }
}
