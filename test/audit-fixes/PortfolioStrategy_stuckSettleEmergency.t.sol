// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ITierRegistry} from "../../src/interfaces/ITierRegistry.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @notice Permissive registry that also attests every token-feed pairing.
contract PermissiveRegistryWithPairs is ITierRegistry {
    function tierOf(address, bytes4) external pure returns (uint8, uint16) {
        return (2, 10_000);
    }

    function isAdapterAllowed(address) external pure returns (bool) {
        return true;
    }

    function isCallableTarget(address) external pure returns (bool) {
        return true;
    }

    function isCounterpartyAllowed(address) external pure returns (bool) {
        return true;
    }

    /// @dev Permissive mirror of factory provenance: anything that answers
    ///      `vault()` is a class member (the strategy clone under test).
    function classOf(address target) external view returns (bytes32) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("vault()"));
        return ok && ret.length == 32 ? keccak256("permissive-strategy-class") : bytes32(0);
    }

    function isPriceSourceForToken(address, bytes32) external pure returns (bool) {
        return true;
    }
}

/// @notice Settable AggregatorV3 push feed.
contract MockAggregator {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

/// @title PortfolioStrategy_stuckSettleEmergency
/// @notice A real governor/vault/registry stack driving a real `PortfolioStrategy` clone:
///         a settle that lands on a stale feed reverts and leaves the proposal Executed, and
///         the owner's `emergencySettleWithCalls` path recovers it once the feed is live again.
contract PortfolioStrategy_stuckSettleEmergencyTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    GuardianRegistry public registry;
    StakedWood public swood;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    ERC20Mock public tsla;
    MockAgentRegistry public agentRegistry;
    MockSwapAdapter public adapter;
    MockAggregator public feed;
    PortfolioStrategy public template;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public factoryEoa;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;

    uint256 constant DEPLOY_AMOUNT = 50_000e6; // 50k USDC
    uint256 constant STRATEGY_DURATION = 2 days; // longer than MAX_PUSH_PRICE_AGE
    int256 constant TSLA_USD_8DEC = 100e8; // $100

    function setUp() public {
        factoryEoa = address(this);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
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
        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        // sWOOD + Governor + Registry circular init; nonce-predicted addresses.
        ProtocolConfig pc = new ProtocolConfig(owner);
        address tierRegistry = address(new PermissiveRegistryWithPairs());
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedGovernor = vm.computeCreateAddress(address(this), baseNonce + 3);
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 5);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factoryEoa,
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: 7 days,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                predictedRegistryProxy,
                address(pc),
                address(this),
                tierRegistry,
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
        require(address(governor) == predictedGovernor, "governor addr mismatch");

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit =
            abi.encodeCall(GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, 3000));
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        address govVault = governor.vault();
        vm.prank(registry.factory());
        registry.addGovernor(address(governor), govVault);
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");

        vm.prank(owner);
        swood.setRegistry(address(registry));

        usdc.mint(lp1, 100_000e6);
        usdc.mint(lp2, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();
        vm.startPrank(lp2);
        usdc.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);

        wood.mint(owner, 100_000e18);
        vm.prank(owner);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(owner);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.prank(factoryEoa);
        swood.bindOwnerStake(owner, address(vault));

        // Venue at the fair $100 rate both ways, feed at 8 decimals.
        adapter = new MockSwapAdapter();
        adapter.setRate(address(usdc), address(tsla), 1e28); // 1 USDC -> 0.01 TSLA
        adapter.setRate(address(tsla), address(usdc), 1e8); // 1 TSLA -> 100 USDC
        tsla.mint(address(adapter), 1_000_000e18);
        usdc.mint(address(adapter), 100_000_000e6);
        feed = new MockAggregator(8, TSLA_USD_8DEC, vm.getBlockTimestamp());
        template = new PortfolioStrategy();
    }

    function _initData() internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 8;
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        return abi.encode(address(usdc), address(adapter), tokens, weights, DEPLOY_AMOUNT, 100, extra, priceDecs, feeds);
    }

    function _execCalls(address strategy) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(IERC20.approve, (strategy, DEPLOY_AMOUNT)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeCall(BaseStrategy.execute, ()), value: 0});
    }

    function _settleCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeCall(BaseStrategy.settle, ()), value: 0});
    }

    /// @dev Clone + init + propose -> vote -> review -> execute. Returns an EXECUTED proposal.
    function _executedBasket() internal returns (PortfolioStrategy strategy, uint256 pid) {
        strategy = PortfolioStrategy(Clones.clone(address(template)));
        strategy.initialize(address(vault), agent, _initData());

        BatchExecutorLib.Call[] memory execCalls = _execCalls(address(strategy));
        BatchExecutorLib.Call[] memory settleCalls = _settleCalls(address(strategy));
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        // Capital leaves on the second execute call; caps must sum to at most `maxCapital`.
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = DEPLOY_AMOUNT;
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(strategy),
            "ipfs://stuck-settle",
            STRATEGY_DURATION,
            env,
            execCalls,
            execCaps,
            settleCalls,
            GovEnvelope.defaultCaps(env.maxCapital, settleCalls.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        feed.setUpdatedAt(vm.getBlockTimestamp());
        governor.executeProposal(pid);

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));
        assertEq(tsla.balanceOf(address(strategy)), 500e18, "50k USDC at $100 buys 500 TSLA");
    }

    /// @notice The feed last updated at execute; two days later every settle path reverts
    ///         `StalePrice` with the proposal still Executed. The owner opens an emergency
    ///         review; by the time it can finalize the feed is live again and the basket unwinds.
    function test_stuckSettle_isRecoveredByEmergencySettleWithCalls() public {
        (PortfolioStrategy strategy, uint256 pid) = _executedBasket();
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);

        // Both pre-committed settle paths hit the stale feed.
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        governor.settleProposal(pid);
        vm.prank(owner);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        governor.unstick(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));
        assertEq(tsla.balanceOf(address(strategy)), 500e18, "nothing sold on the stale feed");

        // Owner opens the emergency review with the settle call; nothing executes yet.
        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, _settleCalls(address(strategy)));
        assertEq(tsla.balanceOf(address(strategy)), 500e18);

        // Review elapses. The feed is still dark: finalize reverts too, and stays recoverable.
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        vm.prank(owner);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        governor.finalizeEmergencySettle(pid);

        // The feed comes back (Monday): the reviewed calls unwind the basket.
        feed.setUpdatedAt(vm.getBlockTimestamp());
        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);

        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        assertEq(tsla.balanceOf(address(strategy)), 0, "basket fully unwound");
        assertEq(usdc.balanceOf(address(vault)), vaultBefore + DEPLOY_AMOUNT, "capital back at the fair rate");
        assertFalse(vault.redemptionsLocked());
    }

    function _rescueCalls(address strategy) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: strategy, data: abi.encodeCall(BaseStrategy.rescueTo, (address(tsla))), value: 0
        });
        calls[1] = BatchExecutorLib.Call({
            target: strategy, data: abi.encodeCall(BaseStrategy.rescueTo, (address(usdc))), value: 0
        });
    }

    /// @notice A retired feed never comes back: a year on, every settle path still reverts.
    ///         An emergency batch of `rescueTo` per basket token pulls the clone's tokens home
    ///         without a price, `finalizeEmergencySettle` closes the proposal and both locks reopen.
    function test_darkFeedForever_emergencyBatchRescuesTheBasketAndFinalises() public {
        (PortfolioStrategy strategy, uint256 pid) = _executedBasket();

        vm.warp(vm.getBlockTimestamp() + 365 days);

        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        governor.settleProposal(pid);
        vm.prank(owner);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        governor.unstick(pid);
        assertTrue(vault.redemptionsLocked(), "premise: locks shut while Executed");

        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, _rescueCalls(address(strategy)));
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);

        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertEq(tsla.balanceOf(address(strategy)), 0, "basket left on the clone");
        assertEq(usdc.balanceOf(address(strategy)), 0, "asset left on the clone");
        assertEq(tsla.balanceOf(address(vault)), 500e18, "basket not delivered to the vault");
        assertFalse(vault.redemptionsLocked(), "redemptions still locked");
        assertFalse(vault.depositsLocked(), "deposits still locked");
    }

    function test_rescueTo_onlyVault() public {
        (PortfolioStrategy strategy,) = _executedBasket();
        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.rescueTo(address(tsla));
        vm.prank(agent);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.rescueTo(address(tsla));
        assertEq(tsla.balanceOf(address(strategy)), 500e18, "moved without the vault");
    }

    /// @notice The batch guard admits `rescueTo` on the callee axis alone, exactly as it admits
    ///         `settle()`: the selector names no recipient, so `isAdapterAllowed` is never
    ///         consulted (denied here), and denying `isCallableTarget` on the clone refuses it.
    function test_rescueTo_isReachableFromAnEmergencyBatch() public {
        (PortfolioStrategy strategy,) = _executedBasket();
        address tierRegistry = governor.tierRegistry();
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = _rescueCalls(address(strategy))[0];

        vm.mockCall(
            tierRegistry, abi.encodeCall(ITierRegistry.isAdapterAllowed, (address(strategy))), abi.encode(false)
        );
        vm.prank(address(governor));
        vault.executeGovernorBatch(calls, new uint256[](0), 0);
        assertEq(tsla.balanceOf(address(vault)), 500e18, "rescue did not land");

        vm.mockCall(
            tierRegistry, abi.encodeCall(ITierRegistry.isCallableTarget, (address(strategy))), abi.encode(false)
        );
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchCallee.selector, address(strategy)));
        vault.executeGovernorBatch(calls, new uint256[](0), 0);
    }

    /// @notice Control: with a live feed the ordinary `settleProposal` clears at the same point.
    function test_settle_clearsWhenFeedIsLive() public {
        (PortfolioStrategy strategy, uint256 pid) = _executedBasket();
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        feed.setUpdatedAt(vm.getBlockTimestamp());
        governor.settleProposal(pid);

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        assertEq(usdc.balanceOf(address(vault)), vaultBefore + DEPLOY_AMOUNT);
    }
}
