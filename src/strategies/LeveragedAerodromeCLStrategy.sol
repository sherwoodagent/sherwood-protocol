// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";
import {INonfungiblePositionManager} from "../interfaces/ISlipstream.sol";
import {Position} from "../interfaces/IPriceRouter.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

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

    // ─────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────

    /// @dev cbBTC is always 8-decimal wrapped Bitcoin.
    uint8 private constant CBBTC_DECIMALS = 8;

    /// @dev WETH is always 18-decimal (WETH9 on Base).
    uint8 private constant WETH_DECIMALS = 18;

    /// @dev Position `kind` tag for the PriceRouter adapter registry.
    bytes32 public constant POSITION_KIND = keccak256("LEVERAGED_AERO_CL");

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
    function _npmPositionData() private view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address npm_ = npm;
        uint256 tokenId_ = tokenId;
        bool ok;
        bytes memory ret;
        (ok, ret) = npm_.staticcall(abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_));
        if (!ok) revert();
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

    /// @dev Task 3.2: open the levered cbBTC/WETH CL position.
    function _execute() internal override {
        revert NotImplemented();
    }

    /// @dev Task 3.3: full proportional unwind to the vault.
    function _settle() internal override {
        revert NotImplemented();
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
