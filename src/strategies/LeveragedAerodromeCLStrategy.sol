// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {LeveragedAeroManager} from "./LeveragedAeroManager.sol";
import {INonfungiblePositionManager, ICLGauge} from "../interfaces/ISlipstream.sol";
import {Position} from "../interfaces/IPriceRouter.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LeveragedAeroFees} from "./LeveragedAeroFees.sol";
import {FeeConstants} from "../FeeConstants.sol";
import {ISyndicateVault} from "../interfaces/ISyndicateVault.sol";

/// @title LeveragedAerodromeCLStrategy
/// @notice Net-short leveraged Aerodrome CL strategy: USDC collateral → Moonwell (mUSDC)
///         → borrow cbBTC + WETH → Slipstream CL position → AERO gauge.
///
///         ERC-1167 clone, one per proposal (BaseStrategy's constructor locks the template).
///         NAV is oracle-priced via `LeveragedAeroValuation.netEquityUsdc`, fail-closed.
///         `ReentrancyGuardTransient` guards every state-changing external op.
contract LeveragedAerodromeCLStrategy is BaseStrategy, ReentrancyGuardTransient, ERC721Holder {
    using SafeERC20 for IERC20;

    // ── Errors ──
    error NotImplemented();
    error TargetLtvExceedsMax();
    error MinHealthTooLow(); // minHealthBps < 10500 (1.05x floor)
    error FeeRecipientRequired();
    error MaxLtvExceedsCF(); // maxLtvBps >= Moonwell USDC collateral factor
    error ComptrollerCallFailed();
    error UnhealthyPosition(uint256 ltvBps, uint256 limitBps);
    error InvalidNpmReturn();
    error ExecuteZeroBalance();
    error MoonwellMintFailed(uint256 errCode);
    error MoonwellBorrowFailed(uint256 errCode);
    error NpmMintFailed();
    error NpmApproveFailed();
    error MoonwellRepayFailed(uint256 errCode);
    error MoonwellRedeemFailed(uint256 errCode);
    error InsufficientShares();
    error InsufficientAssetsOut();
    error InsufficientLiquidity();
    error InsufficientIdle();
    error HealthyNoDeleverage();
    error CannotRescuePositionToken();
    error OnlySelf();
    error PerformanceFeeTooHigh();
    error ManagementFeeTooHigh();
    error MinHealthMaxLtvConflict();
    error AssetMismatch();
    error UnexpectedAssetDecimals();
    error OracleParamOutOfRange();

    // ── Constants ──
    uint8 private constant CBBTC_DECIMALS = 8; // cbBTC is 8dp wrapped Bitcoin
    uint8 private constant WETH_DECIMALS = 18; // WETH9 on Base is 18dp

    /// @dev Position `kind` tag for the PriceRouter adapter registry.
    bytes32 public constant POSITION_KIND = keccak256("LEVERAGED_AERO_CL");

    /// @dev ERC-4626 virtual share offset matching the vault's `_decimalsOffset()` (USDC 6dp → 1e6).
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;

    /// @dev Annual management-fee ceiling (bps); mirrors `SyndicateFactory.MAX_MANAGEMENT_FEE_BPS` (5%/yr).
    uint16 private constant MAX_MANAGEMENT_FEE_BPS = 500;

    // ── Initialisation params (ABI-encoded → BaseStrategy.initialize → _initialize) ──

    struct InitParams {
        // ── Token addresses ──
        address usdc; // USDC (6dp) — unit of account + collateral asset
        address mUsdc; // Moonwell mUSDC market (collateral)
        address mCbBTC; // Moonwell mcbBTC market (borrow leg)
        address mWeth; // Moonwell mWETH market (borrow leg)
        address comptroller; // Moonwell Comptroller (enterMarkets / markets())
        address cbBTC; // cbBTC underlying (8dp)
        address weth; // WETH9 underlying (18dp)
        // ── Venue addresses ──
        address pool; // Aerodrome Slipstream CL pool (cbBTC/WETH tickSpacing=100)
        address npm; // Slipstream Non-Fungible Position Manager
        address gauge; // Gauge for the pool (AERO rewards)
        address swapRouter; // Slipstream CL Swap Router
        // ── Chainlink feeds ──
        address cbBTCFeed; // BTC/USD aggregator (8dp)
        address wethFeed; // ETH/USD aggregator (8dp)
        address usdcFeed; // USDC/USD aggregator (8dp)
        address sequencerFeed; // L2 Sequencer Uptime feed (Base)
        // ── Oracle config ──
        uint256 maxDelay; // Max feed staleness (seconds)
        uint256 gracePeriod; // Sequencer grace period after restart (seconds)
        uint16 calmDeviationTicks; // Max |spotTick − twapTick| before calm-gate fires
        uint32 twapWindow; // TWAP lookback for the calm-gate (seconds)
        // ── Pool config ──
        int24 tickSpacing; // Slipstream pool tickSpacing (100 for primary pool)
        // ── Risk params ──
        uint16 targetLtvBps; // Target LTV in bps (e.g. 5000 = 50%)
        uint16 maxLtvBps; // Maximum LTV cap in bps (e.g. 6500 = 65%)
        uint16 minHealthBps; // Minimum health ratio in bps (e.g. 12000 = 1.20×)
        uint16 maxSlippageBps; // Maximum slippage tolerance for swaps in bps
        // ── Fee params ──
        uint16 managementFeeBps; // Annual management fee in bps (e.g. 100 = 1%/yr)
        uint16 performanceFeeBps; // HWM performance fee in bps (e.g. 1000 = 10%)
        address feeRecipient; // Address that receives fee-shares (must be non-zero if any fee > 0)
    }

    // ── ERC-7201 namespaced (diamond) storage ──
    //
    // All strategy-specific state lives in one `Layout` struct at a fixed ERC-7201 slot, NOT in
    // sequential storage (which holds only BaseStrategy's state). This lets the venue ops run from
    // the deployed `LeveragedAeroManager` library via delegatecall.
    //
    // CORRUPTION-CRITICAL: `Layout`, `STORAGE_SLOT`, and `_layout()` are byte-identical in
    // `LeveragedAeroManager` — they MUST stay in lockstep or a delegatecall reads/writes the wrong
    // slots. Do not reorder `Layout` fields in one file without the other.

    /// @custom:storage-location erc7201:leveraged.aero.cl.storage
    struct Layout {
        // valuation config: token / venue / feed addresses
        address usdc;
        address mUsdc;
        address mCbBTC; // LeveragedAeroValuation.Config.cbBTCMarket
        address mWeth; // LeveragedAeroValuation.Config.wethMarket
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
        // venue / protocol addresses (not in Config)
        address comptroller;
        address npm;
        address gauge;
        address swapRouter;
        int24 tickSpacing;
        // risk params
        uint16 targetLtvBps;
        uint16 maxLtvBps;
        uint16 minHealthBps;
        uint16 maxSlippageBps;
        uint16 usdcCollateralFactorBps; // USDC collateral factor from Moonwell at init (8800 = 88%)
        // position state (all zero pre-deploy / post-settle)
        uint256 tokenId; // active CL position; 0 == flat book
        int24 posTickLower;
        int24 posTickUpper;
        // fee params + state
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        address feeRecipient;
        uint256 hwmPerShare; // HWM nav-per-share (1e18 WAD), 0 until first deposit
        uint256 lastFeeAccrualTimestamp;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @dev ERC-7201 diamond-storage accessor (byte-identical across strategy + manager).
    function _layout() private pure returns (Layout storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    /// @notice Full strategy storage layout (single accessor for tests / off-chain reads).
    function layout() external view returns (Layout memory) {
        return _layout();
    }

    /// @dev Moonwell's mWETH market delivers native ETH on `borrow()`; the strategy wraps it to
    ///      WETH9 before use. Without this receiver the borrow's ETH transfer reverts.
    receive() external payable {}

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Leveraged Aerodrome CL";
    }

    // ── Initialization ──

    /// @notice Validate `InitParams`, read the USDC collateral factor from Moonwell, and persist
    ///         everything to diamond storage. Validation order matches the per-field checks below
    ///         so the same input reverts with the same error.
    function _initialize(bytes calldata data) internal override {
        InitParams memory p = abi.decode(data, (InitParams));

        if (p.usdc == address(0)) revert ZeroAddress();
        if (p.mUsdc == address(0)) revert ZeroAddress();
        if (p.mCbBTC == address(0)) revert ZeroAddress();
        if (p.mWeth == address(0)) revert ZeroAddress();
        if (p.comptroller == address(0)) revert ZeroAddress();
        if (p.cbBTC == address(0)) revert ZeroAddress();
        if (p.weth == address(0)) revert ZeroAddress();
        if (p.pool == address(0)) revert ZeroAddress();
        if (p.npm == address(0)) revert ZeroAddress();
        if (p.gauge == address(0)) revert ZeroAddress();
        if (p.swapRouter == address(0)) revert ZeroAddress();
        if (p.cbBTCFeed == address(0)) revert ZeroAddress();
        if (p.wethFeed == address(0)) revert ZeroAddress();
        if (p.usdcFeed == address(0)) revert ZeroAddress();
        if (p.sequencerFeed == address(0)) revert ZeroAddress();

        // L7: the strategy's unit of account MUST be the vault's ERC-4626 asset, and the
        // SHARES_VIRTUAL_OFFSET (1e6) hardcodes a 6-decimal asset — reject any other wiring.
        if (p.usdc != IERC4626(vault()).asset()) revert AssetMismatch();
        if (IERC20Metadata(p.usdc).decimals() != 6) revert UnexpectedAssetDecimals();

        uint16 cfBps = _readCollateralFactor(p.comptroller, p.mUsdc);
        if (p.targetLtvBps > p.maxLtvBps) revert TargetLtvExceedsMax();
        if (p.minHealthBps < 10500) revert MinHealthTooLow();
        if (p.maxLtvBps >= cfBps) revert MaxLtvExceedsCF();
        // L4: permissionless deleverage triggers at LTV = 1e8 / minHealthBps; that trigger LTV MUST
        // sit strictly above maxLtvBps, else there is an in-band range anyone can grief-deleverage.
        // Cross-multiplied (overflow-free): require minHealthBps * maxLtvBps < 1e8.
        if (uint256(p.minHealthBps) * uint256(p.maxLtvBps) >= 1e8) revert MinHealthMaxLtvConflict();
        // L3 (+L5): bound the oracle / calm-gate params so a misconfig can't silently disable a guard.
        // Bounds admit the confirmed config yet block degenerate values:
        //   maxDelay           ∈ (0, 7 days] — a huge value disables staleness detection
        //   gracePeriod        ∈ [0, 1 days] — sequencer-restart grace
        //   twapWindow         ∈ (0, 1 days] — 0 disables the TWAP / calm-gate
        //   calmDeviationTicks ∈ (0, 5000]   — a huge value disables the calm-gate
        //   maxSlippageBps     ∈ (0, 1000]   — 0 or huge disables swap-slippage protection (10% cap)
        if (p.maxDelay == 0 || p.maxDelay > 7 days) revert OracleParamOutOfRange();
        if (p.gracePeriod > 1 days) revert OracleParamOutOfRange();
        if (p.twapWindow == 0 || p.twapWindow > 1 days) revert OracleParamOutOfRange();
        if (p.calmDeviationTicks == 0 || p.calmDeviationTicks > 5000) revert OracleParamOutOfRange();
        if (p.maxSlippageBps == 0 || p.maxSlippageBps > 1000) revert OracleParamOutOfRange();
        if ((p.managementFeeBps != 0 || p.performanceFeeBps != 0) && p.feeRecipient == address(0)) {
            revert FeeRecipientRequired();
        }
        // M3: hard ceilings on both fee rates (perf mirrors the protocol-wide cap; mgmt the factory's).
        if (p.performanceFeeBps > FeeConstants.MAX_PERFORMANCE_FEE_BPS) revert PerformanceFeeTooHigh();
        if (p.managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert ManagementFeeTooHigh();

        Layout storage $ = _layout();
        $.usdc = p.usdc;
        $.mUsdc = p.mUsdc;
        $.mCbBTC = p.mCbBTC;
        $.mWeth = p.mWeth;
        $.comptroller = p.comptroller;
        $.cbBTC = p.cbBTC;
        $.weth = p.weth;
        $.pool = p.pool;
        $.npm = p.npm;
        $.gauge = p.gauge;
        $.swapRouter = p.swapRouter;
        $.cbBTCFeed = p.cbBTCFeed;
        $.wethFeed = p.wethFeed;
        $.usdcFeed = p.usdcFeed;
        $.sequencerFeed = p.sequencerFeed;
        $.maxDelay = p.maxDelay;
        $.gracePeriod = p.gracePeriod;
        $.calmDeviationTicks = p.calmDeviationTicks;
        $.twapWindow = p.twapWindow;
        $.tickSpacing = p.tickSpacing;
        $.targetLtvBps = p.targetLtvBps;
        $.maxLtvBps = p.maxLtvBps;
        $.minHealthBps = p.minHealthBps;
        $.maxSlippageBps = p.maxSlippageBps;
        $.usdcCollateralFactorBps = cfBps;
        $.managementFeeBps = p.managementFeeBps;
        $.performanceFeeBps = p.performanceFeeBps;
        $.feeRecipient = p.feeRecipient;
        $.lastFeeAccrualTimestamp = block.timestamp;
        // tokenId / posTickLower / posTickUpper / hwmPerShare default to 0 (set in _execute / on first deposit).
    }

    /// @dev USDC collateral factor (bps) from `Comptroller.markets(mUsdc)`. ABI is
    ///      `(bool isListed, uint256 collateralFactorMantissa, ...)`; read the 2nd word (1e18-scaled).
    function _readCollateralFactor(address comptroller_, address mUsdc_) private view returns (uint16 cfBps) {
        (bool ok, bytes memory ret) = comptroller_.staticcall(abi.encodeWithSignature("markets(address)", mUsdc_));
        if (!ok || ret.length < 64) revert ComptrollerCallFailed();
        uint256 cfMantissa;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            cfMantissa := mload(add(ret, 0x40))
        }
        cfBps = uint16(cfMantissa / 1e14); // 0.88e18 / 1e14 = 8800
        if (cfBps == 0) revert ComptrollerCallFailed();
    }

    // ── NAV ──

    /// @notice Oracle NAV of the levered book, in USDC (6dp). `tokenId == 0` (the flat-book
    ///         invariant, maintained by `_execute`/`_settle`) → face value of idle USDC in vault +
    ///         strategy, no oracle. Active position → `LeveragedAeroValuation.netEquityUsdc`
    ///         (oracle-implied sqrtP, fail-closed: reverts on any oracle/calm failure or ≤0 equity).
    function nav() public view virtual returns (uint256) {
        Layout storage $ = _layout();
        if ($.tokenId == 0) {
            // Flat book: sum idle USDC in vault + strategy (face, 6dp, no oracle needed).
            return IERC20($.usdc).balanceOf(vault()) + IERC20($.usdc).balanceOf(address(this));
        }
        // Active position: read ticks + liquidity from the NPM and delegate to the valuation lib.
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _npmPositionData();
        return LeveragedAeroValuation.netEquityUsdc(_config(), address(this), tickLower, tickUpper, liquidity);
    }

    /// @dev Reads only ticks + liquidity (fields 5-7) from the NPM `positions()` 12-tuple via
    ///      staticcall + assembly — avoids putting all 12 returns on the stack (Yul IR 16-slot limit).
    ///      Each is a 32-byte word at `ret + 0x20 + N*0x20`: [5] tickLower=0xC0, [6] tickUpper=0xE0,
    ///      [7] liquidity=0x100.
    function _npmPositionData() internal view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address npm_ = _layout().npm;
        uint256 tokenId_ = _layout().tokenId;
        bool ok;
        bytes memory ret;
        (ok, ret) = npm_.staticcall(abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_));
        if (!ok) revert InvalidNpmReturn();
        // Require at least 9 full words of returndata (0x120 bytes) so the mload
        // at offset 0x100 (field 7, liquidity) cannot read past the allocated buffer.
        if (ret.length < 0x120) revert InvalidNpmReturn();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // ret + 0x20 = start of returndata; field 5 = +0x20+5*0x20 = +0xC0
            tickLower := mload(add(ret, 0xC0))
            tickUpper := mload(add(ret, 0xE0))
            liquidity := mload(add(ret, 0x100))
        }
    }

    // ── Positions (Lane A reporting for the PriceRouter) ──

    /// @inheritdoc IStrategy
    /// @notice Reports the single levered-CL position. `ref` encodes the market addresses the
    ///         `LEVERAGED_AERO_CL` adapter needs to verify the venues.
    function positions() external view override returns (Position[] memory pos) {
        Layout storage $ = _layout();
        pos = new Position[](1);
        pos[0] = Position({venue: $.pool, kind: POSITION_KIND, ref: abi.encode($.gauge, $.mUsdc, $.mCbBTC, $.mWeth)});
    }

    // ── Execute / settle ──

    /// @notice Open the levered cbBTC/WETH CL position: supply USDC → enterMarkets → borrow
    ///         cbBTC+WETH → wrap ETH → mint Slipstream CL → stake gauge → assert health. The venue
    ///         sequence lives in `LeveragedAeroManager.executeImpl()` (delegatecalled, so
    ///         `address(this)` / `_layout()` resolve to this clone).
    function _execute() internal override {
        LeveragedAeroManager.executeImpl();
        // Belt-and-suspenders: keep the fee-accrual clock running even if a clone bypassed
        // _initialize (guards against a ~54-year dt on the first crystallize).
        if (_layout().lastFeeAccrualTimestamp == 0) _layout().lastFeeAccrualTimestamp = block.timestamp;
    }

    /// @notice Full proportional unwind to the vault. The unwind — remove 100% liquidity, repay both
    ///         Moonwell borrows (self-funding any IL/fee shortfall), redeem collateral, sweep residual
    ///         cbBTC/WETH → USDC, clear state — lives in `LeveragedAeroManager.settleImpl()`; the
    ///         realized USDC is pushed to the vault here (the manager never touches `vault()`).
    function _settle() internal override {
        LeveragedAeroManager.settleImpl();
        _pushAllToVault(_layout().usdc);
    }

    /// @dev Crystallise management + HWM performance fees on the PRE-ACTION vault state. The caller
    ///      supplies `navPre` (not a self-call to `nav()`) so the caller controls oracle behaviour:
    ///      deposit passes `nav()` (fail-closed — correct to revert on oracle failure); redeem passes
    ///      0 when `nav()` is unavailable → `crystallize` returns 0 fee-shares and just advances the
    ///      timestamp, keeping redeem oracle-free (§7).
    /// @param navPre Pre-action NAV (USDC 6dp). Pass 0 to skip fees (oracle-free path).
    function _crystallizeFees(uint256 navPre) private {
        Layout storage $ = _layout();
        uint256 supply = IERC20(vault()).totalSupply();
        if (supply == 0) return;
        if ($.lastFeeAccrualTimestamp == 0) {
            $.lastFeeAccrualTimestamp = block.timestamp;
            return;
        }
        (uint256 feeShares, uint256 newHwm, uint256 newLast) = LeveragedAeroFees.crystallize(
            navPre,
            supply,
            $.hwmPerShare,
            $.lastFeeAccrualTimestamp,
            block.timestamp,
            uint256($.managementFeeBps),
            uint256($.performanceFeeBps)
        );
        $.hwmPerShare = newHwm;
        $.lastFeeAccrualTimestamp = newLast;
        if (feeShares > 0) ISyndicateVault(vault()).strategyMint($.feeRecipient, feeShares);
    }

    /// @dev Self-only external wrapper so `redeem` can crystallise fees best-effort via `try/catch`
    ///      (H3). A fee-mint can revert on the vault's `whenNotPaused` / depositor-whitelist gates;
    ///      isolating it in an external call lets a failure roll back ONLY the crystallise (HWM +
    ///      `lastFeeAccrualTimestamp` unchanged → fee defers) while redeem proceeds. Gated to
    ///      `address(this)`; runs inside redeem's `nonReentrant` scope (not itself guarded), so it
    ///      adds no reentrancy surface.
    function crystallizeFeesSelf(uint256 navPre) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _crystallizeFees(navPre);
    }

    /// @notice Oracle-priced deposit: mint vault shares proportional to current NAV. Ordering is
    ///         load-bearing (phantom-fee fix): crystallise fees on the PRE-deposit NAV (fail-closed)
    ///         BEFORE pulling USDC, then mint via the ERC-4626 virtual-offset formula. Deposited USDC
    ///         sits idle until a proposer calls `deployIdle()`.
    /// @param assets    USDC to deposit (6dp).
    /// @param minShares Minimum vault shares to accept (slippage guard).
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (_state != State.Executed) revert NotExecuted();
        // Crystallize on pre-deposit NAV (fail-closed: oracle down → correct revert for deposit).
        uint256 navPre = nav();
        _crystallizeFees(navPre);
        IERC20(_layout().usdc).safeTransferFrom(msg.sender, address(this), assets);
        address vault_ = vault();
        uint256 supply = IERC20(vault_).totalSupply();
        shares = Math.mulDiv(assets, supply + SHARES_VIRTUAL_OFFSET, navPre + 1);
        if (shares < minShares) revert InsufficientShares();
        ISyndicateVault(vault_).strategyMint(msg.sender, shares);
    }

    /// @notice Deploy `amount` of idle strategy USDC into the levered position (supply + borrow +
    ///         increaseLiquidity + health-assert) via `LeveragedAeroManager.deployIdleImpl()`.
    /// @param amount       USDC to deploy (6dp); must be ≤ idle USDC held.
    /// @param minLiquidity Minimum liquidity to accept (slippage guard).
    function deployIdle(uint256 amount, uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroManager.deployIdleImpl(amount, minLiquidity);
    }

    /// @notice Compound AERO rewards: claim → swap to USDC (Aerodrome v2 volatile pool, the deepest
    ///         AERO/USDC venue on Base, bounded by `minUsdcOut`) → redeploy at target leverage, via
    ///         `LeveragedAeroManager.compoundImpl()`. No-op when no AERO is claimable.
    ///
    ///         Fee fairness (§10): crystallise on the PRE-compound NAV first (same fail-closed model
    ///         as `deposit`) so the realized yield can't escape the performance fee. Crystallisation
    ///         lives here (it mints fee-shares); unlike the redeem path an oracle read is correct —
    ///         `compound` is `onlyProposer`, so a stale oracle should defer, not mis-price.
    /// @param minUsdcOut   Minimum USDC out of the AERO→USDC swap (slippage guard).
    /// @param minLiquidity Minimum CL liquidity on the redeploy (slippage guard).
    function compound(uint256 minUsdcOut, uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        // Crystallize on the pre-compound NAV (fail-closed; mirrors deposit's 3.6 fee model).
        _crystallizeFees(nav());
        LeveragedAeroManager.compoundImpl(minUsdcOut, minLiquidity);
    }

    /// @notice Recenter the CL position on the current pool tick WITHOUT swapping, via
    ///         `LeveragedAeroManager.rerangeImpl()`. The calm-gate runs FIRST, so a recenter can never
    ///         execute at a manipulated tick. No swap → principal conserved (IL is realized only on a
    ///         true exit); the collected ratio can't match the new range, so a remainder of ONE
    ///         borrowed leg is left idle — `nav()` prices it, so the recenter is NAV-neutral and the
    ///         remainder stays redeployable. Debt + collateral are untouched (health preserved); a new
    ///         tokenId is minted (Slipstream ticks are immutable), the old empty NFT is harmless dust.
    ///
    ///         NO fee crystallisation: rerange changes neither supply nor NAV, so the streaming fee is
    ///         deferred to the next crystallize point (not lost) and the HWM is unaffected.
    /// @param minLiq0 Minimum token0 (WETH) the re-add must consume (two-sided slippage guard).
    /// @param minLiq1 Minimum token1 (cbBTC) the re-add must consume (two-sided slippage guard).
    function rerange(uint256 minLiq0, uint256 minLiq1) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroManager.rerangeImpl(minLiq0, minLiq1);
    }

    /// @notice Retarget the position's LTV to `targetLtvBps_` (borrow/repay; no new USDC). Collateral
    ///         is untouched, so LTV moves on the debt side via `LeveragedAeroManager.adjustLeverageImpl`:
    ///         lever UP borrows the cbBTC/WETH delta and adds it (`minLiq`); lever DOWN unwinds the
    ///         matching CL fraction and repays (per-leg residual rebalanced through USDC, bounded by
    ///         `minOut`). Ends with `_assertHealthy`. `targetLtvBps_ ≤ maxLtvBps` is checked here.
    ///
    ///         NO fee crystallisation (like `rerange`): no supply change, no PnL realized; the
    ///         streaming fee is deferred and the HWM is unaffected.
    /// @param targetLtvBps_ Target LTV in bps (must be ≤ `maxLtvBps`).
    /// @param minLiq        Minimum CL liquidity on a lever-UP add (slippage guard).
    /// @param minOut        Minimum USDC out of a lever-DOWN residual swap (slippage guard).
    function adjustLeverage(uint16 targetLtvBps_, uint256 minLiq, uint256 minOut) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        if (targetLtvBps_ > _layout().maxLtvBps) revert TargetLtvExceedsMax();
        LeveragedAeroManager.adjustLeverageImpl(targetLtvBps_, minLiq, minOut);
    }

    /// @notice Permissionless safety valve: when health falls below `minHealthBps`, ANYONE may unwind
    ///         CL liquidity and repay debt to restore the buffer. Deliberately NOT `onlyProposer` — a
    ///         public deleverage is the user-safety backstop for the indefinite proposal (§8). Logic in
    ///         `LeveragedAeroManager.deleverageImpl`: same hardened-Chainlink health basis as
    ///         `_assertHealthy`, reverts `HealthyNoDeleverage` when safe / no debt, else repays down to
    ///         a small buffer above the minimum (a recovery op, not the full LTV-≤-max gate).
    ///
    ///         A stale our-feed fail-closes the read (deleveraging at a stale/manipulated price is
    ///         worse than waiting); Moonwell liquidation uses its own oracle, an accepted residual (§13).
    /// @param minOut Minimum USDC out of any residual rebalancing swap (slippage guard).
    function deleverage(uint256 minOut) external nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroManager.deleverageImpl(minOut);
    }

    /// @notice Oracle-free proportional redeem: burn vault shares, receive pro-rata USDC. Caller must
    ///         `vault.approve(strategy, shares)` first (shares are pulled via `safeTransferFrom`).
    ///         Oracle-free guarantee (§7): a best-effort crystallise passes navPre=0 on oracle outage
    ///         (no fees, redeem unblocked); the fraction denominator is fixed once before the burn.
    ///
    ///         The crystallise is FULLY best-effort (H3): it runs through the self-only
    ///         `crystallizeFeesSelf` wrapper under `try/catch`, so even a fee-share MINT failure
    ///         (vault paused, or `feeRecipient` un-whitelisted on a closed-deposit config) rolls back
    ///         only the crystallise — HWM + `lastFeeAccrualTimestamp` are unchanged, the fee DEFERS to
    ///         the next successful crystallise, and redeem ALWAYS proceeds. This preserves the
    ///         pause-immune-redeem + §7 always-available-exit invariants (the sole exit of an
    ///         indefinite proposal can never be bricked by a fee-mint gate).
    /// @param shares       Vault shares to redeem (12dp).
    /// @param minAssetsOut Minimum USDC out (aggregate slippage guard).
    function redeem(uint256 shares, uint256 minAssetsOut) external nonReentrant returns (uint256 assetsOut) {
        if (_state != State.Executed) revert NotExecuted();

        // 1. Best-effort crystallise: oracle outage → navPre=0 → no fees; a fee-mint revert is
        //    swallowed (fee defers) so redeem is never bricked by the vault's mint gates (H3).
        uint256 navPre;
        try this.nav() returns (uint256 navNow) {
            navPre = navNow;
        } catch {
            navPre = 0;
        }
        try this.crystallizeFeesSelf(navPre) {} catch {}

        // 2. Fix the fraction denominator ONCE before the burn (totalSupply is stable here).
        address vault_ = vault();
        uint256 supply = IERC20(vault_).totalSupply();

        // 3. Pull shares from caller (requires prior vault.approve(strategy, shares)).
        IERC20(vault_).safeTransferFrom(msg.sender, address(this), shares);

        // 4. Oracle-free proportional unwind (venue logic in the deployed manager library).
        assetsOut = LeveragedAeroManager.redeemUnwindImpl(shares, supply);

        // 5. Aggregate slippage guard.
        if (assetsOut < minAssetsOut) revert InsufficientAssetsOut();

        // 6. Pay out USDC.
        IERC20(_layout().usdc).safeTransfer(msg.sender, assetsOut);

        // 7. Burn shares (strategy holds them after safeTransferFrom above).
        ISyndicateVault(vault_).strategyBurn(shares);
    }

    /// @notice Sweep a STRAY ERC-20 (airdrop / accidental send) back to the vault. Target is always
    ///         `vault()`, never caller-supplied, so even the proposer cannot exfil (§13). Reverts
    ///         `CannotRescuePositionToken` for any position/accounting token — usdc / cbBTC / weth
    ///         (all NAV-counted) / mUsdc / mCbBTC / mWeth, and AERO (read live from the gauge so a
    ///         sweep can't bypass `compound()`). The position NFT is never swept (no ERC-721 path).
    function rescueToVault(address token) external onlyProposer nonReentrant {
        Layout storage $ = _layout();
        address aero = ICLGauge($.gauge).rewardToken();
        if (
            token == $.usdc || token == $.cbBTC || token == $.weth || token == $.mUsdc || token == $.mCbBTC
                || token == $.mWeth || token == aero
        ) revert CannotRescuePositionToken();
        _pushAllToVault(token);
    }

    /// @dev No tunable params.
    function _updateParams(bytes calldata) internal override {}

    // ── Config builder for LeveragedAeroValuation ──

    /// @dev Build the valuation `Config` from stored state (cbBTC 8dp / WETH 18dp are compile-time
    ///      constants). Field-by-field (not struct-literal) so the Yul IR emits one sload→mstore per
    ///      field, avoiding the 18-live-variable overflow struct-literals trigger under via_ir.
    function _config() internal view returns (LeveragedAeroValuation.Config memory c) {
        Layout storage $ = _layout();
        c.usdc = $.usdc;
        c.vault = vault();
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
