// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {LeveragedAeroManager} from "./LeveragedAeroManager.sol";
import {INonfungiblePositionManager} from "../interfaces/ISlipstream.sol";
import {Position} from "../interfaces/IPriceRouter.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LeveragedAeroFees} from "./LeveragedAeroFees.sol";
import {ISyndicateVault} from "../interfaces/ISyndicateVault.sol";

/// @title LeveragedAerodromeCLStrategy
/// @notice Net-short leveraged Aerodrome CL strategy.
///
///         USDC collateral → Moonwell (mUSDC) → borrow cbBTC + WETH
///         → Slipstream CL position → AERO gauge
///
///         Designed as an ERC-1167 clone deployed per proposal.  The template
///         constructor sets `_initialized = true` (via BaseStrategy) so the
///         template itself is permanently locked.  Clones start with
///         `_initialized = false` and are initialised via `initialize()`.
///
///         NAV is oracle-priced via `LeveragedAeroValuation.netEquityUsdc` (fail-closed).
///         Deposit / Redeem / Manage / Deleverage / Rescue are implemented in later tasks;
///         `_execute` and `_settle` revert `NotImplemented` until Task 3.2 / 3.3.
///
///         `ReentrancyGuardTransient` (EIP-1153 transient storage) guards all
///         state-changing external ops.  Base is on Cancun so TSTORE is available.
contract LeveragedAerodromeCLStrategy is BaseStrategy, ReentrancyGuardTransient, ERC721Holder {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────

    /// @notice Callable in later tasks — stubs revert with this until implemented.
    error NotImplemented();
    /// @notice `targetLtvBps > maxLtvBps`.
    error TargetLtvExceedsMax();
    /// @notice `minHealthBps < 10500`.
    error MinHealthTooLow();
    /// @notice Fee recipient is zero-address while a fee bps is non-zero.
    error FeeRecipientRequired();
    /// @notice `maxLtvBps` ≥ Moonwell USDC collateral factor.
    error MaxLtvExceedsCF();
    /// @notice Low-level call to `Comptroller.markets(mUsdc)` failed or returned short data.
    error ComptrollerCallFailed();
    /// @notice Post-operation LTV exceeds `maxLtvBps`, or Moonwell reports a shortfall.
    /// @param ltvBps    Actual LTV in bps at the time of the check.
    /// @param limitBps  The `maxLtvBps` cap that was exceeded.
    error UnhealthyPosition(uint256 ltvBps, uint256 limitBps);
    /// @notice Low-level call to `npm.positions(tokenId)` failed or returned short data.
    error InvalidNpmReturn();
    /// @notice No USDC balance to deploy at execute time.
    error ExecuteZeroBalance();
    /// @notice Moonwell `ICToken.mint()` returned a non-zero Compound error code.
    error MoonwellMintFailed(uint256 errCode);
    /// @notice Moonwell `IMoonwellMarket.borrow()` returned a non-zero Compound error code.
    error MoonwellBorrowFailed(uint256 errCode);
    /// @notice Slipstream NPM returned tokenId == 0.
    error NpmMintFailed();
    /// @notice ERC-721 `approve(gauge, tokenId)` low-level call failed.
    error NpmApproveFailed();
    /// @notice Moonwell `IMoonwellMarket.repayBorrow()` returned a non-zero Compound error code.
    error MoonwellRepayFailed(uint256 errCode);
    /// @notice Moonwell `ICToken.redeem()` returned a non-zero Compound error code.
    error MoonwellRedeemFailed(uint256 errCode);
    /// @notice `deposit` returned fewer shares than `minShares`.
    error InsufficientShares();
    /// @notice `redeem` produced fewer USDC than `minAssetsOut`.
    error InsufficientAssetsOut();
    /// @notice `deployIdle` produced less liquidity than `minLiquidity`.
    error InsufficientLiquidity();
    /// @notice `deployIdle` called with more USDC than the strategy holds idle.
    error InsufficientIdle();

    // ─────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────

    /// @dev cbBTC is always 8-decimal wrapped Bitcoin.
    uint8 private constant CBBTC_DECIMALS = 8;

    /// @dev WETH is always 18-decimal (WETH9 on Base).
    uint8 private constant WETH_DECIMALS = 18;

    /// @dev Position `kind` tag for the PriceRouter adapter registry.
    bytes32 public constant POSITION_KIND = keccak256("LEVERAGED_AERO_CL");

    /// @dev ERC-4626 virtual share offset matching the vault's `_decimalsOffset()`.
    ///      USDC has 6 decimals → _decimalsOffset = 6 → OFFSET = 1e6.
    ///      Deposit share formula: shares = mulDiv(assets, supply + OFFSET, nav + 1).
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;

    // ─────────────────────────────────────────────────────────────
    // Initialisation params struct
    // ─────────────────────────────────────────────────────────────

    /// @notice Strategy initialisation parameters — ABI-encoded and passed to
    ///         `StrategyFactory.cloneAndInit` → `BaseStrategy.initialize` → `_initialize`.
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

    // ─────────────────────────────────────────────────────────────
    // Storage — ERC-7201 namespaced (diamond) storage
    // ─────────────────────────────────────────────────────────────
    //
    // ALL strategy-specific state lives in one `Layout` struct at a fixed
    // ERC-7201 slot, NOT in the contract's sequential storage. The sequential
    // layout therefore holds only BaseStrategy's state (_hcSelf / _vault /
    // _proposer / _state / _initialized). This is the foundation for moving the
    // management ops into a deployed delegatecall library.

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
        uint16 usdcCollateralFactorBps; // USDC collateral factor read from Moonwell at init (e.g. 8800 = 88%)
        // ── position state (all zero pre-deploy / post-settle) ──
        uint256 tokenId; // NPM tokenId of the active CL position. 0 when no position is open.
        int24 posTickLower; // stored ticks of the active CL position
        int24 posTickUpper;
        // ── fee params + state ──
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        address feeRecipient;
        uint256 hwmPerShare; // HWM NAV per share (USDC 6dp); 0 until first deposit mints shares
        uint256 lastFeeAccrualTimestamp; // timestamp of the last management-fee accrual
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @dev Diamond-storage accessor — all strategy-specific state lives in `Layout` at STORAGE_SLOT.
    function _s() private pure returns (Layout storage l) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            l.slot := STORAGE_SLOT
        }
    }

    // ── Minimal field getters (only the fields read by the test suite). Replaces the
    //    whole-struct `s()` ABI encoder, which cost ~1.9 KB of clone bytecode. ──

    function usdc() external view returns (address) {
        return _s().usdc;
    }

    function mUsdc() external view returns (address) {
        return _s().mUsdc;
    }

    function mCbBTC() external view returns (address) {
        return _s().mCbBTC;
    }

    function mWeth() external view returns (address) {
        return _s().mWeth;
    }

    function pool() external view returns (address) {
        return _s().pool;
    }

    function npm() external view returns (address) {
        return _s().npm;
    }

    function gauge() external view returns (address) {
        return _s().gauge;
    }

    function tickSpacing() external view returns (int24) {
        return _s().tickSpacing;
    }

    function targetLtvBps() external view returns (uint16) {
        return _s().targetLtvBps;
    }

    function maxLtvBps() external view returns (uint16) {
        return _s().maxLtvBps;
    }

    function minHealthBps() external view returns (uint16) {
        return _s().minHealthBps;
    }

    function maxSlippageBps() external view returns (uint16) {
        return _s().maxSlippageBps;
    }

    function usdcCollateralFactorBps() external view returns (uint16) {
        return _s().usdcCollateralFactorBps;
    }

    function tokenId() external view returns (uint256) {
        return _s().tokenId;
    }

    function posTickLower() external view returns (int24) {
        return _s().posTickLower;
    }

    function posTickUpper() external view returns (int24) {
        return _s().posTickUpper;
    }

    function managementFeeBps() external view returns (uint16) {
        return _s().managementFeeBps;
    }

    function performanceFeeBps() external view returns (uint16) {
        return _s().performanceFeeBps;
    }

    function feeRecipient() external view returns (address) {
        return _s().feeRecipient;
    }

    // ─────────────────────────────────────────────────────────────
    // Native ETH receiver
    // ─────────────────────────────────────────────────────────────

    /// @dev Moonwell's mWETH market delivers native ETH to the borrower on `borrow()`.
    ///      Without this the strategy rejects the ETH transfer and the borrow call
    ///      reverts.  We immediately wrap to WETH (WETH9.deposit) before using it.
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────
    // IStrategy — name
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Leveraged Aerodrome CL";
    }

    // ─────────────────────────────────────────────────────────────
    // Initialization
    // ─────────────────────────────────────────────────────────────

    /// @notice Strategy-specific initialisation.  Validates InitParams and stores everything
    ///         to clone storage.  Also reads the USDC collateral factor from Moonwell on-chain.
    ///
    /// @dev All `InitParams` fields are fixed-size.  ABI encoding is a straight 27×32-byte
    ///      sequence.  We decode field groups directly from calldata slices (no in-memory
    ///      struct decode) to stay under the Yul IR's 16-slot stack limit.  Each helper
    ///      decodes ≤7 fields from a slice of `data`, so no helper exceeds ~10 live slots.
    ///
    ///      Field byte offsets (each field = 32 bytes):
    ///       0-6  : usdc, mUsdc, mCbBTC, mWeth, comptroller, cbBTC, weth
    ///       7-10 : pool, npm, gauge, swapRouter
    ///       11-14: cbBTCFeed, wethFeed, usdcFeed, sequencerFeed
    ///       15-18: maxDelay, gracePeriod, calmDeviationTicks, twapWindow
    ///       19-23: tickSpacing, targetLtvBps, maxLtvBps, minHealthBps, maxSlippageBps
    ///       24-26: managementFeeBps, performanceFeeBps, feeRecipient
    function _initialize(bytes calldata data) internal override {
        _initGroupA(data); // fields 0-6: token addresses
        _initGroupB(data[224:]); // fields 7-10: venue addresses
        _initGroupC(data[352:]); // fields 11-14: feed addresses
        _initGroupD(data[480:]); // fields 15-18: oracle params
        // Read CF from Moonwell using addresses already in storage (set by group A).
        uint16 cfBps = _readCollateralFactor(_s().comptroller, _s().mUsdc);
        _initGroupE(data[608:], cfBps); // fields 19-23: risk params + CF validation
        _initGroupF(data[768:]); // fields 24-26: fee params
        _s().lastFeeAccrualTimestamp = block.timestamp;
    }

    // ── Group A: usdc, mUsdc, mCbBTC, mWeth, comptroller, cbBTC, weth (fields 0-6) ──

    function _initGroupA(bytes calldata d) private {
        (address usdc_, address mUsdc_, address mCbBTC_, address mWeth_, address comp_, address cbBTC_, address weth_) =
            abi.decode(d, (address, address, address, address, address, address, address));
        if (usdc_ == address(0)) revert ZeroAddress();
        if (mUsdc_ == address(0)) revert ZeroAddress();
        if (mCbBTC_ == address(0)) revert ZeroAddress();
        if (mWeth_ == address(0)) revert ZeroAddress();
        if (comp_ == address(0)) revert ZeroAddress();
        if (cbBTC_ == address(0)) revert ZeroAddress();
        if (weth_ == address(0)) revert ZeroAddress();
        Layout storage $ = _s();
        $.usdc = usdc_;
        $.mUsdc = mUsdc_;
        $.mCbBTC = mCbBTC_;
        $.mWeth = mWeth_;
        $.comptroller = comp_;
        $.cbBTC = cbBTC_;
        $.weth = weth_;
    }

    // ── Group B: pool, npm, gauge, swapRouter (fields 7-10) ──

    function _initGroupB(bytes calldata d) private {
        (address pool_, address npm_, address gauge_, address swapRouter_) =
            abi.decode(d, (address, address, address, address));
        if (pool_ == address(0)) revert ZeroAddress();
        if (npm_ == address(0)) revert ZeroAddress();
        if (gauge_ == address(0)) revert ZeroAddress();
        if (swapRouter_ == address(0)) revert ZeroAddress();
        Layout storage $ = _s();
        $.pool = pool_;
        $.npm = npm_;
        $.gauge = gauge_;
        $.swapRouter = swapRouter_;
    }

    // ── Group C: cbBTCFeed, wethFeed, usdcFeed, sequencerFeed (fields 11-14) ──

    function _initGroupC(bytes calldata d) private {
        (address cbBTCFeed_, address wethFeed_, address usdcFeed_, address seqFeed_) =
            abi.decode(d, (address, address, address, address));
        if (cbBTCFeed_ == address(0)) revert ZeroAddress();
        if (wethFeed_ == address(0)) revert ZeroAddress();
        if (usdcFeed_ == address(0)) revert ZeroAddress();
        if (seqFeed_ == address(0)) revert ZeroAddress();
        Layout storage $ = _s();
        $.cbBTCFeed = cbBTCFeed_;
        $.wethFeed = wethFeed_;
        $.usdcFeed = usdcFeed_;
        $.sequencerFeed = seqFeed_;
    }

    // ── Group D: maxDelay, gracePeriod, calmDeviationTicks, twapWindow (fields 15-18) ──

    function _initGroupD(bytes calldata d) private {
        (uint256 maxDelay_, uint256 gracePeriod_, uint16 calm_, uint32 twap_) =
            abi.decode(d, (uint256, uint256, uint16, uint32));
        Layout storage $ = _s();
        $.maxDelay = maxDelay_;
        $.gracePeriod = gracePeriod_;
        $.calmDeviationTicks = calm_;
        $.twapWindow = twap_;
    }

    /// @dev Read the USDC collateral factor from `Comptroller.markets(mUsdc)`.
    ///      Returns CF in bps (e.g. 8800 = 88%).
    ///      markets(address) ABI encodes as (bool isListed, uint256 collateralFactorMantissa, ...).
    ///      We skip the first 32-byte word (bool) and read the second (the CF mantissa, 1e18-scaled).
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

    // ── Group E: tickSpacing, targetLtvBps, maxLtvBps, minHealthBps, maxSlippageBps (fields 19-23) ──

    function _initGroupE(bytes calldata d, uint16 cfBps) private {
        (int24 ts_, uint16 target_, uint16 maxLtv_, uint16 minH_, uint16 slip_) =
            abi.decode(d, (int24, uint16, uint16, uint16, uint16));
        if (target_ > maxLtv_) revert TargetLtvExceedsMax();
        if (minH_ < 10500) revert MinHealthTooLow();
        if (maxLtv_ >= cfBps) revert MaxLtvExceedsCF();
        Layout storage $ = _s();
        $.tickSpacing = ts_;
        $.targetLtvBps = target_;
        $.maxLtvBps = maxLtv_;
        $.minHealthBps = minH_;
        $.maxSlippageBps = slip_;
        $.usdcCollateralFactorBps = cfBps;
    }

    // ── Group F: managementFeeBps, performanceFeeBps, feeRecipient (fields 24-26) ──

    function _initGroupF(bytes calldata d) private {
        (uint16 mgmt_, uint16 perf_, address recipient_) = abi.decode(d, (uint16, uint16, address));
        if ((mgmt_ != 0 || perf_ != 0) && recipient_ == address(0)) revert FeeRecipientRequired();
        Layout storage $ = _s();
        $.managementFeeBps = mgmt_;
        $.performanceFeeBps = perf_;
        $.feeRecipient = recipient_;
        // hwmPerShare = 0 (default) — set on first deposit.
        // tokenId / posTickLower / posTickUpper = 0 (default) — set in _execute.
    }

    // ─────────────────────────────────────────────────────────────
    // NAV
    // ─────────────────────────────────────────────────────────────

    /// @notice Oracle NAV of the entire levered book, in USDC (6dp).
    ///
    ///         Pre-deploy / post-settle (tokenId == 0):
    ///           Returns the face value of any idle USDC held by the vault + strategy.
    ///           No oracle call needed — no levered position exists.
    ///           `tokenId == 0` is the invariant for a "flat book"; both `_execute`
    ///           (Task 3.2) and `_settle` (Task 3.3) maintain it: execute sets tokenId
    ///           to the minted NPM token, settle clears it back to 0.
    ///
    ///         Active position (tokenId > 0):
    ///           Reads position ticks + liquidity from the NPM and delegates to
    ///           `LeveragedAeroValuation.netEquityUsdc` — oracle-implied sqrtP,
    ///           fail-closed (reverts on any oracle/calm failure or non-positive equity).
    function nav() public view virtual returns (uint256) {
        Layout storage $ = _s();
        if ($.tokenId == 0) {
            // Flat book: sum idle USDC in vault + strategy (face, 6dp, no oracle needed).
            return IERC20($.usdc).balanceOf(vault()) + IERC20($.usdc).balanceOf(address(this));
        }
        // Active position: read ticks + liquidity from the NPM and delegate to the valuation lib.
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _npmPositionData();
        return LeveragedAeroValuation.netEquityUsdc(_cfg(), address(this), tickLower, tickUpper, liquidity);
    }

    /// @dev Reads only the 3 fields we need from the NPM positions() 12-tuple.
    ///      Using a low-level staticcall + assembly avoids placing all 12 return values on
    ///      the EVM stack simultaneously, which would overflow the Yul IR's 16-slot limit
    ///      when combined with the surrounding `nav()` stack frame.
    ///
    ///      NPM.positions(tokenId) return layout (12 × 32-byte words, all static):
    ///        [0] nonce     [1] operator  [2] token0    [3] token1    [4] tickSpacing
    ///        [5] tickLower [6] tickUpper [7] liquidity  [8] fgRow0   [9] fgRow1
    ///        [10] owed0    [11] owed1
    ///
    ///      Memory layout of `ret` (bytes): [length @ offset 0][data start @ offset 0x20].
    ///      Field at index N starts at `ret + 0x20 + N * 0x20`.
    function _npmPositionData() internal view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address npm_ = _s().npm;
        uint256 tokenId_ = _s().tokenId;
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

    // ─────────────────────────────────────────────────────────────
    // Positions (Lane A reporting for the PriceRouter)
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IStrategy
    /// @notice Reports the single levered-CL position to the vault's PriceRouter.
    ///         The `ref` payload encodes the market addresses required by the
    ///         `LEVERAGED_AERO_CL` adapter (once registered) to verify the venues.
    function positions() external view override returns (Position[] memory pos) {
        Layout storage $ = _s();
        pos = new Position[](1);
        pos[0] = Position({venue: $.pool, kind: POSITION_KIND, ref: abi.encode($.gauge, $.mUsdc, $.mCbBTC, $.mWeth)});
    }

    // ─────────────────────────────────────────────────────────────
    // BaseStrategy stubs (implemented in Tasks 3.2 / 3.3)
    // ─────────────────────────────────────────────────────────────

    /// @notice Open the levered cbBTC/WETH CL position.
    ///
    ///         The full venue sequence — supply USDC → enterMarkets → borrow cbBTC+WETH →
    ///         wrap native ETH → mint Slipstream CL → stake gauge → assert post-op health —
    ///         lives in the deployed `LeveragedAeroManager` library and runs here via
    ///         delegatecall (so `address(this)` / `_s()` are this clone's).
    function _execute() internal override {
        LeveragedAeroManager.executeImpl();
        // Belt-and-suspenders: ensure the fee accrual clock is running. _initialize already
        // seeds it; this guard prevents a ~54-year dt on the first crystallize if a clone
        // (somehow) bypassed _initialize.
        if (_s().lastFeeAccrualTimestamp == 0) _s().lastFeeAccrualTimestamp = block.timestamp;
    }

    /// @notice Full proportional unwind to the vault.
    ///
    ///         The full unwind — unstake + remove 100% liquidity + collect, repay both
    ///         Moonwell borrows (self-funding any IL/fee shortfall), redeem all collateral,
    ///         sweep residual cbBTC/WETH → USDC, clear position state — lives in
    ///         `LeveragedAeroManager.settleImpl()` (delegatecalled). The realized USDC is then
    ///         pushed to the vault here (the manager never touches `vault()`).
    function _settle() internal override {
        LeveragedAeroManager.settleImpl();
        _pushAllToVault(_s().usdc);
    }

    /// @dev Crystallise management + HWM performance fees on the PRE-ACTION vault state.
    ///
    ///      The caller supplies `navPre` (the NAV before any user funds move) rather than
    ///      letting this function call `nav()` itself.  This makes crystallisation
    ///      **oracle-tolerant**: the deposit path passes `nav()` (fail-closed, correct
    ///      behaviour — a revert on oracle failure is right for deposit); the redeem path
    ///      passes 0 when `nav()` is unavailable, causing `LeveragedAeroFees.crystallize`
    ///      to return 0 fee-shares and advance the timestamp — redeem proceeds oracle-free.
    ///
    /// @param navPre  Pre-action NAV (USDC, 6dp).  Pass 0 to skip fees (oracle-free path).
    function _crystallizeFees(uint256 navPre) private {
        Layout storage $ = _s();
        uint256 ts = IERC20(vault()).totalSupply();
        if (ts == 0) return;
        if ($.lastFeeAccrualTimestamp == 0) {
            $.lastFeeAccrualTimestamp = block.timestamp;
            return;
        }
        (uint256 feeShares, uint256 newHwm, uint256 newLast) = LeveragedAeroFees.crystallize(
            navPre,
            ts,
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

    /// @notice Oracle-priced deposit: mint vault shares proportional to current NAV.
    ///
    ///         Call ordering is load-bearing ([1] phantom-fee fix):
    ///           1. Crystallise fees on the PRE-deposit NAV, before USDC is pulled.
    ///           2. Read post-crystallise NAV (fail-closed: reverts on oracle failure).
    ///           3. Pull USDC from caller.
    ///           4. Compute shares via ERC-4626 virtual-offset formula.
    ///           5. Mint shares via vault.strategyMint.
    ///
    ///         The deposited USDC sits idle in the strategy until a proposer calls
    ///         `deployIdle()` to add it to the levered position.
    ///
    /// @param assets    USDC to deposit (6 dp).
    /// @param minShares Minimum vault shares to receive (slippage guard).
    /// @return shares   Vault shares minted to msg.sender.
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (_state != State.Executed) revert NotExecuted();
        // Crystallize on pre-deposit NAV (fail-closed: oracle down → correct revert for deposit).
        uint256 navPre = nav();
        _crystallizeFees(navPre);
        IERC20(_s().usdc).safeTransferFrom(msg.sender, address(this), assets);
        address vault_ = vault();
        uint256 supply = IERC20(vault_).totalSupply();
        shares = Math.mulDiv(assets, supply + SHARES_VIRTUAL_OFFSET, navPre + 1);
        if (shares < minShares) revert InsufficientShares();
        ISyndicateVault(vault_).strategyMint(msg.sender, shares);
    }

    /// @notice Deploy `amount` of idle strategy USDC into the existing levered position.
    ///
    ///         The supply + borrow + (unstake → increaseLiquidity → restake) + health-assert
    ///         sequence lives in `LeveragedAeroManager.deployIdleImpl()` (delegatecalled).
    ///
    /// @param amount       USDC to deploy (6 dp). Must be ≤ idle USDC in strategy.
    /// @param minLiquidity Minimum liquidity units to accept (slippage guard).
    function deployIdle(uint256 amount, uint256 minLiquidity) external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        LeveragedAeroManager.deployIdleImpl(amount, minLiquidity);
    }

    /// @notice Oracle-free proportional redeem: burn vault shares, receive pro-rata USDC.
    ///
    ///         The caller must call `vault.approve(strategy, shares)` first so this
    ///         function can pull the shares via `safeTransferFrom`.
    ///
    ///         Call ordering:
    ///           1. Best-effort fee crystallise — oracle down → navPre=0 → no fees →
    ///              redeem proceeds unblocked (oracle-free guarantee).
    ///           2. Fix fraction denominator ONCE (before burn so supply is stable).
    ///           3. Pull shares from msg.sender via safeTransferFrom.
    ///           4. Proportional oracle-free unwind (LeveragedAeroManager.redeemUnwindImpl).
    ///           5. Revert if assetsOut < minAssetsOut (aggregate slippage guard).
    ///           6. Transfer USDC to msg.sender.
    ///           7. vault.strategyBurn(shares) — burns from the strategy's share balance.
    ///
    /// @param shares       Vault shares to redeem (12 dp).
    /// @param minAssetsOut Minimum USDC to receive (oracle-free aggregate slippage guard).
    /// @return assetsOut   USDC transferred to msg.sender.
    function redeem(uint256 shares, uint256 minAssetsOut) external nonReentrant returns (uint256 assetsOut) {
        if (_state != State.Executed) revert NotExecuted();

        // 1. Best-effort crystallise: oracle outage → navPre=0 → no fees → proceed.
        uint256 navPre;
        try this.nav() returns (uint256 n) {
            navPre = n;
        } catch {
            navPre = 0;
        }
        _crystallizeFees(navPre);

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
        IERC20(_s().usdc).safeTransfer(msg.sender, assetsOut);

        // 7. Burn shares (strategy holds them after safeTransferFrom above).
        ISyndicateVault(vault_).strategyBurn(shares);
    }

    /// @dev Tunable param updates (Task 3.6+).
    function _updateParams(bytes calldata) internal override {}

    // ─────────────────────────────────────────────────────────────
    // Internal: Config builder for LeveragedAeroValuation
    // ─────────────────────────────────────────────────────────────

    /// @notice Build the `LeveragedAeroValuation.Config` from stored state.
    ///         `cbBTCDecimals` and `wethDecimals` are compile-time constants
    ///         (cbBTC is always 8dp, WETH9 is always 18dp).
    ///
    /// @dev Field-by-field assignment (not struct-literal) forces the Yul IR to emit
    ///      one sload→mstore per field, avoiding the 18-simultaneous-live-variable
    ///      overflow that the struct-literal notation can trigger under via_ir.
    function _cfg() internal view returns (LeveragedAeroValuation.Config memory c) {
        Layout storage $ = _s();
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
