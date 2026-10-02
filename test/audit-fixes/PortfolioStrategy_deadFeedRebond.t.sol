// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";

/// @notice Settable AggregatorV3 push feed (answer, updatedAt, decimals).
contract RebondFeed {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 d, int256 a, uint256 u) {
        decimals = d;
        _answer = a;
        _updatedAt = u;
    }

    function setUpdatedAt(uint256 u) external {
        _updatedAt = u;
    }

    function setAnswer(int256 a) external {
        _answer = a;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, 0, _updatedAt, 1);
    }
}

/// @title V1-03 regression on the shipped PortfolioStrategy: a dead feed, a blocked round, then a same-owner re-bond.
/// @notice Ported from the audit PoC `test/audit-2026-10-01-v2/V103_portfolioDeadSettleLeg.t.sol` (post-audit-v2).
contract PortfolioStrategy_deadFeedRebondTest is Test {
    SyndicateFactory public factory;
    GuardianRegistry public registry;
    StakedWood public swood;
    TierRegistry public tierRegistry;
    StrategyFactory public strategyFactory;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    ERC20Mock public tsla; // the token whose feed dies
    ERC20Mock public nvda; // healthy
    MockAgentRegistry public agentRegistry;
    MockSwapAdapter public adapter;
    RebondFeed public tslaFeed;
    RebondFeed public nvdaFeed;
    PortfolioStrategy public template;

    SyndicateVault public vault;
    SyndicateGovernor public gov;
    IVaultWithdrawalQueue public queue;
    PortfolioStrategy public strategy;

    address public owner = makeAddr("protocolSafe");
    address public creator = makeAddr("vaultOwner");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public guardianA = makeAddr("guardianA"); // exactly 30% of guardian stake
    address public guardianB = makeAddr("guardianB");
    address public keeper = makeAddr("keeper");
    uint256 public creatorAgentId;

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant STRATEGY_DURATION = 7 days;
    uint256 constant STAKE_A = 30_000e18;
    uint256 constant STAKE_B = 70_000e18;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        tsla = new ERC20Mock("Tesla", "TSLA", 18);
        nvda = new ERC20Mock("Nvidia", "NVDA", 18);
        executorLib = new BatchExecutorLib();
        SyndicateVault vaultImpl = new SyndicateVault();
        agentRegistry = new MockAgentRegistry();
        creatorAgentId = agentRegistry.mint(creator);

        ProtocolConfig _pc = new ProtocolConfig(owner);
        TierRegistry _tr = new TierRegistry(owner);
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 6);
        address predictedFactoryProxy = vm.computeCreateAddress(address(this), baseNonce + 7);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: predictedFactoryProxy,
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
        GovernorBeacon beacon = new GovernorBeacon(address(govImpl), owner);
        SyndicateFactory factoryImpl = new SyndicateFactory();
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, predictedFactoryProxy, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        require(address(registry) == predictedRegistryProxy, "registry prediction");
        vm.prank(owner);
        swood.setRegistry(address(registry));

        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(_pc),
                    managementFeeBps: 50,
                    guardianRegistry: address(registry),
                    tierRegistry: address(_tr)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));
        require(address(factory) == predictedFactoryProxy, "factory prediction");

        tierRegistry = _tr;
        strategyFactory = new StrategyFactory(address(factory), owner);
        vm.prank(owner);
        tierRegistry.setStrategyFactory(address(strategyFactory));

        wood.mint(creator, 100_000e18);
        wood.mint(guardianA, STAKE_A);
        wood.mint(guardianB, STAKE_B);

        vm.startPrank(creator);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        (, address v) = factory.createSyndicate(
            creatorAgentId,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://v103",
                asset: usdc,
                name: "V103 Vault",
                symbol: "v103",
                openDeposits: true,
                subdomain: "v103-fund"
            })
        );
        vault = SyndicateVault(payable(v));
        vault.registerAgent(creatorAgentId, creator);
        vm.stopPrank();
        gov = SyndicateGovernor(factory.governorOf(v));
        queue = IVaultWithdrawalQueue(vault.withdrawalQueue());

        usdc.mint(lp1, 60_000e6);
        usdc.mint(lp2, 40_000e6);
        vm.startPrank(lp1);
        usdc.approve(v, type(uint256).max);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();
        vm.startPrank(lp2);
        usdc.approve(v, type(uint256).max);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();

        vm.startPrank(guardianA);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(STAKE_A, 101);
        vm.stopPrank();
        vm.startPrank(guardianB);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(STAKE_B, 102);
        vm.stopPrank();
        skip(1 days);

        // Venue + feeds: TSLA $100, NVDA $200, 8-dec feeds; venue fills at the feed price.
        adapter = new MockSwapAdapter();
        _setVenuePrices(100, 200);
        tsla.mint(address(adapter), 10_000_000e18);
        nvda.mint(address(adapter), 10_000_000e18);
        usdc.mint(address(adapter), 1_000_000_000e6);
        tslaFeed = new RebondFeed(8, 100e8, vm.getBlockTimestamp());
        nvdaFeed = new RebondFeed(8, 200e8, vm.getBlockTimestamp());
        template = new PortfolioStrategy();

        // Safe ceremony on the REAL TierRegistry / StrategyFactory (grants after code is deployed).
        vm.startPrank(owner);
        strategyFactory.setTemplateApproval(address(template), true);
        tierRegistry.setCounterpartyAllowed(address(adapter), true);
        tierRegistry.setCounterpartyAllowed(address(tslaFeed), true);
        tierRegistry.setCounterpartyAllowed(address(nvdaFeed), true);
        tierRegistry.setPriceSourceForToken(address(tsla), bytes32(uint256(uint160(address(tslaFeed)))), true);
        tierRegistry.setPriceSourceForToken(address(nvda), bytes32(uint256(uint160(address(nvdaFeed)))), true);
        vm.stopPrank();
    }

    // ── helpers ──

    function _setVenuePrices(uint256 tslaUsd, uint256 nvdaUsd) internal {
        // rate = out-units per in-unit * 1e18
        adapter.setRate(address(usdc), address(tsla), 1e30 / tslaUsd);
        adapter.setRate(address(tsla), address(usdc), 1e6 * tslaUsd);
        adapter.setRate(address(usdc), address(nvda), 1e30 / nvdaUsd);
        adapter.setRate(address(nvda), address(usdc), 1e6 * nvdaUsd);
    }

    function _refreshFeeds() internal {
        tslaFeed.setUpdatedAt(vm.getBlockTimestamp());
        nvdaFeed.setUpdatedAt(vm.getBlockTimestamp());
    }

    function _initData(uint256 amount) internal view returns (bytes memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(nvda);
        tokens[1] = address(tsla);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        bytes[] memory extra = new bytes[](2);
        uint8[] memory decs = new uint8[](2);
        decs[0] = 8;
        decs[1] = 8;
        address[] memory feeds = new address[](2);
        feeds[0] = address(nvdaFeed);
        feeds[1] = address(tslaFeed);
        return abi.encode(address(usdc), address(adapter), tokens, weights, amount, 100, extra, decs, feeds);
    }

    function _execCalls(uint256 amount) internal view returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](2);
        c[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(IERC20.approve, (address(strategy), amount)), value: 0
        });
        c[1] = BatchExecutorLib.Call({
            target: address(strategy), data: abi.encodeCall(BaseStrategy.execute, ()), value: 0
        });
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](1);
        c[0] =
            BatchExecutorLib.Call({target: address(strategy), data: abi.encodeCall(BaseStrategy.settle, ()), value: 0});
    }

    /// @dev The honest owner's price-free unwind: pull every clone balance home.
    function _rescueCalls() internal view returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](3);
        c[0] = BatchExecutorLib.Call({
            target: address(strategy), data: abi.encodeCall(BaseStrategy.rescueTo, (address(tsla))), value: 0
        });
        c[1] = BatchExecutorLib.Call({
            target: address(strategy), data: abi.encodeCall(BaseStrategy.rescueTo, (address(nvda))), value: 0
        });
        c[2] = BatchExecutorLib.Call({
            target: address(strategy), data: abi.encodeCall(BaseStrategy.rescueTo, (address(usdc))), value: 0
        });
    }

    /// @dev cloneAndInit -> propose (owner) -> vote window -> review -> execute (healthy feeds).
    function _executedBasket(uint256 amount) internal returns (uint256 pid) {
        vm.prank(creator);
        strategy = PortfolioStrategy(
            strategyFactory.cloneAndInit(address(template), address(vault), creator, _initData(amount))
        );
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = amount;
        uint256[] memory settleCaps = new uint256[](1);
        uint256 cap = vault.totalAssets();
        vm.prank(creator);
        pid = gov.propose(
            address(vault),
            address(strategy),
            "ipfs://v103",
            STRATEGY_DURATION,
            ISyndicateGovernor.RiskEnvelope({maxCapital: cap, maxDrawdownBps: 10_000}),
            _execCalls(amount),
            execCaps,
            _settleCalls(),
            settleCaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
        skip(24 hours + 1);
        registry.openReview(address(gov), pid);
        skip(REVIEW_PERIOD + 1);
        _refreshFeeds();
        gov.executeProposal(pid);
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed), "executed");
    }

    /// @dev Executed basket whose TSLA feed froze at execute; strategy duration elapsed.
    function _deadFeedProposal() internal returns (uint256 pid) {
        pid = _executedBasket(60_000e6);
        assertEq(tsla.balanceOf(address(strategy)), 300e18, "30k at $100");
        assertEq(nvda.balanceOf(address(strategy)), 150e18, "30k at $200");
        skip(STRATEGY_DURATION + 1);
        nvdaFeed.setUpdatedAt(vm.getBlockTimestamp()); // healthy feed keeps publishing
    }

    function _assertOrdinaryExitsRevert(uint256 pid, bytes4 sel) internal {
        vm.prank(creator);
        vm.expectRevert(sel);
        gov.settleProposal(pid);
        vm.prank(keeper);
        vm.expectRevert(sel);
        gov.settleProposal(pid);
        vm.prank(creator);
        vm.expectRevert(sel);
        gov.unstick(pid);
    }

    function _openAndBlock(uint256 pid) internal {
        vm.prank(creator);
        gov.emergencySettleWithCalls(pid, _rescueCalls());
        vm.prank(guardianA);
        registry.voteBlockEmergencySettle(address(gov), pid);
        vm.prank(creator);
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        gov.cancelEmergencySettle(pid);
        skip(REVIEW_PERIOD + 1);
        vm.prank(keeper);
        registry.resolveEmergencyReview(address(gov), pid);
        assertEq(registry.ownerStake(address(vault)), 0, "bond slashed, slot deleted");
    }

    /// @notice Dead TSLA feed, blocked round, bond burned; the owner re-bonds mid-proposal and a price-free rescue settles.
    function test_deadFeed_blockedRound_sameOwnerRebond_rescueSettles() public {
        uint256 pid = _deadFeedProposal();
        _assertOrdinaryExitsRevert(pid, PortfolioStrategy.StalePrice.selector);
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        uint256 req = vault.requestRedeem(lp2Shares, lp2);

        _openAndBlock(pid);

        vm.startPrank(creator);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        swood.approveOwnerStakeBinding(address(vault));
        factory.rotateOwner(address(vault), creator);
        gov.emergencySettleWithCalls(pid, _rescueCalls());
        vm.stopPrank();
        skip(REVIEW_PERIOD + 1);
        vm.prank(creator);
        gov.finalizeEmergencySettle(pid);

        assertEq(uint256(gov.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertEq(tsla.balanceOf(address(vault)), 300e18, "TSLA rescued in kind");
        assertEq(nvda.balanceOf(address(vault)), 150e18, "NVDA rescued in kind");
        assertFalse(vault.redemptionsLocked(), "redemptions unlocked");
        assertEq(registry.ownerStake(address(vault)), MIN_OWNER_STAKE, "second bond intact");
        vm.prank(lp2);
        queue.claim(req);
    }
}
