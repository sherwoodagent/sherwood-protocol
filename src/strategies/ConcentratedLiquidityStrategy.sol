// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, Id, MarketParams, Market} from "../vendor/morpho/IMorpho.sol";
import {MarketParamsLib} from "../vendor/morpho/MorphoLibs.sol";
import {IUniswapV3Pool} from "../vendor/uniswap/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../vendor/uniswap/INonfungiblePositionManager.sol";

/**
 * @title ConcentratedLiquidityStrategy
 * @notice Deploys vault capital as a market-making position: concentrated
 *         liquidity over a bounded tick range in one Uniswap V3 pool, with the
 *         position funded by borrowing the vault asset against stable
 *         collateral rather than by selling into the volatile leg.
 *
 *   Execute: pull the vault asset → post it (or its ERC-4626 wrapper) as
 *            Morpho collateral → borrow the vault asset → rebalance to the
 *            agent's declared fraction of the pool's other token → mint ONE
 *            position over the fixed tick range.
 *   Rerange: permissionless and fully determined — burn, collect, re-mint the
 *            approved half-width centered on the current TWAP tick. Never
 *            touches the borrow or the collateral.
 *   Settle:  decrease to zero → collect → convert the other token back →
 *            repay → withdraw collateral → push everything to the vault.
 *            Deliverable-maximum, never all-or-revert (see `_settle`).
 *
 *   Batch calls from governor:
 *     Execute: [asset.approve(strategy, assetAmount), strategy.execute()]
 *     Settle:  [strategy.settle()]
 *
 * @dev WHAT THE AGENT CHOOSES AND WHAT THIS CONTRACT BOUNDS. The economics
 *      depend on realized volatility, trailing fee/TVL and venue decay, none of
 *      which are computable on-chain. The agent computes the band, the size,
 *      the target LTV and the swap split off-chain and passes them as init
 *      data; this contract enforces only what it can evaluate from live venue
 *      state — pool and market existence, token match, borrow ≤ lendable,
 *      LTV ≤ LLTV − buffer, minted liquidity ≤ pool-share cap, tick alignment,
 *      and a spot-vs-TWAP bound at every mint. A bad-but-in-bounds proposal
 *      remains possible; that is what voter and guardian review are for.
 */
contract ConcentratedLiquidityStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    // ── Constants ──

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum share of the pool's in-range liquidity this position may
    ///         become, enforced against the ACTUAL minted liquidity at execute.
    /// @dev    Adversary: a proposer sizing against a venue that cannot absorb
    ///         it. A position that is a large share of pool liquidity dilutes
    ///         its own fee income and makes its own exit the dominant flow,
    ///         converting a market-making position into a forced seller. The
    ///         deepest tokenized-equity/USDG pool measured on chain 4663 held
    ///         $820k with 24h volume swinging $0.65M–$15.5M over 14 days, so
    ///         "a share of depth" is the only sizing rule that survives the
    ///         depth moving.
    ///
    ///         A CONSTANT, NOT A CONFIG READ. Deliberate: it is visible in the
    ///         verified source a voter reads, there is nothing to mis-wire per
    ///         clone, and changing it means deploying a new template — which is
    ///         correct, because it changes what every future proposal may do.
    uint256 public constant MAX_POOL_SHARE_BPS = 1_000;

    /// @notice How far below the market's own LLTV the position must initialize.
    /// @dev    Adversary: a proposer initializing so close to liquidation that
    ///         ordinary in-range price movement liquidates the collateral
    ///         before settlement. Sized against the proposal-duration ceiling,
    ///         not against a day — reranging re-centers the LP band but never
    ///         touches the borrow, so nothing in this contract relieves LTV
    ///         once execute has run. This buffer is the only on-chain control.
    uint256 public constant MIN_LLTV_BUFFER_BPS = 500;

    /// @notice Hard ceiling on any configured slippage floor.
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    /// @notice Hard ceiling on the configured spot-vs-TWAP deviation bound.
    uint256 public constant MAX_TWAP_DEVIATION_BPS = 1_000;

    /// @notice Shortest TWAP window a proposal may configure.
    /// @dev    A window this short is still cheap to move; it is a floor on
    ///         absurdity, not a safety margin. The real protection is that the
    ///         attacker must hold the manipulated tick across the whole window.
    uint32 public constant MIN_TWAP_WINDOW = 300;

    /// @notice Ceiling on the approved rerange count.
    /// @dev    Bounds the griefing surface: a permissionless rerange costs the
    ///         position a swap and realized divergence loss each time, so the
    ///         worst case a voter must price is
    ///         `maxReranges × (swap cost + slippage floor)`.
    uint256 public constant MAX_RERANGE_LIMIT = 20;

    // ── Errors ──

    error InvalidAmount();
    /// @notice The configured pool does not quote the vault asset. Adversary: a
    ///         proposer naming a pool whose position could not be unwound into
    ///         the asset the vault redeems in.
    error PoolAssetMismatch();
    /// @notice The pool was not created by the configured factory. Adversary: a
    ///         contract that answers every `IUniswapV3Pool` selector with
    ///         attacker-chosen values — token0/token1 that pass the asset
    ///         check, a `liquidity()` large enough to clear the pool-share cap,
    ///         and an `observe` whose TWAP always equals its own spot.
    error PoolNotFromFactory();
    /// @notice The lending market's loan token is not the vault asset.
    error LoanAssetMismatch();
    /// @notice The market's collateral token is neither the vault asset nor an
    ///         ERC-4626 wrapper of it. Adversary: a proposer collateralizing the
    ///         volatile leg, which is both unexecutable at size on this chain
    ///         (every tokenized-equity market measured held $0–$1.6k lendable)
    ///         and would give the position a second liquidation surface
    ///         correlated with the LP's own divergence loss.
    error CollateralAssetMismatch();
    /// @notice The derived market id has never been created on the configured
    ///         Morpho contract — fail at init rather than at execute.
    error MarketNotCreated();
    /// @notice The requested borrow exceeds what the market can currently fund.
    ///         Fails here rather than reverting the whole batch at execute.
    error BorrowExceedsLiquidity();
    /// @notice The target loan-to-value sits inside the liquidation buffer.
    error LtvInsideLiquidationBuffer();
    /// @notice The position's liquidity exceeds the pool-share cap.
    error PositionExceedsPoolShareCap();
    /// @notice The tick range is inverted, empty, or not aligned to the pool's
    ///         tick spacing. A misaligned tick is rejected by the pool itself at
    ///         mint; catching it at init turns a mid-batch revert into a failed
    ///         proposal.
    error InvalidTickRange();
    /// @notice A rerange-policy field is outside its admissible range.
    error InvalidRerangePolicy();
    /// @notice A configured slippage floor or deviation bound exceeds its ceiling.
    error InvalidBound();
    /// @notice Spot deviates from the window TWAP by more than the configured
    ///         bound. Adversary: an attacker who moves the pool's spot tick
    ///         immediately before a scheduled execution so the position mints
    ///         entirely into the leg they are about to sell back, extracting the
    ///         difference from the vault at mint.
    error SpotOutsideTwapBound();
    /// @notice The pool cannot serve an observation over the configured window.
    ///         Fail-closed on purpose — see `_twapTick`.
    error TwapUnavailable();
    /// @notice `rerange()` was called while the clone was not Executed.
    error NotExecutedForRerange();
    /// @notice Price has not yet reached the approved trigger fraction.
    error RerangeTriggerNotReached();
    /// @notice The approved minimum interval has not elapsed.
    error RerangeTooSoon();
    /// @notice The approved maximum rerange count has been reached. The position
    ///         stays in its last range and remains settleable.
    error RerangeCapReached();
    /// @notice A parameter update tried to change something the review approved.
    error ImmutableParam();
    /// @notice `sweep()` is the post-settlement recovery path only.
    error NotSettled();
    /// @notice The configured adapter could not quote a leg this contract is
    ///         about to swap. Adversary: the absence of a floor. This contract
    ///         carries no price oracle of its own, so the adapter's quote is the
    ///         ONLY source a minimum-output can be derived from — swapping with
    ///         a zero floor would be a free sandwich for whoever is watching the
    ///         mempool. Reverting is correct at execute and at rerange; at
    ///         SETTLE it would hand a griefer a veto, which is why `_settle`
    ///         routes its conversion through `_trySwapToAsset` instead.
    error QuoteUnavailable();

    // ── Events ──

    event PositionOpened(
        address indexed pool,
        uint256 indexed tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 borrowed,
        uint256 collateral
    );

    event PositionReranged(
        uint256 indexed rerangeIndex,
        uint256 oldTokenId,
        uint256 indexed newTokenId,
        int24 oldTickLower,
        int24 oldTickUpper,
        int24 newTickLower,
        int24 newTickUpper,
        int24 twapTick,
        uint128 liquidityBefore,
        uint128 liquidityAfter
    );

    /// @notice Settlement could not clear the whole position in one call.
    ///         Loud on purpose: the governor measures PnL from the vault's
    ///         realized float, so the residue books as a LOSS on this proposal
    ///         and is later returned untaxed by `sweep()`.
    event SettlementIncomplete(uint256 debtRemaining, uint256 collateralRemaining);

    event ResidualSwept(uint256 assets);

    // ── Types ──

    /// @notice Fixed at initialization and immutable thereafter. What voters and
    ///         guardians approve is THIS, not each resulting range.
    struct RerangePolicy {
        /// @notice Half-width, in ticks, of every re-centered range.
        int24 halfWidthTicks;
        /// @notice How far through the active range price must travel before a
        ///         rerange is admissible, as a fraction of the half-range.
        uint256 triggerBps;
        /// @notice Minimum seconds between reranges.
        uint256 minInterval;
        /// @notice Hard cap on the number of reranges.
        uint256 maxReranges;
        /// @notice Slippage floor applied to the re-mint.
        uint256 slippageBps;
        /// @notice Fraction of the freed vault asset to convert into the other
        ///         token before re-minting a centered range.
        uint256 swapFractionBps;
    }

    struct InitParams {
        address pool;
        address positionManager;
        address uniswapFactory;
        address swapAdapter;
        address morpho;
        MarketParams marketParams;
        /// @notice Vault asset pulled at execute and posted as collateral.
        uint256 collateralAmount;
        /// @notice Vault asset borrowed against that collateral.
        uint256 borrowAmount;
        /// @notice Collateral value, in vault-asset terms, the agent priced the
        ///         LTV against. Equals `collateralAmount` when the market takes
        ///         the vault asset directly; for a wrapper it is the agent's
        ///         off-chain valuation of the shares received.
        uint256 collateralValue;
        int24 tickLower;
        int24 tickUpper;
        /// @notice The agent's expected minted liquidity, bounded here against
        ///         the pool-share cap and re-checked against reality at execute.
        uint128 expectedLiquidity;
        /// @notice Fraction of deployable vault asset converted to the other
        ///         token before the initial mint.
        uint256 swapFractionBps;
        uint32 twapWindow;
        uint256 maxTwapDeviationBps;
        uint256 mintSlippageBps;
        RerangePolicy rerange;
        uint256 settleSlippageBps;
        uint256 settleDeadline;
        /// @notice Route data the adapter decodes to pick its venue (a leading
        ///         mode byte plus the route). Opaque here on purpose: this
        ///         contract does not know how many Uniswap versions the adapter
        ///         supports, and encoding that knowledge would couple the
        ///         template to a specific adapter revision.
        bytes swapExtraData;
    }

    // ── Storage (per-clone) ──

    IUniswapV3Pool public pool;
    INonfungiblePositionManager public positionManager;
    ISwapAdapter public swapAdapter;
    IMorpho public morpho;
    Id public marketId;
    MarketParams internal _marketParams;

    /// @notice The vault asset == the market's loan token == one of the pool's
    ///         two tokens (all enforced at init).
    address public asset;
    /// @notice The pool's other token — the volatile leg.
    address public otherToken;
    /// @notice True when the vault asset is the pool's `token0`.
    bool public assetIsToken0;

    uint256 public collateralAmount;
    uint256 public borrowAmount;
    uint256 public swapFractionBps;
    uint128 public expectedLiquidity;

    int24 public tickLower;
    int24 public tickUpper;
    int24 public tickSpacing;

    /// @notice The live position, or 0 when none is held. At most one at a time
    ///         — a rerange REPLACES it rather than adding to it.
    uint256 public tokenId;

    uint32 public twapWindow;
    uint256 public maxTwapDeviationBps;
    uint256 public mintSlippageBps;

    RerangePolicy internal _rerange;
    uint256 public rerangeCount;
    uint256 public lastRerangeAt;

    /// @notice Adapter route data, fixed at init. Not tunable: it selects which
    ///         venue every swap crosses, which is part of what review approved.
    bytes public swapExtraData;

    // Tunable between execute and settle, by the proposer only.
    uint256 public settleSlippageBps;
    /// @notice Deadline stamped onto settlement's position calls. Zero means
    ///         "this block", which is the safe default; a proposer raises it
    ///         only to tolerate a settlement batch that may land later.
    uint256 public settleDeadline;

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Concentrated Liquidity LP";
    }

    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    function rerangePolicy() external view returns (RerangePolicy memory) {
        return _rerange;
    }

    // ── Initialization ──

    /// @dev Validation runs in the spec's adversary order. Every check below
    ///      fails the PROPOSAL rather than the batch: a typo'd or infeasible
    ///      configuration must not reach execute with vault funds in flight.
    function _initialize(bytes calldata data) internal override {
        InitParams memory p = abi.decode(data, (InitParams));

        if (p.pool == address(0) || p.positionManager == address(0)) revert ZeroAddress();
        if (p.morpho == address(0) || p.swapAdapter == address(0)) revert ZeroAddress();
        if (p.uniswapFactory == address(0)) revert ZeroAddress();
        if (p.collateralAmount == 0 || p.borrowAmount == 0) revert InvalidAmount();
        if (p.expectedLiquidity == 0) revert InvalidAmount();

        address vaultAsset = IERC4626(vault()).asset();

        // (1) The pool exists and one of its two tokens is the vault asset.
        //     The factory check comes first: without it every other read below
        //     is attacker-chosen, because a contract can answer all of these
        //     selectors. `getPool` is NOT used — a pool reporting its own
        //     factory is the direction that cannot be forged by a third party
        //     deploying a real pool for a fake token pair.
        IUniswapV3Pool pool_ = IUniswapV3Pool(p.pool);
        if (pool_.factory() != p.uniswapFactory) revert PoolNotFromFactory();

        address t0 = pool_.token0();
        address t1 = pool_.token1();
        if (t0 == vaultAsset) {
            assetIsToken0 = true;
            otherToken = t1;
        } else if (t1 == vaultAsset) {
            assetIsToken0 = false;
            otherToken = t0;
        } else {
            revert PoolAssetMismatch();
        }

        // (2) The market exists and lends the vault asset.
        if (p.marketParams.loanToken != vaultAsset) revert LoanAssetMismatch();
        Id id = p.marketParams.id();
        if (IMorpho(p.morpho).market(id).lastUpdate == 0) revert MarketNotCreated();

        //     Collateral is the vault asset or an ERC-4626 wrapper OF the vault
        //     asset — never the volatile leg. `otherToken` is excluded
        //     explicitly rather than relying on the wrapper probe to reject it,
        //     because a volatile token could itself be an ERC-4626 over the
        //     vault asset and would otherwise slip through.
        if (p.marketParams.collateralToken == otherToken) revert CollateralAssetMismatch();
        if (p.marketParams.collateralToken != vaultAsset) {
            if (!_isWrapperOf(p.marketParams.collateralToken, vaultAsset)) revert CollateralAssetMismatch();
        }

        // (3) The borrow fits the market's currently lendable liquidity.
        {
            Market memory m = IMorpho(p.morpho).market(id);
            uint256 lendable = m.totalSupplyAssets > m.totalBorrowAssets
                ? uint256(m.totalSupplyAssets) - uint256(m.totalBorrowAssets)
                : 0;
            if (p.borrowAmount > lendable) revert BorrowExceedsLiquidity();
        }

        // (4) The resulting LTV clears the market's own LLTV by the buffer.
        //     `lltv` is WAD upstream; convert to bps before comparing.
        {
            if (p.collateralValue == 0) revert InvalidAmount();
            uint256 ltvBps = (p.borrowAmount * BPS_DENOMINATOR) / p.collateralValue;
            uint256 lltvBps = (p.marketParams.lltv * BPS_DENOMINATOR) / 1e18;
            if (lltvBps < MIN_LLTV_BUFFER_BPS) revert LtvInsideLiquidationBuffer();
            if (ltvBps > lltvBps - MIN_LLTV_BUFFER_BPS) revert LtvInsideLiquidationBuffer();
        }

        // (5) The position does not exceed the pool-share cap. This bounds the
        //     agent's CLAIM; `_execute` re-checks the liquidity actually minted
        //     against live pool liquidity, which is the enforceable version.
        _requireWithinPoolShare(pool_, p.expectedLiquidity);

        // (6) The tick range is ordered, non-empty, and spacing-aligned.
        int24 spacing = pool_.tickSpacing();
        _requireValidRange(p.tickLower, p.tickUpper, spacing);

        _requireValidBounds(p);
        _requireValidRerangePolicy(p.rerange, spacing);

        pool = pool_;
        positionManager = INonfungiblePositionManager(p.positionManager);
        swapAdapter = ISwapAdapter(p.swapAdapter);
        morpho = IMorpho(p.morpho);
        marketId = id;
        _marketParams = p.marketParams;
        asset = vaultAsset;

        collateralAmount = p.collateralAmount;
        borrowAmount = p.borrowAmount;
        swapFractionBps = p.swapFractionBps;
        expectedLiquidity = p.expectedLiquidity;

        tickLower = p.tickLower;
        tickUpper = p.tickUpper;
        tickSpacing = spacing;

        twapWindow = p.twapWindow;
        maxTwapDeviationBps = p.maxTwapDeviationBps;
        mintSlippageBps = p.mintSlippageBps;

        _rerange = p.rerange;
        swapExtraData = p.swapExtraData;
        settleSlippageBps = p.settleSlippageBps;
        settleDeadline = p.settleDeadline;
    }

    /// @dev Adapter-quote-driven floor, mirroring `PortfolioStrategy._quoteMinOut`.
    ///      An adapter whose `quote()` returns 0 or reverts cannot guarantee
    ///      slippage at all, so there is nothing to degrade TO — the caller
    ///      decides whether that is fatal.
    function _quoteMinOut(address tokenIn, address tokenOut, uint256 amountIn, uint256 slippageBps)
        private
        returns (uint256)
    {
        try swapAdapter.quote(tokenIn, tokenOut, amountIn, swapExtraData) returns (uint256 expected) {
            if (expected == 0) revert QuoteUnavailable();
            return (expected * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
        } catch {
            revert QuoteUnavailable();
        }
    }

    /// @dev The deadline settlement stamps onto its position calls.
    ///      EXTEND-ONLY, NEVER EXPIRING. A tunable that could resolve to a past
    ///      timestamp would let the proposer brick `settle()` — the vault's only
    ///      exit — by setting it once and walking away, which is precisely the
    ///      settlement veto the deliverable-maximum design exists to remove.
    ///      Taking the max means the field can only ever widen the window a
    ///      later-landing settlement batch is accepted in.
    function _deadline() private view returns (uint256) {
        uint256 d = settleDeadline;
        return d > block.timestamp ? d : block.timestamp;
    }

    /// @dev Probe for "is `token` an ERC-4626 whose underlying is `underlying`".
    ///      Raw staticcall with an explicit `ret.length` check, per the repo's
    ///      oracle-read discipline: a high-level call here would revert in THIS
    ///      frame with no data when `token` is a plain ERC-20 with no `asset()`,
    ///      which is a legitimate configuration this function must be able to
    ///      answer "no" to rather than abort on.
    ///      FAILS CLOSED: anything that does not cleanly decode to `underlying`
    ///      is treated as not-a-wrapper, and the caller reverts.
    function _isWrapperOf(address token, address underlying) private view returns (bool) {
        if (token.code.length == 0) return false;
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC4626.asset, ()));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (address)) == underlying;
    }

    function _requireValidRange(int24 lower, int24 upper, int24 spacing) private pure {
        if (lower >= upper) revert InvalidTickRange();
        if (spacing <= 0) revert InvalidTickRange();
        if (lower % spacing != 0 || upper % spacing != 0) revert InvalidTickRange();
    }

    function _requireValidBounds(InitParams memory p) private pure {
        if (p.twapWindow < MIN_TWAP_WINDOW) revert InvalidBound();
        if (p.maxTwapDeviationBps == 0 || p.maxTwapDeviationBps > MAX_TWAP_DEVIATION_BPS) revert InvalidBound();
        if (p.mintSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidBound();
        if (p.settleSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidBound();
        if (p.swapFractionBps > BPS_DENOMINATOR) revert InvalidBound();
    }

    function _requireValidRerangePolicy(RerangePolicy memory r, int24 spacing) private pure {
        // A half-width below one tick spacing cannot snap to a non-empty range.
        if (r.halfWidthTicks < spacing) revert InvalidRerangePolicy();
        if (r.triggerBps == 0 || r.triggerBps > BPS_DENOMINATOR) revert InvalidRerangePolicy();
        if (r.maxReranges > MAX_RERANGE_LIMIT) revert InvalidRerangePolicy();
        if (r.slippageBps > MAX_SLIPPAGE_BPS) revert InvalidRerangePolicy();
        if (r.swapFractionBps > BPS_DENOMINATOR) revert InvalidRerangePolicy();
    }

    function _requireWithinPoolShare(IUniswapV3Pool pool_, uint128 liquidity) private view {
        uint256 poolLiquidity = pool_.liquidity();
        // A pool with zero in-range liquidity admits no position at all: the
        // cap is a SHARE, and every share of zero is zero.
        uint256 cap = (poolLiquidity * MAX_POOL_SHARE_BPS) / BPS_DENOMINATOR;
        if (uint256(liquidity) > cap) revert PositionExceedsPoolShareCap();
    }

    // ── Price guards ──

    /// @notice The pool's arithmetic-mean tick over `twapWindow`.
    /// @dev    FAILS CLOSED, deliberately, and unlike `PortfolioStrategy`'s
    ///         `_tryPushFeedPrice`. This read IS the security boundary against
    ///         minting into a manipulated tick, and its failure is recoverable
    ///         (redeploy the clone, propose again) while the loss it prevents is
    ///         not. A pool whose observation ring cannot serve the window
    ///         reverts here rather than degrading to spot — degrading to spot
    ///         would compare spot against itself and pass unconditionally,
    ///         which is worse than no guard because it looks like one.
    ///
    ///         Raw staticcall rather than a typed call so an `observe` that
    ///         reverts (upstream `OLD`) is distinguishable from one that returns
    ///         malformed data, and neither reaches `abi.decode` unchecked.
    function _twapTick() private view returns (int24) {
        // Cardinality 1 means the ring holds only the current observation:
        // there is no history to average, so `observe` would answer with spot.
        (,,, uint16 cardinality,,,) = pool.slot0();
        if (cardinality < 2) revert TwapUnavailable();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (bool ok, bytes memory ret) = address(pool).staticcall(abi.encodeCall(IUniswapV3Pool.observe, (secondsAgos)));
        if (!ok) revert TwapUnavailable();
        (int56[] memory tickCumulatives,) = abi.decode(ret, (int56[], uint160[]));
        if (tickCumulatives.length != 2) revert TwapUnavailable();

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        // The quotient is a mean of two ticks, so it is bounded by the tick
        // range itself (±887272) and cannot overflow int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 avg = int24(delta / int56(uint56(twapWindow)));
        // Upstream `OracleLibrary` floors toward negative infinity; mirror it so
        // a re-centered range derived here matches an off-chain simulation.
        if (delta < 0 && (delta % int56(uint56(twapWindow)) != 0)) avg--;
        return avg;
    }

    /// @dev Reverts unless spot sits within `maxTwapDeviationBps` of the TWAP.
    ///      Compared in TICK space, not price space: a tick is a log of price,
    ///      so a bound on tick distance is a bound on the RATIO of the two
    ///      prices, which is what "deviation" means here. Doing it in price
    ///      space would need the exp this contract deliberately does not carry.
    function _requireSpotNearTwap() private view returns (int24 twap) {
        twap = _twapTick();
        (, int24 spot,,,,,) = pool.slot0();
        int24 diff = spot > twap ? spot - twap : twap - spot;
        // One tick is a factor of 1.0001, i.e. ~1 bps, so a bound expressed in
        // bps maps onto ticks one-for-one. The mapping is a FIRST-ORDER
        // approximation and drifts as the bound grows: at the
        // `MAX_TWAP_DEVIATION_BPS` ceiling of 1_000, `1.0001^1000 = 1.1052`, so
        // the check actually admits ~10.5% rather than exactly 10%. It errs
        // PERMISSIVE, never strict, which is why the ceiling is the real
        // control and this conversion is not asked to be exact. Computing the
        // exact bound needs the exp this contract deliberately does not carry
        // (design Decision 2).
        //
        // `diff` is non-negative by construction above, so the cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint256(uint24(diff)) > maxTwapDeviationBps) revert SpotOutsideTwapBound();
    }

    // ── Execute ──

    function _execute() internal override {
        _requireSpotNearTwap();

        // Pull, then post as collateral. The wrapper deposit happens here rather
        // than at init because init moves no funds.
        _pullFromVault(asset, collateralAmount);
        uint256 posted = _postCollateral(collateralAmount);

        morpho.borrow(_marketParams, borrowAmount, 0, address(this), address(this));

        (uint256 tid, uint128 liquidity) = _mintPosition(tickLower, tickUpper, swapFractionBps, mintSlippageBps);
        tokenId = tid;

        // Post-execute invariants, asserted in-contract because they are cheap
        // here and expensive to reconstruct after the fact.
        _requireWithinPoolShare(pool, liquidity);

        emit PositionOpened(address(pool), tid, tickLower, tickUpper, liquidity, borrowAmount, posted);
    }

    /// @dev Returns the collateral amount actually posted, in collateral-token
    ///      units — equal to the pulled amount when the market takes the vault
    ///      asset directly, and the ERC-4626 shares received when it does not.
    function _postCollateral(uint256 amount) private returns (uint256 posted) {
        address collateralToken = _marketParams.collateralToken;
        if (collateralToken == asset) {
            posted = amount;
        } else {
            IERC20(asset).forceApprove(collateralToken, amount);
            posted = IERC4626(collateralToken).deposit(amount, address(this));
        }
        IERC20(collateralToken).forceApprove(address(morpho), posted);
        morpho.supplyCollateral(_marketParams, posted, address(this), "");
    }

    /// @dev Converts `swapFraction` of `assetAmount` into the other token, then
    ///      mints one position over `[lower, upper]`.
    ///
    ///      THE SPLIT IS THE AGENT'S NUMBER, NOT A DERIVED ONE. Sizing the two
    ///      legs of a range exactly needs `sqrtRatioAtTick` for both bounds; the
    ///      design rejects carrying that math on-chain, and the agent has
    ///      already computed the ratio precisely off-chain. What bounds a wrong
    ///      split is the mint floor below, not a recomputation.
    /// @dev Move the held balances to `targetOtherBps` of TOTAL value in the
    ///      other token, swapping only the difference in whichever direction it
    ///      is needed.
    ///
    ///      MEASURES WHAT IS HELD, RATHER THAN ASSUMING IT IS ALL VAULT ASSET.
    ///      This is the difference between a rerange that preserves the position
    ///      and one that decays it. At execute the clone holds only the borrowed
    ///      vault asset, so "swap `targetOtherBps` of the asset" and "move to
    ///      `targetOtherBps` of total" coincide. At RERANGE they do not: the
    ///      close returns BOTH legs, so swapping a further fraction of the asset
    ///      side ratchets the position further into `otherToken` every single
    ///      time. The ratio drifts, the mint consumes less of the offered
    ///      balances, and liquidity falls on every rerange even when the swap
    ///      itself is free — a permissionless caller could then bleed the
    ///      position through the drift alone, which is exactly the griefing the
    ///      rerange cap is supposed to bound. Valuing the held `otherToken`
    ///      through the adapter and swapping only the delta removes the drift at
    ///      its source rather than capping its consequences.
    ///
    ///      Fails closed on an unavailable quote, like the mint it feeds.
    function _rebalanceToTarget(uint256 targetOtherBps, uint256 slippageBps) private {
        uint256 assetBal = IERC20(asset).balanceOf(address(this));
        uint256 otherBal = IERC20(otherToken).balanceOf(address(this));

        uint256 otherValue;
        if (otherBal != 0) {
            try swapAdapter.quote(otherToken, asset, otherBal, swapExtraData) returns (uint256 v) {
                if (v == 0) revert QuoteUnavailable();
                otherValue = v;
            } catch {
                revert QuoteUnavailable();
            }
        }

        uint256 total = assetBal + otherValue;
        if (total == 0) return;
        uint256 targetOtherValue = (total * targetOtherBps) / BPS_DENOMINATOR;

        if (targetOtherValue > otherValue) {
            uint256 toSwap = targetOtherValue - otherValue; // asset units
            if (toSwap > assetBal) toSwap = assetBal;
            if (toSwap == 0) return;
            uint256 minOut = _quoteMinOut(asset, otherToken, toSwap, slippageBps);
            IERC20(asset).forceApprove(address(swapAdapter), toSwap);
            swapAdapter.swap(asset, otherToken, toSwap, minOut, swapExtraData);
        } else {
            uint256 excessValue = otherValue - targetOtherValue; // asset units
            // Convert the excess back into `otherToken` units proportionally —
            // `otherValue` is the adapter's price for exactly `otherBal`, so the
            // ratio is the conversion and no separate price read is needed.
            uint256 toSwap = (otherBal * excessValue) / otherValue;
            if (toSwap == 0) return;
            uint256 minOut = _quoteMinOut(otherToken, asset, toSwap, slippageBps);
            IERC20(otherToken).forceApprove(address(swapAdapter), toSwap);
            swapAdapter.swap(otherToken, asset, toSwap, minOut, swapExtraData);
        }
    }

    function _mintPosition(int24 lower, int24 upper, uint256 targetOtherBps, uint256 slippageBps)
        private
        returns (uint256 tid, uint128 liquidity)
    {
        _rebalanceToTarget(targetOtherBps, slippageBps);

        uint256 assetBal = IERC20(asset).balanceOf(address(this));
        uint256 otherBal = IERC20(otherToken).balanceOf(address(this));

        IERC20(asset).forceApprove(address(positionManager), assetBal);
        IERC20(otherToken).forceApprove(address(positionManager), otherBal);

        (uint256 amount0Desired, uint256 amount1Desired) = assetIsToken0 ? (assetBal, otherBal) : (otherBal, assetBal);

        uint256 floor = BPS_DENOMINATOR - slippageBps;
        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: assetIsToken0 ? asset : otherToken,
            token1: assetIsToken0 ? otherToken : asset,
            fee: pool.fee(),
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: (amount0Desired * floor) / BPS_DENOMINATOR,
            amount1Min: (amount1Desired * floor) / BPS_DENOMINATOR,
            recipient: address(this),
            deadline: block.timestamp
        });

        (tid, liquidity,,) = positionManager.mint(mp);
    }

    // ── Rerange ──

    /// @notice The range a `rerange()` right now would produce.
    /// @dev    `public view` on purpose: a caller can simulate the exact result
    ///         before sending, and a test can prove the derivation and the mint
    ///         agree. No caller, including the proposer, gets to choose this —
    ///         the only thing a caller influences is WHEN, which conditions
    ///         (2)–(4) in `rerange()` already bound.
    function derivedRange() public view returns (int24 newLower, int24 newUpper) {
        return _derivedRange(_twapTick());
    }

    function _derivedRange(int24 center) private view returns (int24 newLower, int24 newUpper) {
        int24 spacing = tickSpacing;
        int24 half = _rerange.halfWidthTicks;
        newLower = _snapDown(center - half, spacing);
        newUpper = _snapUp(center + half, spacing);
        // `halfWidthTicks >= spacing` at init guarantees the snapped range is
        // non-empty, so this cannot produce `lower == upper`.
    }

    /// @dev Floor division toward negative infinity — Solidity's `/` truncates
    ///      toward zero, which would snap a negative tick the WRONG way and
    ///      produce a range whose derivation an off-chain simulation could not
    ///      reproduce.
    function _snapDown(int24 tick, int24 spacing) private pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q--;
        return q * spacing;
    }

    function _snapUp(int24 tick, int24 spacing) private pure returns (int24) {
        int24 q = tick / spacing;
        if (tick > 0 && tick % spacing != 0) q++;
        return q * spacing;
    }

    /// @notice Re-center the position on the current TWAP tick.
    /// @dev    PERMISSIONLESS BY CONSTRUCTION, NOT BY OVERSIGHT. The resulting
    ///         range is fully determined by the approved policy plus live chain
    ///         state, so there is no discretion left to gate. It moves no vault
    ///         funds — it burns and re-mints this clone's own position — which
    ///         is what keeps it callable by a keeper directly rather than only
    ///         through a governor batch.
    ///
    ///         Adversary: a caller who reranges repeatedly to bleed the position
    ///         through swap cost and realized divergence loss, or who times a
    ///         permitted rerange to follow an unfavorable tick move. Conditions
    ///         (2)–(4) bound the first to `maxReranges × (swap cost + slippage
    ///         floor)`. The second is bounded, NOT eliminated — an accepted
    ///         residual, recorded here so a later reader does not mistake it for
    ///         an oversight.
    function rerange() external returns (uint256 newTokenId) {
        // (1) Executed.
        if (_state != State.Executed) revert NotExecutedForRerange();
        // (3) The minimum interval has elapsed since execute or the last rerange.
        if (block.timestamp < lastRerangeAt + _rerange.minInterval) revert RerangeTooSoon();
        // (4) The count is below the approved maximum.
        if (rerangeCount >= _rerange.maxReranges) revert RerangeCapReached();
        // (5) Spot is within the same TWAP bound `execute()` enforces — a
        //     rerange must not become a manipulated re-mint that execute would
        //     have refused.
        int24 twap = _requireSpotNearTwap();
        // (2) Price has reached the approved trigger fraction of the range.
        _requireTriggerReached(twap);

        int24 oldLower = tickLower;
        int24 oldUpper = tickUpper;
        uint256 oldTokenId = tokenId;

        (uint128 liquidityBefore,) = _positionLiquidity(oldTokenId);
        _closePosition(oldTokenId);

        (int24 newLower, int24 newUpper) = _derivedRange(twap);

        // Everything freed by the close is redeployed — both legs, which is why
        // the re-mint rebalances from measured balances rather than assuming it
        // holds only the vault asset (see `_rebalanceToTarget`). The borrow and
        // the collateral are untouched by construction: no Morpho call appears
        // anywhere in this path.
        (uint256 tid, uint128 liquidityAfter) =
            _mintPosition(newLower, newUpper, _rerange.swapFractionBps, _rerange.slippageBps);

        tokenId = tid;
        tickLower = newLower;
        tickUpper = newUpper;
        lastRerangeAt = block.timestamp;
        unchecked {
            rerangeCount++;
        }

        emit PositionReranged(
            rerangeCount, oldTokenId, tid, oldLower, oldUpper, newLower, newUpper, twap, liquidityBefore, liquidityAfter
        );
        return tid;
    }

    /// @dev Price must have travelled `triggerBps` of the way from the range's
    ///      midpoint to whichever boundary it is approaching.
    function _requireTriggerReached(int24 twap) private view {
        int24 lower = tickLower;
        int24 upper = tickUpper;
        int24 mid = (lower + upper) / 2;
        int24 halfRange = (upper - lower) / 2;
        int24 travelled = twap > mid ? twap - mid : mid - twap;
        // Both are non-negative by construction: `halfRange` because the range
        // is ordered and non-empty (checked at init and preserved by every
        // rerange), `travelled` because it is an absolute difference.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 threshold = (uint256(uint24(halfRange)) * _rerange.triggerBps) / BPS_DENOMINATOR;
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint256(uint24(travelled)) < threshold) revert RerangeTriggerNotReached();
    }

    function _positionLiquidity(uint256 tid) private view returns (uint128 liquidity, bool exists) {
        if (tid == 0) return (0, false);
        (,,,,,,, uint128 l,,,,) = positionManager.positions(tid);
        return (l, true);
    }

    /// @dev Decrease to zero, then collect. `decreaseLiquidity` only moves the
    ///      principal into the position's OWED balances — `collect` is what
    ///      actually pays out, which is why both are required and in this order.
    function _closePosition(uint256 tid) private {
        (uint128 liquidity, bool exists) = _positionLiquidity(tid);
        if (!exists) return;
        if (liquidity != 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tid,
                    liquidity: liquidity,
                    // Floors are deliberately zero on the WITHDRAWAL leg: a
                    // decrease returns the position's own principal at the
                    // current tick and there is no counterparty to be
                    // sandwiched by. A non-zero floor here would hand a griefer
                    // a way to block settlement by nudging the tick.
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: _deadline()
                })
            );
        }
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tid, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        positionManager.burn(tid);
    }

    // ── Settle ──

    /// @dev ORDER IS LOAD-BEARING: unwind → collect → convert → repay →
    ///      withdraw collateral → push. Adversary: an ordering that withdraws
    ///      collateral first, leaving an outstanding borrow collateralized by
    ///      nothing and the position exposed to liquidation during its own
    ///      settlement. Morpho enforces the same thing from its side, so a
    ///      wrong order here reverts rather than mis-settling — but reverting
    ///      IS the failure this contract is built to avoid.
    ///
    ///      DELIVERABLE-MAXIMUM, NOT ALL-OR-REVERT (the `MorphoSupplyStrategy`
    ///      argument, applied unchanged). Reverting on any shortfall hands
    ///      whoever can create that shortfall a veto over the vault's whole
    ///      settlement path, freezing redemptions vault-wide for as long as they
    ///      sustain it. So settle takes what it can, emits loudly, and leaves
    ///      the residue recoverable through `sweep()`. The residue costs THIS
    ///      proposal, because the governor measures PnL from realized float —
    ///      deliberate: a proposer who parks the vault in a venue that cannot
    ///      pay out at settlement should wear the mark.
    function _settle() internal override {
        _closePosition(tokenId);
        tokenId = 0;

        _trySwapToAsset(settleSlippageBps);

        (uint256 debtRemaining, uint256 collateralRemaining) = _repayAndWithdraw();
        if (debtRemaining != 0 || collateralRemaining != 0) {
            emit SettlementIncomplete(debtRemaining, collateralRemaining);
        }

        _pushAllToVault(asset);
    }

    /// @dev Converts the whole `otherToken` balance back to the vault asset.
    ///      Fee income accrues in BOTH tokens, so this is what brings the
    ///      non-vault-asset half of the fees into the amount the vault receives.
    ///      Reuses the proposer's configured adapter rather than opening a
    ///      second swap path.
    /// @dev DEGRADES, unlike the mint-side swap. The asymmetry is deliberate and
    ///      is the same argument as the deliverable-maximum repay below: settle
    ///      is the vault's only exit, so anything that can revert here is a veto
    ///      over vault-wide redemption. An adapter that cannot quote leaves the
    ///      `otherToken` unconverted and the residue recoverable by `sweep()`,
    ///      which costs this proposal — strictly better than freezing the vault.
    ///      The swap is NEVER attempted without a floor; it is skipped instead.
    function _trySwapToAsset(uint256 slippageBps) private {
        uint256 bal = IERC20(otherToken).balanceOf(address(this));
        if (bal == 0) return;

        uint256 minOut;
        try swapAdapter.quote(otherToken, asset, bal, swapExtraData) returns (uint256 expected) {
            if (expected == 0) return;
            minOut = (expected * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
        } catch {
            return;
        }

        IERC20(otherToken).forceApprove(address(swapAdapter), bal);
        // The swap itself is also allowed to fail: a quote that stood a moment
        // ago can be gone by the time the swap lands, and that must not revert
        // settlement either.
        (bool ok,) = address(swapAdapter)
            .call(abi.encodeCall(ISwapAdapter.swap, (otherToken, asset, bal, minOut, swapExtraData)));
        if (!ok) IERC20(otherToken).forceApprove(address(swapAdapter), 0);
    }

    /// @dev Repays by SHARES when the position can afford the whole debt, and by
    ///      ASSETS only when taking the deliverable maximum. Shares-mode is what
    ///      clears the debt EXACTLY — a single dust share left behind blocks
    ///      `withdrawCollateral` entirely, which would turn a full settlement
    ///      into a stranded one.
    function _repayAndWithdraw() private returns (uint256 debtRemaining, uint256 collateralRemaining) {
        morpho.accrueInterest(_marketParams);

        uint128 borrowShares = morpho.position(marketId, address(this)).borrowShares;
        uint128 collateral = morpho.position(marketId, address(this)).collateral;

        if (borrowShares != 0) {
            Market memory m = morpho.market(marketId);
            uint256 owed = _sharesToAssetsUp(borrowShares, m.totalBorrowAssets, m.totalBorrowShares);
            uint256 held = IERC20(asset).balanceOf(address(this));

            if (held >= owed) {
                IERC20(asset).forceApprove(address(morpho), owed);
                morpho.repay(_marketParams, 0, borrowShares, address(this), "");
            } else if (held != 0) {
                IERC20(asset).forceApprove(address(morpho), held);
                morpho.repay(_marketParams, held, 0, address(this), "");
            }
        }

        borrowShares = morpho.position(marketId, address(this)).borrowShares;
        if (borrowShares == 0) {
            collateral = morpho.position(marketId, address(this)).collateral;
            if (collateral != 0) {
                _tryWithdrawCollateral(collateral);
            }
        }

        // Re-read rather than reasoning from the branch taken: a partial repay
        // that rounded, or a capped withdrawal, must be reported as it actually
        // landed and not as it was intended.
        borrowShares = morpho.position(marketId, address(this)).borrowShares;
        collateral = morpho.position(marketId, address(this)).collateral;
        if (borrowShares != 0) {
            Market memory m2 = morpho.market(marketId);
            debtRemaining = _sharesToAssetsUp(borrowShares, m2.totalBorrowAssets, m2.totalBorrowShares);
        }
        collateralRemaining = collateral;
    }

    /// @dev Degrades rather than reverting. A collateral withdrawal can fail for
    ///      reasons outside this proposal's control; taking the shortfall as an
    ///      incomplete settlement keeps the vault's redemption path open, and
    ///      `sweep()` recovers it once the condition clears.
    function _tryWithdrawCollateral(uint128 amount) private {
        (bool ok,) = address(morpho)
            .call(abi.encodeCall(IMorpho.withdrawCollateral, (_marketParams, amount, address(this), address(this))));
        if (!ok) return;
        address collateralToken = _marketParams.collateralToken;
        if (collateralToken != asset) {
            uint256 shares = IERC20(collateralToken).balanceOf(address(this));
            if (shares != 0) IERC4626(collateralToken).redeem(shares, address(this), address(this));
        }
    }

    function _sharesToAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        private
        pure
        returns (uint256)
    {
        // Mirrors `SharesMathLib.toAssetsUp` including the virtual offsets, so a
        // value computed here and one computed by the singleton agree exactly.
        uint256 tA = totalAssets + 1;
        uint256 tS = totalShares + 1e6;
        return (shares * tA + (tS - 1)) / tS;
    }

    /// @notice Recover a residue left behind by an incomplete settlement.
    /// @dev    Permissionless and post-settlement only: it moves value in
    ///         exactly one direction — out of this strategy, into the vault it
    ///         was always owed to — so there is nothing to gate. Idempotent and
    ///         safe to call with nothing to move.
    function sweep() external returns (uint256 assets) {
        if (_state != State.Settled) revert NotSettled();

        _trySwapToAsset(settleSlippageBps);
        _repayAndWithdraw();

        assets = IERC20(asset).balanceOf(address(this));
        if (assets != 0) {
            _pushAllToVault(asset);
            emit ResidualSwept(assets);
        }
    }

    // ── Tunables ──

    /// @notice Decode: (uint256 settleSlippageBps, uint256 settleDeadline)
    /// @dev    ONLY risk-reducing parameters. The pool, the market, the sizes,
    ///         the active range and EVERY rerange-policy field are immutable
    ///         after initialization, and there is deliberately no encoding by
    ///         which this function can reach them.
    ///
    ///         Adversary: a proposer who, having had a position approved by
    ///         voters and guardians, mutates it after approval into a materially
    ///         different position the review never covered — including by
    ///         re-centering the band repeatedly until it sits somewhere the
    ///         review would not have approved. That is why the range is not
    ///         settable here even though `rerange()` changes it: `rerange()`
    ///         cannot be steered, and this could be.
    function _updateParams(bytes calldata data) internal override {
        (uint256 slippageBps, uint256 deadline) = abi.decode(data, (uint256, uint256));
        if (slippageBps > MAX_SLIPPAGE_BPS) revert InvalidBound();
        settleSlippageBps = slippageBps;
        settleDeadline = deadline;
    }
}
