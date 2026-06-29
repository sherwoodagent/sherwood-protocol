// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase, IAggregatorV3} from "../integration/strategies/LeveragedAeroForkBase.sol";
import {BaseAddresses} from "../integration/strategies/BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroCLHandler, MockVaultShares} from "./handlers/LeveragedAeroCLHandler.sol";
import {ICLPool, ICLSwapRouter} from "../../src/interfaces/ISlipstream.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";

/// @title  LeveragedAeroCLInvariants
/// @notice Task 3.12b — bounded invariant fuzzing of the leveraged Aerodrome-CL strategy
///         against a real Base fork. Each handler op is a Tenderly-vnet RPC round-trip, so the
///         budget is intentionally small (runs=12 × depth=15 ≈ 180 calls). The handler is
///         designed to MOSTLY SUCCEED (funded/bounded deposits, held-share redeems, pranked
///         proposer ops, AERO dealt before compound) and to bracket every op with the
///         manipulation-immune oracle NAV.
///
///         Invariants (priority order from the task):
///           (d) REDEEM CONSERVATION — per-share oracle NAV of the continuous stayer is
///               non-decreasing within a per-op slack budget (THE headline; the two real skims
///               this phase were a +79% and a −3.2% stayer loss).
///           (b) HEALTH — health >= minHealthBps after every successful non-deleverage op.
///           (c) totalSupply CONSERVED — holder-sum == totalSupply == ghost(mint − burn + fee).
///           (a) NO EXFIL — Σ redeem payout ≤ Σ oracle-fair entitlement (+5%).
///           (e) NO PHANTOM FEE — deposits-only ⇒ zero fee-shares (deterministic anchor below).
///
///         (f) CowSwap-order invariant is N/A — `compound` is synchronous (no async order).
///
/// forge-config: default.invariant.runs = 20
/// forge-config: default.invariant.depth = 20
/// forge-config: default.invariant.fail-on-revert = false
contract LeveragedAeroCLInvariants is StdInvariant, LeveragedAeroForkBase {
    LeveragedAerodromeCLStrategy internal strategy;
    MockVaultShares internal vaultShares;
    LeveragedAeroCLHandler internal handler;

    address internal stayer; // depositorA — never transacts
    address internal feeRecipient;
    address internal proposer;

    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint16 internal constant MAX_LTV_BPS = 6500;
    uint16 internal constant MIN_HEALTH_BPS = 12000;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;

    uint256 internal constant PRINCIPAL = 50_000e6;
    uint256 internal constant DEPOSITOR_A_SHARES = PRINCIPAL * 1e6; // ERC-4626 virtual offset 1e6

    function setUp() public override {
        super.setUp(); // forks (or sets _skip when TENDERLY_FORK_RPC_URL is unset → CI-safe)

        stayer = makeAddr("aero_stayer");
        feeRecipient = makeAddr("aero_feeRecipient");
        proposer = makeAddr("aero_proposer");

        vaultShares = new MockVaultShares(stayer, DEPOSITOR_A_SHARES);

        address clone = Clones.clone(address(new LeveragedAerodromeCLStrategy()));
        strategy = LeveragedAerodromeCLStrategy(payable(clone));

        if (!_skip) {
            // Modest fees so the mixed fuzz still exercises crystallisation; (e) is checked
            // separately on a deposits-only sequence.
            strategy.initialize(address(vaultShares), proposer, abi.encode(_initParams(100, 1000, feeRecipient)));
            _fundUSDC(address(strategy), PRINCIPAL);
            vm.prank(address(vaultShares));
            strategy.execute();
        }

        handler = new LeveragedAeroCLHandler(strategy, vaultShares, proposer, stayer, feeRecipient, !_skip);

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = LeveragedAeroCLHandler.deposit.selector;
        sel[1] = LeveragedAeroCLHandler.redeem.selector;
        sel[2] = LeveragedAeroCLHandler.deployIdle.selector;
        sel[3] = LeveragedAeroCLHandler.compound.selector;
        sel[4] = LeveragedAeroCLHandler.rerange.selector;
        sel[5] = LeveragedAeroCLHandler.adjustLeverage.selector;
        sel[6] = LeveragedAeroCLHandler.deleverage.selector;
        sel[7] = LeveragedAeroCLHandler.shove.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));

        if (!_skip) {
            // Warm the state so redeems / deployIdle are reachable from call 1 (improves
            // non-vacuity). Routed THROUGH the handler so ghost accounting stays consistent.
            handler.deposit(0, 8_000e6);
            handler.deposit(1, 12_000e6);
            handler.deployIdle(type(uint256).max);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Invariants
    // ─────────────────────────────────────────────────────────────

    /// @notice (d) THE headline — stayer's per-share oracle NAV never skimmed beyond per-op slack.
    function invariant_redeemConservation() public view {
        if (_skip) return;
        assertFalse(handler.conservationViolated(), "INV-d: stayer per-share oracle NAV skimmed");
    }

    /// @notice (b) Post-op health >= minHealthBps (deleverage / unhealthy-mock windows excluded).
    function invariant_health() public view {
        if (_skip) return;
        assertFalse(handler.healthViolated(), "INV-b: health fell below minHealthBps");
    }

    /// @notice (c) totalSupply conserved two independent ways: holder-sum AND ghost mint−burn+fee.
    function invariant_totalSupplyConserved() public view {
        if (_skip) return;
        uint256 ts = vaultShares.totalSupply();

        // Holder-sum: every share lives with a known holder (stayer / actors / fee recipient /
        // strategy-transient). Sums to totalSupply iff no share leaked.
        uint256 sum = vaultShares.balanceOf(stayer) + vaultShares.balanceOf(feeRecipient)
            + vaultShares.balanceOf(address(strategy));
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            sum += vaultShares.balanceOf(handler.actorAt(i));
        }
        assertEq(ts, sum, "INV-c: totalSupply diverged from holder ledger");

        // Independent ghost: initial + deposit mints + fee-share mints − redeem burns.
        uint256 ghost =
            DEPOSITOR_A_SHARES + handler.ghostMinted() + vaultShares.balanceOf(feeRecipient) - handler.ghostBurned();
        assertEq(ts, ghost, "INV-c: totalSupply diverged from mint/burn ghost");
    }

    /// @notice (a) NO EXFIL — strategy pays redeemers no more than their oracle-fair entitlement
    ///         (+5% tolerance for realizing own LP at a shoved tick vs the conservative oracle mark).
    function invariant_noExfil() public view {
        if (_skip) return;
        uint256 fair = handler.ghostFairOut();
        if (fair == 0) return; // no redeems yet
        assertLe(handler.ghostPaidOut(), (fair * 10500) / 10000, "INV-a: redeemer over-paid (exfil)");
    }

    /// @notice Non-vacuity gate + call summary.
    function afterInvariant() external view {
        if (_skip) return;
        assertGt(handler.opCount(), 0, "fuzz vacuous: handler never called");
        assertGt(handler.depositOk() + handler.redeemOk(), 0, "fuzz vacuous: no deposit/redeem landed");
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _initParams(uint16 mgmt, uint16 perf, address feeRcpt)
        internal
        pure
        returns (LeveragedAerodromeCLStrategy.InitParams memory p)
    {
        p = LeveragedAerodromeCLStrategy.InitParams({
            usdc: BaseAddresses.USDC,
            mUsdc: BaseAddresses.MOONWELL_MUSDC,
            mCbBTC: BaseAddresses.MOONWELL_MCBBTC,
            mWeth: BaseAddresses.MOONWELL_MWETH,
            comptroller: BaseAddresses.MOONWELL_COMPTROLLER,
            cbBTC: BaseAddresses.CBBTC,
            weth: BaseAddresses.WETH,
            pool: BaseAddresses.CBBTC_WETH_POOL,
            npm: BaseAddresses.SLIPSTREAM_NPM,
            gauge: BaseAddresses.CBBTC_WETH_GAUGE,
            swapRouter: BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER,
            cbBTCFeed: BaseAddresses.CHAINLINK_BTC_USD,
            wethFeed: BaseAddresses.CHAINLINK_ETH_USD,
            usdcFeed: BaseAddresses.CHAINLINK_USDC_USD,
            sequencerFeed: BaseAddresses.SEQUENCER_UPTIME_FEED,
            maxDelay: 48 hours,
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: BaseAddresses.CBBTC_WETH_TICK_SPACING,
            targetLtvBps: TARGET_LTV_BPS,
            maxLtvBps: MAX_LTV_BPS,
            minHealthBps: MIN_HEALTH_BPS,
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            managementFeeBps: mgmt,
            performanceFeeBps: perf,
            feeRecipient: feeRcpt
        });
    }
}

/// @title  LeveragedAeroCLConservationAnchors
/// @notice Deterministic anchors that GUARANTEE coverage of the properties the bounded fuzz may
///         not reach at runs=12/depth=15 — the headline triple-coincidence (d), the deposits-only
///         no-phantom-fee (e), and the deleverage health window (b). These run regardless of the
///         fuzz budget and are the "tighter targeted fork sequence" fallback the task prescribes.
contract LeveragedAeroCLConservationAnchors is LeveragedAeroForkBase {
    address internal stayer; // depositorA
    address internal depositorB;
    address internal feeRecipient;
    address internal proposer;
    address internal stranger;

    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint16 internal constant MAX_LTV_BPS = 6500;
    uint16 internal constant MIN_HEALTH_BPS = 12000;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;

    uint256 internal constant PRINCIPAL = 50_000e6;
    uint256 internal constant DEPOSITOR_A_SHARES = PRINCIPAL * 1e6;

    function setUp() public override {
        super.setUp();
        stayer = makeAddr("anchor_stayer");
        depositorB = makeAddr("anchor_depositorB");
        feeRecipient = makeAddr("anchor_feeRecipient");
        proposer = makeAddr("anchor_proposer");
        stranger = makeAddr("anchor_stranger");
    }

    // ─────────────────────────────────────────────────────────────
    // (d) headline — post-rerange partial redeem under IL: stayer must stay whole
    // ─────────────────────────────────────────────────────────────

    /// @notice The triple-coincidence the two real skims required: a rerange remainder of ONE leg
    ///         (I_leg > 0), a hard IL shortfall on the SAME leg, and a PARTIAL redeem (f < 1).
    ///         Arbiter = the stayer's per-share ORACLE NAV (oracle-implied sqrtP + Chainlink, no
    ///         calm-gate → immune to the shove): it must be NON-DECREASING across the redeem.
    function test_anchor_conservation_postRerangePartialRedeemUnderIL() public {
        if (_skip) return;
        require(ICLPool(POOL).token0() == WETH, "fork: expected pool token0 == WETH");

        // Zero-fee book so fee crystallisation never confounds the conservation delta.
        (LeveragedAerodromeCLStrategy strat, MockVaultShares v, LeveragedAeroCLHandler h) = _freshBook(0, 0);

        // Second LP so the partial redeem leaves the stayer (depositorA).
        uint256 sharesB = _depositFrom(strat, depositorB, 10_000e6);
        assertGt(sharesB, 0, "B got 0 shares");

        // Drain idle USDC so the ONLY idle asset becomes the rerange remainder leg.
        uint256 idle = IERC20(USDC).balanceOf(address(strat));
        vm.prank(proposer);
        strat.deployIdle(idle, 0);
        assertEq(IERC20(USDC).balanceOf(address(strat)), 0, "idle USDC not drained");

        // (a) In-band drift ~450 ticks down, then no-swap recenter → idle remainder of ONE leg.
        (, int24 t0,,,,) = ICLPool(POOL).slot0();
        _shoveToTickDown(t0 - 450);
        vm.prank(proposer);
        strat.rerange(0, 0);
        uint256 idleCb = IERC20(CBBTC).balanceOf(address(strat));
        uint256 idleWeth = IERC20(WETH).balanceOf(address(strat));
        assertTrue(idleCb > 0 || idleWeth > 0, "rerange left no idle remainder leg");

        // (b) Hard shove to drive a real IL shortfall on the SAME leg as the remainder.
        bool remainderIsWeth = idleWeth >= idleCb;
        if (remainderIsWeth) _shoveTick(200e8, false); // sell cbBTC → tick UP → WETH under-collected
        else _shoveTick(2_000e18, true); // sell WETH → tick DOWN → cbBTC under-collected
        {
            (, int24 tShoved,,,,) = ICLPool(POOL).slot0();
            int24 pl = strat.layout().posTickLower;
            int24 pu = strat.layout().posTickUpper;
            assertTrue(tShoved < pl || tShoved > pu, "shove did not push LP out of range");
        }

        // Snapshot stayer per-share BEFORE the partial redeem.
        uint256 supplyBefore = v.totalSupply();
        uint256 navBefore = h.oracleNavNoGate();
        uint256 perShareBefore = h.perShareNoGate();

        // (c) PARTIAL redeem: depositorB redeems ALL of B's shares (f < 1), leaving the stayer.
        vm.prank(depositorB);
        v.approve(address(strat), sharesB);
        vm.prank(depositorB);
        uint256 assetsOut = strat.redeem(sharesB, 0);

        uint256 supplyAfter = v.totalSupply();
        assertEq(supplyAfter, supplyBefore - sharesB, "supply bookkeeping");
        uint256 perShareAfter = h.perShareNoGate();

        emit log_named_uint("perShareBefore (1e18)", perShareBefore);
        emit log_named_uint("perShareAfter  (1e18)", perShareAfter);
        emit log_named_uint("assetsOut (USDC)", assetsOut);
        emit log_named_uint("fairShare (USDC)", (navBefore * sharesB) / supplyBefore);

        // PRIMARY arbiter: stayer per-share NON-DECREASING (buggy code dropped ~3.2%; fix keeps it
        // dust-flat). Tight 0.1% tolerance — only mulDiv dust is permitted here (pure redeem path).
        assertGe(perShareAfter, (perShareBefore * 999) / 1000, "STAYER SKIM: per-share NAV dropped");

        // SECONDARY: redeemer must not be grossly over-paid (the pre-fix skim drove ~17.5% over fair).
        uint256 fairShare = (navBefore * sharesB) / supplyBefore;
        assertLe(assetsOut, (fairShare * 105) / 100, "redeemer grossly over-paid (skimmed stayers)");
    }

    // ─────────────────────────────────────────────────────────────
    // (e) no phantom fee — deposits-only ⇒ zero fee-shares
    // ─────────────────────────────────────────────────────────────

    /// @notice A sequence of ONLY deposits grows neither per-share NAV (deposits are NAV-neutral)
    ///         nor the clock (frozen fork ⇒ dt = 0), so NO performance fee and NO management fee
    ///         may be minted. feeRecipient share balance must stay exactly 0.
    function test_anchor_noPhantomFee_depositsOnly() public {
        if (_skip) return;

        // Non-zero fee config — the whole point is that NONE crystallises on deposits.
        (LeveragedAerodromeCLStrategy strat, MockVaultShares v, LeveragedAeroCLHandler h) = _freshBook(100, 1000);

        uint256 perShare0 = h.perShareNoGate();
        assertEq(v.balanceOf(feeRecipient), 0, "fee shares minted before any deposit");

        _depositFrom(strat, depositorB, 5_000e6);
        assertEq(v.balanceOf(feeRecipient), 0, "phantom fee after deposit 1");
        _depositFrom(strat, stranger, 3_000e6);
        assertEq(v.balanceOf(feeRecipient), 0, "phantom fee after deposit 2");
        _depositFrom(strat, depositorB, 9_000e6);
        assertEq(v.balanceOf(feeRecipient), 0, "phantom fee after deposit 3");

        // Per-share oracle NAV flat across deposits (deposits mint at the oracle mark).
        uint256 perShare1 = h.perShareNoGate();
        assertApproxEqRel(perShare1, perShare0, 0.002e18, "deposits moved per-share NAV");
    }

    // ─────────────────────────────────────────────────────────────
    // (b) health — deleverage window: unhealthy is the EXCLUDED window, then restored
    // ─────────────────────────────────────────────────────────────

    /// @notice An adverse Chainlink move pushes health < minHealthBps (the deliberate
    ///         unhealthy-inducing window the health invariant excludes); the permissionless
    ///         `deleverage` then strictly improves health — invariant (b) holds outside the window.
    function test_anchor_health_deleverageWindow() public {
        if (_skip) return;

        (LeveragedAerodromeCLStrategy strat,, LeveragedAeroCLHandler h) = _freshBook(0, 0);

        // Healthy at open (invariant (b) holds).
        assertGe(h.healthBps(), MIN_HEALTH_BPS, "fresh book should be healthy");

        // EXCLUDED window: mock BTC/USD 3× → net-short cbBTC debt triples → health < min.
        _mockBtcScaled(3, 1);
        uint256 unhealthy = h.healthBps();
        assertLt(unhealthy, MIN_HEALTH_BPS, "mock did not push health below min");

        // Permissionless safety valve (a non-proposer stranger) restores the buffer.
        vm.prank(stranger);
        strat.deleverage(0);

        uint256 restored = h.healthBps();
        assertGt(restored, unhealthy, "deleverage did not improve health");
        assertGe(restored, MIN_HEALTH_BPS, "deleverage did not restore health to >= min");

        vm.clearMockedCalls();
    }

    // ─────────────────────────────────────────────────────────────
    // Anchor helpers
    // ─────────────────────────────────────────────────────────────

    /// @dev Open a fresh levered book (stayer holds the initial DEPOSITOR_A_SHARES) and bind a
    ///      handler to it purely as the oracle-NAV / health reader (the §7 arbiter).
    function _freshBook(uint16 mgmt, uint16 perf)
        internal
        returns (LeveragedAerodromeCLStrategy strat, MockVaultShares v, LeveragedAeroCLHandler h)
    {
        v = new MockVaultShares(stayer, DEPOSITOR_A_SHARES);
        strat = LeveragedAerodromeCLStrategy(payable(Clones.clone(address(new LeveragedAerodromeCLStrategy()))));
        strat.initialize(address(v), proposer, abi.encode(_initParams(mgmt, perf)));
        _fundUSDC(address(strat), PRINCIPAL);
        vm.prank(address(v));
        strat.execute();
        h = new LeveragedAeroCLHandler(strat, v, proposer, stayer, feeRecipient, true);
    }

    function _depositFrom(LeveragedAerodromeCLStrategy strat, address who, uint256 amt)
        internal
        returns (uint256 shares)
    {
        _fundUSDC(who, amt);
        vm.prank(who);
        IERC20(USDC).approve(address(strat), amt);
        vm.prank(who);
        shares = strat.deposit(amt, 0);
    }

    /// @dev Bounded in-band DOWN shove (sell WETH, stop at `targetTick` via sqrtPriceLimit) — stays
    ///      inside the calm band so the subsequent `rerange` calm-gate passes. (Ports the redeem
    ///      fork test's `_shoveToTickDown`.)
    function _shoveToTickDown(int24 targetTick) internal {
        address shover = makeAddr("anchor_inband_shover");
        uint256 wethIn = 1_000e18;
        _fundWETH(shover, wethIn);
        vm.startPrank(shover);
        IERC20(WETH).approve(CL_ROUTER, wethIn);
        ICLSwapRouter(CL_ROUTER)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: CBBTC,
                tickSpacing: TICK_SPACING,
                recipient: shover,
                deadline: block.timestamp + 600,
                amountIn: wethIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(targetTick)
            })
            );
        vm.stopPrank();
    }

    /// @dev Scale the BTC/USD feed by num/den, preserving fresh round metadata (ports the leverage
    ///      fork test's `_mockBtcScaled`).
    function _mockBtcScaled(uint256 num, uint256 den) internal {
        address feed = BaseAddresses.CHAINLINK_BTC_USD;
        (uint80 rid, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 air) =
            IAggregatorV3(feed).latestRoundData();
        int256 scaled = (ans * int256(num)) / int256(den);
        vm.mockCall(
            feed, abi.encodeWithSignature("latestRoundData()"), abi.encode(rid, scaled, startedAt, updatedAt, air)
        );
    }

    function _initParams(uint16 mgmt, uint16 perf)
        internal
        view
        returns (LeveragedAerodromeCLStrategy.InitParams memory p)
    {
        p = LeveragedAerodromeCLStrategy.InitParams({
            usdc: BaseAddresses.USDC,
            mUsdc: BaseAddresses.MOONWELL_MUSDC,
            mCbBTC: BaseAddresses.MOONWELL_MCBBTC,
            mWeth: BaseAddresses.MOONWELL_MWETH,
            comptroller: BaseAddresses.MOONWELL_COMPTROLLER,
            cbBTC: BaseAddresses.CBBTC,
            weth: BaseAddresses.WETH,
            pool: BaseAddresses.CBBTC_WETH_POOL,
            npm: BaseAddresses.SLIPSTREAM_NPM,
            gauge: BaseAddresses.CBBTC_WETH_GAUGE,
            swapRouter: BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER,
            cbBTCFeed: BaseAddresses.CHAINLINK_BTC_USD,
            wethFeed: BaseAddresses.CHAINLINK_ETH_USD,
            usdcFeed: BaseAddresses.CHAINLINK_USDC_USD,
            sequencerFeed: BaseAddresses.SEQUENCER_UPTIME_FEED,
            maxDelay: 48 hours,
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: BaseAddresses.CBBTC_WETH_TICK_SPACING,
            targetLtvBps: TARGET_LTV_BPS,
            maxLtvBps: MAX_LTV_BPS,
            minHealthBps: MIN_HEALTH_BPS,
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            managementFeeBps: mgmt,
            performanceFeeBps: perf,
            feeRecipient: feeRecipient
        });
    }
}
