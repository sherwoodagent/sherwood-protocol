// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";

/// @title Vault_batchQueueTargets_lifecycle
/// @notice Issue #93 through the REAL governor lifecycle. The sibling unit file
///         (`Vault_batchQueueTargets.t.sol`) proves what `_guardBatchCalls`
///         rejects, by calling `vault.executeGovernorBatch` directly behind a
///         mocked governor. This file proves the complementary half: that the
///         guard actually sits on the paths an attacker would really use.
///
///         `_guardBatchCalls` being the single chokepoint for every batch path
///         is the load-bearing claim of the fix — it is why one check covers
///         execute, settlement and the emergency paths with no per-entrypoint
///         duplication. A mocked-governor test cannot establish that; only
///         driving `executeProposal` / `settleProposal` / `unstick` end to end
///         can. If someone later routes a batch around `executeGovernorBatch`,
///         the unit tests keep passing and these fail.
///
/// @dev    This governor has NO TierRegistry wired, so `tierRegistry()` returns
///         `address(0)` and the SELECTOR guard degrades open — the documented
///         posture for a registry-less deployment. That makes this harness a
///         second, independent witness for the placement claim: the batches
///         below are stopped by the target denylist alone, sitting above that
///         early return, with the rest of the guard switched off.
contract VaultBatchQueueTargetsLifecycleTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ProtocolConfig protocolConfig;
    MockRegistryMinimal guardianRegistry;
    MockAgentRegistry agentRegistry;
    ERC20Mock usdc;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address victim = makeAddr("victim");
    address voter = makeAddr("voter");
    address attacker = makeAddr("attacker");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant STRATEGY_DURATION = 7 days;
    uint256 constant SELF_SETTLE_FLOOR = 1 hours;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        uint256 agentNftId = agentRegistry.mint(agent);

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
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        // The test contract is the vault's factory (it deployed the proxy), so it
        // binds the queue and answers `governorOf`.
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(protocolConfig),
                address(this), // factory
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        // Lane A off (no PriceRouter) — exercises the async Lane B queue paths.
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));

        usdc.mint(victim, 60_000e6);
        usdc.mint(voter, 40_000e6);
        vm.startPrank(victim);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, victim);
        vm.stopPrank();
        // `voter` keeps its shares for the whole test, so a proposal raised after
        // the victim has escrowed still has live vote weight behind it.
        vm.startPrank(voter);
        usdc.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, voter);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── helpers ──

    function _noCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    /// @dev A call that clears both halves of the guard and moves nothing: a
    ///      view selector on the asset token. Not a privileged target, and not
    ///      one of the four guarded value-moving selectors.
    function _benignCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.balanceOf, (address(vault))), value: 0
        });
    }

    /// @dev The attack payload: forge a redeem claim for the attacker against
    ///      shares somebody else escrowed. Reaches the queue's `onlyVault` gate
    ///      with `msg.sender == vault`, courtesy of the delegatecall.
    function _queueRedeemCalls(uint256 shares, uint256 pid)
        internal
        view
        returns (BatchExecutorLib.Call[] memory calls)
    {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(queue),
            data: abi.encodeCall(IVaultWithdrawalQueue.queueRedeem, (attacker, shares, pid)),
            value: 0
        });
    }

    /// @dev Widest legal envelope at current TVL. Callers MUST hoist the result
    ///      into a local before arming a cheatcode: the `totalAssets()`
    ///      staticcall in here would otherwise consume a pending one-shot
    ///      `vm.prank` or an armed `vm.expectRevert`.
    function _permissiveEnv() internal view returns (ISyndicateGovernor.RiskEnvelope memory) {
        return ISyndicateGovernor.RiskEnvelope({maxCapital: vault.totalAssets(), maxDrawdownBps: 10_000});
    }

    function _proposeAndApprove(
        ISyndicateGovernor.RiskEnvelope memory env,
        BatchExecutorLib.Call[] memory openCalls,
        BatchExecutorLib.Call[] memory settleCalls
    ) internal returns (uint256 pid) {
        vm.prank(agent);
        pid = governor.propose(
            address(vault), address(0), "ipfs://p", STRATEGY_DURATION, env, openCalls, settleCalls, _noCoProposers()
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(voter);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    /// @dev Runs the issue's steps 1-2: a live proposal forces the victim's exit
    ///      through Lane B, then that proposal settles and stamps its price,
    ///      leaving the victim's shares sitting in queue custody unclaimed.
    function _victimEscrowsThenProposalSettles() internal returns (uint256 victimShares) {
        ISyndicateGovernor.RiskEnvelope memory env = _permissiveEnv();
        uint256 pid1 = _proposeAndApprove(env, _benignCalls(), _benignCalls());
        governor.executeProposal(pid1);
        assertTrue(vault.redemptionsLocked(), "a live proposal locks redemptions");

        victimShares = vault.balanceOf(victim);
        vm.prank(victim);
        vault.requestRedeem(victimShares, victim);
        assertEq(vault.balanceOf(address(queue)), victimShares, "the queue custodies the victim's shares");

        vm.warp(vm.getBlockTimestamp() + SELF_SETTLE_FLOOR + 1);
        vm.prank(agent);
        governor.settleProposal(pid1);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN_PERIOD + 1);
    }

    // ── the reported trace, end to end ──

    /// @notice ISSUE #93's SIX-STEP TRACE, driven through `executeProposal`.
    ///           1. the victim `requestRedeem`s; the queue holds their shares
    ///           2. the prior proposal settles and stamps
    ///           3. propose with `maxCapital = 1` and
    ///              `executeCalls = [queueRedeem(attacker, victimShares, pid)]`
    ///           4. it passes review — nothing about it looks expensive: the
    ///              outflow meter reads zero, tier-2 coverage asks for 1 wei
    ///           5. `executeProposal` reaches `vault.executeGovernorBatch`
    ///           6. the target denylist refuses it before any call runs
    ///         Steps 5-6 on unpatched `main` were: the queue mints the attacker
    ///         a claim on the victim's shares, the attacker claims, and the
    ///         victim's own claim then reverts.
    function test_sixStepQueueSteal_isRejectedAtExecuteProposal() public {
        uint256 victimShares = _victimEscrowsThenProposalSettles();

        // A 1-wei envelope: tier-2 coverage is `requiredCoverage == maxCapital`,
        // so the whole steal is underwritten for a rounding error.
        ISyndicateGovernor.RiskEnvelope memory steal =
            ISyndicateGovernor.RiskEnvelope({maxCapital: 1, maxDrawdownBps: 10_000});
        uint256 pid2 = _proposeAndApprove(steal, _queueRedeemCalls(victimShares, 2), _benignCalls());
        assertEq(governor.getProposal(pid2).maxCapital, 1, "1 wei of declared capital");

        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        governor.executeProposal(pid2);

        // The escrow is intact and the victim can still exit — the outcome that
        // actually matters, asserted rather than inferred from the revert.
        assertEq(vault.balanceOf(address(queue)), victimShares, "victim escrow untouched");
        assertEq(queue.pendingShares(), victimShares, "no forged claim was recorded");
        vm.prank(victim);
        uint256 paid = queue.claim(1);
        assertGt(paid, 0, "the victim still claims their assets");
        assertEq(usdc.balanceOf(attacker), 0, "the attacker got nothing");
    }

    /// @notice THE SETTLEMENT BATCH IS THE SAME CHOKEPOINT. Settlement calls are
    ///         arbitrary pre-committed calldata, so a proposal can look harmless
    ///         at execute time and carry the steal in its settle leg — reviewed
    ///         once, long before it runs.
    function test_queueTargetingSettlementBatch_isRejectedAtSettleProposal() public {
        ISyndicateGovernor.RiskEnvelope memory env = _permissiveEnv();
        uint256 pid = _proposeAndApprove(env, _benignCalls(), _queueRedeemCalls(1e6, 1));
        governor.executeProposal(pid);
        vm.warp(vm.getBlockTimestamp() + SELF_SETTLE_FLOOR + 1);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        governor.settleProposal(pid);
    }

    // ── the owner-driven emergency path ──

    /// @notice `unstick` runs the pre-committed settlement calls on the vault
    ///         owner's say-so alone — no guardian review, no fresh vote, no
    ///         coverage quorum. It still routes through `executeGovernorBatch`,
    ///         which is precisely why one guard covers it.
    function test_unstickWithQueueTargetingCalls_reverts() public {
        ISyndicateGovernor.RiskEnvelope memory env = _permissiveEnv();
        uint256 pid = _proposeAndApprove(env, _benignCalls(), _queueRedeemCalls(1e6, 1));
        governor.executeProposal(pid);
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        governor.unstick(pid);
    }

    /// @notice And the emergency path still WORKS for honest calls — the guard
    ///         did not brick the rescue hatch it now polices.
    function test_unstickWithHonestCallsStillSettles() public {
        ISyndicateGovernor.RiskEnvelope memory env = _permissiveEnv();
        uint256 pid = _proposeAndApprove(env, _benignCalls(), _benignCalls());
        governor.executeProposal(pid);
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);

        vm.prank(owner);
        governor.unstick(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertFalse(vault.redemptionsLocked(), "settled: redemptions unlocked again");
    }
}
