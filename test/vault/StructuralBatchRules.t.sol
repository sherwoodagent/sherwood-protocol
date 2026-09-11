// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {MarketParams} from "../../src/vendor/morpho/IMorpho.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {GlobalDollarMock} from "../mocks/GlobalDollarMock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {MockMorpho, MockIrm, MockMorphoOracle} from "../mocks/MockMorpho.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockERC4626Wrapper} from "../mocks/MockERC4626Wrapper.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

/// @notice A hand-written strategy nobody certified: it answers `IStrategy`'s three getters,
///         pulls `amount` of `token` on `frobnicate` (a selector no registry names) and
///         accepts any other selector.
contract CustomStrategy {
    address public immutable vault;
    address public immutable proposer;

    constructor(address vault_, address proposer_) {
        vault = vault_;
        proposer = proposer_;
    }

    function executed() external pure returns (bool) {
        return false;
    }

    function frobnicate(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function refund(address token, uint256 amount) external {
        IERC20(token).transfer(msg.sender, amount);
    }

    fallback() external {}
}

/// @notice An asset with an allowance-granting selector no list would name.
contract GrantSpendMock is ERC20Mock {
    constructor() ERC20Mock("Odd", "ODD", 6) {}

    function grantSpend(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
}

/// @notice A contract with code and no functions.
contract Stub {}

/// @notice A plain ERC-20 that also carries the pre-OZ-5 `increaseAllowance`.
contract UsdcMock is ERC20Mock {
    constructor() ERC20Mock("USD Coin", "USDC", 6) {}

    function increaseAllowance(address spender, uint256 added) external returns (bool) {
        _approve(msg.sender, spender, allowance(msg.sender, spender) + added);
        return true;
    }
}

/// @notice The vault's batch guard is four structural rules and nothing else: every non-asset
///         target is a registered strategy; on the asset a call is a metered transfer
///         (`transferFrom` from the vault only) or allowance-shaped, and every allowance-shaped
///         call's first argument is reset after the batch; the meters bound the rest.
contract StructuralBatchRulesTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockRegistryMinimal guardianRegistry;
    TierRegistry tierRegistry;
    StrategyFactory strategyFactory;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp1 = makeAddr("lp1");
    address attacker = makeAddr("attacker");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant DEPOSIT = 20_000_000e6;
    uint256 constant CLASS_BOUND = 500;

    function setUp() public {
        _deployStack(new UsdcMock());
    }

    /// @dev The whole stack on `asset_`, so a test can re-run it on a differently shaped asset.
    function _deployStack(ERC20Mock asset_) internal {
        usdc = asset_;
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
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
                address(this),
                address(tierRegistry),
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: 1 days,
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

        // The test contract is the syndicate factory.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("vaultToSyndicate(address)"), abi.encode(uint256(1)));
        strategyFactory = new StrategyFactory(address(this), address(this));
        tierRegistry.setStrategyFactory(address(strategyFactory));

        uint256 agentId = agentRegistry.mint(agent);
        vm.prank(owner);
        vault.registerAgent(agentId, agent);

        usdc.mint(lp1, 100_000_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT, lp1);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── helpers ──

    function _call(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: target, value: 0, data: data});
    }

    function _one(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = _call(target, data);
    }

    function _runBatch(BatchExecutorLib.Call[] memory calls, uint256 maxNetOutflow) internal {
        vm.prank(address(governor));
        vault.executeGovernorBatch(calls, new uint256[](0), maxNetOutflow);
    }

    function _expectBatchRevert(BatchExecutorLib.Call[] memory calls, uint256 maxNetOutflow, bytes memory err)
        internal
    {
        vm.prank(address(governor));
        vm.expectRevert(err);
        vault.executeGovernorBatch(calls, new uint256[](0), maxNetOutflow);
    }

    /// @dev A registered, uncertified hand-written strategy.
    function _custom() internal returns (CustomStrategy c) {
        c = new CustomStrategy(address(vault), agent);
        strategyFactory.registerStrategy(address(c));
    }

    function _expectTransferFromRefused(bytes memory data, address from) internal {
        _expectBatchRevert(
            _one(address(usdc), data), 0, abi.encodeWithSelector(ISyndicateVault.TransferFromNotVault.selector, from)
        );
    }

    function _propose(
        address strategy,
        BatchExecutorLib.Call[] memory execCalls,
        uint256[] memory execCaps,
        BatchExecutorLib.Call[] memory settleCalls,
        uint256[] memory settleCaps,
        uint256 maxCapital
    ) internal returns (uint256 pid) {
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            strategy,
            "ipfs://structural",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            settleCalls,
            settleCaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function _certifyClassNow(address template, bytes4 selector, uint8 tier, uint16 bound) internal {
        tierRegistry.proposeClassCertification(template, selector, tier, bound, address(0), template.codehash);
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certifyClass(template, selector);
    }

    // ── Morpho template fixture ──

    MockMorpho morpho;
    MarketParams mp;

    function _morphoVenue() internal returns (MorphoSupplyStrategy template) {
        MockIrm irm = new MockIrm();
        irm.setRate(uint256(0.05e18) / 365 days);
        morpho = new MockMorpho();
        mp = MarketParams({
            loanToken: address(usdc),
            collateralToken: makeAddr("collateral"),
            oracle: makeAddr("oracle"),
            irm: address(irm),
            lltv: 0.86e18
        });
        morpho.createMarket(mp);
        template = new MorphoSupplyStrategy();
        strategyFactory.setTemplateApproval(address(template), true);
        tierRegistry.setCounterpartyAllowed(address(morpho), true);
    }

    function _morphoClone(address template, address proposer, uint256 amount) internal returns (address clone) {
        vm.prank(proposer);
        clone =
            strategyFactory.cloneAndInit(template, address(vault), proposer, abi.encode(address(morpho), mp, amount));
    }

    // ── Portfolio template fixture ──

    MockAggregatorV3 portfolioFeed;

    function _portfolioClone(uint256 amount) internal returns (address clone) {
        ERC20Mock tsla = new ERC20Mock("Tesla", "TSLA", 18);
        MockSwapAdapter adapter = new MockSwapAdapter();
        // 1 USDC (1e6) buys 0.01 TSLA (1e16); 1 TSLA sells for 100 USDC (1e8).
        adapter.setRate(address(usdc), address(tsla), 1e28);
        adapter.setRate(address(tsla), address(usdc), 1e8);
        tsla.mint(address(adapter), 1_000_000e18);
        usdc.mint(address(adapter), 1_000_000e6);
        MockAggregatorV3 feed = new MockAggregatorV3(18, int256(100e18));
        portfolioFeed = feed;

        PortfolioStrategy template = new PortfolioStrategy();
        strategyFactory.setTemplateApproval(address(template), true);
        tierRegistry.setCounterpartyAllowed(address(adapter), true);
        tierRegistry.setCounterpartyAllowed(address(feed), true);
        tierRegistry.setPriceSourceForToken(address(tsla), bytes32(uint256(uint160(address(feed)))), true);

        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        uint8[] memory pd = new uint8[](1);
        pd[0] = 18;
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        bytes memory data = abi.encode(address(usdc), address(adapter), tokens, weights, amount, 100, extra, pd, feeds);
        vm.prank(agent);
        clone = strategyFactory.cloneAndInit(address(template), address(vault), agent, data);
    }

    // ── Concentrated-liquidity template fixture ──

    function _clClone() internal returns (address clone) {
        ERC20Mock nvda = new ERC20Mock("NVDA", "NVDA", 18);
        MockERC4626Wrapper spUsdc = new MockERC4626Wrapper(IERC20(address(usdc)), "spUSDC", "spUSDC");
        MockIrm irm = new MockIrm();
        irm.setRate(uint256(0.05e18) / 365 days);
        MockMorpho clMorpho = new MockMorpho();
        MarketParams memory clMp = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(spUsdc),
            oracle: address(new MockMorphoOracle()),
            irm: address(irm),
            lltv: 0.915e18
        });
        clMorpho.createMarket(clMp);
        address supplier = makeAddr("supplier");
        usdc.mint(supplier, 1_000_000e6);
        vm.startPrank(supplier);
        usdc.approve(address(clMorpho), 1_000_000e6);
        clMorpho.supply(clMp, 1_000_000e6, 0, supplier, "");
        vm.stopPrank();

        MockUniswapV3Factory uniFactory = new MockUniswapV3Factory();
        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(usdc), address(nvda), 500, 10, address(uniFactory));
        pool.setLiquidity(1e18);
        pool.setTicks(0, 0);
        pool.setSqrtPriceX96(uint160(1e5) * uint160(2 ** 96));
        uniFactory.register(address(usdc), address(nvda), 500, address(pool));
        MockPositionManager posm = new MockPositionManager(address(uniFactory));
        MockSwapAdapter adapter = new MockSwapAdapter();
        adapter.setRate(address(usdc), address(nvda), 1e18 * 1e12 / 100);
        adapter.setRate(address(nvda), address(usdc), 100 * 1e18 / 1e12);
        nvda.mint(address(adapter), 1_000_000e18);
        usdc.mint(address(adapter), 1_000_000e6);

        ConcentratedLiquidityStrategy template = new ConcentratedLiquidityStrategy();
        strategyFactory.setTemplateApproval(address(template), true);
        tierRegistry.setCounterpartyAllowed(address(adapter), true);
        tierRegistry.setCounterpartyAllowed(address(posm), true);
        tierRegistry.setCounterpartyAllowed(address(clMorpho), true);
        tierRegistry.setCounterpartyAllowed(address(uniFactory), true);
        tierRegistry.setCounterpartyAllowed(address(spUsdc), true);
        tierRegistry.setCounterpartyAllowed(address(nvda), true);

        ConcentratedLiquidityStrategy.InitParams memory p = ConcentratedLiquidityStrategy.InitParams({
            pool: address(pool),
            positionManager: address(posm),
            uniswapFactory: address(uniFactory),
            swapAdapter: address(adapter),
            morpho: address(clMorpho),
            marketParams: clMp,
            collateralAmount: 100_000e6,
            borrowAmount: 50_000e6,
            lpAmount: 0,
            tickLower: -1000,
            tickUpper: 1000,
            expectedLiquidity: 1e16,
            swapFractionBps: 5_000,
            twapWindow: 1800,
            maxTwapDeviationBps: 100,
            mintSlippageBps: 500,
            rerange: ConcentratedLiquidityStrategy.RerangePolicy({
                halfWidthTicks: 1000,
                triggerBps: 8_000,
                minInterval: 1 hours,
                maxReranges: 3,
                slippageBps: 500,
                swapFractionBps: 5_000
            }),
            settleSlippageBps: 500,
            settleDeadline: 0,
            swapExtraData: ""
        });
        vm.prank(agent);
        clone = strategyFactory.cloneAndInit(address(template), address(vault), agent, abi.encode(p));
    }

    /// @dev Propose → vote window → execute → duration → settle, for a template clone
    ///      whose execute pulls `amount` of the asset.
    function _runLifecycle(address clone, uint256 amount) internal returns (uint256 pid) {
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (clone, amount)));
        execCalls[1] = _call(clone, abi.encodeCall(BaseStrategy.execute, ()));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = amount;
        pid = _propose(
            clone, execCalls, execCaps, _one(clone, abi.encodeCall(BaseStrategy.settle, ())), new uint256[](1), amount
        );
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        if (address(portfolioFeed) != address(0)) portfolioFeed.setUpdatedAt(vm.getBlockTimestamp());
        governor.executeProposal(pid);
        assertEq(uint256(BaseStrategy(clone).state()), uint256(BaseStrategy.State.Executed), "executed");
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        if (address(portfolioFeed) != address(0)) portfolioFeed.setUpdatedAt(vm.getBlockTimestamp());
        governor.settleProposal(pid);
        assertEq(uint256(BaseStrategy(clone).state()), uint256(BaseStrategy.State.Settled), "settled");
        assertEq(usdc.allowance(address(vault), clone), 0, "no allowance outlives the batch");
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
    }

    // ── Rule 1: every non-asset target is a registered strategy ──

    /// @notice Morpho directly, the queue, the governor, the vault, the registry, a stub: none registered.
    function test_batchTargetingAnUnregisteredContractReverts() public {
        _morphoVenue();
        address[6] memory targets = [
            address(morpho),
            address(queue),
            address(governor),
            address(vault),
            address(tierRegistry),
            address(new Stub())
        ];
        for (uint256 i = 0; i < targets.length; i++) {
            assertFalse(strategyFactory.isRegisteredStrategy(targets[i]), "not registered");
            bytes memory err = abi.encodeWithSelector(ISyndicateVault.NotARegisteredStrategy.selector, targets[i]);
            _expectBatchRevert(_one(targets[i], hex"deadbeef"), 0, err);
        }
        _expectBatchRevert(
            _one(address(queue), abi.encodeCall(IVaultWithdrawalQueue.queueRedeem, (attacker, 1e6, 1))),
            0,
            abi.encodeWithSelector(ISyndicateVault.NotARegisteredStrategy.selector, address(queue))
        );
        _expectBatchRevert(
            _one(address(vault), abi.encodeCall(ISyndicateVault.ratchetHighWaterMark, ())),
            0,
            abi.encodeWithSelector(ISyndicateVault.NotARegisteredStrategy.selector, address(vault))
        );
    }

    function test_batchTargetingARegisteredStrategyWithAnySelectorIsAdmitted() public {
        CustomStrategy c = _custom();
        uint256 amount = 1_000e6;
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        calls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(c), amount)));
        calls[1] = _call(address(c), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), amount)));
        calls[2] = _call(address(c), hex"deadbeef");
        _runBatch(calls, amount);
        assertEq(usdc.balanceOf(address(c)), amount, "admitted and executed");
    }

    /// @notice Registration is a shape check, so the protocol contracts and an EOA cannot register.
    function test_registerStrategy_rejectsAContractWithoutTheInterface() public {
        address[5] memory rejected = [address(queue), address(usdc), address(vault), attacker, address(new Stub())];
        for (uint256 i = 0; i < rejected.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(StrategyFactory.NotAStrategy.selector, rejected[i]));
            strategyFactory.registerStrategy(rejected[i]);
        }
    }

    function test_registeredStrategyDeregistersOnCodeChange() public {
        CustomStrategy c = _custom();
        assertTrue(strategyFactory.isRegisteredStrategy(address(c)), "registered");
        vm.etch(address(c), address(new Stub()).code);
        assertFalse(strategyFactory.isRegisteredStrategy(address(c)), "code changed");
        _expectBatchRevert(
            _one(address(c), hex"deadbeef"),
            0,
            abi.encodeWithSelector(ISyndicateVault.NotARegisteredStrategy.selector, address(c))
        );
    }

    /// @notice A registry with no factory wired registers nothing; the asset rules still run.
    function test_unwiredStrategyFactoryRefusesEveryNonAssetTarget() public {
        CustomStrategy c = _custom();
        vm.mockCall(address(tierRegistry), abi.encodeWithSignature("strategyFactory()"), abi.encode(address(0)));
        _expectBatchRevert(
            _one(address(c), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), 0))),
            0,
            abi.encodeWithSelector(ISyndicateVault.NotARegisteredStrategy.selector, address(c))
        );
        _runBatch(_one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 1))), 0);
    }

    function test_factoryWithoutTheSelectorFailsClosed() public {
        CustomStrategy c = _custom();
        vm.mockCallRevert(
            address(strategyFactory), abi.encodeWithSelector(StrategyFactory.isRegisteredStrategy.selector), ""
        );
        _expectBatchRevert(
            _one(address(c), hex"deadbeef"),
            0,
            abi.encodeWithSelector(ISyndicateVault.NotARegisteredStrategy.selector, address(c))
        );
    }

    /// @notice The `strategy` field names a registered strategy, nothing else: not zero, not an
    ///         EOA, not an unregistered contract.
    function test_proposeRequiresARegisteredStrategyField() public {
        CustomStrategy c = new CustomStrategy(address(vault), agent);
        BatchExecutorLib.Call[] memory calls = _one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 0)));
        uint256[] memory caps = new uint256[](1);
        address[3] memory rejected = [address(0), attacker, address(c)];
        for (uint256 i = 0; i < rejected.length; i++) {
            vm.prank(agent);
            vm.expectRevert(abi.encodeWithSelector(ISyndicateGovernor.StrategyNotRegistered.selector, rejected[i]));
            governor.propose(
                address(vault),
                rejected[i],
                "ipfs://structural",
                7 days,
                ISyndicateGovernor.RiskEnvelope({maxCapital: 1, maxDrawdownBps: 10_000}),
                calls,
                caps,
                calls,
                caps,
                new ISyndicateGovernor.CoProposer[](0)
            );
        }
        strategyFactory.registerStrategy(address(c));
        uint256 pid = _propose(address(c), calls, caps, calls, caps, 1);
        assertEq(governor.getProposal(pid).strategy, address(c), "stored verbatim");
    }

    // ── Rule 2: transferFrom on the asset must draw from the vault ──

    /// @notice The LP's standing deposit allowance is the one asset flow the meter cannot see.
    function test_assetTransferFromLpReverts() public {
        _expectTransferFromRefused(abi.encodeCall(usdc.transferFrom, (lp1, attacker, 1)), lp1);
        _expectTransferFromRefused(abi.encodeCall(usdc.transferFrom, (lp1, address(vault), 1)), lp1);
        _expectTransferFromRefused(
            abi.encodePacked(usdc.transferFrom.selector, bytes32(uint256(uint160(address(vault))) | (1 << 160))),
            address(vault)
        );
        assertEq(usdc.allowance(lp1, address(vault)), type(uint256).max, "the LP allowance is untouched");
    }

    function test_assetTransferFromVaultItselfIsAdmittedAndMetered() public {
        uint256 amount = 1_000e6;
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(vault), amount)));
        calls[1] = _call(address(usdc), abi.encodeCall(usdc.transferFrom, (address(vault), attacker, amount)));
        _expectBatchRevert(
            calls,
            amount - 1,
            abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, amount, amount - 1)
        );
        _runBatch(calls, amount);
        assertEq(usdc.balanceOf(attacker), amount, "admitted within the cap");
        assertEq(usdc.allowance(address(vault), address(vault)), 0, "self-allowance reset");
    }

    function test_assetTransferIsAdmittedAndMetered() public {
        uint256 amount = 1_000e6;
        BatchExecutorLib.Call[] memory calls = _one(address(usdc), abi.encodeCall(usdc.transfer, (attacker, amount)));
        _expectBatchRevert(
            calls,
            amount - 1,
            abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, amount, amount - 1)
        );
        _runBatch(calls, amount);
        assertEq(usdc.balanceOf(attacker), amount, "admitted within the cap");
    }

    /// @notice Reads and well-formed grants on the asset are admitted; a read's first argument is
    ///         reset like a spender, which is a no-op.
    function test_assetReadsAndApproveAreAdmitted() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](4);
        calls[0] = _call(address(usdc), abi.encodeCall(usdc.balanceOf, (address(vault))));
        calls[1] = _call(address(usdc), abi.encodeCall(usdc.allowance, (lp1, address(vault))));
        calls[2] = _call(address(usdc), abi.encodeCall(usdc.approve, (attacker, 1)));
        calls[3] = _call(address(usdc), abi.encodeWithSignature("increaseAllowance(address,uint256)", attacker, 1));
        _runBatch(calls, 0);
        assertEq(usdc.allowance(address(vault), attacker), 0, "granted inside, gone after");
        assertEq(usdc.allowance(lp1, address(vault)), type(uint256).max, "the LP's own allowance is not the vault's");
    }

    /// @notice Every asset call carries at least a selector and one argument word; shorter
    ///         calldata has no spender to reset and is refused before the token sees it.
    function test_shortAssetCalldataIsRefused() public {
        bytes[] memory shapes = new bytes[](4);
        shapes[0] = "";
        shapes[1] = abi.encodeCall(usdc.decimals, ());
        shapes[2] = abi.encodePacked(usdc.transferFrom.selector);
        shapes[3] = abi.encodePacked(usdc.approve.selector, new bytes(31));
        (bool ok,) = address(usdc).call(shapes[1]);
        assertTrue(ok, "control: the token itself answers decimals()");
        for (uint256 i = 0; i < shapes.length; i++) {
            bytes4 sel = shapes[i].length >= 4 ? bytes4(shapes[i]) : bytes4(0);
            _expectBatchRevert(
                _one(address(usdc), shapes[i]),
                0,
                abi.encodeWithSelector(ISyndicateVault.MalformedAssetCall.selector, sel)
            );
        }
    }

    /// @notice Selectors the guard does not name reach the token, which answers for itself:
    ///         an empty revert (no such function) rather than any guard error.
    function test_unrecognisedAssetSelectorsReachTheToken() public {
        bytes[] memory shapes = new bytes[](4);
        shapes[0] = abi.encodeWithSignature(
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            address(vault),
            attacker,
            type(uint256).max,
            type(uint256).max,
            uint8(27),
            bytes32(0),
            bytes32(0)
        );
        shapes[1] = abi.encodeWithSignature("transferAndCall(address,uint256)", attacker, 1);
        shapes[2] = abi.encodeWithSignature("authorizeOperator(address)", attacker);
        shapes[3] = abi.encodePacked(usdc.approve.selector, bytes32(uint256(uint160(attacker))));
        for (uint256 i = 0; i < shapes.length; i++) {
            (bool ok, bytes memory ret) = address(usdc).call(shapes[i]);
            assertTrue(!ok && ret.length == 0, "control: the token itself reverts empty");
            _expectBatchRevert(_one(address(usdc), shapes[i]), 0, "");
        }
    }

    // ── Rule 3: no standing allowance ──

    function test_allowanceToEverySpenderIsZeroAfterTheBatch() public {
        CustomStrategy puller = _custom();
        CustomStrategy idle = _custom();
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        calls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(puller), 100e6)));
        calls[1] = _call(address(puller), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), 100e6)));
        calls[2] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(idle), 100e6)));
        _runBatch(calls, 100e6);
        assertEq(usdc.balanceOf(address(puller)), 100e6, "the puller pulled inside the batch");
        assertEq(usdc.allowance(address(vault), address(puller)), 0, "pulled spender reset");
        assertEq(usdc.allowance(address(vault), address(idle)), 0, "idle spender reset");
    }

    function test_increaseAllowanceIsResetAfterTheBatch() public {
        CustomStrategy puller = _custom();
        CustomStrategy idle = _custom();
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        calls[0] =
            _call(address(usdc), abi.encodeWithSignature("increaseAllowance(address,uint256)", address(puller), 100e6));
        calls[1] = _call(address(puller), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), 100e6)));
        calls[2] =
            _call(address(usdc), abi.encodeWithSignature("increaseAllowance(address,uint256)", address(idle), 100e6));
        _runBatch(calls, 100e6);
        assertEq(usdc.balanceOf(address(puller)), 100e6, "the allowance was live inside the batch");
        assertEq(usdc.allowance(address(vault), address(puller)), 0, "pulled spender reset");
        assertEq(usdc.allowance(address(vault), address(idle)), 0, "idle spender reset");
    }

    function test_approveThenDrainNextBlockIsImpossible() public {
        _runBatch(_one(address(usdc), abi.encodeCall(usdc.approve, (attacker, type(uint256).max))), 0);
        vm.roll(block.number + 1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, 1));
        usdc.transferFrom(address(vault), attacker, 1);
    }

    /// @notice The launch asset (USDG, Paxos-shaped) grants through `increaseApproval`, a
    ///         selector no OZ list names. It is reset like any other allowance-shaped call.
    function test_increaseApprovalOnAPaxosShapedAssetIsResetAfterTheBatch() public {
        _deployStack(new GlobalDollarMock());
        (bool ok,) = address(usdc).call(abi.encodeWithSignature("increaseAllowance(address,uint256)", attacker, 1));
        assertFalse(ok, "control: the Paxos shape has no increaseAllowance");

        CustomStrategy puller = _custom();
        CustomStrategy idle = _custom();
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        calls[0] =
            _call(address(usdc), abi.encodeWithSignature("increaseApproval(address,uint256)", address(puller), 100e6));
        calls[1] = _call(address(puller), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), 100e6)));
        calls[2] =
            _call(address(usdc), abi.encodeWithSignature("increaseApproval(address,uint256)", address(idle), 100e6));
        _runBatch(calls, 100e6);
        assertEq(usdc.balanceOf(address(puller)), 100e6, "the allowance was live inside the batch");
        assertEq(usdc.allowance(address(vault), address(puller)), 0, "pulled spender reset");
        assertEq(usdc.allowance(address(vault), address(idle)), 0, "idle spender reset");
    }

    function test_approveThenDrainNextBlockIsImpossible_paxosAsset() public {
        _deployStack(new GlobalDollarMock());
        _runBatch(
            _one(address(usdc), abi.encodeWithSignature("increaseApproval(address,uint256)", attacker, DEPOSIT)), 0
        );
        assertEq(usdc.allowance(address(vault), attacker), 0, "no allowance survives the batch");
        vm.roll(block.number + 1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, DEPOSIT));
        usdc.transferFrom(address(vault), attacker, DEPOSIT);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT, "the float is intact");
    }

    /// @notice A grant through a selector nobody has heard of is reset too: the rule is the
    ///         shape of the call, not its name.
    function test_unknownAllowanceShapedAssetSelectorIsReset() public {
        _deployStack(new GrantSpendMock());
        _runBatch(_one(address(usdc), abi.encodeWithSignature("grantSpend(address,uint256)", attacker, DEPOSIT)), 0);
        assertEq(usdc.allowance(address(vault), attacker), 0, "reset without naming the selector");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, DEPOSIT));
        usdc.transferFrom(address(vault), attacker, DEPOSIT);
    }

    // ── Settle batches bring assets home ──

    /// @notice A settle leg has a zero net-egress budget: a registered strategy pulling one unit
    ///         at settle reverts on `settleProposal` and on `unstick` alike.
    function test_settleBatchCannotMoveAssetsOutOfTheVault() public {
        CustomStrategy c = _custom();
        BatchExecutorLib.Call[] memory settleCalls = new BatchExecutorLib.Call[](2);
        settleCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(c), 1)));
        settleCalls[1] = _call(address(c), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), 1)));
        uint256[] memory settleCaps = new uint256[](2);
        settleCaps[1] = 1;
        uint256 pid = _propose(
            address(c),
            _one(address(usdc), abi.encodeCall(usdc.approve, (address(c), 0))),
            new uint256[](1),
            settleCalls,
            settleCaps,
            1
        );
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(pid);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);

        bytes memory err = abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, 1, 0);
        vm.expectRevert(err);
        governor.settleProposal(pid);
        vm.prank(owner);
        vm.expectRevert(err);
        governor.unstick(pid);
        assertEq(usdc.balanceOf(address(c)), 0, "nothing left at settle");
    }

    function test_settleBatchThatOnlyBringsAssetsHomeSucceeds() public {
        CustomStrategy c = _custom();
        uint256 amount = 1_000e6;
        uint256 before = usdc.balanceOf(address(vault));
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(c), amount)));
        execCalls[1] = _call(address(c), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), amount)));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = amount;
        uint256 pid = _propose(
            address(c),
            execCalls,
            execCaps,
            _one(address(c), abi.encodeCall(CustomStrategy.refund, (address(usdc), amount))),
            new uint256[](1),
            amount
        );
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(pid);
        assertEq(usdc.balanceOf(address(vault)), before - amount, "execute deployed the capital");
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
        assertEq(usdc.balanceOf(address(vault)), before, "settle brought it home");
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
    }

    /// @notice A zero first argument on the asset (`balanceOf(address(0))`) names no spender; the
    ///         reset skips it instead of reverting `ERC20InvalidSpender` and losing the batch.
    function test_zeroAddressArg0OnTheAssetExecutes() public {
        _runBatch(_one(address(usdc), abi.encodeCall(usdc.balanceOf, (address(0)))), 0);
    }

    // ── Propose-time mirror of the asset rules ──

    /// @notice A leg of each refused asset shape is rejected at propose with the vault's own error, in
    ///         either batch, so no proposal can reach Executed on a leg settle would refuse.
    function test_refusedAssetShapesAreRejectedAtPropose() public {
        CustomStrategy c = _custom();
        BatchExecutorLib.Call[] memory good = _one(address(usdc), abi.encodeCall(usdc.approve, (address(c), 0)));
        bytes[] memory shapes = new bytes[](3);
        bytes[] memory errs = new bytes[](3);
        shapes[0] = abi.encodeCall(usdc.transferFrom, (lp1, address(vault), 1));
        errs[0] = abi.encodeWithSelector(ISyndicateVault.TransferFromNotVault.selector, lp1);
        shapes[1] = abi.encodePacked(usdc.approve.selector, new bytes(31));
        errs[1] = abi.encodeWithSelector(ISyndicateVault.MalformedAssetCall.selector, usdc.approve.selector);
        shapes[2] = abi.encodeCall(usdc.totalSupply, ());
        errs[2] = abi.encodeWithSelector(ISyndicateVault.MalformedAssetCall.selector, usdc.totalSupply.selector);
        for (uint256 i = 0; i < shapes.length; i++) {
            BatchExecutorLib.Call[] memory bad = _one(address(usdc), shapes[i]);
            _expectProposeRevert(address(c), good, bad, errs[i]);
            _expectProposeRevert(address(c), bad, good, errs[i]);
        }
    }

    /// @notice Control: a metered `transfer` and a 36-byte read in a settle leg still propose.
    function test_transferAndReadSettleLegsStillPropose() public {
        CustomStrategy c = _custom();
        BatchExecutorLib.Call[] memory settle = new BatchExecutorLib.Call[](2);
        settle[0] = _call(address(usdc), abi.encodeCall(usdc.transfer, (attacker, 1)));
        settle[1] = _call(address(usdc), abi.encodeCall(usdc.balanceOf, (address(0))));
        uint256 pid = _propose(
            address(c),
            _one(address(usdc), abi.encodeCall(usdc.approve, (address(c), 0))),
            new uint256[](1),
            settle,
            new uint256[](2),
            1
        );
        assertEq(governor.getProposal(pid).strategy, address(c), "proposed");
    }

    function _expectProposeRevert(
        address strategy,
        BatchExecutorLib.Call[] memory execCalls,
        BatchExecutorLib.Call[] memory settleCalls,
        bytes memory err
    ) internal {
        uint256[] memory execCaps = new uint256[](execCalls.length);
        uint256[] memory settleCaps = new uint256[](settleCalls.length);
        vm.prank(agent);
        vm.expectRevert(err);
        governor.propose(
            address(vault),
            strategy,
            "ipfs://structural",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: 1, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            settleCalls,
            settleCaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    // ── Rule 4: everything else is admitted and metered ──

    function test_arbitraryContractWithArbitrarySelectorIsAdmittedAndMetered() public {
        CustomStrategy venue = _custom();
        uint256 amount = 1_000e6;
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(venue), amount)));
        calls[1] = _call(address(venue), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), amount)));

        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, amount, amount - 1));
        vault.executeGovernorBatch(calls, new uint256[](0), amount - 1);

        _runBatch(calls, amount);
        assertEq(usdc.balanceOf(address(venue)), amount, "admitted within the cap");
    }

    // ── Pricing through the real governor and registry ──

    function test_uncertifiedStrategyPricesTierTwoFullCoverage() public {
        CustomStrategy venue = _custom();
        uint256 cap = 1_000_000e6;
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(venue), cap)));
        execCalls[1] = _call(address(venue), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), cap)));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = cap;
        uint256 pid = _propose(
            address(venue),
            execCalls,
            execCaps,
            _one(address(venue), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), 0))),
            new uint256[](1),
            cap
        );
        assertEq(governor.getProposalTier(pid), 2, "uncertified -> tier 2");
        assertEq(governor.getRequiredCoverage(pid), cap, "full notional");

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(pid);
        assertEq(usdc.balanceOf(address(venue)), cap, "admitted and executed");
    }

    /// @notice The class tier is a property of the code: a clone anyone minted through the
    ///         permissionless factory prices at its class.
    function test_certifiedTemplateClonePricesItsClassTier() public {
        MorphoSupplyStrategy template = _morphoVenue();
        _certifyClassNow(address(template), BaseStrategy.execute.selector, 1, uint16(CLASS_BOUND));

        address rando = makeAddr("rando");
        address clone = _morphoClone(address(template), rando, 1_000e6);
        assertEq(strategyFactory.cloneTemplate(clone), address(template), "provenance recorded");
        (uint8 tier, uint16 bound) = tierRegistry.tierOf(clone, BaseStrategy.execute.selector);
        assertEq(tier, 1, "class tier inherited by a clone anyone minted");
        assertEq(bound, CLASS_BOUND, "class bound");
        (tier, bound) = tierRegistry.tierOf(clone, BaseStrategy.settle.selector);
        assertEq(tier, 2, "uncertified selector on the same clone stays tier 2");
    }

    function test_twoStrategyBatchPricesEachLegAtItsOwnTier() public {
        MorphoSupplyStrategy template = _morphoVenue();
        _certifyClassNow(address(template), BaseStrategy.execute.selector, 1, uint16(CLASS_BOUND));
        uint256 c1 = 4_000_000e6;
        uint256 c2 = 1_000_000e6;
        address clone = _morphoClone(address(template), agent, c1);
        CustomStrategy custom = _custom();

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](4);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (clone, c1)));
        execCalls[1] = _call(clone, abi.encodeCall(BaseStrategy.execute, ()));
        execCalls[2] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(custom), c2)));
        execCalls[3] = _call(address(custom), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), c2)));
        uint256[] memory execCaps = new uint256[](4);
        execCaps[1] = c1;
        execCaps[3] = c2;
        uint256 pid = _propose(
            clone, execCalls, execCaps, _one(clone, abi.encodeCall(BaseStrategy.settle, ())), new uint256[](1), c1 + c2
        );
        assertEq(governor.getProposalTier(pid), 2, "max over legs");
        assertEq(governor.getRequiredCoverage(pid), c1 * CLASS_BOUND / 10_000 + c2, "tier_1 x cap_1 + tier_2 x cap_2");

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(pid);
        assertEq(usdc.balanceOf(address(custom)), c2, "the uncertified leg executed");
        assertEq(usdc.allowance(address(vault), clone), 0, "clone allowance reset");
        assertEq(usdc.allowance(address(vault), address(custom)), 0, "custom allowance reset");
    }

    // ── Liveness: the shipped templates need only counterparty grants ──

    function test_theThreeShippedTemplatesExecuteAndSettleWithNoAllowlisting() public {
        uint256 before = usdc.balanceOf(address(vault));

        MorphoSupplyStrategy morphoTemplate = _morphoVenue();
        _runLifecycle(_morphoClone(address(morphoTemplate), agent, 1_000_000e6), 1_000_000e6);
        assertGe(usdc.balanceOf(address(vault)), before, "morpho round-trips");

        _runLifecycle(_portfolioClone(1_000_000e6), 1_000_000e6);
        assertGe(
            usdc.balanceOf(address(vault)), before - 1_000_000e6 * 2 / 100, "portfolio round-trips within slippage"
        );
        portfolioFeed = MockAggregatorV3(address(0));

        _runLifecycle(_clClone(), 100_000e6);
        assertEq(governor.getActiveProposal(), 0, "nothing open after three settled lifecycles");
    }
}
