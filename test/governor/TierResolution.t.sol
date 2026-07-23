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
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50);
        tierRegistry.certify(address(usdc), usdc.approve.selector, 0, 50); // the settle call

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
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50);

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
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50);

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
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50);

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
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50);
        tierRegistry.certify(address(mockAdapter), mockAdapter.transfer.selector, 1, 200);
        tierRegistry.certify(address(usdc), usdc.approve.selector, 0, 50); // the settle call

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
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50);

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
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50);
        tierRegistry.certify(address(usdc), usdc.approve.selector, 0, 50); // the settle call

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 0);
        assertEq(governor.getRequiredCoverage(pid), 10e6); // (50 + 50) bps of 1_000e6

        _advancePastVoting();

        // Same tier 0, 10x the extractable bound → tier check passes, the
        // coverage check must not.
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 500);
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
        tierRegistry.certify(address(mockAdapter), mockAdapter.approve.selector, 0, 50);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _certifiedCall();
        uint256 pid = _propose(calls);
        assertEq(governor.getProposalTier(pid), 0);

        _advancePastVoting();

        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Executed));
    }
}
