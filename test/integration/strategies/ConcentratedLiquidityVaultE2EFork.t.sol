// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RobinhoodMainnetIntegrationTest} from "../RobinhoodMainnetIntegrationTest.sol";
import {ConcentratedLiquidityStrategy} from "../../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {UniswapSwapAdapter, ISwapRouter} from "../../../src/adapters/UniswapSwapAdapter.sol";
import {TierRegistry} from "../../../src/TierRegistry.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";
import {ISyndicateVault} from "../../../src/interfaces/ISyndicateVault.sol";
import {IMorpho, Id, MarketParams, Position} from "../../../src/vendor/morpho/IMorpho.sol";
import {MorphoBalancesLib, SharesMathLib} from "../../../src/vendor/morpho/MorphoLibs.sol";
import {IUniswapV3Pool} from "../../../src/vendor/uniswap/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "../../../src/vendor/uniswap/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "../../../src/vendor/uniswap/INonfungiblePositionManager.sol";

/**
 * @title ConcentratedLiquidityVaultE2EForkTest
 * @notice `ConcentratedLiquidityStrategy` driven through the REAL
 *         `SyndicateVault` + `SyndicateGovernor` on a Robinhood mainnet (4663)
 *         fork, against the live Uniswap v3 deployment and the live Morpho Blue
 *         singleton.
 *
 *         The sibling suite `ConcentratedLiquidityMainnetFork.t.sol` drives the
 *         same template through a `ForkVaultStub`, so nothing there exercises
 *         `_pullFromVault`/`_pushAllToVault` against a vault that prices shares,
 *         the governor's propose→vote→review→execute→settle envelope, or the
 *         `hasUndeliveredValue()` deposit lock. That is the gap this file
 *         closes. It leaves the stub suite alone.
 *
 *  ── Venue, measured on chain (Tenderly archive vnet of 4663, head block
 *     4,447,892, 2026-08-12) ────────────────────────────────────────────────
 *     USDG/WETH v3 pools reported by factory `getPool`:
 *       fee   100: 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca
 *                  liquidity 4.355e18, 3,199,589 USDG / 3,384 WETH, cardinality 2500
 *       fee   500: 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a
 *                  liquidity 4.071e17,   691,571 USDG /   768 WETH, cardinality 3000
 *       fee  3000: 0xa9188730Fe85Be88ad499D7d52B099e800fB0334   <-- USED HERE
 *                  liquidity 2.617e17,   255,585 USDG /   305 WETH, cardinality 2500
 *                  tick -200940, tickSpacing 60, sqrtPriceX96 3.4336e24 (~$1,881/ETH,
 *                  agreeing with the live Chainlink ETH/USD answer 188192000000)
 *       fee 10000: 0x5f009E071F07e92B6C624e83F52F17bBDa34680D — liquidity 7.99e8, dust
 *
 *     The 0.3% pool is chosen deliberately over the deeper 0.01% one: a
 *     position sized inside `MAX_POOL_SHARE_BPS` there earns fee income large
 *     enough to be distinguished from settlement noise, which is the only way
 *     `test_cl_fullLifecycle_feesReachVault` can FAIL if `collect()` stopped
 *     paying. Both `observationCardinality` figures are far above the 2 the TWAP
 *     guard requires, so no fixture has to bump cardinality here.
 *
 *     Morpho market (same one the Morpho fork suite uses), read on chain:
 *       id 0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114
 *       loan USDG / collateral spUSDG 0xde770c84FE66E063336b31737cFE9790f18c4087
 *       lltv 0.915e18, totalSupply 20,516,357 USDG, totalBorrow 18,625,126 USDG
 *       (~1.89M USDG lendable — the 7k borrowed here is noise against it)
 *
 *  ── Fork clock ────────────────────────────────────────────────────────────
 *     The Tenderly vnet's `block.timestamp` (1,783,526,915) lags the state it
 *     serves: the Chainlink feeds report `updatedAt` 1,786,562,123 and this
 *     Morpho market's `lastUpdate` is 1,786,576,990, LATER still. The harness
 *     `_normalizeFeedClock()` only warps past the feeds, which leaves
 *     `block.timestamp < market.lastUpdate` — and Morpho's `_accrueInterest`
 *     computes `block.timestamp - lastUpdate` unchecked-of-nothing, so every
 *     `supplyCollateral`/`borrow` would panic 0x11. `setUp` below warps past the
 *     market clock too. Forward-only (`vm.warp` backwards is a no-op in forge
 *     1.7.1) and idempotent on a fork whose clock is already ahead.
 *
 * @dev Run:
 *        set -a; source .env; set +a
 *        export ROBINHOOD_RPC_URL="$TENDERLY_ROBINHOOD_RPC_URL"
 *        export ROBINHOOD_FORK_CHAIN_ID=9994663
 *        forge test --match-path \
 *          "test/integration/strategies/ConcentratedLiquidityVaultE2EFork.t.sol" -vv
 */
contract ConcentratedLiquidityVaultE2EForkTest is RobinhoodMainnetIntegrationTest {
    using MorphoBalancesLib for IMorpho;

    address constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    bytes32 constant MARKET_ID = 0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114;

    uint24 constant POOL_FEE = 3000;
    uint32 constant TWAP_WINDOW = 1800;

    /// @dev Position band: ±360 ticks (~±3.6%), a multiple of the pool's
    ///      spacing of 60. Narrow enough that the position holds a real share of
    ///      in-range depth (fees are measurable), wide enough that ordinary
    ///      churn stays inside it.
    int24 constant HALF_WIDTH = 360;

    /// @dev Rerange bands are WIDER than the initial one — legal
    ///      (`_requireValidRerangePolicy` demands only `>=`) and necessary to
    ///      test the TWAP guard at all. `_mintPosition` floors both legs at
    ///      `10_000 - rerange.slippageBps` of what it was offered, and a rerange
    ///      landing `o` ticks off the centre of a half-width-`h` band consumes
    ///      only `(h-o)/(h+o)` of the over-supplied leg, so the re-mint reverts
    ///      "Price slippage check" once `o > h/19`. On a ±360 band that is 19
    ///      ticks — well inside any TWAP bound the guard can be configured
    ///      with, so the mint floor would always fire first and the guard would
    ///      never be the thing under test. ±3600 admits ~190 ticks, which
    ///      brackets the 200-tick bound the guard tests use.
    int24 constant RERANGE_HALF_WIDTH = 3_600;

    uint256 constant COLLATERAL = 10_000e6; // half the vault's 20k float
    uint256 constant BORROW = 7_000e6; // LTV 70% vs the 86.5% effective ceiling
    uint256 constant STRATEGY_DURATION = 1 hours;
    /// @dev Zero on purpose: a performance fee would move vault float at settle
    ///      for reasons unrelated to what these tests measure.
    uint256 constant PERF_FEE_BPS = 0;

    UniswapSwapAdapter adapter;
    address template;
    IUniswapV3Pool pool;
    MarketParams mp;
    bool forkReady;

    address whale = makeAddr("whale");
    address keeper = makeAddr("keeper");
    address outsider = makeAddr("outsider");

    function setUp() public override {
        super.setUp();
        // `super.setUp()` skips (and leaves `vault` unset) when there is no RPC.
        if (address(vault) == address(0)) return;

        // ── Venue identity, not code presence ──
        assertEq(
            keccak256(bytes(INonfungiblePositionManager(POSITION_MANAGER).symbol())),
            keccak256(bytes("UNI-V3-POS")),
            "position manager is not a Uniswap V3 NFT manager"
        );
        assertEq(
            INonfungiblePositionManager(POSITION_MANAGER).factory(),
            UNISWAP_V3_FACTORY,
            "position manager points at a different factory"
        );

        address poolAddr = IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(USDG, WETH, POOL_FEE);
        require(poolAddr != address(0), "no USDG/WETH 0.3% pool on this fork");
        pool = IUniswapV3Pool(poolAddr);
        // Token ordering is load-bearing for `_wethInUsdg` below.
        assertEq(pool.token0(), WETH, "WETH is not token0 of this pool");
        assertEq(pool.token1(), USDG, "USDG is not token1 of this pool");

        (,,, uint16 cardinality,,,) = pool.slot0();
        assertGe(cardinality, 2, "pool cannot serve a TWAP window");
        assertGt(pool.liquidity(), 0, "pool has no in-range liquidity");
        console2.log("pool liquidity:", uint256(pool.liquidity()));
        console2.log("pool cardinality:", uint256(cardinality));

        mp = IMorpho(MORPHO).idToMarketParams(Id.wrap(MARKET_ID));
        assertEq(mp.loanToken, USDG, "market does not lend the vault asset");
        assertEq(IERC4626(mp.collateralToken).asset(), USDG, "collateral is not a USDG wrapper");

        // ── Fork clock: past the Morpho market's own `lastUpdate` (see header) ──
        uint256 marketClock = IMorpho(MORPHO).market(Id.wrap(MARKET_ID)).lastUpdate;
        if (vm.getBlockTimestamp() <= marketClock) {
            console2.log("warping past Morpho lastUpdate by (s):", marketClock + 1 hours - vm.getBlockTimestamp());
            vm.warp(marketClock + 1 hours);
        }

        _rebaseNftIdCounter();

        adapter = new UniswapSwapAdapter(UNISWAP_SWAP_ROUTER, UNISWAP_QUOTER_V2, V4_POOL_MANAGER, V4_QUOTER);
        template = address(new ConcentratedLiquidityStrategy());

        // `_initialize` binds the swap adapter on the STRONG axis
        // (`isAdapterAllowed`) and everything else it approves or calls on the
        // weak one (`isCounterpartyAllowed`). A freshly deployed registry
        // answers false to both.
        vm.startPrank(deployer);
        TierRegistry(tierRegistry).setAdapterAllowed(address(adapter), true);
        TierRegistry(tierRegistry).setCounterpartyAllowed(POSITION_MANAGER, true);
        TierRegistry(tierRegistry).setCounterpartyAllowed(MORPHO, true);
        TierRegistry(tierRegistry).setCounterpartyAllowed(UNISWAP_V3_FACTORY, true);
        TierRegistry(tierRegistry).setCounterpartyAllowed(mp.collateralToken, true);
        TierRegistry(tierRegistry).setCounterpartyAllowed(WETH, true); // the volatile leg
        vm.stopPrank();

        forkReady = true;
    }

    /// @dev FORK-ENVIRONMENT WORKAROUND, not a protocol concern. Measured on the
    ///      Tenderly archive vnet 2026-08-12: `NonfungiblePositionManager` packs
    ///      `uint176 _nextId` (low 176 bits) and `uint80 _nextPoolId` (high 80)
    ///      into slot 13, and the vnet answers `eth_getStorageAt` and `eth_call`
    ///      from DIFFERENT points in its history — slot 13 read through the fork
    ///      gives `_nextId == 675345` while `ownerOf(675345)`, `ownerOf(675346)`
    ///      and `ownerOf(675347)` all resolve to live owners over the same
    ///      endpoint. The first mint in a test therefore lands on a free id and
    ///      the SECOND reverts `ERC721: token already minted` — which is what a
    ///      rerange does, and it has nothing to do with the code under test.
    ///
    ///      Push the counter far above anything the real chain has minted
    ///      (~675k) so every id this suite consumes is free under either view.
    ///      `_nextPoolId` is preserved bit-for-bit. `test_cl_fullLifecycle_*`
    ///      asserts the minted id actually came from here, so a layout change
    ///      upstream fails loudly instead of silently making this a no-op.
    uint256 constant NFT_ID_SLOT = 13;
    uint256 constant NFT_ID_BASE = 5_000_000;

    function _rebaseNftIdCounter() internal {
        uint256 packed = uint256(vm.load(POSITION_MANAGER, bytes32(NFT_ID_SLOT)));
        uint256 nextPoolId = packed >> 176;
        vm.store(POSITION_MANAGER, bytes32(NFT_ID_SLOT), bytes32((nextPoolId << 176) | NFT_ID_BASE));
    }

    /// @dev `vm.skip` from the TEST BODY — the setUp form is forge-version
    ///      dependent and reads as `[FAIL: skipped]` on the version CI runs.
    function _requireFork() internal {
        if (!forkReady) vm.skip(true);
    }

    // ==================== FIXTURE ====================

    function _align(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        if (tick % spacing != 0 && tick < 0) q--;
        return q * spacing;
    }

    /// @dev Mode 0 = Uniswap v3 single hop, on the SAME fee tier as the LP
    ///      pool, so the adapter quote and the pool anchor describe one venue.
    ///      Its own function to keep `_initData`'s frame inside the IR stack.
    function _routeData() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x00), abi.encode(POOL_FEE));
    }

    /// @dev The band, snapped to the live pool's spacing around live spot.
    function _band() internal view returns (int24 lower, int24 upper) {
        (, int24 spot,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        lower = _align(spot - HALF_WIDTH, spacing);
        upper = _align(spot + HALF_WIDTH, spacing);
    }

    /// @dev The rerange policy, built in its OWN frame. See `_initParams`.
    function _rerangePolicy() internal pure returns (ConcentratedLiquidityStrategy.RerangePolicy memory r) {
        // `halfWidthTicks` must be >= the initial half-width, else
        // `_requireValidRerangePolicy` rejects it (the pool-share cap is
        // preserved at bind time rather than re-checked at rerange).
        r.halfWidthTicks = RERANGE_HALF_WIDTH;
        r.triggerBps = 1;
        r.minInterval = 0;
        r.maxReranges = 2;
        r.slippageBps = 1_000;
        r.swapFractionBps = 5_000;
    }

    /// @dev Assembled field-by-field rather than as a struct literal: the
    ///      literal plus the live reads it needs overflows the IR stack in this
    ///      frame (`via_ir = true`, `optimizer_runs = 50`).
    ///
    ///      SPLIT FROM `_initData`, AND THE SPLIT IS LOAD-BEARING. Assembling
    ///      the struct and then `abi.encode`-ing it in one frame overflows the
    ///      IR stack by a single slot — the encoder needs its own live memory
    ///      pointers on top of every pointer the assembly above still holds
    ///      (`Cannot swap ... too deep in the stack by 1 slots`, reported
    ///      against whichever constant the frame happens to reference). Keeping
    ///      the encode in a separate frame is what makes this file compile at
    ///      all; the nested `rerange` gets the same treatment for the same
    ///      reason. Sub-frames, not `--via-ir` tuning, because the profile is
    ///      repo-wide and this is one test file's frame.
    function _initParams(uint256 twapDeviationBps)
        internal
        view
        returns (ConcentratedLiquidityStrategy.InitParams memory p)
    {
        p.pool = address(pool);
        p.positionManager = POSITION_MANAGER;
        p.uniswapFactory = UNISWAP_V3_FACTORY;
        p.swapAdapter = address(adapter);
        p.morpho = MORPHO;
        p.marketParams = mp;
        p.collateralAmount = COLLATERAL;
        p.borrowAmount = BORROW;
        (p.tickLower, p.tickUpper) = _band();
        // Bounds the CLAIM only; `_execute` re-checks the liquidity actually
        // minted against the pre-mint snapshot, which is the enforceable one.
        p.expectedLiquidity = uint128(pool.liquidity() / 20);
        p.swapFractionBps = 5_000;
        p.twapWindow = TWAP_WINDOW;
        p.maxTwapDeviationBps = twapDeviationBps;
        p.mintSlippageBps = 1_000;
        p.rerange = _rerangePolicy();
        p.settleSlippageBps = 1_000;
        p.settleDeadline = 0;
        p.swapExtraData = _routeData();
    }

    function _initData(uint256 twapDeviationBps) internal view returns (bytes memory) {
        return abi.encode(_initParams(twapDeviationBps));
    }

    function _execCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: USDG, data: abi.encodeCall(IERC20.approve, (strategy, COLLATERAL)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});
    }

    function _settleCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    function _deploy(uint256 twapDeviationBps) internal returns (address strategy, uint256 proposalId) {
        strategy = _cloneAndInit(template, _initData(twapDeviationBps));
        proposalId = _proposeVoteExecute(_execCalls(strategy), _settleCalls(strategy), PERF_FEE_BPS, STRATEGY_DURATION);
    }

    // ==================== LIVE-POOL MANIPULATION ====================

    /// @dev `sqrtPriceX96` after moving `dTicks`. One tick is a factor of
    ///      1.0001 in PRICE, hence 1.00005 in sqrt-price to first order; the
    ///      per-step error (~1e-8) accumulates to well under one tick over the
    ///      hundreds of ticks used here, and every caller asserts the tick it
    ///      actually achieved rather than trusting this.
    function _sqrtAfterTicks(uint160 sqrtP, int24 dTicks) internal pure returns (uint160) {
        uint256 sp = uint256(sqrtP);
        uint256 n = dTicks >= 0 ? uint256(uint24(dTicks)) : uint256(uint24(-dTicks));
        for (uint256 i = 0; i < n; ++i) {
            sp = dTicks >= 0 ? (sp * 100_005) / 100_000 : (sp * 100_000) / 100_005;
        }
        return uint160(sp);
    }

    /// @notice Move the live pool by `dTicks` using a price-limited swap, so the
    ///         pool takes exactly the input needed and no more.
    /// @return achieved the tick the pool actually landed on.
    function _pushTicks(int24 dTicks) internal returns (int24 achieved) {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        uint160 limit = _sqrtAfterTicks(sqrtP, dTicks);
        // token0 = WETH, token1 = USDG. Selling USDG raises USDG-per-WETH
        // (sqrtPrice up); selling WETH lowers it. The price limit is what makes
        // the pool take only the input it needs out of the huge amount offered.
        if (dTicks >= 0) {
            _whaleSwap(USDG, WETH, 50_000_000e6, limit);
        } else {
            _whaleSwap(WETH, USDG, 50_000e18, limit);
        }
        (, achieved,,,,,) = pool.slot0();
    }

    /// @dev One live swap from a freshly funded whale. Split out of its callers
    ///      so no single test-helper frame carries the router struct plus a loop.
    function _whaleSwap(address tokenIn, address tokenOut, uint256 amountIn, uint160 limit)
        internal
        returns (uint256 amountOut)
    {
        deal(tokenIn, whale, amountIn);
        vm.startPrank(whale);
        IERC20(tokenIn).approve(UNISWAP_SWAP_ROUTER, amountIn);
        amountOut = ISwapRouter(UNISWAP_SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                recipient: whale,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: limit
            })
            );
        vm.stopPrank();
    }

    /// @notice Round-trip real volume across the live pool so LP fees accrue.
    function _churn(uint256 rounds, uint256 usdgPerRound) internal {
        for (uint256 i = 0; i < rounds; ++i) {
            uint256 wethOut = _whaleSwap(USDG, WETH, usdgPerRound, 0);
            _whaleSwap(WETH, USDG, wethOut, 0);
        }
    }

    /// @notice The pool's current TWAP tick over `TWAP_WINDOW`, read the same
    ///         way the strategy reads it.
    function _twapTick() internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        ago[1] = 0;
        (int56[] memory c,) = pool.observe(ago);
        int56 delta = c[1] - c[0];
        int24 avg = int24(delta / int56(uint56(TWAP_WINDOW)));
        if (delta < 0 && (delta % int56(uint56(TWAP_WINDOW)) != 0)) avg--;
        return avg;
    }

    /// @dev `collectResidue` behind a helper purely to keep the caller's stack
    ///      shallow — this suite's lifecycle tests are already at the via-IR
    ///      limit, and inlining the call there trips "stack too deep".
    ///      Permissionless, and since `sweep()` became vault-only it is the only
    ///      door to a residue recovery.
    function _collectResidue(address strategy) internal returns (uint256) {
        return vault.collectResidue(strategy);
    }

    /// @dev Same shape, same reason, for the last-resort hatch: `sweep()` and
    ///      `releaseUnconvertible()` are both vault-only now, and both have a
    ///      permissionless vault-side door that measures what arrives.
    ///      Returns the WETH the hatch handed over — the vault's own return
    ///      value counts VAULT ASSET, which is a different thing here — and
    ///      pranks internally so the caller keeps one local, not four.
    ///
    ///      MEASURES THE CEILING WHILE IT IS HERE. Both recovery paths now run
    ///      under `SyndicateVault._SWEEP_GAS` (1,500,000), where before they
    ///      could be called directly with unbounded gas — so the cap binds the
    ///      heavy path for the first time, and it has never been measured
    ///      against live Morpho / Uniswap / ERC-4626 rather than mocks. It has
    ///      to be measured HERE: the unit-level pin in
    ///      `ConcentratedLiquidityStrategySettle.t.sol` bounds the template's
    ///      own logic against stubbed vendors, which is a floor, not the bound.
    ///
    ///      AND AN OVERRUN IS SILENT WITHOUT THE SECOND ASSERT. The vault
    ///      ignores the sub-call's result, so a hatch that exhausts the cap does
    ///      not revert — it recovers nothing, stays counted, and holds the
    ///      deposit gate. Gas-under-ceiling alone would therefore pass on
    ///      exactly the failure being guarded, since a call that OOG'd at the
    ///      cap also "fits". Pairing it with a recovery that actually landed is
    ///      what makes the check non-vacuous.
    ///
    ///      THREE LOCALS, DELIBERATELY. This suite sits at the via-IR stack
    ///      limit (see the note on `_collectResidue`); a fourth here fails the
    ///      whole file to compile, which is why the assertion lives in its own
    ///      frame below rather than inline.
    function _releaseUnconvertible(address strategy, address caller) internal returns (uint256 releasedWeth) {
        uint256 wethBefore = IERC20(WETH).balanceOf(strategy);
        uint256 gasBefore = gasleft();
        vm.prank(caller);
        vault.releaseUnconvertible(strategy);
        _assertFitsSweepCap(gasBefore);
        return wethBefore - IERC20(WETH).balanceOf(strategy);
    }

    /// @dev Reads `gasleft()` one frame down, so the figure carries this call's
    ///      own overhead. That biases it slightly HIGH, which is the safe
    ///      direction for a ceiling check — it can report a near-miss that is
    ///      really a pass, never a pass that is really an overrun.
    function _assertFitsSweepCap(uint256 gasBefore) internal {
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("releaseUnconvertible gas (fork, whole vault call)", gasUsed);
        assertLt(gasUsed, SWEEP_GAS_CEILING, "the hatch no longer fits the vault's forwarding cap");
    }

    /// @dev Mirrors `SyndicateVault._SWEEP_GAS`, which is private and cannot be
    ///      read from here. Quoted by name in that constant's own natspec as the
    ///      thing that measures it, so lowering one without the other is caught
    ///      by review rather than silently going stale in the permissive
    ///      direction.
    uint256 internal constant SWEEP_GAS_CEILING = 1_500_000;

    function _tickGap() internal view returns (uint256) {
        (, int24 spot,,,,,) = pool.slot0();
        int24 twap = _twapTick();
        int24 diff = spot > twap ? spot - twap : twap - spot;
        return uint256(uint24(diff));
    }

    // ==================== VALUATION ====================

    /// @dev WETH valued at the pool's own mid price, net of the pool fee — the
    ///      same construction `_poolAnchoredMinOut` uses, so a settlement that
    ///      cleared its floor must land at or above this figure minus the
    ///      configured slippage band. WETH is token0, so token0→token1
    ///      multiplies by the price.
    function _wethInUsdg(uint256 amount) internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        uint256 sp = uint256(sqrtP);
        uint256 v = Math.mulDiv(Math.mulDiv(amount, sp, 1 << 96), sp, 1 << 96);
        return (v * (1e6 - uint256(POOL_FEE))) / 1e6;
    }

    /// @notice Fees the live position has accrued but not yet collected.
    /// @dev    Measured by actually calling `collect` under a state snapshot,
    ///         which pokes the pool exactly as the position manager would; there
    ///         is no view that reports uncollected fees honestly.
    function _accruedFees(address strategy) internal returns (uint256 wethFee, uint256 usdgFee) {
        uint256 snap = vm.snapshotState();
        uint256 tid = ConcentratedLiquidityStrategy(strategy).tokenId();
        vm.prank(strategy);
        (wethFee, usdgFee) = INonfungiblePositionManager(POSITION_MANAGER)
            .collect(
                INonfungiblePositionManager.CollectParams({
                tokenId: tid, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
            );
        vm.revertToState(snap);
    }

    /// @notice Vault-asset value a settlement RIGHT NOW could deliver: the whole
    ///         position (principal + uncollected fees) plus the Morpho
    ///         collateral, less the debt, with the volatile leg valued at the
    ///         pool's mid price net of the pool fee.
    /// @dev    Computed by performing the unwind under a state snapshot and
    ///         reading the resulting balances, then rolling the chain back. This
    ///         is the figure `settle()` is graded against: anything the real
    ///         settlement leaves behind — uncollected fees, an uncollected
    ///         principal leg, collateral stranded behind residual debt — shows up
    ///         as a shortfall against it.
    function _deliverableUsdg(address strategy) internal returns (uint256 value) {
        uint256 snap = vm.snapshotState();

        uint256 tid = ConcentratedLiquidityStrategy(strategy).tokenId();
        if (tid != 0) {
            uint128 liquidity = _liquidityOf(tid);
            vm.startPrank(strategy);
            if (liquidity != 0) {
                INonfungiblePositionManager(POSITION_MANAGER)
                    .decreaseLiquidity(
                        INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tid,
                        liquidity: liquidity,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: vm.getBlockTimestamp()
                    })
                    );
            }
            INonfungiblePositionManager(POSITION_MANAGER)
                .collect(
                    INonfungiblePositionManager.CollectParams({
                    tokenId: tid, recipient: strategy, amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
                );
            vm.stopPrank();
        }

        value = IERC20(USDG).balanceOf(strategy) + _wethInUsdg(IERC20(WETH).balanceOf(strategy));

        Position memory pos = IMorpho(MORPHO).position(Id.wrap(MARKET_ID), strategy);
        if (pos.collateral != 0) {
            value += IERC4626(mp.collateralToken).convertToAssets(uint256(pos.collateral));
        }
        if (pos.borrowShares != 0) {
            (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = IMorpho(MORPHO).expectedMarketBalances(mp);
            uint256 debt = SharesMathLib.toAssetsUp(uint256(pos.borrowShares), totalBorrowAssets, totalBorrowShares);
            value = value > debt ? value - debt : 0;
        }

        vm.revertToState(snap);
    }

    /// @dev Narrow readers over the position manager's 12-field tuple. Reading
    ///      the whole tuple inline in a test body blows the IR stack.
    function _liquidityOf(uint256 tid) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(tid);
    }

    function _bandOf(uint256 tid) internal view returns (int24 lower, int24 upper) {
        (,,,,, lower, upper,,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(tid);
    }

    function _assertPositionBurned(uint256 tid) internal view {
        (bool ok,) = POSITION_MANAGER.staticcall(abi.encodeCall(INonfungiblePositionManager.positions, (tid)));
        assertFalse(ok, "position NFT still exists after settlement");
    }

    function _morphoPosition(address strategy) internal view returns (Position memory) {
        return IMorpho(MORPHO).position(Id.wrap(MARKET_ID), strategy);
    }

    // ==================== 1. FULL LIFECYCLE + LP FEE ACCRUAL ====================

    /// @notice Mint through the real vault, generate REAL swap volume against
    ///         the live pool so fees actually accrue, settle, and prove the fee
    ///         income landed in the VAULT.
    /// @dev    What breaks this: dropping `collect()` from `_closePosition`,
    ///         pushing only one leg at settle, or leaving the collected fees on
    ///         the clone. Each shows up twice — as a shortfall against
    ///         `_deliverableUsdg` (measured with the fees included) and as a
    ///         round trip that no longer pays for itself.
    function test_cl_fullLifecycle_feesReachVault() public {
        _requireFork();

        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vault));
        uint256 ppsBefore = _pricePerShare();

        (address strategy, uint256 proposalId) = _deploy(1_000);

        // ── Execute landed a real position and a real debt ──
        uint256 tid = ConcentratedLiquidityStrategy(strategy).tokenId();
        // Also proves `_rebaseNftIdCounter` wrote the slot it meant to.
        assertGe(tid, NFT_ID_BASE, "position id did not come from the rebased counter");
        assertGt(_liquidityOf(tid), 0, "position holds no liquidity");
        assertGt(_morphoPosition(strategy).borrowShares, 0, "no debt booked");
        assertGt(_morphoPosition(strategy).collateral, 0, "no collateral posted");
        assertEq(
            IERC20(USDG).balanceOf(address(vault)),
            vaultBefore - COLLATERAL,
            "vault paid exactly the approved collateral"
        );
        console2.log("minted liquidity:", uint256(_liquidityOf(tid)));
        console2.log("pool liquidity now:", uint256(pool.liquidity()));

        // ── Real volume across the live pool ──
        _churn(32, 30_000e6);

        (uint256 wethFee, uint256 usdgFee) = _accruedFees(strategy);
        console2.log("accrued WETH fee (wei):", wethFee);
        console2.log("accrued USDG fee (6dp):", usdgFee);
        uint256 feeValue = usdgFee + _wethInUsdg(wethFee);
        console2.log("accrued fee value (USDG):", feeValue);
        assertGt(wethFee, 0, "no token0 fees accrued - churn never crossed the position");
        assertGt(usdgFee, 0, "no token1 fees accrued - churn never crossed the position");

        // ── Settle ──
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION);
        uint256 deliverable = _deliverableUsdg(strategy);
        console2.log("deliverable at settle (USDG):", deliverable);
        // The fee income must be big enough to be visible through the tolerance
        // band below, or the conservation assertion could not detect fees being
        // stranded. Asserted, not assumed.
        assertGt(feeValue, (deliverable * 50) / 10_000, "fee income below the 0.5% conservation band");

        uint256 vaultPreSettle = IERC20(USDG).balanceOf(address(vault));
        governor.settleProposal(proposalId);
        uint256 delivered = IERC20(USDG).balanceOf(address(vault)) - vaultPreSettle;
        console2.log("delivered to vault (USDG):", delivered);

        // ── Nothing stranded ──
        assertEq(ConcentratedLiquidityStrategy(strategy).tokenId(), 0, "tokenId not cleared");
        _assertPositionBurned(tid);
        address[] memory tokens = new address[](3);
        tokens[0] = USDG;
        tokens[1] = WETH;
        tokens[2] = mp.collateralToken;
        _assertNoDust(strategy, tokens);
        assertEq(_morphoPosition(strategy).borrowShares, 0, "debt not fully repaid");
        assertEq(_morphoPosition(strategy).collateral, 0, "collateral not fully withdrawn");
        assertFalse(
            ConcentratedLiquidityStrategy(strategy).hasUndeliveredValue(), "residue reported after a clean settlement"
        );

        // ── Conservation: what the vault received matches what the position
        //    could deliver, within the pool fee + impact the exit swap pays.
        //    `deliverable` was measured WITH the uncollected fees in it, so a
        //    settlement that failed to collect them lands below this floor. ──
        assertGe(delivered, (deliverable * 9_950) / 10_000, "settlement delivered less than the position was worth");
        assertLe(delivered, (deliverable * 10_010) / 10_000, "settlement delivered more than the position was worth");

        // ── The LPs are better off: fee income exceeded the round trip's cost ──
        uint256 vaultAfter = IERC20(USDG).balanceOf(address(vault));
        console2.log("vault USDG before / after:", vaultBefore, vaultAfter);
        assertGt(vaultAfter, vaultBefore, "round trip did not return the LP fee income to the vault");
        assertGt(_pricePerShare(), ppsBefore, "price per share did not rise with the fee income");

        address[] memory holders = new address[](2);
        holders[0] = lp1;
        holders[1] = lp2;
        _assertShareClaimsSolvent(holders);
    }

    // ==================== 2. SETTLEMENT AT AN ADVERSE TICK ====================

    /// @notice Price moves GENUINELY (spot and TWAP together) far below the
    ///         band, so the position is entirely on the volatile side at
    ///         settlement.
    /// @dev    The POSITION unwind must still complete — NFT burned, both legs
    ///         collected, the volatile leg converted through a TWAP-verified
    ///         floor, nothing left on the clone. The MORPHO leg cannot: the LP
    ///         notional is exactly the borrow, so an adverse move leaves the
    ///         position short of its own debt by construction, and the template
    ///         is deliberately deliverable-maximum rather than all-or-revert
    ///         there. What this pins is that the shortfall is accounted for
    ///         rather than lost: delivered + still-stranded == deliverable.
    function test_cl_settleOutOfRange_completeUnwind() public {
        _requireFork();

        (address strategy, uint256 proposalId) = _deploy(1_000);
        uint256 tid = ConcentratedLiquidityStrategy(strategy).tokenId();
        (int24 lower, int24 upper) = _bandOf(tid);
        uint128 collateralPosted = _morphoPosition(strategy).collateral;

        // Drive spot ~2000 ticks (~18%) below the band. token0 = WETH, so a
        // band entirely above spot holds WETH only.
        int24 achieved = _pushTicks(-2_000);
        console2.log("band lower:", int256(lower));
        console2.log("band upper:", int256(upper));
        console2.log("spot after push:", int256(achieved));
        assertLt(achieved, lower, "push did not take spot out of the band");

        // The move is REAL, not a same-block manipulation: warp two TWAP windows
        // so the observation ring reports the new level and `_spotNearTwap()`
        // is true again. Without this the settle path deliberately refuses to
        // convert — that case is `test_cl_residue_manipulatedSpot_*` below.
        vm.warp(vm.getBlockTimestamp() + 2 * TWAP_WINDOW + STRATEGY_DURATION);
        console2.log("spot/TWAP gap at settle (ticks):", _tickGap());
        assertLe(_tickGap(), 1_000, "TWAP did not converge on the new level");

        uint256 deliverable = _deliverableUsdg(strategy);
        console2.log("deliverable at settle (USDG):", deliverable);

        uint256 vaultPreSettle = IERC20(USDG).balanceOf(address(vault));
        governor.settleProposal(proposalId);
        uint256 delivered = IERC20(USDG).balanceOf(address(vault)) - vaultPreSettle;
        console2.log("delivered to vault (USDG):", delivered);

        // ── The POSITION unwind is complete, and the volatile leg WAS converted ──
        assertEq(ConcentratedLiquidityStrategy(strategy).tokenId(), 0, "tokenId not cleared");
        _assertPositionBurned(tid);
        address[] memory tokens = new address[](3);
        tokens[0] = USDG;
        tokens[1] = WETH;
        tokens[2] = mp.collateralToken;
        // Zero WETH is the load-bearing half: spot re-converged on the TWAP, so
        // `_trySwapToAsset` was allowed to sell. Contrast
        // `test_cl_residue_manipulatedSpot_*`, where the same price level
        // reached by manipulation leaves the whole leg unconverted.
        _assertNoDust(strategy, tokens);

        // ── Deliverable maximum, NOT all-or-revert ──
        Position memory pos = _morphoPosition(strategy);
        console2.log("residual debt shares:", uint256(pos.borrowShares));
        console2.log("collateral posted:", uint256(collateralPosted));
        console2.log("collateral remaining:", uint256(pos.collateral));
        assertGt(pos.borrowShares, 0, "an 18% adverse move left no residual debt - premise broken");
        // PASHOV FINDING #8, on a live market: residual debt must not strand the
        // WHOLE collateral. Before that fix this figure was `collateralPosted`.
        assertLt(uint256(pos.collateral), uint256(collateralPosted), "health-preserving partial withdrawal never ran");
        assertTrue(ConcentratedLiquidityStrategy(strategy).hasUndeliveredValue(), "stranded collateral not reported");

        // ── Conservation across an INCOMPLETE settlement: what reached the
        //    vault plus what is still stranded equals what the position was
        //    worth, inside the exit swap's fee + impact. A settlement that lost
        //    the volatile leg, or that filled it below the pool-anchored floor,
        //    breaks this. ──
        uint256 residualNet = IERC4626(mp.collateralToken).convertToAssets(uint256(pos.collateral));
        {
            (,, uint256 tba, uint256 tbs) = IMorpho(MORPHO).expectedMarketBalances(mp);
            uint256 debt = SharesMathLib.toAssetsUp(uint256(pos.borrowShares), tba, tbs);
            residualNet = residualNet > debt ? residualNet - debt : 0;
        }
        console2.log("still stranded, net of debt (USDG):", residualNet);
        assertGe(delivered + residualNet, (deliverable * 9_900) / 10_000, "value vanished across the settlement");
        assertLe(delivered + residualNet, (deliverable * 10_010) / 10_000, "settlement accounted for more than existed");

        // Divergence loss is REAL and must be visible: the position bought WETH
        // all the way down through its band. A settlement that silently returned
        // the principal would mean the LP leg was never marked.
        assertLt(delivered, COLLATERAL + BORROW, "no divergence loss after an 18% adverse move");
    }

    // ==================== 3. UNPRICEABLE RESIDUE / releaseUnconvertible ====================

    /// @notice Settle with spot pushed outside the TWAP bound: `_trySwapToAsset`
    ///         refuses to convert at a manipulated price, so the clone keeps the
    ///         whole volatile leg and the debt goes unpaid.
    /// @dev    Three things are pinned here:
    ///           1. the vault FAILS CLOSED — `hasUndeliveredValue()` is true and
    ///              instant deposits revert `DepositsLocked`, while
    ///              `undeliveredValue()` under-reports (it prices only idle
    ///              vault asset, never the volatile leg or the wrapper), so no
    ///              stamp can ever count value that has not arrived;
    ///           2. `releaseUnconvertible()` hands the residue to the vault
    ///              without anyone minting against it in between — the released
    ///              WETH is NOT the vault asset, so `totalAssets()` does not move;
    ///           3. SUSPECTED BUG, see the block at the end.
    function test_cl_residue_manipulatedSpot_failsClosedAndReleases() public {
        _requireFork();

        (address strategy, uint256 proposalId) = _deploy(1_000);
        uint256 tid = ConcentratedLiquidityStrategy(strategy).tokenId();

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION);

        // Same-block manipulation: push spot far below the band and settle
        // immediately, so the TWAP still reports the pre-push level.
        _pushTicks(-2_000);
        uint256 gap = _tickGap();
        console2.log("spot/TWAP gap at settle (ticks):", gap);
        assertGt(gap, 1_000, "spot is not outside the configured TWAP bound");

        governor.settleProposal(proposalId);

        // ── 1. The volatile leg was NOT sold into the manipulated pool ──
        uint256 wethResidue = IERC20(WETH).balanceOf(strategy);
        console2.log("WETH residue on the clone (wei):", wethResidue);
        assertGt(wethResidue, 0, "settle converted the volatile leg at a manipulated price");
        assertEq(ConcentratedLiquidityStrategy(strategy).tokenId(), 0, "position not unwound");
        _assertPositionBurned(tid);

        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(strategy);
        assertTrue(s.hasUndeliveredValue(), "residue not reported");
        // Under-reports on purpose: only idle vault asset is priced. The WETH
        // leg and the Morpho collateral are worth far more than this figure.
        assertEq(s.undeliveredValue(), IERC20(USDG).balanceOf(strategy), "undeliveredValue priced more than idle asset");
        assertLt(s.undeliveredValue(), _wethInUsdg(wethResidue), "undeliveredValue did not under-report the residue");

        // ── The vault refuses to mint against it ──
        _dealUSDG(outsider, 1_000e6);
        vm.startPrank(outsider);
        IERC20(USDG).approve(address(vault), 1_000e6);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, outsider);
        vm.stopPrank();

        // ── 2. The escape hatch hands the residue over, uncounted ──
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(address(vault));
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        // Permissionless by design, and still is — but through the vault, so
        // any VAULT ASSET the hatch converts on its way is measured and split
        // with the exited cohort. The clone-side function is vault-only.
        uint256 released = _releaseUnconvertible(strategy, outsider);

        assertEq(released, wethResidue, "released amount does not match the residue");
        assertEq(IERC20(WETH).balanceOf(strategy), 0, "residue still on the clone");
        assertEq(
            IERC20(WETH).balanceOf(address(vault)),
            vaultWethBefore + released,
            "released residue did not reach the vault"
        );
        // The release mints nothing and prices nothing: WETH is not the vault
        // asset, so `totalAssets()` is untouched and no share was created
        // against unpriced value.
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets moved on an unpriced token");
        assertEq(vault.totalSupply(), supplyBefore, "shares minted against unpriced value");

        // ── 3. SUSPECTED BUG: the release FORECLOSES the only permissionless
        //    recovery, and the vault stays deposit-locked forever.
        //
        //    `_repayAndWithdraw` could not repay (the clone held no vault asset
        //    at settle, only WETH), so the debt survives and the collateral is
        //    pinned behind it — `_withdrawableWhileHealthy` frees only the slice
        //    above the LLTV buffer. `hasUndeliveredValue()` keys on that
        //    collateral, so deposits stay shut.
        //
        //    `SyndicateVault._depositsLocked` justifies locking with "NOBODY IS
        //    WEDGED BY THIS. `sweep()` is permissionless and untaxed, so the
        //    very depositor this refuses can call it and then deposit at the
        //    correct price." That claim does not survive this path:
        //    `releaseUnconvertible()` is equally permissionless and has just
        //    moved the only asset `sweep()` could have converted into the repay,
        //    so every later sweep — even once the pool is honest again —
        //    recovers nothing and the lock never clears without the vault owner
        //    manually rescuing the WETH and sending it back to the clone.
        //    `releaseUnconvertible`'s own natspec anticipates the foreclosure
        //    ("pushing on every sweep would FORECLOSE the conversion") but
        //    prices it as "the owner sells it manually", not as an indefinite
        //    vault-wide deposit lock any passer-by can trigger for the price of
        //    one manipulated block.
        Position memory pos = _morphoPosition(strategy);
        console2.log("residual debt shares:", uint256(pos.borrowShares));
        console2.log("stranded collateral (spUSDG):", uint256(pos.collateral));
        assertGt(pos.borrowShares, 0, "no residual debt - scenario did not reproduce");
        assertGt(pos.collateral, 0, "no stranded collateral - scenario did not reproduce");
        assertTrue(s.hasUndeliveredValue(), "collateral stranded behind debt is not reported");

        // Let the pool become honest again — the TWAP walks to spot — and give
        // the permissionless recovery every chance.
        vm.warp(vm.getBlockTimestamp() + 2 * TWAP_WINDOW);
        assertLe(_tickGap(), 1_000, "TWAP did not converge - sweep would be refused for the right reason");
        // `sweep()` is vault-only now; `collectResidue` is the permissionless
        // door and drives it, so this still tests "anyone can recover".
        uint256 recovered = _collectResidue(address(s));
        console2.log("sweep recovered (USDG):", recovered);
        // Not exactly zero: wrapper yield since settlement nudges
        // `_withdrawableWhileHealthy` up by a few wei of USDG. The point is the
        // ORDER OF MAGNITUDE — a residue worth thousands of USDG was released
        // away, and the permissionless retry can now recover cents.
        assertLt(recovered, _wethInUsdg(released) / 100, "sweep still recovers the residue after a release");
        assertTrue(s.hasUndeliveredValue(), "vault unlocked without the residue ever being delivered");

        vm.startPrank(outsider);
        IERC20(USDG).approve(address(vault), 1_000e6);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, outsider);
        vm.stopPrank();
    }

    // ==================== 4. THE TWAP GUARD, AGAINST LIVE OBSERVATIONS ====================

    /// @notice A spot/TWAP divergence beyond the configured bound is REFUSED on
    ///         the permissionless rerange path.
    /// @dev    `rerange()` checks the TWAP before the trigger, so the revert can
    ///         only be the guard. The measured gap is asserted first, so a test
    ///         that failed to move the pool cannot pass by accident.
    function test_cl_twapGuard_rerangeRevertsOnPushedSpot() public {
        _requireFork();

        // WIDE band on purpose — see the sibling test: with a +/-360 band the
        // re-mint's own 10% amount floor rejects a rerange long before a 2%
        // TWAP divergence does, so a narrow band cannot tell the two guards
        // apart. +/-3600 admits up to ~190 ticks of off-centre, which brackets
        // the 200-tick bound under test.
        (address strategy,) = _deploy(200); // 2% bound ~ 200 ticks

        int24 twapBefore = _twapTick();
        _pushTicks(600);
        uint256 gap = _tickGap();
        console2.log("TWAP before push:", int256(twapBefore));
        console2.log("gap after push (ticks):", gap);
        assertGt(gap, 200, "push did not exceed the configured bound");

        vm.prank(keeper);
        vm.expectRevert(ConcentratedLiquidityStrategy.SpotOutsideTwapBound.selector);
        ConcentratedLiquidityStrategy(strategy).rerange();
    }

    /// @notice The same guard, just INSIDE the bound, admits the rerange.
    /// @dev    The counterpart to the case above: a guard that never admits
    ///         anything is indistinguishable from one that is always tripping.
    ///         The gap is asserted to be non-zero as well as within bound, so
    ///         the comparison is real rather than spot-against-itself.
    function test_cl_twapGuard_rerangeSucceedsInsideBound() public {
        _requireFork();

        (address strategy,) = _deploy(200);
        uint256 oldTokenId = ConcentratedLiquidityStrategy(strategy).tokenId();

        // Inside the 200-tick bound, but not trivially so. MEASURED, since the
        // ceiling here is not the guard: `_mintPosition` floors both legs at
        // `10_000 - rerange.slippageBps` of what it was offered, and a rerange
        // that lands `o` ticks off the centre of a band of half-width `h`
        // consumes only `(h-o)/(h+o)` of the over-supplied leg — so the re-mint
        // reverts "Price slippage check" once `o > h/19`. On the +/-360 band the
        // other tests use that is 19 ticks, which is why this pair runs on the
        // wide band instead.
        _pushTicks(100);
        uint256 gap = _tickGap();
        console2.log("gap after push (ticks):", gap);
        assertGt(gap, 0, "no divergence at all - the guard was never exercised");
        assertLe(gap, 200, "push overshot the configured bound");

        vm.prank(keeper);
        uint256 newTokenId = ConcentratedLiquidityStrategy(strategy).rerange();

        assertTrue(newTokenId != oldTokenId, "rerange did not replace the position");
        assertEq(ConcentratedLiquidityStrategy(strategy).tokenId(), newTokenId, "tokenId not updated");
        assertGt(_liquidityOf(newTokenId), 0, "re-minted position is empty");
        _assertPositionBurned(oldTokenId);
        // The borrow is untouched by a rerange, by construction.
        assertGt(_morphoPosition(strategy).borrowShares, 0, "rerange disturbed the debt");
    }
}
