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
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {MockMorpho, MockIrm, MockMorphoOracle} from "../mocks/MockMorpho.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockERC4626Wrapper} from "../mocks/MockERC4626Wrapper.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

/// @notice An arbitrary contract nobody certified or allowlisted. `frobnicate` is
///         a selector no registry names; it pulls `amount` of `token` from the caller.
contract RandomVenue {
    function frobnicate(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

/// @notice A contract with code and no functions; stands in for a protocol collaborator
///         whose getters are mocked.
contract Stub {}

/// @notice The vault's batch guard is four structural rules and nothing else.
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
    Stub ledgerStub;
    Stub gameStub;
    Stub swoodStub;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp1 = makeAddr("lp1");
    address attacker = makeAddr("attacker");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant DEPOSIT = 20_000_000e6;
    uint256 constant CLASS_BOUND = 500;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
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

        // The ledger, game and sWOOD hops the governor cannot name here are mocked
        // onto contracts with code, so the privileged set resolves all ten entries.
        ledgerStub = new Stub();
        gameStub = new Stub();
        swoodStub = new Stub();
        vm.mockCall(address(governor), abi.encodeCall(ISyndicateGovernor.exposureLedger, ()), abi.encode(ledgerStub));
        vm.mockCall(address(ledgerStub), abi.encodeWithSignature("coverageFreezer()"), abi.encode(gameStub));
        vm.mockCall(address(guardianRegistry), abi.encodeWithSignature("swood()"), abi.encode(swoodStub));

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

    function _expectAssetRefused(bytes memory data) internal {
        bytes4 sel = data.length >= 4 ? bytes4(data) : bytes4(0);
        BatchExecutorLib.Call[] memory calls = _one(address(usdc), data);
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedAssetSelector.selector, sel));
        vault.executeGovernorBatch(calls, new uint256[](0), 0);
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

    // ── Rule 1: privileged targets ──

    /// @notice Every protocol contract the vault can resolve is refused as a target, whatever the calldata.
    function test_batchTargetingAPrivilegedContractReverts() public {
        address[10] memory privileged = [
            address(vault),
            address(queue),
            address(governor),
            address(tierRegistry),
            address(strategyFactory),
            address(this),
            address(ledgerStub),
            address(gameStub),
            address(guardianRegistry),
            address(swoodStub)
        ];
        for (uint256 i = 0; i < privileged.length; i++) {
            assertTrue(vault.isPrivilegedBatchTarget(privileged[i]), "privileged view");
            BatchExecutorLib.Call[] memory calls = _one(privileged[i], hex"deadbeef");
            vm.prank(address(governor));
            vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, privileged[i]));
            vault.executeGovernorBatch(calls, new uint256[](0), 0);
        }
        assertFalse(vault.isPrivilegedBatchTarget(address(new RandomVenue())), "an ordinary contract is not");
        assertFalse(vault.isPrivilegedBatchTarget(address(0)), "the governor's probe address is not");
    }

    // ── Rule 2: asset is approve-only ──

    function test_assetTransferFromLpReverts() public {
        _expectAssetRefused(abi.encodeCall(usdc.transferFrom, (lp1, address(vault), 1)));
        _expectAssetRefused(abi.encodeCall(usdc.transferFrom, (address(vault), attacker, 1)));
    }

    function test_assetTransferReverts() public {
        _expectAssetRefused(abi.encodeCall(usdc.transfer, (attacker, 1)));
    }

    function test_assetPermitReverts() public {
        _expectAssetRefused(
            abi.encodeWithSignature(
                "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                address(vault),
                attacker,
                type(uint256).max,
                type(uint256).max,
                uint8(27),
                bytes32(0),
                bytes32(0)
            )
        );
    }

    function test_assetIncreaseAllowanceReverts() public {
        _expectAssetRefused(abi.encodeWithSignature("increaseAllowance(address,uint256)", attacker, 1));
        _expectAssetRefused(abi.encodeWithSignature("transferAndCall(address,uint256)", attacker, 1));
        _expectAssetRefused(abi.encodeWithSignature("authorizeOperator(address)", attacker));
        _expectAssetRefused("");
        _expectAssetRefused(abi.encodePacked(usdc.approve.selector, bytes32(uint256(uint160(attacker)))));
    }

    /// @notice Control for the rule above: a well-formed `approve` on the asset is admitted.
    function test_assetApproveIsAdmitted() public {
        _runBatch(_one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 1))), 0);
    }

    // ── Rule 3: no standing allowance ──

    function test_allowanceToEverySpenderIsZeroAfterTheBatch() public {
        RandomVenue puller = new RandomVenue();
        RandomVenue idle = new RandomVenue();
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        calls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(puller), 100e6)));
        calls[1] = _call(address(puller), abi.encodeCall(RandomVenue.frobnicate, (address(usdc), 100e6)));
        calls[2] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(idle), 100e6)));
        _runBatch(calls, 100e6);
        assertEq(usdc.balanceOf(address(puller)), 100e6, "the puller pulled inside the batch");
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

    // ── Rule 4: everything else is admitted and metered ──

    function test_arbitraryContractWithArbitrarySelectorIsAdmittedAndMetered() public {
        RandomVenue venue = new RandomVenue();
        uint256 amount = 1_000e6;
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(venue), amount)));
        calls[1] = _call(address(venue), abi.encodeCall(RandomVenue.frobnicate, (address(usdc), amount)));

        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, amount, amount - 1));
        vault.executeGovernorBatch(calls, new uint256[](0), amount - 1);

        _runBatch(calls, amount);
        assertEq(usdc.balanceOf(address(venue)), amount, "admitted within the cap");
    }

    // ── Pricing through the real governor and registry ──

    function test_uncertifiedStrategyPricesTierTwoFullCoverage() public {
        RandomVenue venue = new RandomVenue();
        uint256 cap = 1_000_000e6;
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(venue), cap)));
        execCalls[1] = _call(address(venue), abi.encodeCall(RandomVenue.frobnicate, (address(usdc), cap)));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = cap;
        uint256 pid = _propose(
            address(venue),
            execCalls,
            execCaps,
            _one(address(venue), abi.encodeCall(RandomVenue.frobnicate, (address(usdc), 0))),
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
        RandomVenue custom = new RandomVenue();

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](4);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (clone, c1)));
        execCalls[1] = _call(clone, abi.encodeCall(BaseStrategy.execute, ()));
        execCalls[2] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(custom), c2)));
        execCalls[3] = _call(address(custom), abi.encodeCall(RandomVenue.frobnicate, (address(usdc), c2)));
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
