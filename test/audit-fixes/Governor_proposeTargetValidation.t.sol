// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlacklistingERC20Mock} from "../mocks/BlacklistingERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {MockStrategyAdapter} from "../mocks/MockStrategyAdapter.sol";

/// @title Governor_proposeTargetValidation
/// @notice Issue #118 — propose-time coverage that doesn't fit the lifecycle
///         file's real-attack-trace framing: a batch naming the vault or the
///         governor is refused at `propose` because neither is a registered
///         strategy, and the `claimUnclaimedFees` re-entry shape never stores.
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

    TierRegistry tierRegistry;
    StrategyFactory strategyFactory;
    MockStrategyAdapter strat;

    /// @dev A real registry wired to a real factory, with one registered strategy for the field.
    function _realRegistry() internal returns (TierRegistry) {
        tierRegistry = new TierRegistry(address(this));
        strategyFactory = new StrategyFactory(address(this), address(this));
        tierRegistry.setStrategyFactory(address(strategyFactory));
        strat = new MockStrategyAdapter();
        strategyFactory.registerStrategy(address(strat));
        return tierRegistry;
    }

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
                address(this),
                address(_realRegistry()),
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

    /// @dev A call that clears the guard and moves nothing: a zero `approve` on the asset.
    function _benignCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(vault), 0)), value: 0
        });
    }

    function _vaultSelfCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(vault), data: abi.encodeCall(ISyndicateVault.ratchetHighWaterMark, ()), value: 0
        });
    }

    function _voteAndAdvance(uint256 pid) internal {
        vm.prank(voter);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    // ── executeCalls-side rejection ──

    /// @notice The execute leg gets the same treatment as the settlement leg (pinned in the
    ///         lifecycle file): the vault is not a registered strategy, so naming it is
    ///         refused at `propose`, sparing a vote cycle on a proposal that could never run.
    function test_propose_rejectsVaultTargetInExecuteCalls() public {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory ex = _vaultSelfCalls();
        BatchExecutorLib.Call[] memory st = _benignCalls();
        uint256[] memory exCaps = GovEnvelope.defaultCaps(env.maxCapital, ex.length);
        uint256[] memory stCaps = GovEnvelope.defaultCaps(env.maxCapital, st.length);
        ISyndicateGovernor.CoProposer[] memory cps = _noCoProposers();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.NotARegisteredStrategy.selector, address(vault)));
        governor.propose(
            address(vault), address(strat), "ipfs://p", STRATEGY_DURATION, env, ex, exCaps, st, stCaps, cps
        );
    }

    /// @notice Sanity: an honest proposal (registered strategy, asset-only calls) is unaffected.
    function test_propose_acceptsBenignProposal() public {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(strat),
            "ipfs://p",
            STRATEGY_DURATION,
            env,
            _benignCalls(),
            GovEnvelope.defaultCaps(env.maxCapital, (_benignCalls()).length),
            _benignCalls(),
            GovEnvelope.defaultCaps(env.maxCapital, (_benignCalls()).length),
            _noCoProposers()
        );
        assertGt(pid, 0, "benign proposal is accepted at propose");
    }

    // ── claimUnclaimedFees reentrancy latch ──

    /// @notice A batch that names the governor is refused at propose: the governor is not a
    ///         registered strategy, so the mid-batch re-entry into `claimUnclaimedFees` the
    ///         reentrancy latch also closes is never stored.
    /// @dev    The escrow key the reentrant call would resolve is `(vault, vault, token)`,
    ///         populated here by paying the protocol fee to the vault's own address while
    ///         the vault is blacklisted as a transfer recipient.
    function test_claimUnclaimedFees_reentrantMidBatch_reverts() public {
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(address(vault));
        usdc.setBlacklisted(address(vault), true);

        ISyndicateGovernor.RiskEnvelope memory env1 = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        uint256 pid1 = governor.propose(
            address(vault),
            address(strat),
            "ipfs://p1",
            STRATEGY_DURATION,
            env1,
            _benignCalls(),
            GovEnvelope.defaultCaps(env1.maxCapital, (_benignCalls()).length),
            _benignCalls(),
            GovEnvelope.defaultCaps(env1.maxCapital, (_benignCalls()).length),
            _noCoProposers()
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
        uint256[] memory caps = GovEnvelope.defaultCaps(env2.maxCapital, 1);
        BatchExecutorLib.Call[] memory settle = _benignCalls();
        ISyndicateGovernor.CoProposer[] memory cps = _noCoProposers();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.NotARegisteredStrategy.selector, address(governor)));
        governor.propose(
            address(vault), address(strat), "ipfs://p2", STRATEGY_DURATION, env2, reentrantCall, caps, settle, caps, cps
        );

        // The escrow survives untouched: the shape never reached execution.
        assertEq(governor.unclaimedFees(address(vault), address(vault), address(usdc)), escrowed, "escrow unaffected");
    }

    /// @notice The latch changes nothing for the legitimate pull path: an
    ///         ordinary external call (outside any governor call frame) with
    ///         a populated escrow slot still pays out exactly as before.
    function test_claimUnclaimedFees_ordinaryClaim_stillPaysUnderLatch() public {
        usdc.setBlacklisted(protocolRecipient, true);

        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(strat),
            "ipfs://p",
            STRATEGY_DURATION,
            env,
            _benignCalls(),
            GovEnvelope.defaultCaps(env.maxCapital, (_benignCalls()).length),
            _benignCalls(),
            GovEnvelope.defaultCaps(env.maxCapital, (_benignCalls()).length),
            _noCoProposers()
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
