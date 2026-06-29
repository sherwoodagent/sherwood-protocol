// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {LiquidityAmounts} from "../libraries/LiquidityAmounts.sol";
import {ChainlinkReader} from "../libraries/ChainlinkReader.sol";
import {IMoonwellMarket, IComptroller, ICToken} from "../interfaces/IMoonwellMarket.sol";
import {ICLPool, ICLGauge, INonfungiblePositionManager, ICLSwapRouter} from "../interfaces/ISlipstream.sol";

/// @dev Minimal WETH9 interface — wraps native ETH into ERC-20 WETH.
interface IWETH9 {
    function deposit() external payable;
}

/// @dev Minimal Aerodrome v2 (AMM) Router interface — the deepest AERO/USDC venue on Base
///      is the v2 volatile pool, so the `compound()` reward swap routes through this router
///      (mirrors the v2-swap pattern in `WstETHMoonwellStrategy`). The CL SwapRouter
///      (`$.swapRouter`) only serves Slipstream CL pools, which are far shallower for AERO/USDC.
interface IAeroRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @title  LeveragedAeroManager
/// @notice DEPLOYED, delegatecalled venue library for `LeveragedAerodromeCLStrategy`.
///
///         The strategy clone is at the EIP-170 bytecode margin, so the heavy on-venue
///         sequences (supply / borrow / mint / stake / unwind / repay / swap) live here
///         and are reached via `LeveragedAeroManager.xxxImpl()` — a `public` library
///         function call compiles to `DELEGATECALL`, so this code runs **in the clone's
///         context**: `address(this)` is the clone, `_s()` resolves to the clone's
///         ERC-7201 diamond storage, and every Moonwell / Slipstream / gauge call acts on
///         the clone's position. Mirrors the already-deployed `LeveragedAeroValuation`
///         delegatecall pattern.
///
///         **Slot discipline (corruption-critical):** the `Layout` struct, the
///         `STORAGE_SLOT` constant, and the `_s()` accessor are byte-for-byte identical to
///         the strategy's — they MUST stay in lockstep or a delegatecall would read/write
///         the wrong slots. Do not reorder `Layout` fields in one file without the other.
///
///         This library never touches `vault()` / `proposer()` / shares / fees — those stay
///         in the strategy entrypoints. It only reads config + position state from `_s()`
///         and performs venue calls. It may delegatecall the deployed `LeveragedAeroValuation`
///         (e.g. `_calmGate`) — nested delegatecall from the clone is fine.
library LeveragedAeroManager {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    // Errors (selectors match the strategy's declarations 1:1, so a
    // test's `vm.expectRevert(LeveragedAerodromeCLStrategy.X.selector)`
    // still matches a revert thrown from here)
    // ─────────────────────────────────────────────────────────────

    error UnhealthyPosition(uint256 ltvBps, uint256 limitBps);
    error InvalidNpmReturn();
    error ExecuteZeroBalance();
    error MoonwellMintFailed(uint256 errCode);
    error MoonwellBorrowFailed(uint256 errCode);
    error NpmMintFailed();
    error NpmApproveFailed();
    error MoonwellRepayFailed(uint256 errCode);
    error MoonwellRedeemFailed(uint256 errCode);
    error InsufficientLiquidity();
    error InsufficientIdle();
    /// @dev `deleverage()` called while the position is at/above `minHealthBps` (no-op when safe).
    error HealthyNoDeleverage();

    // ─────────────────────────────────────────────────────────────
    // Constants (duplicated from the strategy — compile-time literals)
    // ─────────────────────────────────────────────────────────────

    /// @dev cbBTC is always 8-decimal wrapped Bitcoin.
    uint8 private constant CBBTC_DECIMALS = 8;
    /// @dev WETH is always 18-decimal (WETH9 on Base).
    uint8 private constant WETH_DECIMALS = 18;
    /// @dev Number of tick-spacings on each side of the current tick for the initial CL range.
    uint8 private constant RANGE_TICK_SPACINGS = 20;
    /// @dev `deleverage()` repays down to `minHealthBps × (1 + this/1e4)` — a small buffer above the
    ///      minimum so a rescue does not land exactly on the threshold and immediately re-trigger.
    uint16 private constant DELEVERAGE_BUFFER_BPS = 500; // +5% above minHealthBps

    /// @dev Aerodrome v2 (AMM) Router on Base — the AERO→USDC reward swap in `compoundImpl`
    ///      routes through its volatile pool, the deepest AERO/USDC liquidity on Base
    ///      (~$10.4M vs ~$1.2M for the deepest Slipstream CL pool, fork-measured). Canonical
    ///      immutable Base infra, baked into the deployed manager (like the hardcoded CL
    ///      `tickSpacing` in the swap helpers).
    address private constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    /// @dev Aerodrome v2 PoolFactory on Base (`router.defaultFactory()`), required by the Route.
    address private constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    // ─────────────────────────────────────────────────────────────
    // Diamond storage — MUST match LeveragedAerodromeCLStrategy exactly
    // ─────────────────────────────────────────────────────────────

    /// @custom:storage-location erc7201:leveraged.aero.cl.storage
    struct Layout {
        // ── valuation config: token / venue / feed addresses ──
        address usdc;
        address mUsdc;
        address mCbBTC; // maps to LeveragedAeroValuation.Config.cbBTCMarket
        address mWeth; // maps to LeveragedAeroValuation.Config.wethMarket
        address cbBTC;
        address weth;
        address pool;
        address cbBTCFeed;
        address wethFeed;
        address usdcFeed;
        address sequencerFeed;
        uint256 maxDelay;
        uint256 gracePeriod;
        uint16 calmDeviationTicks;
        uint32 twapWindow;
        // ── venue / protocol addresses (not in Config) ──
        address comptroller;
        address npm;
        address gauge;
        address swapRouter;
        int24 tickSpacing;
        // ── risk params ──
        uint16 targetLtvBps;
        uint16 maxLtvBps;
        uint16 minHealthBps;
        uint16 maxSlippageBps;
        uint16 usdcCollateralFactorBps;
        // ── position state ──
        uint256 tokenId;
        int24 posTickLower;
        int24 posTickUpper;
        // ── fee params + state ──
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        address feeRecipient;
        uint256 hwmPerShare;
        uint256 lastFeeAccrualTimestamp;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @dev Diamond-storage accessor — resolves to the clone's storage under delegatecall.
    function _s() private pure returns (Layout storage l) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            l.slot := STORAGE_SLOT
        }
    }

    // ═════════════════════════════════════════════════════════════
    // PUBLIC IMPLS (delegatecalled by the strategy entrypoints)
    // ═════════════════════════════════════════════════════════════

    /// @notice Open the levered cbBTC/WETH CL position (body of the strategy's `_execute`).
    ///         supply USDC → enterMarkets → borrow cbBTC+WETH → wrap → mint CL → stake gauge.
    function executeImpl() public {
        uint256 usdcAmt = _supplyCollateral();
        (uint256 cbBTCAmt, uint256 wethAmt) = _computeAndBorrow(usdcAmt);
        _wrapNativeEth();
        _mintAndStake(cbBTCAmt, wethAmt);
        _assertHealthy();
    }

    /// @notice Full proportional unwind to the strategy (body of the strategy's `_settle`,
    ///         steps 1-6). The strategy pushes the realized USDC to the vault afterward.
    /// @return realizedUsdc USDC held by the strategy after the unwind (the amount the
    ///         strategy then forwards to the vault).
    function settleImpl() public returns (uint256 realizedUsdc) {
        Layout storage $ = _s();
        // 1+2. Unstake + remove 100% liquidity + collect (num==den → no restake)
        _unwindLiquidity(1, 1);
        // 3. Repay both Moonwell borrows (handles shortfall)
        _settleRepayDebts();
        // 4. Redeem all remaining mUSDC collateral (debt = 0 now)
        uint256 mBal = ICToken($.mUsdc).balanceOf(address(this));
        if (mBal > 0) {
            uint256 err = ICToken($.mUsdc).redeem(mBal);
            if (err != 0) revert MoonwellRedeemFailed(err);
        }
        // 5. Sweep residual WETH + cbBTC → USDC (Chainlink-bounded min-out)
        {
            (uint256 pBTC,) = ChainlinkReader.readUsd($.cbBTCFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
            (uint256 pETH,) = ChainlinkReader.readUsd($.wethFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
            (uint256 pUsdc,) = ChainlinkReader.readUsd($.usdcFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
            uint256 slip = uint256($.maxSlippageBps);
            _swapTokenToUsdc(
                $.weth,
                _tokenToUsdc(IERC20($.weth).balanceOf(address(this)), WETH_DECIMALS, pETH, pUsdc) * (10000 - slip)
                    / 10000
            );
            _swapTokenToUsdc(
                $.cbBTC,
                _tokenToUsdc(IERC20($.cbBTC).balanceOf(address(this)), CBBTC_DECIMALS, pBTC, pUsdc) * (10000 - slip)
                    / 10000
            );
        }
        // 6. Clear position state (flat-book invariant: nav() reads tokenId==0 branch)
        $.tokenId = 0;
        $.posTickLower = 0;
        $.posTickUpper = 0;
        realizedUsdc = IERC20($.usdc).balanceOf(address(this));
    }

    /// @notice Oracle-free proportional unwind: remove f = shares/supply of every leg
    ///         (body of the strategy's `_redeemUnwind`). Returns the redeemer's USDC.
    /// @dev Idle USDC accounting: the strategy may hold idle USDC from deposits not yet
    ///      deployed. The redeemer receives f of that idle USDC; stayers keep (1-f). We
    ///      snapshot `idleUsdcBefore` and subtract `stayersIdle` from the final balance.
    function redeemUnwindImpl(uint256 shares, uint256 supply) public returns (uint256) {
        Layout storage $ = _s();
        // Snapshot idle USDC — stayers keep (1-f) of it.
        uint256 idleUsdcBefore = IERC20($.usdc).balanceOf(address(this));
        uint256 stayersIdle = idleUsdcBefore - Math.mulDiv(idleUsdcBefore, shares, supply);
        // Snapshot the stayers' (1-f) share of any PRE-EXISTING idle leg. A `rerange` recenter
        // leaves a remainder of one borrowed leg (cbBTC or WETH) idle in the strategy — the leg
        // sweep at step E would otherwise hand a partial redeemer 100% of it, skimming the stayers'
        // share. Reserving (1-f) of it keeps redeem oracle-free (stayers' share stays as LEGS, not
        // oracle-valued). Both are ~0 (clean no-op) outside a post-rerange partial redeem.
        uint256 stayersCb = _stayerLeg($.cbBTC, shares, supply);
        uint256 stayersWeth = _stayerLeg($.weth, shares, supply);

        // A — partial CL unwind (pool-based mins, oracle-free).
        _unwindLiquidity(shares, supply);

        // B — repay f of each debt from collected tokens; capture any IL shortfall. The repay is
        // capped at the REDEEMER's own per-leg budget (`legBal − stayersLeg`) so a severe IL
        // shortfall can never consume the stayers' reserved `(1-f)` idle-leg share to over-repay
        // the redeemer's debt. Passing `stayersCb`/`stayersWeth` keeps the genuine shortfall flowing
        // to `cbShort`/`wethShort` → covered from the redeemer's OWN collateral (step C), upholding
        // the §7 invariant ("stayers keep (1-f) of every leg, regardless of price").
        (uint256 cbShort, uint256 wethShort) = _redeemRepayFromCollected(shares, supply, stayersCb, stayersWeth);

        if (shares == supply) {
            // Full redemption — two-phase debt clearance before 100 % collateral redeem.
            //
            // Phase 1 (oracle-free): cover IL shortfall from idle USDC via exact-output swap.
            //   When idle == 0 the calls are safe no-ops (amountInMaximum = 0 → early return).
            if (cbShort > 0) _redeemCoverShortfall($.cbBTC, $.mCbBTC, cbShort);
            if (wethShort > 0) _redeemCoverShortfall($.weth, $.mWeth, wethShort);
            // Phase 2 (self-fund fallback): if residual debt remains after Phase 1 (idle == 0 case),
            //   redeem mUSDC collateral → swap to deficit token → repay (settle-shortfall pattern).
            //   _settleShortfall reads the oracle only when borrowBalance > 0, so it is a no-op
            //   (oracle-free) when Phase 1 fully covered the shortfall.
            _settleShortfall();
            // Phase 3: all debt cleared — Moonwell now permits 100 % collateral redemption.
            _redeemCollateral(shares, supply);
            // Clear position state (flat-book invariant: no stayers remain after a full redeem).
            $.tokenId = 0;
            $.posTickLower = 0;
            $.posTickUpper = 0;
        } else {
            // Partial redemption: redeem f*collateral first (Finding 1 fix).
            _redeemCollateral(shares, supply);
            if (cbShort > 0) _redeemCoverShortfall($.cbBTC, $.mCbBTC, cbShort);
            if (wethShort > 0) _redeemCoverShortfall($.weth, $.mWeth, wethShort);
        }

        // E — sweep residual cbBTC/WETH → USDC, LEAVING the stayers' reserved leg share un-swept
        // (min-out=0; aggregate guard applies). For a full redeem (f=1) or no rerange remainder,
        // stayers* == 0 → sweep all (identical to the prior unconditional sweep). In the common
        // partial case this hands the redeemer exactly f*(idleLeg + LP_leg − debt_leg).
        _sweepLegToUsdc($.cbBTC, stayersCb, 0);
        _sweepLegToUsdc($.weth, stayersWeth, 0);

        // assetsOut = total USDC minus the (1-f) idle-USDC portion that stays for stayers (the
        // stayers' idle-leg share already stayed un-swept above, as legs).
        uint256 usdcFinal = IERC20($.usdc).balanceOf(address(this));
        return usdcFinal > stayersIdle ? usdcFinal - stayersIdle : 0;
    }

    /// @notice Deploy `amount` of idle strategy USDC into the existing levered position
    ///         (body of the strategy's `deployIdle`): supply + borrow + increaseLiquidity.
    function deployIdleImpl(uint256 amount, uint256 minLiquidity) public {
        Layout storage $ = _s();
        if (amount > IERC20($.usdc).balanceOf(address(this))) revert InsufficientIdle();
        _supplyAmount(amount);
        (uint256 cbBTCAmt, uint256 wethAmt) = _computeAndBorrow(amount);
        _wrapAddRestake(cbBTCAmt, wethAmt, minLiquidity);
        _assertHealthy();
    }

    /// @notice Compound AERO gauge rewards back into the levered position (body of the
    ///         strategy's `compound`): claim AERO → swap ALL of it to USDC synchronously →
    ///         redeploy the proceeds at target leverage via `deployIdleImpl`.
    ///
    ///         The reward swap uses the Aerodrome **v2 (AMM) volatile** AERO/USDC pool — the
    ///         deepest AERO/USDC liquidity on Base — bounded by the caller-supplied
    ///         `minUsdcOut` (the swap reverts if the venue can't fill it). `compound` is
    ///         `onlyProposer`, so a trusted backend supplies a fair `minUsdcOut` (e.g. derived
    ///         off-chain from the Base AERO/USD Chainlink feed) — consistent with `deployIdle`'s
    ///         caller-supplied `minLiquidity`.
    ///
    ///         No-op (clean return, no revert) when there is no open position or no AERO is
    ///         claimable. Fee crystallisation lives in the strategy entrypoint (it mints
    ///         fee-shares via the vault), NOT here.
    ///
    /// @param minUsdcOut   Minimum USDC out of the AERO→USDC swap (proposer slippage guard).
    /// @param minLiquidity Minimum CL liquidity to accept on the redeploy (slippage guard).
    function compoundImpl(uint256 minUsdcOut, uint256 minLiquidity) public {
        Layout storage $ = _s();
        uint256 tid = $.tokenId;
        if (tid == 0) return; // flat book — nothing staked, nothing to compound

        // 1. Claim AERO for the staked NFT. The reward token is read from the gauge
        //    (definitionally AERO on this pool — fork-confirmed `rewardToken() == AERO`).
        address gauge_ = $.gauge;
        address aero = ICLGauge(gauge_).rewardToken();
        ICLGauge(gauge_).getReward(tid);
        uint256 aeroBal = IERC20(aero).balanceOf(address(this));
        if (aeroBal == 0) return; // no rewards accrued — clean no-op

        // 2. Swap ALL claimed AERO → USDC via the Aerodrome v2 volatile pool, enforcing minUsdcOut.
        uint256 usdcBefore = IERC20($.usdc).balanceOf(address(this));
        IERC20(aero).forceApprove(AERO_V2_ROUTER, aeroBal);
        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0] = IAeroRouter.Route({from: aero, to: $.usdc, stable: false, factory: AERO_V2_FACTORY});
        IAeroRouter(AERO_V2_ROUTER)
            .swapExactTokensForTokens(aeroBal, minUsdcOut, routes, address(this), block.timestamp + 600);
        uint256 usdcOut = IERC20($.usdc).balanceOf(address(this)) - usdcBefore;
        if (usdcOut == 0) return;

        // 3. Redeploy ONLY the realized yield (usdcOut) into the position at target leverage
        //    (supply → borrow → increaseLiquidity → restake → _assertHealthy). Any pre-existing
        //    idle USDC is left untouched — compound deploys the AERO yield, nothing else.
        deployIdleImpl(usdcOut, minLiquidity);
    }

    /// @notice Recenter the CL position on the current tick WITHOUT swapping (body of the
    ///         strategy's `rerange`): calm-gate → unstake + remove 100% liquidity + collect →
    ///         recompute a tickSpacing-aligned range on the current tick → re-add the collected
    ///         legs (two-sided slippage mins) → restake → assert health. The Moonwell debt +
    ///         collateral are untouched.
    ///
    ///         **No swap by construction** → principal is conserved (IL is realized only on a
    ///         true exit). The collected token ratio cannot match the new range's required ratio,
    ///         so a remainder of ONE borrowed leg is left idle in the strategy — counted by
    ///         `nav()` (`LeveragedAeroValuation` prices idle cbBTC/WETH on the Chainlink basis),
    ///         so the recenter is NAV-neutral and the remainder stays redeployable. Slipstream
    ///         position ticks are immutable, so a recenter MUST mint a NEW tokenId; the old
    ///         (now-empty, unstaked) NFT is left owned by the strategy — harmless 0-liquidity dust.
    ///
    ///         No-op (clean return) on a flat book (tokenId == 0). Health is preserved because
    ///         debt + collateral are untouched; `_assertHealthy` runs as a belt-and-suspenders gate.
    ///
    /// @param minLiq0 Minimum token0 (WETH) the re-add must consume (caller two-sided slippage min).
    /// @param minLiq1 Minimum token1 (cbBTC) the re-add must consume (caller two-sided slippage min).
    function rerangeImpl(uint256 minLiq0, uint256 minLiq1) public {
        Layout storage $ = _s();
        if ($.tokenId == 0) return; // flat book — nothing to recenter

        // 1. Calm-gate BEFORE touching the pool — never recenter at a manipulated tick.
        LeveragedAeroValuation._calmGate(_cfg());

        // 2. Unstake + remove 100% liquidity + collect (num==den → no restake). The old NFT is
        //    left empty + unstaked; a recenter needs a fresh range == fresh tokenId.
        _unwindLiquidity(1, 1);

        // 3. New tickSpacing-aligned range centered on the current (calm) tick.
        (int24 tL, int24 tU) = _computeTickRange();

        // 4. Re-add the collected legs (full balances as desired) into the new range. No swap →
        //    principal conserved. `_mintPosition` enforces the two-sided `maxSlippageBps` mins
        //    (the §8 always-on floor) and approves the NPM; the caller's `minLiq0/minLiq1` add an
        //    explicit two-sided guard on the consumed amounts (proposer-tightenable, like
        //    compound's `minUsdcOut`).
        uint256 wethBal = IERC20($.weth).balanceOf(address(this));
        uint256 cbBal = IERC20($.cbBTC).balanceOf(address(this));
        (uint256 newTid, uint256 used0, uint256 used1) = _mintPosition(wethBal, cbBal, tL, tU);
        if (used0 < minLiq0 || used1 < minLiq1) revert InsufficientLiquidity();

        // 5. Restake the new NFT to resume AERO gauge rewards (mirrors _mintAndStake).
        address gauge_ = $.gauge;
        (bool ok,) = $.npm.call(abi.encodeWithSignature("approve(address,uint256)", gauge_, newTid));
        if (!ok) revert NpmApproveFailed();
        ICLGauge(gauge_).deposit(newTid);

        // 6. Persist the recentered position (nav()/positions() now read the new NFT).
        $.tokenId = newTid;
        $.posTickLower = tL;
        $.posTickUpper = tU;

        // 7. Debt + collateral untouched by rerange → health preserved; assert as a belt.
        _assertHealthy();
    }

    /// @notice Retarget the position's LTV to `targetLtvBps_` (body of the strategy's
    ///         `adjustLeverage`). The strategy entrypoint has already enforced
    ///         `targetLtvBps_ ≤ maxLtvBps` (reverts `TargetLtvExceedsMax` otherwise).
    ///
    ///         Collateral is untouched, so LTV moves purely via the debt side:
    ///         - **Lever UP** (target debt > current): borrow the cbBTC/WETH delta at the target,
    ///           wrap native ETH, and `increaseLiquidity` the new legs into the existing position
    ///           (`minLiq` slippage). Mirrors `deployIdleImpl` minus the new-collateral supply.
    ///         - **Lever DOWN** (target debt < current): unwind the matching fraction of CL
    ///           liquidity, repay the debt delta from the collected legs, rebalancing any per-leg
    ///           residual through USDC (caller `minOut` bounds that swap; no-op when balanced).
    ///
    ///         Ends with `_assertHealthy()` — reverts if the post-op LTV exceeds `maxLtvBps` or
    ///         Moonwell reports a shortfall. No share supply change → NO fee crystallisation (that
    ///         lives in the strategy entrypoints; this op realizes no PnL to the vault).
    ///
    /// @param targetLtvBps_ Target loan-to-value in bps (≤ `maxLtvBps`, checked by the entrypoint).
    /// @param minLiq        Minimum CL liquidity to accept on a lever-UP add (slippage guard).
    /// @param minOut        Minimum USDC out of a lever-DOWN residual rebalancing swap (slippage guard).
    function adjustLeverageImpl(uint16 targetLtvBps_, uint256 minLiq, uint256 minOut) public {
        (uint256 collateralUsdc, uint256 debtUsdc) = _readCollateralDebt();
        uint256 targetDebt = (uint256(targetLtvBps_) * collateralUsdc) / 10000;
        if (targetDebt > debtUsdc) {
            _leverUp(targetDebt - debtUsdc, minLiq);
        } else if (debtUsdc > targetDebt) {
            _leverDown(debtUsdc - targetDebt, debtUsdc, minOut);
        }
        _assertHealthy();
    }

    /// @notice Permissionless safety valve (body of the strategy's `deleverage`): when the
    ///         position's health has fallen below `minHealthBps`, anyone may unwind CL liquidity
    ///         and repay debt to restore the buffer.
    ///
    ///         **Health basis** mirrors `_assertHealthy`: `health = collateralUsdc × 1e4 / debtUsdc`
    ///         (bps), priced through the SAME hardened Chainlink reads. A position at/above
    ///         `minHealthBps` reverts `HealthyNoDeleverage` (no-op when safe); zero debt is trivially
    ///         healthy → also reverts.
    ///
    ///         Repays down to `minHealthBps × (1 + DELEVERAGE_BUFFER_BPS/1e4)` (a small buffer above
    ///         the minimum so the rescue does not immediately re-trigger). As a recovery op it does
    ///         NOT require the full `_assertHealthy` LTV-≤-max gate (the position may have been pushed
    ///         past max by the adverse move); instead it asserts health strictly improved and the
    ///         Moonwell shortfall is cleared or reduced.
    ///
    ///         **Oracle-staleness (accepted residual, spec §13):** like `_assertHealthy`, this reads
    ///         Chainlink, so a stale feed reverts (fail-safe — deleveraging at a stale/manipulated
    ///         price is worse than waiting). Moonwell liquidation uses Moonwell's OWN oracle, so a
    ///         window where our feed is stale but Moonwell's is fresh is an accepted residual.
    ///
    /// @param minOut Minimum USDC out of any residual rebalancing swap (caller slippage guard).
    function deleverageImpl(uint256 minOut) public {
        Layout storage $ = _s();
        (uint256 c0, uint256 d0) = _readCollateralDebt();
        if (d0 == 0) revert HealthyNoDeleverage(); // no debt ⇒ infinitely healthy
        uint256 health0 = (c0 * 10000) / d0;
        uint256 minHealth = uint256($.minHealthBps);
        if (health0 >= minHealth) revert HealthyNoDeleverage();
        (,, uint256 shortfall0) = IComptroller($.comptroller).getAccountLiquidity(address(this));

        // Target debt that lands health at minHealthBps + the re-trigger buffer (collateral is
        // untouched, so health = c / d ⇒ targetDebt = c × 1e4 / targetHealth).
        uint256 targetHealth = (minHealth * (10000 + uint256(DELEVERAGE_BUFFER_BPS))) / 10000;
        uint256 targetDebt = (c0 * 10000) / targetHealth;
        if (d0 > targetDebt) _leverDown(d0 - targetDebt, d0, minOut);

        // Recovery gate: health strictly improved AND the Moonwell shortfall cleared or reduced.
        (uint256 c1, uint256 d1) = _readCollateralDebt();
        uint256 health1 = d1 == 0 ? type(uint256).max : (c1 * 10000) / d1;
        if (health1 <= health0) revert UnhealthyPosition(health1, minHealth);
        (uint256 err,, uint256 shortfall1) = IComptroller($.comptroller).getAccountLiquidity(address(this));
        if (err != 0 || (shortfall1 != 0 && shortfall1 >= shortfall0)) revert UnhealthyPosition(health1, minHealth);
    }

    // ═════════════════════════════════════════════════════════════
    // Leverage helpers (adjustLeverage / deleverage)
    // ═════════════════════════════════════════════════════════════

    /// @dev Lever UP by `borrowDeltaUsd` (USDC face, 6dp): borrow the cbBTC/WETH delta (50/50) and
    ///      add it to the existing position. No new collateral — mirrors `deployIdleImpl`'s
    ///      borrow→wrap→add→restake without the supply step.
    function _leverUp(uint256 borrowDeltaUsd, uint256 minLiq) private {
        (uint256 cbBTCAmt, uint256 wethAmt) = _borrowHalfEach(borrowDeltaUsd);
        _wrapAddRestake(cbBTCAmt, wethAmt, minLiq);
    }

    /// @dev Lever DOWN by `repayUsd` (USDC face, 6dp) of the current `debtUsd`: unwind the matching
    ///      fraction `f = repayUsd/debtUsd` of CL liquidity, repay `f` of each debt from the
    ///      collected legs (oracle-free direct repay), then cover any per-leg IL residual by selling
    ///      the over-collected sibling leg → USDC (caller `minOut` bounds it) and buying the deficit.
    ///      Balanced legs (the common case) leave no residual → no swap → `minOut` unused.
    function _leverDown(uint256 repayUsd, uint256 debtUsd, uint256 minOut) private {
        Layout storage $ = _s();
        _unwindLiquidity(repayUsd, debtUsd);
        (uint256 cbShort, uint256 wethShort) = _redeemRepayFromCollected(repayUsd, debtUsd, 0, 0);
        if (cbShort > 0) {
            _rebalanceCover($.weth, $.cbBTC, $.mCbBTC, cbShort, minOut);
        } else if (wethShort > 0) {
            _rebalanceCover($.cbBTC, $.weth, $.mWeth, wethShort, minOut);
        }
    }

    /// @dev Cover an IL-driven debt shortfall on `deficitTok` by selling the over-collected
    ///      `surplusTok` → USDC (`minUsdcOut` bounds this rebalancing swap), then buying exactly the
    ///      deficit via exact-output from that USDC and repaying it. Any leftover USDC stays idle
    ///      (NAV-counted; recoverable via `deployIdle`/`redeem`).
    function _rebalanceCover(
        address surplusTok,
        address deficitTok,
        address deficitMkt,
        uint256 shortAmt,
        uint256 minUsdcOut
    ) private {
        _sweepLegToUsdc(surplusTok, 0, minUsdcOut);
        _redeemCoverShortfall(deficitTok, deficitMkt, shortAmt);
    }

    /// @dev Collateral + debt in USDC face (6dp) on the SAME hardened-Chainlink basis as
    ///      `_assertHealthy` (the LTV/health basis) — sizes the adjustLeverage / deleverage targets.
    ///      Returns `debtUsdc == 0` (skipping the price reads) when both borrows are clear.
    function _readCollateralDebt() private view returns (uint256 collateralUsdc, uint256 debtUsdc) {
        Layout storage $ = _s();
        uint256 cBal = ICToken($.mUsdc).balanceOf(address(this));
        uint256 rate = ICToken($.mUsdc).exchangeRateStored();
        collateralUsdc = (cBal * rate) / 1e18;
        uint256 cbDebt = IMoonwellMarket($.mCbBTC).borrowBalanceStored(address(this));
        uint256 wethDebt = IMoonwellMarket($.mWeth).borrowBalanceStored(address(this));
        if (cbDebt == 0 && wethDebt == 0) return (collateralUsdc, 0);
        (uint256 pBTC,) = ChainlinkReader.readUsd($.cbBTCFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        (uint256 pETH,) = ChainlinkReader.readUsd($.wethFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        (uint256 pUsdc,) = ChainlinkReader.readUsd($.usdcFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        debtUsdc =
            _tokenToUsdc(cbDebt, CBBTC_DECIMALS, pBTC, pUsdc) + _tokenToUsdc(wethDebt, WETH_DECIMALS, pETH, pUsdc);
    }

    // ═════════════════════════════════════════════════════════════
    // Execute helpers
    // ═════════════════════════════════════════════════════════════

    /// @dev Supply all strategy USDC to Moonwell and enter the mUSDC market.
    function _supplyCollateral() private returns (uint256 usdcAmt) {
        Layout storage $ = _s();
        address usdc_ = $.usdc;
        address mUsdc_ = $.mUsdc;
        usdcAmt = IERC20(usdc_).balanceOf(address(this));
        if (usdcAmt == 0) revert ExecuteZeroBalance();
        IERC20(usdc_).forceApprove(mUsdc_, usdcAmt);
        uint256 err = ICToken(mUsdc_).mint(usdcAmt);
        if (err != 0) revert MoonwellMintFailed(err);
        address[] memory markets = new address[](1);
        markets[0] = mUsdc_;
        IComptroller($.comptroller).enterMarkets(markets);
    }

    /// @dev Borrow against `usdcAmt` of fresh collateral at `targetLtvBps` (execute / deployIdle).
    ///      The borrow USD = `usdcAmt × targetLtvBps / 1e4`, split 50/50 across cbBTC/WETH.
    function _computeAndBorrow(uint256 usdcAmt) private returns (uint256 cbBTCAmt, uint256 wethAmt) {
        return _borrowHalfEach((usdcAmt * uint256(_s().targetLtvBps)) / 10000);
    }

    /// @dev Borrow `borrowUsd6` of debt (USDC face, 6dp) split 50/50 by USD across cbBTC + WETH, at
    ///      hardened-Chainlink prices, and execute both borrows. Used by `_computeAndBorrow` (fresh
    ///      collateral at target) and by `_leverUp` (a target-LTV debt delta with no new collateral).
    function _borrowHalfEach(uint256 borrowUsd6) private returns (uint256 cbBTCAmt, uint256 wethAmt) {
        Layout storage $ = _s();
        (uint256 pBTC,) = ChainlinkReader.readUsd($.cbBTCFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        (uint256 pETH,) = ChainlinkReader.readUsd($.wethFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        // halfBorrowUsd8: borrowUsd6 (6dp) → 8dp via ×100, then halve for the per-leg USD value.
        uint256 halfBorrowUsd8 = (borrowUsd6 * 100) / 2;
        cbBTCAmt = (halfBorrowUsd8 * 1e8) / pBTC;
        wethAmt = (halfBorrowUsd8 * 1e18) / pETH;
        uint256 cbErr = IMoonwellMarket($.mCbBTC).borrow(cbBTCAmt);
        if (cbErr != 0) revert MoonwellBorrowFailed(cbErr);
        uint256 wethErr = IMoonwellMarket($.mWeth).borrow(wethAmt);
        if (wethErr != 0) revert MoonwellBorrowFailed(wethErr);
    }

    /// @dev Wrap all native ETH held by the strategy into ERC-20 WETH9.
    function _wrapNativeEth() private {
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            IWETH9(_s().weth).deposit{value: ethBal}();
        }
    }

    /// @dev Compute a tickSpacing-aligned range centred on the current pool tick.
    function _computeTickRange() private view returns (int24 tL, int24 tU) {
        Layout storage $ = _s();
        (, int24 currentTick,,,,) = ICLPool($.pool).slot0();
        int24 ts = $.tickSpacing;
        int24 span = int24(uint24(RANGE_TICK_SPACINGS)) * ts;
        tL = _alignTick(currentTick - span, ts);
        tU = _alignTick(currentTick + span, ts);
        if (tU <= tL) tU = tL + ts;
    }

    /// @dev Mint the Slipstream CL position and return its tokenId + the amounts actually
    ///      consumed. token0 = WETH (18dp), token1 = cbBTC (8dp). Two-sided slippage mins are
    ///      derived from the expected-actual deposit amounts at the calm-gated sqrtP (the §8
    ///      always-on floor); `rerange` layers an additional caller-supplied two-sided guard on
    ///      the returned `used0`/`used1`.
    function _mintPosition(uint256 wethAmt, uint256 cbBTCAmt, int24 tL, int24 tU)
        private
        returns (uint256 tid, uint256 used0, uint256 used1)
    {
        Layout storage $ = _s();
        address npm_ = $.npm;
        address weth_ = $.weth;
        address cbBTC_ = $.cbBTC;

        // Compute expected actual deposits at the calm-gated sqrtP.
        (uint160 sqrtP,,,,,) = ICLPool($.pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tL);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tU);
        uint128 L = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, wethAmt, cbBTCAmt);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, L);
        uint256 slip = uint256($.maxSlippageBps);
        uint256 amt0Min = exp0 * (10000 - slip) / 10000;
        uint256 amt1Min = exp1 * (10000 - slip) / 10000;

        IERC20(weth_).forceApprove(npm_, wethAmt);
        IERC20(cbBTC_).forceApprove(npm_, cbBTCAmt);
        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: weth_,
            token1: cbBTC_,
            tickSpacing: $.tickSpacing,
            tickLower: tL,
            tickUpper: tU,
            amount0Desired: wethAmt,
            amount1Desired: cbBTCAmt,
            amount0Min: amt0Min,
            amount1Min: amt1Min,
            recipient: address(this),
            deadline: block.timestamp + 600,
            sqrtPriceX96: 0
        });
        (tid,, used0, used1) = INonfungiblePositionManager(npm_).mint(mp);
        if (tid == 0) revert NpmMintFailed();
    }

    /// @dev Mint the CL position, stake in gauge, and persist state.
    function _mintAndStake(uint256 cbBTCAmt, uint256 wethAmt) private {
        // Calm-gate before reading spot tick / anchoring slippage mins.
        Layout storage $ = _s();
        LeveragedAeroValuation._calmGate(_cfg());
        (int24 tL, int24 tU) = _computeTickRange();
        (uint256 tid,,) = _mintPosition(wethAmt, cbBTCAmt, tL, tU);
        address gauge_ = $.gauge;
        // ERC-721 approve (approve(address,uint256)) via low-level call.
        (bool ok,) = $.npm.call(abi.encodeWithSignature("approve(address,uint256)", gauge_, tid));
        if (!ok) revert NpmApproveFailed();
        ICLGauge(gauge_).deposit(tid);
        // Persist position state (so nav()/positions() see the live position)
        $.tokenId = tid;
        $.posTickLower = tL;
        $.posTickUpper = tU;
    }

    /// @dev Align `tick` down to the nearest multiple of `spacing` (handles negatives).
    function _alignTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    // ═════════════════════════════════════════════════════════════
    // Settle helpers
    // ═════════════════════════════════════════════════════════════

    /// @dev Unstake NFT, remove num/den fraction of liquidity, collect both tokens.
    ///      When num==den (full settle), no restake. When num<den (partial redeem),
    ///      restakes if remaining liq > 0.
    function _unwindLiquidity(uint256 num, uint256 den) private {
        Layout storage $ = _s();
        uint256 tid = $.tokenId;
        if (tid == 0) return; // flat book — no LP to unwind

        (int24 tL, int24 tU, uint128 liq) = _npmPositionData();

        // Unstake so NPM can modify the position
        address gauge_ = $.gauge;
        address npm_ = $.npm;
        ICLGauge(gauge_).withdraw(tid);

        uint128 liqToRemove = (num == den) ? liq : uint128(Math.mulDiv(uint256(liq), num, den));

        if (liqToRemove > 0) {
            (uint160 sqrtP,,,,,) = ICLPool($.pool).slot0();
            uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tL);
            uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tU);
            (uint256 exp0, uint256 exp1) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liqToRemove);
            uint256 slip = uint256($.maxSlippageBps);
            INonfungiblePositionManager(npm_)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tid,
                    liquidity: liqToRemove,
                    amount0Min: exp0 * (10000 - slip) / 10000,
                    amount1Min: exp1 * (10000 - slip) / 10000,
                    deadline: block.timestamp + 600
                })
                );
            INonfungiblePositionManager(npm_)
                .collect(
                    INonfungiblePositionManager.CollectParams({
                    tokenId: tid, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
                );
        }

        // Re-stake only when remaining liquidity is non-zero.
        (,, uint128 remainingLiq) = _npmPositionData();
        if (remainingLiq > 0) {
            (bool ok,) = npm_.call(abi.encodeWithSignature("approve(address,uint256)", gauge_, tid));
            if (!ok) revert NpmApproveFailed();
            ICLGauge(gauge_).deposit(tid);
        }
    }

    /// @dev Repay as much of both Moonwell borrows as current balances allow, then cover
    ///      any remaining debt via _settleShortfall().
    function _settleRepayDebts() private {
        Layout storage $ = _s();
        address mCbBTC_ = $.mCbBTC;
        address mWeth_ = $.mWeth;
        address cbBTC_ = $.cbBTC;
        address weth_ = $.weth;
        uint256 cbDebt = IMoonwellMarket(mCbBTC_).borrowBalanceStored(address(this));
        uint256 wethDebt = IMoonwellMarket(mWeth_).borrowBalanceStored(address(this));
        // Repay cbBTC
        uint256 cbBal = IERC20(cbBTC_).balanceOf(address(this));
        if (cbBal > 0 && cbDebt > 0) {
            IERC20(cbBTC_).forceApprove(mCbBTC_, cbBal);
            uint256 err = IMoonwellMarket(mCbBTC_).repayBorrow(cbBal >= cbDebt ? type(uint256).max : cbBal);
            if (err != 0) revert MoonwellRepayFailed(err);
        }
        // Repay WETH (ERC-20 — no unwrap; mWETH accepts WETH ERC-20 for repay)
        uint256 wethBal = IERC20(weth_).balanceOf(address(this));
        if (wethBal > 0 && wethDebt > 0) {
            IERC20(weth_).forceApprove(mWeth_, wethBal);
            uint256 err = IMoonwellMarket(mWeth_).repayBorrow(wethBal >= wethDebt ? type(uint256).max : wethBal);
            if (err != 0) revert MoonwellRepayFailed(err);
        }
        // Handle any remaining shortfall (IL or fees ate into LP value)
        _settleShortfall();
    }

    /// @dev If any borrow balance remains after the direct repay attempt, redeem USDC from
    ///      mUSDC collateral and swap to cover it. Chainlink prices + 10% buffer; dust floor.
    function _settleShortfall() private {
        Layout storage $ = _s();
        uint256 cbDebtRem = IMoonwellMarket($.mCbBTC).borrowBalanceStored(address(this));
        uint256 wethDebtRem = IMoonwellMarket($.mWeth).borrowBalanceStored(address(this));
        if (cbDebtRem == 0 && wethDebtRem == 0) return;
        // Read Chainlink prices (8dp each)
        (uint256 pBTC,) = ChainlinkReader.readUsd($.cbBTCFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        (uint256 pETH,) = ChainlinkReader.readUsd($.wethFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        (uint256 pUsdc,) = ChainlinkReader.readUsd($.usdcFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        // USDC needed for each shortfall leg (+10% buffer)
        uint256 cbUsdcNeed = _tokenToUsdc(cbDebtRem, 8, pBTC, pUsdc) * 11000 / 10000;
        uint256 wethUsdcNeed = _tokenToUsdc(wethDebtRem, 18, pETH, pUsdc) * 11000 / 10000;
        // Dust floor: nonzero debt but oracle cost rounds to 0 (e.g. 1 wei WETH) → redeem enough
        // to acquire at least 1 unit of that token.
        if (cbDebtRem > 0 && cbUsdcNeed == 0) cbUsdcNeed = 1e5;
        if (wethDebtRem > 0 && wethUsdcNeed == 0) wethUsdcNeed = 1e5;
        uint256 totalNeed = cbUsdcNeed + wethUsdcNeed;
        // Redeem USDC collateral to fund the swaps (health elevated after partial repays)
        if (totalNeed > 0) {
            uint256 redeemErr = ICToken($.mUsdc).redeemUnderlying(totalNeed);
            if (redeemErr != 0) revert MoonwellRedeemFailed(redeemErr);
        }
        uint256 slip = uint256($.maxSlippageBps);
        // Cover cbBTC shortfall
        if (cbDebtRem > 0) {
            _swapUsdcExactIn($.cbBTC, cbUsdcNeed, cbDebtRem * (10000 - slip) / 10000);
            uint256 cbBal2 = IERC20($.cbBTC).balanceOf(address(this));
            if (cbBal2 > 0) {
                IERC20($.cbBTC).forceApprove($.mCbBTC, cbBal2);
                uint256 err = IMoonwellMarket($.mCbBTC).repayBorrow(type(uint256).max);
                if (err != 0) revert MoonwellRepayFailed(err);
            }
        }
        // Cover WETH shortfall (spend remaining USDC after cbBTC leg)
        if (wethDebtRem > 0) {
            uint256 usdcLeft = IERC20($.usdc).balanceOf(address(this));
            _swapUsdcExactIn($.weth, usdcLeft, wethDebtRem * (10000 - slip) / 10000);
            uint256 wBal2 = IERC20($.weth).balanceOf(address(this));
            if (wBal2 > 0) {
                IERC20($.weth).forceApprove($.mWeth, wBal2);
                uint256 err = IMoonwellMarket($.mWeth).repayBorrow(type(uint256).max);
                if (err != 0) revert MoonwellRepayFailed(err);
            }
        }
    }

    /// @dev Swap a fixed USDC amount in for `tokenOut` via Slipstream exactInputSingle.
    ///      Caps actualIn at the current USDC balance.
    function _swapUsdcExactIn(address tokenOut, uint256 amountIn, uint256 minAmtOut) private {
        Layout storage $ = _s();
        uint256 usdcBal = IERC20($.usdc).balanceOf(address(this));
        uint256 actualIn = usdcBal < amountIn ? usdcBal : amountIn;
        if (actualIn == 0) return;
        IERC20($.usdc).forceApprove($.swapRouter, actualIn);
        ICLSwapRouter($.swapRouter)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                tokenIn: $.usdc,
                tokenOut: tokenOut,
                tickSpacing: int24(100),
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: actualIn,
                amountOutMinimum: minAmtOut,
                sqrtPriceLimitX96: 0
            })
            );
    }

    /// @dev Sweep the full balance of `tokenIn` to USDC via exactInputSingle (minOut may be 0).
    function _swapTokenToUsdc(address tokenIn, uint256 minOut) private {
        _sweepLegToUsdc(tokenIn, 0, minOut);
    }

    /// @dev Sweep (balance − `keep`) of `tokenIn` → USDC via exactInputSingle. `keep` reserves a
    ///      stayers' idle-leg share on the redeem path; settle / full-sweep callers pass keep == 0.
    function _sweepLegToUsdc(address tokenIn, uint256 keep, uint256 minOut) private {
        Layout storage $ = _s();
        uint256 bal = IERC20(tokenIn).balanceOf(address(this));
        if (bal <= keep) return;
        uint256 amt = bal - keep;
        IERC20(tokenIn).forceApprove($.swapRouter, amt);
        ICLSwapRouter($.swapRouter)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: $.usdc,
                tickSpacing: int24(100),
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: amt,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
            );
    }

    /// @dev (1-f) of the strategy's current `token` balance, f = shares/supply. Used by redeem to
    ///      reserve the stayers' share of a pre-existing idle leg (a rerange remainder) before the
    ///      residual sweep — keeping the partial-redeem path oracle-free and stayer-fair.
    function _stayerLeg(address token, uint256 shares, uint256 supply) private view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal - Math.mulDiv(bal, shares, supply);
    }

    /// @dev Convert `amt` (in `dec`-decimal token units) to USDC (6dp) using Chainlink prices.
    ///      pToken and pUsdc are both 8dp.
    function _tokenToUsdc(uint256 amt, uint8 dec, uint256 pToken, uint256 pUsdc) private pure returns (uint256) {
        return (amt * pToken * 1e6) / ((10 ** uint256(dec)) * pUsdc);
    }

    // ═════════════════════════════════════════════════════════════
    // deployIdle helpers
    // ═════════════════════════════════════════════════════════════

    /// @dev Supply a specific USDC amount to Moonwell mUSDC (no enterMarkets — already entered).
    function _supplyAmount(uint256 amt) private {
        Layout storage $ = _s();
        IERC20($.usdc).forceApprove($.mUsdc, amt);
        uint256 err = ICToken($.mUsdc).mint(amt);
        if (err != 0) revert MoonwellMintFailed(err);
    }

    /// @dev Add liquidity to the existing tokenId position via NPM.increaseLiquidity.
    ///      Caller must own the NFT (position unstaked from the gauge).
    function _addLiquidity(uint256 wethAmt, uint256 cbBTCAmt, uint256 minLiquidity) private {
        Layout storage $ = _s();
        LeveragedAeroValuation._calmGate(_cfg());
        uint256 tid = $.tokenId;
        address npm_ = $.npm;
        (uint160 sqrtP,,,,,) = ICLPool($.pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick($.posTickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick($.posTickUpper);
        uint128 L = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, wethAmt, cbBTCAmt);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, L);
        uint256 slip = uint256($.maxSlippageBps);
        IERC20($.weth).forceApprove(npm_, wethAmt);
        IERC20($.cbBTC).forceApprove(npm_, cbBTCAmt);
        (uint128 liq,,) = INonfungiblePositionManager(npm_)
            .increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tid,
                amount0Desired: wethAmt,
                amount1Desired: cbBTCAmt,
                amount0Min: exp0 * (10000 - slip) / 10000,
                amount1Min: exp1 * (10000 - slip) / 10000,
                deadline: block.timestamp + 600
            })
            );
        if (uint256(liq) < minLiquidity) revert InsufficientLiquidity();
    }

    /// @dev Wrap native ETH from a borrow → WETH, unstake the NFT so the NPM can modify it,
    ///      `increaseLiquidity` the borrowed legs into the existing position (`minLiquidity`
    ///      slippage), then restake for AERO rewards. Shared by `deployIdleImpl` and `_leverUp`.
    function _wrapAddRestake(uint256 cbBTCAmt, uint256 wethAmt, uint256 minLiquidity) private {
        Layout storage $ = _s();
        _wrapNativeEth();
        uint256 tid = $.tokenId;
        address gauge_ = $.gauge;
        ICLGauge(gauge_).withdraw(tid);
        _addLiquidity(wethAmt, cbBTCAmt, minLiquidity);
        (bool ok,) = $.npm.call(abi.encodeWithSignature("approve(address,uint256)", gauge_, tid));
        if (!ok) revert NpmApproveFailed();
        ICLGauge(gauge_).deposit(tid);
    }

    // ═════════════════════════════════════════════════════════════
    // redeem helpers
    // ═════════════════════════════════════════════════════════════

    /// @dev Repay f = shares/supply of each Moonwell borrow from currently-held tokens, capping
    ///      each leg's repay at the REDEEMER's own budget = `legBal − stayersLeg`. `stayersLeg`
    ///      is the stayers' reserved `(1-f)` share of a PRE-EXISTING idle leg (a rerange
    ///      remainder), snapshotted before the unwind. Subtracting it makes the budget exactly
    ///      `f·idleLeg + collectedLeg` — the redeemer's fair share — so an IL over-repay can never
    ///      eat the stayers' reserve; the genuine shortfall instead flows to `cbShort`/`wethShort`
    ///      and is covered from the redeemer's own freed collateral. With `stayersLeg == 0` (full
    ///      redeem f=1, or no rerange remainder) the cap is the full balance — behaviour unchanged.
    ///      Returns the shortfall amounts (0 if fully covered).
    function _redeemRepayFromCollected(uint256 shares, uint256 supply, uint256 stayersCb, uint256 stayersWeth)
        private
        returns (uint256 cbShort, uint256 wethShort)
    {
        Layout storage $ = _s();
        address mCbBTC_ = $.mCbBTC;
        address mWeth_ = $.mWeth;
        address cbBTC_ = $.cbBTC;
        address weth_ = $.weth;

        uint256 cbDebtRepay = Math.mulDiv(IMoonwellMarket(mCbBTC_).borrowBalanceStored(address(this)), shares, supply);
        uint256 wethDebtRepay = Math.mulDiv(IMoonwellMarket(mWeth_).borrowBalanceStored(address(this)), shares, supply);

        // ── cbBTC leg ── (budget = balance minus the stayers' reserved idle-leg share)
        if (cbDebtRepay > 0) {
            uint256 cbBal = IERC20(cbBTC_).balanceOf(address(this));
            uint256 cbBudget = cbBal > stayersCb ? cbBal - stayersCb : 0;
            uint256 cbRepay = cbBudget >= cbDebtRepay ? cbDebtRepay : cbBudget;
            if (cbRepay > 0) {
                IERC20(cbBTC_).forceApprove(mCbBTC_, cbRepay);
                uint256 err = IMoonwellMarket(mCbBTC_).repayBorrow(cbRepay);
                if (err != 0) revert MoonwellRepayFailed(err);
            }
            cbShort = cbDebtRepay > cbBudget ? cbDebtRepay - cbBudget : 0;
        }

        // ── WETH leg ── (budget = balance minus the stayers' reserved idle-leg share)
        if (wethDebtRepay > 0) {
            uint256 wethBal = IERC20(weth_).balanceOf(address(this));
            uint256 wethBudget = wethBal > stayersWeth ? wethBal - stayersWeth : 0;
            uint256 wethRepay = wethBudget >= wethDebtRepay ? wethDebtRepay : wethBudget;
            if (wethRepay > 0) {
                IERC20(weth_).forceApprove(mWeth_, wethRepay);
                uint256 err = IMoonwellMarket(mWeth_).repayBorrow(wethRepay);
                if (err != 0) revert MoonwellRepayFailed(err);
            }
            wethShort = wethDebtRepay > wethBudget ? wethDebtRepay - wethBudget : 0;
        }
    }

    /// @dev Cover a debt shortfall (IL-driven) by swapping idle USDC → `tokenOut` via
    ///      exactOutputSingle, then repaying the exact remaining amount.
    function _redeemCoverShortfall(address tokenOut, address market, uint256 amountOut) private {
        Layout storage $ = _s();
        uint256 usdcBal = IERC20($.usdc).balanceOf(address(this));
        if (usdcBal == 0 || amountOut == 0) return;
        IERC20($.usdc).forceApprove($.swapRouter, usdcBal);
        ICLSwapRouter($.swapRouter)
            .exactOutputSingle(
                ICLSwapRouter.ExactOutputSingleParams({
                tokenIn: $.usdc,
                tokenOut: tokenOut,
                tickSpacing: int24(100),
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountOut: amountOut,
                amountInMaximum: usdcBal,
                sqrtPriceLimitX96: 0
            })
            );
        IERC20($.usdc).forceApprove($.swapRouter, 0);
        uint256 tokenBal = IERC20(tokenOut).balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20(tokenOut).forceApprove(market, tokenBal);
            uint256 err = IMoonwellMarket(market).repayBorrow(tokenBal >= amountOut ? amountOut : tokenBal);
            if (err != 0) revert MoonwellRepayFailed(err);
        }
    }

    /// @dev Redeem f = shares/supply of the mUSDC underlying collateral.
    function _redeemCollateral(uint256 shares, uint256 supply) private {
        address mUsdc_ = _s().mUsdc;
        uint256 cBal = ICToken(mUsdc_).balanceOf(address(this));
        if (cBal == 0) return;
        uint256 rate = ICToken(mUsdc_).exchangeRateStored();
        uint256 totalUnderlying = (cBal * rate) / 1e18;
        uint256 toRedeem = Math.mulDiv(totalUnderlying, shares, supply);
        if (toRedeem == 0) return;
        uint256 err = ICToken(mUsdc_).redeemUnderlying(toRedeem);
        if (err != 0) revert MoonwellRedeemFailed(err);
    }

    // ═════════════════════════════════════════════════════════════
    // Shared helpers (health, NPM read, config build)
    // ═════════════════════════════════════════════════════════════

    /// @notice Delegatecall entrypoint that runs `_assertHealthy` in the caller's context.
    ///         `executeImpl` / `deployIdleImpl` call the private `_assertHealthy` directly;
    ///         this public wrapper exists so the post-op health invariant can be exercised in
    ///         isolation (offline `HealthHarness` unit tests).
    function assertHealthyImpl() public view {
        _assertHealthy();
    }

    /// @notice Post-operation LTV + Moonwell-liquidity invariant.
    ///         Reverts `UnhealthyPosition` if Chainlink-priced LTV exceeds `maxLtvBps` or
    ///         Moonwell reports a shortfall. Scaling mirrors `LeveragedAeroValuation`.
    function _assertHealthy() private view {
        Layout storage $ = _s();
        // ── Collateral (USDC face, 6dp) ──
        address mUsdc_ = $.mUsdc;
        uint256 cBal = ICToken(mUsdc_).balanceOf(address(this));
        uint256 rate = ICToken(mUsdc_).exchangeRateStored();
        uint256 collateralUsd = (cBal * rate) / 1e18;

        // ── Raw borrow balances ──
        uint256 cbDebt = IMoonwellMarket($.mCbBTC).borrowBalanceStored(address(this));
        uint256 wethDebt = IMoonwellMarket($.mWeth).borrowBalanceStored(address(this));
        if (cbDebt == 0 && wethDebt == 0) return; // no debt → trivially healthy (skip oracle)

        // ── Price via hardened Chainlink (same feeds + staleness guards as nav()) ──
        (uint256 pBTC,) = ChainlinkReader.readUsd($.cbBTCFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        (uint256 pETH,) = ChainlinkReader.readUsd($.wethFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);
        (uint256 pUsdc,) = ChainlinkReader.readUsd($.usdcFeed, $.sequencerFeed, $.maxDelay, $.gracePeriod);

        // ── Debt (USDC face, 6dp) ──
        uint256 debtUsd =
            _tokenToUsdc(cbDebt, CBBTC_DECIMALS, pBTC, pUsdc) + _tokenToUsdc(wethDebt, WETH_DECIMALS, pETH, pUsdc);
        if (debtUsd == 0) return; // dust-level debt rounds to 0 → trivially healthy

        // ── LTV check — binding post-op gate ──
        uint16 maxLtv = $.maxLtvBps;
        if (collateralUsd == 0) revert UnhealthyPosition(type(uint256).max, uint256(maxLtv));
        uint256 ltvBps_ = (debtUsd * 10_000) / collateralUsd;
        if (ltvBps_ > uint256(maxLtv)) revert UnhealthyPosition(ltvBps_, uint256(maxLtv));

        // ── Moonwell belt: authoritative no-liquidation check ──
        (uint256 err,, uint256 shortfall) = IComptroller($.comptroller).getAccountLiquidity(address(this));
        if (err != 0 || shortfall != 0) revert UnhealthyPosition(ltvBps_, uint256(maxLtv));
    }

    /// @dev Reads only the 3 fields we need from the NPM positions() 12-tuple via a
    ///      low-level staticcall + assembly (avoids placing all 12 returns on the stack).
    function _npmPositionData() private view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address npm_ = _s().npm;
        uint256 tokenId_ = _s().tokenId;
        bool ok;
        bytes memory ret;
        (ok, ret) = npm_.staticcall(abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_));
        if (!ok) revert InvalidNpmReturn();
        if (ret.length < 0x120) revert InvalidNpmReturn();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // ret + 0x20 = start of returndata; field 5 (tickLower) = +0xC0
            tickLower := mload(add(ret, 0xC0))
            tickUpper := mload(add(ret, 0xE0))
            liquidity := mload(add(ret, 0x100))
        }
    }

    /// @dev Build the `LeveragedAeroValuation.Config` from stored state (for the calm-gate).
    function _cfg() private view returns (LeveragedAeroValuation.Config memory c) {
        Layout storage $ = _s();
        c.usdc = $.usdc;
        c.vault = address(0); // calm-gate ignores vault; only the strategy's nav() needs the float term
        c.mUsdc = $.mUsdc;
        c.cbBTCMarket = $.mCbBTC;
        c.wethMarket = $.mWeth;
        c.cbBTC = $.cbBTC;
        c.weth = $.weth;
        c.cbBTCDecimals = CBBTC_DECIMALS;
        c.wethDecimals = WETH_DECIMALS;
        c.pool = $.pool;
        c.cbBTCFeed = $.cbBTCFeed;
        c.wethFeed = $.wethFeed;
        c.usdcFeed = $.usdcFeed;
        c.sequencerFeed = $.sequencerFeed;
        c.maxDelay = $.maxDelay;
        c.gracePeriod = $.gracePeriod;
        c.calmDeviationTicks = $.calmDeviationTicks;
        c.twapWindow = $.twapWindow;
    }
}
