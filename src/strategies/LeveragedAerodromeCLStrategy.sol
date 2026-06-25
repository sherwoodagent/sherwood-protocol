// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {LiquidityAmounts} from "../libraries/LiquidityAmounts.sol";
import {ChainlinkReader} from "../libraries/ChainlinkReader.sol";
import {IMoonwellMarket, IComptroller, ICToken} from "../interfaces/IMoonwellMarket.sol";
import {ICLPool, ICLGauge, INonfungiblePositionManager, ICLSwapRouter} from "../interfaces/ISlipstream.sol";
import {Position} from "../interfaces/IPriceRouter.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @dev Minimal WETH9 interface — deposit wraps native ETH into ERC-20 WETH.
interface IWETH9 {
    function deposit() external payable;
}

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
contract LeveragedAerodromeCLStrategy is BaseStrategy, ReentrancyGuardTransient {
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
    /// @notice Post-operation health or LTV is out of bounds.
    error UnhealthyPosition();
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

    // ─────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────

    /// @dev cbBTC is always 8-decimal wrapped Bitcoin.
    uint8 private constant CBBTC_DECIMALS = 8;

    /// @dev WETH is always 18-decimal (WETH9 on Base).
    uint8 private constant WETH_DECIMALS = 18;

    /// @dev Position `kind` tag for the PriceRouter adapter registry.
    bytes32 public constant POSITION_KIND = keccak256("LEVERAGED_AERO_CL");

    /// @dev Number of tick-spacings on each side of the current tick for the initial CL range.
    ///      Mirrors the harness `_openRealBook` range of ±20 tickSpacings.
    uint8 private constant RANGE_TICK_SPACINGS = 20;

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
    // Storage — valuation config fields
    // ─────────────────────────────────────────────────────────────

    address public usdc;
    address public mUsdc;
    address public mCbBTC; // maps to LeveragedAeroValuation.Config.cbBTCMarket
    address public mWeth; // maps to LeveragedAeroValuation.Config.wethMarket
    address public cbBTC;
    address public weth;
    address public pool;
    address public cbBTCFeed;
    address public wethFeed;
    address public usdcFeed;
    address public sequencerFeed;
    uint256 public maxDelay;
    uint256 public gracePeriod;
    uint16 public calmDeviationTicks;
    uint32 public twapWindow;

    // ─────────────────────────────────────────────────────────────
    // Storage — venue / protocol addresses (not in Config)
    // ─────────────────────────────────────────────────────────────

    address public comptroller;
    address public npm;
    address public gauge;
    address public swapRouter;
    int24 public tickSpacing;

    // ─────────────────────────────────────────────────────────────
    // Storage — risk params
    // ─────────────────────────────────────────────────────────────

    uint16 public targetLtvBps;
    uint16 public maxLtvBps;
    uint16 public minHealthBps;
    uint16 public maxSlippageBps;
    /// @notice USDC collateral factor read from Moonwell at init (e.g. 8800 = 88%).
    uint16 public usdcCollateralFactorBps;

    // ─────────────────────────────────────────────────────────────
    // Storage — position state (all zero pre-deploy / post-settle)
    // ─────────────────────────────────────────────────────────────

    /// @notice NPM tokenId of the active CL position.  0 when no position is open.
    uint256 public tokenId;
    /// @notice Stored ticks of the active CL position.
    int24 public posTickLower;
    int24 public posTickUpper;

    // ─────────────────────────────────────────────────────────────
    // Storage — fee params + state
    // ─────────────────────────────────────────────────────────────

    uint16 public managementFeeBps;
    uint16 public performanceFeeBps;
    address public feeRecipient;

    /// @notice High-water-mark NAV per share in USDC (6dp), updated on fee crystallization.
    ///         Zero until the first deposit mints shares.
    uint256 public hwmPerShare;

    /// @notice Timestamp of the last management-fee accrual.
    uint256 public lastFeeAccrualTimestamp;

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
        uint16 cfBps = _readCollateralFactor(comptroller, mUsdc);
        _initGroupE(data[608:], cfBps); // fields 19-23: risk params + CF validation
        _initGroupF(data[768:]); // fields 24-26: fee params
        lastFeeAccrualTimestamp = block.timestamp;
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
        usdc = usdc_;
        mUsdc = mUsdc_;
        mCbBTC = mCbBTC_;
        mWeth = mWeth_;
        comptroller = comp_;
        cbBTC = cbBTC_;
        weth = weth_;
    }

    // ── Group B: pool, npm, gauge, swapRouter (fields 7-10) ──

    function _initGroupB(bytes calldata d) private {
        (address pool_, address npm_, address gauge_, address swapRouter_) =
            abi.decode(d, (address, address, address, address));
        if (pool_ == address(0)) revert ZeroAddress();
        if (npm_ == address(0)) revert ZeroAddress();
        if (gauge_ == address(0)) revert ZeroAddress();
        if (swapRouter_ == address(0)) revert ZeroAddress();
        pool = pool_;
        npm = npm_;
        gauge = gauge_;
        swapRouter = swapRouter_;
    }

    // ── Group C: cbBTCFeed, wethFeed, usdcFeed, sequencerFeed (fields 11-14) ──

    function _initGroupC(bytes calldata d) private {
        (address cbBTCFeed_, address wethFeed_, address usdcFeed_, address seqFeed_) =
            abi.decode(d, (address, address, address, address));
        if (cbBTCFeed_ == address(0)) revert ZeroAddress();
        if (wethFeed_ == address(0)) revert ZeroAddress();
        if (usdcFeed_ == address(0)) revert ZeroAddress();
        if (seqFeed_ == address(0)) revert ZeroAddress();
        cbBTCFeed = cbBTCFeed_;
        wethFeed = wethFeed_;
        usdcFeed = usdcFeed_;
        sequencerFeed = seqFeed_;
    }

    // ── Group D: maxDelay, gracePeriod, calmDeviationTicks, twapWindow (fields 15-18) ──

    function _initGroupD(bytes calldata d) private {
        (uint256 maxDelay_, uint256 gracePeriod_, uint16 calm_, uint32 twap_) =
            abi.decode(d, (uint256, uint256, uint16, uint32));
        maxDelay = maxDelay_;
        gracePeriod = gracePeriod_;
        calmDeviationTicks = calm_;
        twapWindow = twap_;
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
        tickSpacing = ts_;
        targetLtvBps = target_;
        maxLtvBps = maxLtv_;
        minHealthBps = minH_;
        maxSlippageBps = slip_;
        usdcCollateralFactorBps = cfBps;
    }

    // ── Group F: managementFeeBps, performanceFeeBps, feeRecipient (fields 24-26) ──

    function _initGroupF(bytes calldata d) private {
        (uint16 mgmt_, uint16 perf_, address recipient_) = abi.decode(d, (uint16, uint16, address));
        if ((mgmt_ != 0 || perf_ != 0) && recipient_ == address(0)) revert FeeRecipientRequired();
        managementFeeBps = mgmt_;
        performanceFeeBps = perf_;
        feeRecipient = recipient_;
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
    function nav() public view returns (uint256) {
        if (tokenId == 0) {
            // Flat book: sum idle USDC in vault + strategy (face, 6dp, no oracle needed).
            return IERC20(usdc).balanceOf(vault()) + IERC20(usdc).balanceOf(address(this));
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
        address npm_ = npm;
        uint256 tokenId_ = tokenId;
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
        pos = new Position[](1);
        pos[0] = Position({venue: pool, kind: POSITION_KIND, ref: abi.encode(gauge, mUsdc, mCbBTC, mWeth)});
    }

    // ─────────────────────────────────────────────────────────────
    // BaseStrategy stubs (implemented in Tasks 3.2 / 3.3)
    // ─────────────────────────────────────────────────────────────

    /// @notice Open the levered cbBTC/WETH CL position.
    ///
    ///         Sequence:
    ///           1. Supply all USDC at `address(this)` as Moonwell collateral.
    ///           2. Enter mUSDC market in the Comptroller.
    ///           3. Read Chainlink prices; borrow cbBTC + WETH at `targetLtvBps / 2` each.
    ///           4. Moonwell mWETH sends native ETH — wrap it to WETH9.
    ///           5. Mint a Slipstream CL position straddling current tick (±RANGE_TICK_SPACINGS).
    ///           6. Stake the NFT in the AERO gauge.
    ///           7. Store tokenId + ticks.
    ///
    ///         `_assertHealthy()` (Task 3.4) is wired in here once implemented.
    function _execute() internal override {
        uint256 usdcAmt = _supplyCollateral();
        (uint256 cbBTCAmt, uint256 wethAmt) = _computeAndBorrow(usdcAmt);
        _wrapNativeEth();
        _mintAndStake(cbBTCAmt, wethAmt);
    }

    /// @dev Supply all strategy USDC to Moonwell and enter the mUSDC market.
    ///      Returns the amount of USDC supplied (needed for borrow sizing).
    function _supplyCollateral() private returns (uint256 usdcAmt) {
        address usdc_ = usdc;
        address mUsdc_ = mUsdc;
        usdcAmt = IERC20(usdc_).balanceOf(address(this));
        if (usdcAmt == 0) revert ExecuteZeroBalance();
        IERC20(usdc_).forceApprove(mUsdc_, usdcAmt);
        uint256 err = ICToken(mUsdc_).mint(usdcAmt);
        if (err != 0) revert MoonwellMintFailed(err);
        address[] memory markets = new address[](1);
        markets[0] = mUsdc_;
        IComptroller(comptroller).enterMarkets(markets);
    }

    /// @dev Read Chainlink prices, compute borrow amounts, and execute both borrows.
    ///
    ///      Borrow sizing:
    ///        halfBorrowUsd8 = collateralUsdc6dp × 100 × targetLtvBps / (2 × 10000)
    ///        (× 100 converts USDC 6dp to 8dp; ÷ 20000 = ÷ 2 × 10000 = half of LTV%)
    ///
    ///      cbBTC amount (8dp) = halfBorrowUsd8 × 1e8 / pBTC_8dp
    ///      WETH  amount (18dp) = halfBorrowUsd8 × 1e18 / pETH_8dp
    function _computeAndBorrow(uint256 usdcAmt) private returns (uint256 cbBTCAmt, uint256 wethAmt) {
        (uint256 pBTC,) = ChainlinkReader.readUsd(cbBTCFeed, sequencerFeed, maxDelay, gracePeriod);
        (uint256 pETH,) = ChainlinkReader.readUsd(wethFeed, sequencerFeed, maxDelay, gracePeriod);
        // halfBorrowUsd8: usdcAmt (6dp) → 8dp via ×100, then ×targetLtvBps÷(2×10000)
        uint256 halfBorrowUsd8 = (usdcAmt * 100 * uint256(targetLtvBps)) / (2 * 10000);
        cbBTCAmt = (halfBorrowUsd8 * 1e8) / pBTC;
        wethAmt = (halfBorrowUsd8 * 1e18) / pETH;
        uint256 cbErr = IMoonwellMarket(mCbBTC).borrow(cbBTCAmt);
        if (cbErr != 0) revert MoonwellBorrowFailed(cbErr);
        uint256 wethErr = IMoonwellMarket(mWeth).borrow(wethAmt);
        if (wethErr != 0) revert MoonwellBorrowFailed(wethErr);
    }

    /// @dev Wrap all native ETH held by the strategy into ERC-20 WETH9.
    ///      Moonwell's mWETH market sends native ETH to borrowers; the strategy's
    ///      `receive()` absorbs it and we wrap it here before calling NPM.mint.
    function _wrapNativeEth() private {
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            IWETH9(weth).deposit{value: ethBal}();
        }
    }

    /// @dev Compute a tickSpacing-aligned range centred on the current pool tick.
    function _computeTickRange() private view returns (int24 tL, int24 tU) {
        (, int24 currentTick,,,,) = ICLPool(pool).slot0();
        int24 ts = tickSpacing;
        int24 span = int24(uint24(RANGE_TICK_SPACINGS)) * ts;
        tL = _alignTick(currentTick - span, ts);
        tU = _alignTick(currentTick + span, ts);
        if (tU <= tL) tU = tL + ts;
    }

    /// @dev Mint the Slipstream CL position and return its tokenId.
    ///      token0 = WETH (18dp), token1 = cbBTC (8dp) — confirmed for ts=100 pool.
    ///
    ///      Two-sided slippage mins are derived from the **expected actual** deposit
    ///      amounts, not from the desired amounts. The approach:
    ///        1. Read the current pool `sqrtPriceX96` (calm-gated by `_mintAndStake`
    ///           before this call, so spot ≈ TWAP — not manipulated).
    ///        2. Compute L = getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper,
    ///                        wethAmt, cbBTCAmt).
    ///        3. Compute (exp0, exp1) = getAmountsForLiquidity(sqrtP, …, L) — these
    ///           are the true expected per-leg deposits at the current price.
    ///        4. amount{0,1}Min = exp{0,1} × (10000 − maxSlippageBps) / 10000.
    ///
    ///      Using desired amounts as mins would spuriously revert: a straddle mint's
    ///      actual deposit of one leg can be far below its desired amount when the
    ///      current price is near a tick boundary. Using expected actuals is tight +
    ///      correct; the calm-gate guarantees sqrtP ≈ TWAP so exp0/exp1 reflect
    ///      genuine price and the mins only absorb in-block drift.
    function _mintPosition(uint256 wethAmt, uint256 cbBTCAmt, int24 tL, int24 tU) private returns (uint256 tid) {
        address npm_ = npm;
        address weth_ = weth;
        address cbBTC_ = cbBTC;

        // Compute expected actual deposits at the calm-gated sqrtP.
        (uint160 sqrtP,,,,,) = ICLPool(pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tL);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tU);
        uint128 L = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, wethAmt, cbBTCAmt);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, L);
        uint256 slip = uint256(maxSlippageBps);
        uint256 amt0Min = exp0 * (10000 - slip) / 10000;
        uint256 amt1Min = exp1 * (10000 - slip) / 10000;

        IERC20(weth_).forceApprove(npm_, wethAmt);
        IERC20(cbBTC_).forceApprove(npm_, cbBTCAmt);
        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: weth_,
            token1: cbBTC_,
            tickSpacing: tickSpacing,
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
        (tid,,,) = INonfungiblePositionManager(npm_).mint(mp);
        if (tid == 0) revert NpmMintFailed();
    }

    /// @dev Mint the CL position, stake in gauge, and persist state.
    function _mintAndStake(uint256 cbBTCAmt, uint256 wethAmt) private {
        // Calm-gate: revert CalmGateBreached if spot tick deviates from TWAP beyond
        // `calmDeviationTicks`. Must run before _computeTickRange (which reads spot tick)
        // and before _mintPosition (which anchors slippage mins to the calm sqrtP).
        LeveragedAeroValuation._calmGate(_cfg());
        (int24 tL, int24 tU) = _computeTickRange();
        uint256 tid = _mintPosition(wethAmt, cbBTCAmt, tL, tU);
        address gauge_ = gauge;
        // ERC-721 approve: same function selector as ERC-20 approve (approve(address,uint256))
        // but operates on the NFT, not a fungible allowance. Low-level call avoids IERC20 cast.
        (bool ok,) = npm.call(abi.encodeWithSignature("approve(address,uint256)", gauge_, tid));
        if (!ok) revert NpmApproveFailed();
        ICLGauge(gauge_).deposit(tid);
        // Persist position state (so nav()/positions() see the live position)
        tokenId = tid;
        posTickLower = tL;
        posTickUpper = tU;
    }

    /// @dev Align `tick` down to the nearest multiple of `spacing`.
    ///      Handles negative ticks correctly (Solidity truncates-toward-zero by default).
    function _alignTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    /// @notice Full proportional unwind to the vault.
    ///
    ///         Sequence:
    ///           1. Unstake NFT from AERO gauge (auto-claims accrued AERO).
    ///           2. Remove 100% liquidity + collect both tokens.
    ///           3. Repay both Moonwell borrows; handle any IL/fee shortfall via
    ///              a Chainlink-priced USDC→token swap funded by partial mUSDC redeem.
    ///           4. Redeem all remaining mUSDC collateral.
    ///           5. Sweep residual WETH + cbBTC → USDC via exactInputSingle.
    ///           6. Clear position state (tokenId = 0 restores flat-book invariant).
    ///           7. Push all USDC back to vault.
    function _settle() internal override {
        uint256 tid = tokenId;
        // 1. Unstake (auto-claims AERO via gauge spec)
        ICLGauge(gauge).withdraw(tid);
        // 2. Remove 100% liquidity + collect
        _settleLiquidity(tid);
        // 3. Repay both Moonwell borrows (handles shortfall)
        _settleRepayDebts();
        // 4. Redeem all remaining mUSDC collateral (debt = 0 now)
        uint256 mBal = ICToken(mUsdc).balanceOf(address(this));
        if (mBal > 0) {
            uint256 err = ICToken(mUsdc).redeem(mBal);
            if (err != 0) revert MoonwellRedeemFailed(err);
        }
        // 5. Sweep residual WETH + cbBTC → USDC
        _swapTokenToUsdc(weth, WETH_DECIMALS, wethFeed);
        _swapTokenToUsdc(cbBTC, CBBTC_DECIMALS, cbBTCFeed);
        // 6. Clear position state (flat-book invariant: nav() reads tokenId==0 branch)
        tokenId = 0;
        posTickLower = 0;
        posTickUpper = 0;
        // 7. Push all USDC back to vault
        _pushAllToVault(usdc);
    }

    /// @dev Decrease 100% of the CL position's liquidity and collect both tokens.
    ///      Two-sided slippage mins are derived from the expected actual deposits at
    ///      the current sqrtP (same technique as _mintPosition).
    function _settleLiquidity(uint256 tid) private {
        (int24 tL, int24 tU, uint128 liq) = _npmPositionData();
        if (liq == 0) return;
        (uint160 sqrtP,,,,,) = ICLPool(pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tL);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tU);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liq);
        uint256 slip = uint256(maxSlippageBps);
        INonfungiblePositionManager(npm)
            .decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tid,
                liquidity: liq,
                amount0Min: exp0 * (10000 - slip) / 10000,
                amount1Min: exp1 * (10000 - slip) / 10000,
                deadline: block.timestamp + 600
            })
            );
        INonfungiblePositionManager(npm)
            .collect(
                INonfungiblePositionManager.CollectParams({
                tokenId: tid, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
            );
    }

    /// @dev Repay as much of both Moonwell borrows as the current token balances allow,
    ///      then delegate to _settleShortfall() to cover any remaining debt via USDC swap.
    function _settleRepayDebts() private {
        address mCbBTC_ = mCbBTC;
        address mWeth_ = mWeth;
        address cbBTC_ = cbBTC;
        address weth_ = weth;
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

    /// @dev If any borrow balance remains after the direct repay attempt (shortfall due to
    ///      IL or fee accumulation), redeem USDC from mUSDC collateral and swap to cover it.
    ///      Uses Chainlink prices + 10% buffer for the redeem amount; swaps via exactInputSingle.
    function _settleShortfall() private {
        uint256 cbDebtRem = IMoonwellMarket(mCbBTC).borrowBalanceStored(address(this));
        uint256 wethDebtRem = IMoonwellMarket(mWeth).borrowBalanceStored(address(this));
        if (cbDebtRem == 0 && wethDebtRem == 0) return;
        // Read Chainlink prices (8dp each)
        (uint256 pBTC,) = ChainlinkReader.readUsd(cbBTCFeed, sequencerFeed, maxDelay, gracePeriod);
        (uint256 pETH,) = ChainlinkReader.readUsd(wethFeed, sequencerFeed, maxDelay, gracePeriod);
        (uint256 pUsdc,) = ChainlinkReader.readUsd(usdcFeed, sequencerFeed, maxDelay, gracePeriod);
        // USDC needed for each shortfall leg (+10% buffer)
        uint256 cbUsdcNeed = _tokenToUsdc(cbDebtRem, 8, pBTC, pUsdc) * 11000 / 10000;
        uint256 wethUsdcNeed = _tokenToUsdc(wethDebtRem, 18, pETH, pUsdc) * 11000 / 10000;
        uint256 totalNeed = cbUsdcNeed + wethUsdcNeed;
        // Redeem USDC collateral to fund the swaps (health elevated after partial repays)
        if (totalNeed > 0) {
            uint256 redeemErr = ICToken(mUsdc).redeemUnderlying(totalNeed);
            if (redeemErr != 0) revert MoonwellRedeemFailed(redeemErr);
        }
        uint256 slip = uint256(maxSlippageBps);
        // Cover cbBTC shortfall
        if (cbDebtRem > 0) {
            _swapUsdcExactIn(cbBTC, cbUsdcNeed, cbDebtRem * (10000 - slip) / 10000);
            uint256 cbBal2 = IERC20(cbBTC).balanceOf(address(this));
            if (cbBal2 > 0) {
                IERC20(cbBTC).forceApprove(mCbBTC, cbBal2);
                uint256 err = IMoonwellMarket(mCbBTC).repayBorrow(type(uint256).max);
                if (err != 0) revert MoonwellRepayFailed(err);
            }
        }
        // Cover WETH shortfall (spend remaining USDC after cbBTC leg)
        if (wethDebtRem > 0) {
            uint256 usdcLeft = IERC20(usdc).balanceOf(address(this));
            _swapUsdcExactIn(weth, usdcLeft, wethDebtRem * (10000 - slip) / 10000);
            uint256 wBal2 = IERC20(weth).balanceOf(address(this));
            if (wBal2 > 0) {
                IERC20(weth).forceApprove(mWeth, wBal2);
                uint256 err = IMoonwellMarket(mWeth).repayBorrow(type(uint256).max);
                if (err != 0) revert MoonwellRepayFailed(err);
            }
        }
    }

    /// @dev Swap a fixed USDC amount in for `tokenOut` via Slipstream exactInputSingle.
    ///      Caps actualIn at the current USDC balance so a shortfall redeem shortfall
    ///      cannot cause a revert — we swap whatever USDC we have.
    ///      USDC/WETH and USDC/cbBTC pools both use tickSpacing=100 (fork-confirmed).
    function _swapUsdcExactIn(address tokenOut, uint256 amountIn, uint256 minAmtOut) private {
        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        uint256 actualIn = usdcBal < amountIn ? usdcBal : amountIn;
        if (actualIn == 0) return;
        IERC20(usdc).forceApprove(swapRouter, actualIn);
        ICLSwapRouter(swapRouter)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                tokenIn: usdc,
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

    /// @dev Sweep the full balance of `tokenIn` to USDC via Slipstream exactInputSingle.
    ///      Chainlink price bounds the minimum out; used to sweep residual WETH + cbBTC
    ///      after debt repayment completes.
    function _swapTokenToUsdc(address tokenIn, uint8 decimals, address priceFeed) private {
        uint256 bal = IERC20(tokenIn).balanceOf(address(this));
        if (bal == 0) return;
        (uint256 pToken,) = ChainlinkReader.readUsd(priceFeed, sequencerFeed, maxDelay, gracePeriod);
        (uint256 pUsdc,) = ChainlinkReader.readUsd(usdcFeed, sequencerFeed, maxDelay, gracePeriod);
        uint256 expectedUsdc = _tokenToUsdc(bal, decimals, pToken, pUsdc);
        uint256 minOut = expectedUsdc * (10000 - uint256(maxSlippageBps)) / 10000;
        IERC20(tokenIn).forceApprove(swapRouter, bal);
        ICLSwapRouter(swapRouter)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: usdc,
                tickSpacing: int24(100),
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: bal,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
            );
    }

    /// @dev Convert `amt` (in `dec`-decimal token units) to USDC (6dp) using Chainlink prices.
    ///      pToken and pUsdc are both 8dp (standard Chainlink USD feeds).
    ///
    ///      amt(dec) × pToken(8dp) / 10^dec = USD(8dp); × 1e6 / pUsdc = USDC(6dp)
    function _tokenToUsdc(uint256 amt, uint8 dec, uint256 pToken, uint256 pUsdc) private pure returns (uint256) {
        return (amt * pToken * 1e6) / ((10 ** uint256(dec)) * pUsdc);
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
        c.usdc = usdc;
        c.vault = vault();
        c.mUsdc = mUsdc;
        c.cbBTCMarket = mCbBTC;
        c.wethMarket = mWeth;
        c.cbBTC = cbBTC;
        c.weth = weth;
        c.cbBTCDecimals = CBBTC_DECIMALS;
        c.wethDecimals = WETH_DECIMALS;
        c.pool = pool;
        c.cbBTCFeed = cbBTCFeed;
        c.wethFeed = wethFeed;
        c.usdcFeed = usdcFeed;
        c.sequencerFeed = sequencerFeed;
        c.maxDelay = maxDelay;
        c.gracePeriod = gracePeriod;
        c.calmDeviationTicks = calmDeviationTicks;
        c.twapWindow = twapWindow;
    }
}
