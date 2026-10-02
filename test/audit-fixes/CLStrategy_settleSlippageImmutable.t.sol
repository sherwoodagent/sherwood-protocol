// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {MarketParams, Id} from "../../src/vendor/morpho/IMorpho.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockERC4626Wrapper} from "../mocks/MockERC4626Wrapper.sol";
import {MockMorpho, MockIrm, MockMorphoOracle} from "../mocks/MockMorpho.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {PermissiveRegistryWithPairs} from "../audit-fixes/PortfolioStrategy_stuckSettleEmergency.t.sol";

/// @notice Swap venue that fills token1 -> token0 with exact single-range Uniswap V3 math
///         (constant L, fee on input) against the mock pool's sqrtPriceX96, and token0 -> token1
///         at a flat spot rate. `L` is public pool depth: anyone may add to it (JIT liquidity).
contract FP06V3Venue is ISwapAdapter {
    uint256 constant Q96 = 1 << 96;
    MockUniswapV3Pool public immutable pool;
    address public immutable token0;
    address public immutable token1;
    uint256 public immutable rate01; // token0 -> token1, 1e18-scaled
    uint256 public L;
    uint24 public routeFee;

    error TooLittleReceived(uint256 out, uint256 minOut);

    constructor(MockUniswapV3Pool pool_, uint256 rate01_, uint24 routeFee_) {
        pool = pool_;
        token0 = pool_.token0();
        token1 = pool_.token1();
        rate01 = rate01_;
        routeFee = routeFee_;
    }

    function setLiquidity(uint256 l) external {
        L = l;
    }

    function setRouteFee(uint24 f) external {
        routeFee = f;
    }

    function previewOut(uint256 amountIn) public view returns (uint256 out, uint160 sqrtNew) {
        uint256 sp = pool.sqrtPriceX96();
        uint256 inLessFee = (amountIn * (1e6 - routeFee)) / 1e6;
        uint256 sn = sp + Math.mulDiv(inLessFee, Q96, L);
        out = Math.mulDiv(L << 96, sn - sp, sn) / sp;
        sqrtNew = uint160(sn);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256 amountOutMin, bytes calldata)
        external
        returns (uint256 out)
    {
        if (tokenIn == token0) {
            out = (amountIn * rate01) / 1e18;
            if (out < amountOutMin) revert TooLittleReceived(out, amountOutMin);
            IERC20(token0).transferFrom(msg.sender, address(this), amountIn);
            IERC20(token1).transfer(msg.sender, out);
        } else {
            uint160 sn;
            (out, sn) = previewOut(amountIn);
            if (out < amountOutMin) revert TooLittleReceived(out, amountOutMin);
            IERC20(token1).transferFrom(msg.sender, address(this), amountIn);
            IERC20(token0).transfer(msg.sender, out);
            pool.setSqrtPriceX96(sn);
        }
    }

    function quote(address tokenIn, address, uint256 amountIn, bytes calldata) external view returns (uint256) {
        return tokenIn == token0 ? (amountIn * rate01) / 1e18 : (amountIn * 1e18) / rate01;
    }
}

/// @notice Audit 2026-10-02 FP-06 (N-01): the CL settle slippage is floored at init and fixed after it.
contract CLStrategy_settleSlippageImmutableTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    GuardianRegistry registry;
    StakedWood swood;
    ERC20Mock usdg;
    ERC20Mock wood;
    ERC20Mock nvda;
    MockAgentRegistry agentRegistry;
    MockERC4626Wrapper spUsdg;
    MockMorpho morpho;
    MockIrm irm;
    MockMorphoOracle oracle;
    MockUniswapV3Factory uniFactory;
    MockUniswapV3Pool pool;
    MockPositionManager posm;
    FP06V3Venue venue;
    ConcentratedLiquidityStrategy clTemplate;
    MarketParams mp;
    Id marketId;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address stranger = makeAddr("stranger");
    uint256 ownerAgentNft;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant DURATION = 2 days;

    uint256 constant COLLATERAL = 100_000e6;
    uint256 constant BORROW = 50_000e6;
    uint24 constant POOL_FEE = 3000; // 0.30% anchor pool
    // sqrt(1e10) * 2^96: 1 USDG (6dp) = 0.01 NVDA (18dp), i.e. NVDA = $100.
    uint160 constant SQRT_P = uint160(1e5) * uint160(2 ** 96);
    uint256 constant RATE_01 = 1e28; // 1 USDG raw -> 1e10 NVDA raw
    // Real V3 liquidity of a +/-1000-tick position centred on spot holding 250 NVDA:
    // 250e18 / (1e5 * (1 - 1.0001^-500)).
    uint256 constant L_POS = 51_262_915_670_272_180;

    function setUp() public {
        address factoryEoa = address(this);
        usdg = new ERC20Mock("USDG", "USDG", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        nvda = new ERC20Mock("NVDA", "NVDA", 18);
        BatchExecutorLib executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        vm.mockCall(address(this), abi.encodeWithSignature("agentRegistry()"), abi.encode(address(agentRegistry)));
        uint256 agentNft = agentRegistry.mint(agent);
        ownerAgentNft = agentRegistry.mint(owner);

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdg),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));
        vm.prank(owner);
        vault.registerAgent(agentNft, agent);

        ProtocolConfig pc = new ProtocolConfig(owner);
        address tierRegistry = address(new PermissiveRegistryWithPairs());
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 5);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factoryEoa,
                    minGuardianStake: 10_000e18,
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
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("depositsRestricted()"), abi.encode(false));
        vm.mockCall(address(this), abi.encodeWithSignature("ownerOnlyProposals()"), abi.encode(false));

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit =
            abi.encodeCall(GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, 3000));
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        require(address(registry) == predictedRegistryProxy, "registry addr");
        vm.prank(registry.factory());
        registry.addGovernor(address(governor), address(vault));
        vm.prank(owner);
        swood.setRegistry(address(registry));

        _deposit(lp1, 120_000e6);
        _deposit(lp2, 80_000e6);
        vm.warp(vm.getBlockTimestamp() + 1);

        wood.mint(owner, 100_000e18);
        vm.startPrank(owner);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.stopPrank();
        swood.bindOwnerStake(owner, address(vault));

        // Morpho market: spUSDG collateral, USDG loan, par oracle.
        spUsdg = new MockERC4626Wrapper(IERC20(address(usdg)), "spUSDG", "spUSDG");
        irm = new MockIrm();
        irm.setRate(uint256(0.05e18) / 365 days);
        morpho = new MockMorpho();
        oracle = new MockMorphoOracle();
        mp = MarketParams({
            loanToken: address(usdg),
            collateralToken: address(spUsdg),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.915e18
        });
        marketId = morpho.createMarket(mp);
        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(morpho), type(uint256).max);
        morpho.supply(mp, 1_000_000e6, 0, address(this), "");

        // Anchor pool (0.30%), its factory and position manager.
        uniFactory = new MockUniswapV3Factory();
        pool = new MockUniswapV3Pool(address(usdg), address(nvda), POOL_FEE, 10, address(uniFactory));
        // Strategy's own pool-share check sees this position at exactly the 10% cap (mock units).
        pool.setLiquidity(2.5e16);
        pool.setTicks(0, 0);
        pool.setSqrtPriceX96(SQRT_P);
        uniFactory.register(address(usdg), address(nvda), POOL_FEE, address(pool));
        posm = new MockPositionManager(address(uniFactory));

        // Route = the anchor pool itself; depth after the position leaves = 9 x L_POS (10% share).
        venue = new FP06V3Venue(pool, RATE_01, POOL_FEE);
        venue.setLiquidity(9 * L_POS);
        usdg.mint(address(venue), 10_000_000e6);
        nvda.mint(address(venue), 1_000_000e18);

        clTemplate = new ConcentratedLiquidityStrategy();
    }

    // ── helpers ──

    function _deposit(address lp, uint256 amt) internal {
        usdg.mint(lp, amt);
        vm.startPrank(lp);
        usdg.approve(address(vault), amt);
        vault.deposit(amt, lp);
        vm.stopPrank();
    }

    function _clParams(uint256 settleSlip) internal view returns (ConcentratedLiquidityStrategy.InitParams memory) {
        return ConcentratedLiquidityStrategy.InitParams({
            pool: address(pool),
            positionManager: address(posm),
            uniswapFactory: address(uniFactory),
            swapAdapter: address(venue),
            morpho: address(morpho),
            marketParams: mp,
            collateralAmount: COLLATERAL,
            borrowAmount: BORROW,
            tickLower: -1000,
            tickUpper: 1000,
            expectedLiquidity: 2.5e15,
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
            settleSlippageBps: settleSlip,
            settleDeadline: 0,
            swapExtraData: ""
        });
    }

    function _newClone(address proposer_, uint256 settleSlip) internal returns (ConcentratedLiquidityStrategy s) {
        s = ConcentratedLiquidityStrategy(Clones.clone(address(clTemplate)));
        s.initialize(address(vault), proposer_, abi.encode(_clParams(settleSlip)));
    }

    function _settleCalls(address s) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: s, data: abi.encodeCall(BaseStrategy.settle, ()), value: 0});
    }

    function _proposeAndExecute(address governorProposer, address strategy, uint256 capital)
        internal
        returns (uint256 pid)
    {
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(usdg), data: abi.encodeCall(IERC20.approve, (strategy, capital)), value: 0
        });
        execCalls[1] =
            BatchExecutorLib.Call({target: strategy, data: abi.encodeCall(BaseStrategy.execute, ()), value: 0});
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = capital;
        BatchExecutorLib.Call[] memory settleCalls = _settleCalls(strategy);
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(governorProposer);
        pid = governor.propose(
            address(vault),
            strategy,
            "ipfs://fp06",
            DURATION,
            env,
            execCalls,
            execCaps,
            settleCalls,
            GovEnvelope.defaultCaps(env.maxCapital, 1),
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
        governor.executeProposal(pid);
    }

    function _executedCL(uint256 settleSlip) internal returns (ConcentratedLiquidityStrategy s, uint256 pid) {
        s = _newClone(agent, settleSlip);
        pid = _proposeAndExecute(agent, address(s), COLLATERAL);
        assertTrue(s.executed(), "premise: executed");
        assertGt(s.tokenId(), 0, "premise: position");
    }

    function _positionLiquidity(uint256 tid) internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = posm.positions(tid);
    }

    function _state(uint256 pid) internal view returns (ISyndicateGovernor.ProposalState) {
        return governor.getProposal(pid).state;
    }

    /// @notice After execute the proposer can no longer move the settle slippage, down or up; zero keeps it.
    function test_updateParams_settleSlippageFixedAfterExecute() public {
        ConcentratedLiquidityStrategy s = _newClone(agent, 500);
        vm.prank(agent);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        s.updateParams(abi.encode(uint256(1), uint256(0)));
        _proposeAndExecute(agent, address(s), COLLATERAL);

        vm.prank(agent);
        vm.expectRevert(ConcentratedLiquidityStrategy.InvalidBound.selector);
        s.updateParams(abi.encode(uint256(1001), uint256(0)));
        uint256[3] memory moves = [uint256(1), 499, 501];
        for (uint256 i; i < 3; ++i) {
            vm.prank(agent);
            vm.expectRevert(ConcentratedLiquidityStrategy.ImmutableParam.selector);
            s.updateParams(abi.encode(moves[i], uint256(0)));
        }
        vm.prank(agent);
        s.updateParams(abi.encode(uint256(500), uint256(0)));
        vm.prank(agent);
        s.updateParams(abi.encode(uint256(0), uint256(0)));
        assertEq(s.settleSlippageBps(), 500, "settle slippage moved after execute");
    }

    /// @notice The settle deadline stays tunable while the slippage is fixed.
    function test_updateParams_deadlineStillTunable() public {
        ConcentratedLiquidityStrategy s = _newClone(agent, 500);
        _proposeAndExecute(agent, address(s), COLLATERAL);
        vm.prank(agent);
        s.updateParams(abi.encode(uint256(0), uint256(7 days)));
        assertEq(s.settleDeadline(), 7 days);
        vm.prank(agent);
        s.updateParams(abi.encode(uint256(500), uint256(1 days)));
        assertEq(s.settleDeadline(), 1 days);
        assertEq(s.settleSlippageBps(), 500);
    }

    /// @notice Init below the floor is refused; the floor itself is admitted.
    function test_init_belowFloorRefused() public {
        uint256 floor = clTemplate.MIN_SETTLE_SLIPPAGE_BPS();
        assertEq(floor, 50);
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(clTemplate)));
        bytes memory data = abi.encode(_clParams(floor - 1));
        address v = address(vault);
        vm.expectRevert(ConcentratedLiquidityStrategy.InvalidBound.selector);
        s.initialize(v, agent, data);

        ConcentratedLiquidityStrategy ok = _newClone(agent, floor);
        assertEq(ok.settleSlippageBps(), floor);
    }

    /// @notice Control: at the reviewed 500 bp the ordinary settle clears and the clone is emptied.
    function test_control_settlesAtReviewedSlippage() public {
        (ConcentratedLiquidityStrategy s, uint256 pid) = _executedCL(500);
        uint256 tid = s.tokenId();
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        vm.prank(stranger);
        governor.settleProposal(pid);
        assertEq(uint256(_state(pid)), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertEq(_positionLiquidity(tid), 0, "position unwound");
        assertEq(morpho.position(marketId, address(s)).collateral, 0, "collateral freed");
        assertGt(usdg.balanceOf(address(vault)) - vaultBefore, 99_000e6);
    }

    /// @notice The 1 bp ratchet that bricked every settle route is refused, so settle still clears.
    function test_ratchetToOneBpRefused_settleStillClears() public {
        (ConcentratedLiquidityStrategy s, uint256 pid) = _executedCL(500);
        vm.prank(agent);
        vm.expectRevert(ConcentratedLiquidityStrategy.ImmutableParam.selector);
        s.updateParams(abi.encode(uint256(1), uint256(0)));
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        vm.prank(stranger);
        governor.settleProposal(pid);
        assertEq(uint256(_state(pid)), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertFalse(s.executed(), "clone settled");
        assertFalse(vault.redemptionsLocked());
    }

    /// @notice Under ownerOnlyProposals the clone's agent proposer still cannot lower the slippage.
    function test_ownerOnlyFlag_cloneProposerCannotLower() public {
        vm.mockCall(address(this), abi.encodeWithSignature("ownerOnlyProposals()"), abi.encode(true));
        vm.prank(owner);
        vault.registerAgent(ownerAgentNft, owner);
        ConcentratedLiquidityStrategy s = _newClone(agent, 500);
        uint256 pid = _proposeAndExecute(owner, address(s), COLLATERAL);
        vm.prank(agent);
        vm.expectRevert(ConcentratedLiquidityStrategy.ImmutableParam.selector);
        s.updateParams(abi.encode(uint256(1), uint256(0)));
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        governor.settleProposal(pid);
        assertFalse(s.executed(), "clone settled");
    }
}
