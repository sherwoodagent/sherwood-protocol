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
import {BlacklistingERC20Mock} from "../mocks/BlacklistingERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @title Governor_proposeTargetValidation
/// @notice Issue #118 — propose-time coverage that doesn't fit the lifecycle
///         file's real-attack-trace framing: the `executeCalls`-side rejection,
///         the single-sourced predicate's parity with the execution-time guard,
///         its degrade-open behavior against a vault that predates the view,
///         and the `claimUnclaimedFees` reentrancy-latch addition.
///
///         The six-step-trace and settlement-batch scenarios (the two
///         propose-time rejections that are #118's actual reported bugs) live
///         in `Vault_batchQueueTargets_lifecycle.t.sol`, alongside the retired
///         `unstick` test and the still-working honest-calls path.
contract GovernorProposeTargetValidationTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ProtocolConfig protocolConfig;
    MockRegistryMinimal guardianRegistry;
    MockAgentRegistry agentRegistry;
    BlacklistingERC20Mock usdc;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address voter = makeAddr("voter");
    address attacker = makeAddr("attacker");
    address protocolRecipient = makeAddr("protocolRecipient");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant STRATEGY_DURATION = 7 days;
    uint256 constant SELF_SETTLE_FLOOR = 1 hours;

    function setUp() public {
        usdc = new BlacklistingERC20Mock("USD Coin", "USDC", 6);
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
                    managementFeeBps: 50
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        // Test contract acts as factory; queue is deployed and bound by it.
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(protocolRecipient);

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

        usdc.mint(voter, 100_000e6);
        vm.startPrank(voter);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, voter);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── helpers ──

    function _noCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    /// @dev A call that clears both halves of the guard and moves nothing: a
    ///      view selector on the asset token.
    function _benignCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.balanceOf, (address(vault))), value: 0
        });
    }

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

    function _vaultSelfCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(vault), data: abi.encodeCall(ISyndicateVault.reservedQueueAssets, ()), value: 0});
    }

    function _voteAndAdvance(uint256 pid) internal {
        vm.prank(voter);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    // ── executeCalls-side rejection ──

    /// @notice The execute leg gets the same treatment as the settlement leg
    ///         (both pinned in the lifecycle file): a batch that names the
    ///         vault itself in `executeCalls` is rejected at `propose`,
    ///         sparing a vote cycle on a proposal `executeProposal` could
    ///         never run.
    function test_propose_rejectsVaultTargetInExecuteCalls() public {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(vault)));
        governor.propose(
            address(vault), address(0), "ipfs://p", STRATEGY_DURATION, env, _vaultSelfCalls(), _benignCalls(), _noCoProposers()
        );
    }

    /// @notice Sanity: an honest proposal (no privileged targets in either
    ///         array) is unaffected by the new check.
    function test_propose_acceptsBenignProposal() public {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault), address(0), "ipfs://p", STRATEGY_DURATION, env, _benignCalls(), _benignCalls(), _noCoProposers()
        );
        assertGt(pid, 0, "benign proposal is accepted at propose");
    }

    // ── predicate parity ──

    /// @notice The view and the guard are two callers of one predicate: it
    ///         must answer true for exactly the two addresses
    ///         `executeGovernorBatch` would reject as targets, and false for
    ///         everything else — an adapter, the asset token, and the zero
    ///         address.
    function test_isPrivilegedBatchTarget_matchesGuardDecisions() public {
        address adapter = makeAddr("adapter");

        assertTrue(vault.isPrivilegedBatchTarget(address(vault)), "vault itself is privileged");
        assertTrue(vault.isPrivilegedBatchTarget(address(queue)), "bound queue is privileged");
        assertFalse(vault.isPrivilegedBatchTarget(address(usdc)), "the asset token is not privileged");
        assertFalse(vault.isPrivilegedBatchTarget(adapter), "an arbitrary adapter address is not privileged");
        assertFalse(vault.isPrivilegedBatchTarget(address(0)), "the zero address is not privileged");
    }

    // ── degrade-open ──

    /// @notice A vault that predates `isPrivilegedBatchTarget` must not brick
    ///         `propose`. Simulated by making the EXTERNAL selector revert
    ///         (`vm.mockCallRevert` intercepts the CALL/STATICCALL opcode
    ///         only) — the INTERNAL `_isPrivilegedBatchTarget` that
    ///         `_guardBatchCalls` actually calls is reached via a JUMP, never
    ///         a CALL, so it is untouched and the execution-time guard stays
    ///         authoritative.
    function test_propose_degradesOpen_whenVaultLacksPredicateView() public {
        vm.mockCallRevert(
            address(vault), abi.encodeWithSelector(ISyndicateVault.isPrivilegedBatchTarget.selector), bytes("no view")
        );

        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://p",
            STRATEGY_DURATION,
            env,
            _queueRedeemCalls(1e6, 1),
            _benignCalls(),
            _noCoProposers()
        );
        assertGt(pid, 0, "propose accepted a queue-targeting batch when the view is unavailable");

        _voteAndAdvance(pid);

        // The authoritative layer is unchanged: executeGovernorBatch's guard
        // fires exactly as it always has, mock or no mock.
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        governor.executeProposal(pid);
    }

    // ── claimUnclaimedFees reentrancy latch ──

    /// @notice A batch that re-enters `claimUnclaimedFees` mid-execution now
    ///         reverts the whole batch, instead of no-oping as it did before
    ///         this change. Constructed as the design doc traces it: a
    ///         governor entrypoint holds the reentrancy latch through
    ///         `executeGovernorBatch`, and a sub-call whose target is the
    ///         governor itself (not denylisted — only the vault and its
    ///         queue are) calls back into `claimUnclaimedFees`.
    /// @dev    The escrow key the reentrant call resolves is
    ///         `(vault, msg.sender, token)` with `msg.sender == vault`
    ///         (delegatecall), so it only has anything to pay if a fee
    ///         recipient is literally the vault's own address — configured
    ///         here via the protocol-fee recipient, forced to escrow rather
    ///         than pay by blacklisting the vault as a transfer recipient
    ///         (even a self-transfer reverts once blacklisted).
    function test_claimUnclaimedFees_reentrantMidBatch_reverts() public {
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(address(vault));
        usdc.setBlacklisted(address(vault), true);

        ISyndicateGovernor.RiskEnvelope memory env1 = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        uint256 pid1 = governor.propose(
            address(vault), address(0), "ipfs://p1", STRATEGY_DURATION, env1, _benignCalls(), _benignCalls(), _noCoProposers()
        );
        _voteAndAdvance(pid1);
        governor.executeProposal(pid1);

        vm.warp(vm.getBlockTimestamp() + SELF_SETTLE_FLOOR + 1);
        vm.prank(agent);
        governor.settleProposal(pid1);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN_PERIOD + 1);

        uint256 escrowed = governor.unclaimedFees(address(vault), address(vault), address(usdc));
        assertGt(escrowed, 0, "escrow populated at the (vault, vault, token) key");

        BatchExecutorLib.Call[] memory reentrantCall = new BatchExecutorLib.Call[](1);
        reentrantCall[0] = BatchExecutorLib.Call({
            target: address(governor),
            data: abi.encodeCall(ISyndicateGovernor.claimUnclaimedFees, (address(vault), address(usdc))),
            value: 0
        });

        ISyndicateGovernor.RiskEnvelope memory env2 = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        uint256 pid2 = governor.propose(
            address(vault), address(0), "ipfs://p2", STRATEGY_DURATION, env2, reentrantCall, _benignCalls(), _noCoProposers()
        );
        _voteAndAdvance(pid2);

        vm.expectRevert(ISyndicateGovernor.Reentrancy.selector);
        governor.executeProposal(pid2);

        // The escrow survives untouched: the reentrant attempt failed the
        // whole batch instead of silently paying out mid-execution.
        assertEq(
            governor.unclaimedFees(address(vault), address(vault), address(usdc)), escrowed, "escrow unaffected"
        );
    }

    /// @notice The latch changes nothing for the legitimate pull path: an
    ///         ordinary external call (outside any governor call frame) with
    ///         a populated escrow slot still pays out exactly as before.
    function test_claimUnclaimedFees_ordinaryClaim_stillPaysUnderLatch() public {
        usdc.setBlacklisted(protocolRecipient, true);

        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault), address(0), "ipfs://p", STRATEGY_DURATION, env, _benignCalls(), _benignCalls(), _noCoProposers()
        );
        _voteAndAdvance(pid);
        governor.executeProposal(pid);

        vm.warp(vm.getBlockTimestamp() + SELF_SETTLE_FLOOR + 1);
        vm.prank(agent);
        governor.settleProposal(pid);

        uint256 escrowed = governor.unclaimedFees(address(vault), protocolRecipient, address(usdc));
        assertGt(escrowed, 0, "fee escrowed while blacklisted");

        usdc.setBlacklisted(protocolRecipient, false);
        vm.prank(protocolRecipient);
        governor.claimUnclaimedFees(address(vault), address(usdc));

        assertEq(usdc.balanceOf(protocolRecipient), escrowed, "latch does not block the ordinary pull path");
        assertEq(governor.unclaimedFees(address(vault), protocolRecipient, address(usdc)), 0, "escrow cleared");
    }
}
