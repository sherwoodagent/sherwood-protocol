// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IStrategyDelivery} from "../interfaces/IStrategyDelivery.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMorpho, Id, MarketParams, Market, Position} from "../vendor/morpho/IMorpho.sol";
import {MarketParamsLib, MorphoBalancesLib} from "../vendor/morpho/MorphoLibs.sol";
import {IUniswapV3Pool} from "../vendor/uniswap/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "../vendor/uniswap/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "../vendor/uniswap/INonfungiblePositionManager.sol";

/// @notice The `vault() -> governor() -> tierRegistry() -> isAdapterAllowed(x)`
///         walk. The SAME registry, reached the same way, that
///         `SyndicateVault._guardBatchCalls` gates batch approvals against.
/// @dev    Declared locally rather than imported, mirroring
///         `PortfolioStrategy.ITierBindingPath`: every hop is a length-checked
///         raw staticcall, so this template takes on no type dependency and no
///         hop can revert `_initialize` undecodably. Exists to generate
///         selectors, not to type the responses.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isAdapterAllowed(address adapter) external view returns (bool);
    function isCounterpartyAllowed(address counterparty) external view returns (bool);
}

/// @notice Morpho Blue's oracle surface: the collateral price quoted in
///         loan-token units, scaled by `ORACLE_PRICE_SCALE`.
/// @dev    Declared locally for the same reason as `ITierBindingPath`, and read
///         the same way — a length-checked raw staticcall. The oracle address
///         is a member of the proposer-supplied `MarketParams`, so a typed call
///         would let whoever controls it revert this frame undecodably and veto
///         settlement. Exists to generate a selector, not to type the response.
interface IMorphoOracle {
    function price() external view returns (uint256);
}

/// @dev Morpho Blue's fixed oracle price scale (`1e36`).
uint256 constant ORACLE_PRICE_SCALE = 1e36;

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
contract ConcentratedLiquidityStrategy is BaseStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    // ── Constants ──

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Uniswap V3 fee scale: `fee()` is in hundredths of a bip, so
    ///         1e6 is 100% and the 500 / 3_000 / 10_000 tiers are 0.05% / 0.3%
    ///         / 1%. Distinct from `BPS_DENOMINATOR` on purpose — conflating
    ///         the two would misprice `_poolAnchoredMinOut`'s fee haircut by
    ///         two orders of magnitude.
    uint256 public constant FEE_DENOMINATOR = 1e6;

    /// @notice Uniswap V3's tick domain. Mirrored here rather than imported so
    ///         `_derivedRange` can clamp without pulling in `TickMath`.
    int24 public constant MIN_TICK = -887_272;
    int24 public constant MAX_TICK = 887_272;

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
    ///
    ///         MEASURED AGAINST THE VENUE AS IT WAS BEFORE THIS POSITION JOINED
    ///         IT. `_execute` snapshots `pool.liquidity()` before it touches the
    ///         pool and checks the minted liquidity against that snapshot.
    ///         Reading it back AFTER the mint would count this position in its
    ///         own denominator and silently loosen the cap from 10% to
    ///         `L <= (P+L)/10`, i.e. ~11.1% of the venue actually joined.
    ///
    ///         KNOWN LIMITATION: `pool.liquidity()` is the liquidity active at
    ///         the CURRENT tick, not the pool's total. A band that does not
    ///         straddle spot is therefore sized against the depth at spot rather
    ///         than the depth it will itself occupy. That errs strict for an
    ///         out-of-range band on a thin current tick and permissive for the
    ///         reverse; sizing exactly needs per-tick liquidity this contract
    ///         deliberately does not walk (design Decision 2).
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
    ///
    ///         THE CAP, NOT `minInterval`, IS THE BINDING CONTROL. That bound is
    ///         a total, not a rate, so it holds whatever the interval is — a
    ///         policy may set `minInterval` to zero and spend the whole budget
    ///         in one block without exceeding what the voter priced.
    uint256 public constant MAX_RERANGE_LIMIT = 20;

    /// @notice Ceiling on the configured rerange half-width.
    /// @dev    A half-width wider than the tick domain itself cannot describe a
    ///         band any voter meant to approve, and letting one through would
    ///         make `_derivedRange` silently clamp to full-range — a materially
    ///         different position from the one reviewed. Rejected at init so the
    ///         clamp in `_derivedRange` only ever handles the edge case of a
    ///         legitimate band running off the domain near an extreme tick.
    int24 public constant MAX_HALF_WIDTH_TICKS = MAX_TICK;

    // ── Errors ──

    error InvalidAmount();
    /// @notice The configured pool does not quote the vault asset. Adversary: a
    ///         proposer naming a pool whose position could not be unwound into
    ///         the asset the vault redeems in.
    error PoolAssetMismatch();
    /// @notice The allowlisted factory does not name `pool` as the canonical
    ///         pool for `pool`'s own `(token0, token1, fee)` key — including
    ///         when the factory cannot be read at all, which vouches for
    ///         nothing. Adversary: a contract that answers every
    ///         `IUniswapV3Pool` selector with attacker-chosen values —
    ///         token0/token1 that pass the asset check, a `liquidity()` large
    ///         enough to clear the pool-share cap, an `observe` whose TWAP
    ///         always equals its own spot, and a `factory()` naming whichever
    ///         address makes the check pass.
    ///         Also raised when `pool` itself holds no code: the key the factory
    ///         is asked about is read off the pool with typed calls, and an
    ///         address that cannot be asked what pair it trades was never a pool
    ///         the factory created.
    /// @dev    Deliberately does NOT read `pool.factory()`. That answer comes
    ///         from the party being checked; see check (1) in `_initialize` for
    ///         why asking the factory is the only direction that establishes
    ///         anything.
    error PoolNotFromFactory();
    /// @notice A proposer-supplied counterparty is not allowlisted in the
    ///         `TierRegistry` the vault's own governor gates batch approvals
    ///         against. Covers `swapAdapter`, `positionManager`, `morpho`,
    ///         `marketParams.collateralToken`, `uniswapFactory` and the pool's
    ///         volatile leg (`otherToken`) — every address this contract
    ///         approves or calls with vault funds, plus the factory whose word
    ///         the pool's provenance rests on.
    error CounterpartyNotAllowed(address counterparty, address registry);
    /// @notice The `vault() -> governor() -> tierRegistry()` walk yielded no
    ///         registry, so no counterparty can be vouched for. Fails closed at
    ///         binding time rather than deploying capital through unvetted
    ///         addresses.
    error TierRegistryUnresolved();
    /// @notice The lending market's loan token is not the vault asset.
    error LoanAssetMismatch();
    /// @notice The market's collateral token is neither the vault asset nor an
    ///         ERC-4626 wrapper of it. Adversary: a proposer collateralizing the
    ///         volatile leg, which is both unexecutable at size on this chain
    ///         (every tokenized-equity market measured held $0–$1.6k lendable)
    ///         and would give the position a second liquidation surface
    ///         correlated with the LP's own divergence loss.
    error CollateralAssetMismatch();
    /// @notice The collateral's value in vault-asset terms could not be read
    ///         from the collateral token itself. Adversary: a proposer supplying
    ///         the valuation the LTV gate divides by. The gate below is the only
    ///         on-chain control over liquidation risk, so the number it divides
    ///         by must come from the chain, never from init data — an
    ///         attacker-chosen collateral value clears the buffer check
    ///         unconditionally and the control stops existing.
    error CollateralValueUnavailable();
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
    /// @notice A parameter update tried to change something the review approved
    ///         — including loosening a bound in the risk-INCREASING direction,
    ///         which is the same thing by another route.
    error ImmutableParam();
    /// @notice `sweep()` is the post-settlement recovery path only.
    error NotSettled();
    /// @notice `unwindPosition()` is an internal step exposed only so the
    ///         settlement path can `try/catch` it; nobody else may call it.
    error NotSelf();
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

    /// @notice A residue left the clone WITHOUT being converted to the vault
    ///         asset. Distinct from `ResidualSwept` on purpose: this is not
    ///         proceeds, it is an unpriced token the vault owner must deal with.
    event UnconvertibleReleased(address indexed token, uint256 amount);

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

        // (0) GOVERNANCE BINDING — must run BEFORE any of the checks below,
        //     because every one of them resolves through an address the
        //     proposer chose. `getPool` asks a factory which pool it created;
        //     `market(id).lastUpdate` asks a Morpho whether a market exists;
        //     `_isWrapperOf` asks a token what it wraps. Bind the address first
        //     and each of those is a question put to something the protocol
        //     vouched for; bind nothing and each is self-consistent by
        //     construction. Finding #4 was that exact failure — the pool's
        //     provenance was settled by comparing two values the proposer
        //     supplied — so `uniswapFactory` is bound here too.
        //
        //     The vault's batch guard cannot substitute. `_guardBatchCalls`
        //     PART 2a checks the CLONE is an allowlisted callee; the approvals
        //     that actually move money — `forceApprove(collateralToken)` in
        //     `_postCollateral`, `forceApprove(swapAdapter)` in
        //     `_rebalanceToTarget` — are issued INSIDE this contract, one hop
        //     past anything the governor batch names.
        //
        //     FAIL CLOSED on an unresolvable registry, matching
        //     `PortfolioStrategy._initialize`. Binding time is the cheap place
        //     to refuse: it costs a re-proposal, where discovering it at
        //     execute costs the deployed capital. No hop is proposer input, so
        //     the proposer cannot steer the walk into the skip.
        //
        //     TWO AXES, BECAUSE THEY ARE TWO QUESTIONS. `isAdapterAllowed` is
        //     the predicate `SyndicateVault._guardBatchCalls` uses to decide
        //     which addresses a governor batch may call directly, approve as a
        //     spender, and transfer to — and `setAdapterAllowed`'s own contract
        //     says exotic-asset contracts, naming LP-position NFTs, MUST NOT be
        //     listed on it. A Uniswap position manager is exactly one, so
        //     binding everything through that axis would have made running this
        //     template require the entry the axis forbids, and would have
        //     widened the batch guard for Morpho and the position manager as a
        //     side effect of a decision about a strategy.
        //
        //     CORRECTION (PR #217 review). An earlier version of this note said
        //     the swap adapter is "the one address here that receives
        //     `forceApprove` of this strategy's balances". THAT IS FALSE and
        //     nothing should be reasoned from it: `_postCollateral` approves the
        //     collateral token and then Morpho, `_mintPosition` approves the
        //     position manager on both legs, and `_repayAndWithdraw` approves
        //     Morpho again. ALL FOUR bound addresses receive approvals of clone
        //     balances. The split is not "who touches funds".
        //
        //     THE ACTUAL LINE IS WHOSE CALLDATA. Every `isAdapterAllowed` read
        //     in `SyndicateVault` sits inside `_guardBatchCalls`, iterating the
        //     governor batch's own `calls[]` — it answers "may a PROPOSER-
        //     AUTHORED batch name this address as a callee, an approve spender
        //     or a transfer recipient". Nothing in the vault gates what a
        //     strategy clone does with capital already delegated to it; that is
        //     governed by the template's own code, which is itself certified
        //     and allowlisted before any batch can reach it.
        //
        //     So `isCounterpartyAllowed` grants "a certified template may bind
        //     and approve this address from inside its own reviewed code path",
        //     and withholds "arbitrary batch calldata may name it". Those are
        //     different capabilities over different calldata, which is what
        //     makes the weaker grant meaningful — not any claim that a
        //     counterparty never sees funds.
        //
        //     The swap adapter stays on the strong axis anyway, for a reason
        //     that survives the correction: `PortfolioStrategy` binds its own
        //     adapter through `isAdapterAllowed`, and a swap adapter is exactly
        //     the kind of address a batch legitimately names. Keeping the two
        //     templates asking the same question of the same role is worth more
        //     than the one entry it costs. Adapter standing implies counterparty
        //     standing, so a registry configured before this axis existed keeps
        //     working unchanged.
        //
        //     THE VAULT ASSET IS EXEMPT, mirroring `_guardBatchCalls`' own
        //     `target != asset_` carve-out. `collateralToken == vaultAsset` is
        //     an explicitly supported configuration (see check (2) and
        //     `_collateralValue`), and the vault's own guard treats its asset as
        //     needing no allowlist entry — so requiring one here would refuse a
        //     legitimate market on a registry that is configured exactly right.
        //     The exemption is safe on its own terms: the address is read from
        //     the vault, not from `p`, so a proposer cannot name it into the
        //     skip. `swapAdapter`, `positionManager` and `morpho` get no such
        //     exemption; they are never the asset.
        //     NOT ALL OF THEM ARE BOUND HERE. `otherToken` is a counterparty by
        //     the same rule as the rest, but its address is not known until the
        //     pool has been proven and read, so it is bound at the end of check
        //     (1). `registry` is hoisted out of this block for that.
        address registry = _resolveTierRegistry();
        if (registry == address(0)) revert TierRegistryUnresolved();
        {
            // Strong axis for the swap adapter, matching `PortfolioStrategy`'s
            // binding of the same role; weak axis for the rest, which adapter
            // standing implies. All four receive approvals — see the note above
            // for why that is not what separates them.
            _requireAllowedAdapter(registry, p.swapAdapter);
            _requireAllowedCounterparty(registry, p.positionManager);
            _requireAllowedCounterparty(registry, p.morpho);
            // The factory is the authority check (1) delegates the pool's
            // provenance to, so it has to be an authority the PROTOCOL chose. A
            // proposer-authored factory vouching for a proposer-authored pool is
            // the same self-attestation one hop further out.
            _requireAllowedCounterparty(registry, p.uniswapFactory);
            if (p.marketParams.collateralToken != vaultAsset) {
                _requireAllowedCounterparty(registry, p.marketParams.collateralToken);
            }
        }

        // (1) The pool is the one the FACTORY created for its own key, and one
        //     of its two tokens is the vault asset. Provenance comes first:
        //     without it every other read below is attacker-chosen, because a
        //     contract can answer all of these selectors.
        //
        //     THE FACTORY IS ASKED, NOT THE POOL (pashov 2026-08 finding #4).
        //     This check used to read `pool_.factory() != p.uniswapFactory`,
        //     which established nothing — both operands came from the same
        //     proposer, and `p.uniswapFactory` was otherwise unused, so an
        //     impostor answering the whole `IUniswapV3Pool` surface simply
        //     named itself a factory and passed. Binding `p.uniswapFactory` to
        //     the registry, which (0) now does, is necessary but NOT sufficient
        //     on its own: an impostor is equally free to report the genuine
        //     factory's address, and the comparison still succeeds. The
        //     direction is what was wrong. Only the factory can say which pool
        //     is canonical for a key, and no contract can make the real factory
        //     point at it.
        //
        //     An earlier note here argued against `getPool` on the grounds that
        //     self-reporting "cannot be forged by a third party deploying a
        //     real pool for a fake token pair". THAT REASONING DOES NOT HOLD
        //     and nothing should be built on it: a genuinely factory-created
        //     pool over a worthless second token reports the real factory too,
        //     so it clears both formulations identically. The two differ only
        //     on the impostor, which self-reporting admits and this rejects.
        //     What that note was reaching for is a real gap, and provenance is
        //     genuinely not the control for it: a proposer may create a real
        //     pool of the vault asset against a token it controls, and every
        //     provenance check passes because every one of them is true. That
        //     is closed SEPARATELY, by binding `otherToken` below — do not read
        //     THIS check as covering it.
        //
        //     `p.pool` is non-zero (checked above) and the read is length-
        //     checked, so a factory that cannot answer — no code, revert, short
        //     return — resolves to `address(0)`, fails the comparison, and
        //     reverts with THIS contract's error rather than undecodably inside
        //     a typed call.
        //
        //     BOTH SIDES GET THAT TREATMENT. The pool is read with TYPED calls
        //     (`token0`/`token1`/`fee`) before the factory is asked, because
        //     they only build the lookup key — but a typed call to an address
        //     with no code reverts in THIS frame with empty returndata, which is
        //     indistinguishable from a bug in the guard. So codelessness is
        //     rejected here, up front, with the same error the provenance
        //     comparison raises: an address that cannot be asked what pair it
        //     trades was never a pool the factory created.
        if (p.pool.code.length == 0) revert PoolNotFromFactory();
        IUniswapV3Pool pool_ = IUniswapV3Pool(p.pool);

        address t0 = pool_.token0();
        address t1 = pool_.token1();
        {
            bytes memory call_ = abi.encodeCall(IUniswapV3Factory.getPool, (t0, t1, pool_.fee()));
            if (_readAddress(p.uniswapFactory, call_) != p.pool) revert PoolNotFromFactory();
        }
        if (t0 == vaultAsset) {
            assetIsToken0 = true;
            otherToken = t1;
        } else if (t1 == vaultAsset) {
            assetIsToken0 = false;
            otherToken = t0;
        } else {
            revert PoolAssetMismatch();
        }

        //     THE VOLATILE LEG IS A COUNTERPARTY (pashov 2026-08, the gap named
        //     in the provenance note above). Provenance proves where the pool
        //     came from; it says nothing about what the pool TRADES. Without
        //     this, a proposer deploys a worthless ERC-20, creates a genuine
        //     `(vaultAsset, junk)` pool through the real factory, initialises
        //     it at a price of their choosing, and every check above passes on
        //     the merits. `_rebalanceToTarget` then buys that token with vault
        //     asset, and BOTH slippage floors are derived from that same
        //     attacker-priced venue — the anchor from the pool's own `slot0`,
        //     the quote from the only venue that quotes the pair — so they
        //     agree with each other and with nothing real.
        //
        //     It belongs on this axis by the rule the axis already states:
        //     every address this contract approves or calls with vault funds.
        //     `_mintPosition` force-approves it to the position manager,
        //     `_rebalanceToTarget` and `_convertOtherToAsset` approve it to the
        //     swap adapter, and `rerange()`'s own natspec already calls it "any
        //     ERC-20 for which a real pool exists, so a transfer hook is a live
        //     possibility". It was the one such address left unbound.
        //
        //     NO VAULT-ASSET EXEMPTION IS NEEDED, unlike `collateralToken`:
        //     `otherToken` is by construction the token that is NOT the vault
        //     asset — the branch above assigns it from whichever side failed to
        //     match — so the carve-out could never apply.
        _requireAllowedCounterparty(registry, otherToken);

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
            uint256 collateralValue = _collateralValueOf(p.marketParams.collateralToken, vaultAsset, p.collateralAmount);
            uint256 ltvBps = (p.borrowAmount * BPS_DENOMINATOR) / collateralValue;
            uint256 lltvBps = (p.marketParams.lltv * BPS_DENOMINATOR) / 1e18;
            if (lltvBps < MIN_LLTV_BUFFER_BPS) revert LtvInsideLiquidationBuffer();
            if (ltvBps > lltvBps - MIN_LLTV_BUFFER_BPS) revert LtvInsideLiquidationBuffer();
        }

        // (5) The position does not exceed the pool-share cap. This bounds the
        //     agent's CLAIM; `_execute` re-checks the liquidity actually minted
        //     against the venue as it stood before the mint, which is the
        //     enforceable version.
        _requireWithinPoolShare(pool_.liquidity(), p.expectedLiquidity);

        // (6) The tick range is ordered, non-empty, and spacing-aligned.
        int24 spacing = pool_.tickSpacing();
        _requireValidRange(p.tickLower, p.tickUpper, spacing);

        _requireValidBounds(p);
        _requireValidRerangePolicy(p.rerange, spacing, p.tickLower, p.tickUpper);

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
    ///
    ///      NOT SANDWICH PROTECTION ON ITS OWN, and it must not be described as
    ///      such: the quote is taken in the same transaction, through the same
    ///      `swapExtraData` route, as the swap it bounds, so a searcher who
    ///      moves that venue first gets a quote at the moved price and a floor
    ///      derived from it. `_poolAnchoredMinOut` is the answer to that; every
    ///      call site takes the MAX of the two.
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

    /// @dev Floor derived from the CONFIGURED POOL's own price, independent of
    ///      whatever venue `swapExtraData` routes through.
    ///
    ///      THE GAP THIS CLOSES (pashov 2026-08 finding #4). `swapExtraData` is
    ///      stored verbatim at `_initialize` and nothing ties it to `pool`: the
    ///      adapter may route a different fee tier, a V4 pool, or a multi-hop
    ///      path. `_requireSpotNearTwap` reads `pool.slot0()` — the LP venue —
    ///      so it never observed the venue the swap actually crossed, and
    ///      `_quoteMinOut` took both of its operands from that unobserved
    ///      venue. Every swap floor in this contract therefore moved with the
    ///      attacker, on a `rerange()` that is permissionless by design.
    ///
    ///      WHY sqrtPriceX96 AND NOT THE TWAP TICK. Converting a tick to a
    ///      price needs `TickMath.getSqrtRatioAtTick`, which this contract
    ///      deliberately does not vendor (see `_derivedRange`). `slot0()`
    ///      already returns `sqrtPriceX96` directly. So the anchor is a pool
    ///      price reached without new price math.
    ///
    ///      SPOT, AND THEREFORE ONLY AS SAFE AS ITS CALLER'S TWAP CHECK. The
    ///      minting sites (`_execute`, `rerange`) have already asserted spot
    ///      against the TWAP via `_requireSpotNearTwap()` and reverted
    ///      otherwise, so for them this is a TWAP-verified price. `_settle` and
    ///      `sweep` assert nothing, so `_trySwapToAsset` gates the call on
    ///      `_spotNearTwap()` itself — see the note there on why an unverified
    ///      spot used as a floor is a denial lever rather than a guard. Do NOT
    ///      add a call site without deciding which of the two it is.
    ///
    ///      NETTED OF THE POOL FEE. The value derived here is the pool's MID
    ///      price; `_quoteMinOut`'s operand is an adapter quote, which already
    ///      has the venue's fee and price impact taken out of it. Applying the
    ///      same `slippageBps` to both would silently redefine what that budget
    ///      has to cover — on the mid it would have to absorb the fee before it
    ///      absorbs any slippage at all, so a 0.3% tier would eat 30 bps of it
    ///      and a 1% tier 100, and every configuration sized against the old
    ///      quote-only floor would start reverting at `_rebalanceToTarget`
    ///      (which, unlike settle, does NOT degrade). Subtracting `pool.fee()`
    ///      first keeps `slippageBps` meaning the same thing it did before.
    ///      The routed venue may charge differently, so this is the configured
    ///      pool's fee as a proxy, not a claim about the route.
    ///
    ///      `price(token1 per token0) = sqrtPriceX96^2 / 2^192`, split into two
    ///      `mulDiv`s by 2^96 so the intermediate never overflows.
    ///      Decimals need no handling: `sqrtPriceX96` encodes the ratio of RAW
    ///      token amounts, so both legs' scales are already baked in.
    ///
    ///      Returns 0 when the pool price is unreadable or the result rounds to
    ///      nothing — the caller then falls back to the quote floor alone,
    ///      which is the pre-existing behaviour rather than a new brick.
    function _poolAnchoredMinOut(address tokenIn, uint256 amountIn, uint256 slippageBps)
        private
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (sqrtPriceX96 == 0) return 0;

        uint256 sp = uint256(sqrtPriceX96);
        uint256 expected;
        // token0 -> token1 multiplies by the price; token1 -> token0 divides.
        if (tokenIn == (assetIsToken0 ? asset : otherToken)) {
            expected = Math.mulDiv(Math.mulDiv(amountIn, sp, 1 << 96), sp, 1 << 96);
        } else {
            expected = Math.mulDiv(Math.mulDiv(amountIn, 1 << 96, sp), 1 << 96, sp);
        }
        if (expected == 0) return 0;
        // Fee first, slippage second — see the NatSpec. `pool.fee()` is in
        // hundredths of a bip (1e6 = 100%), and Uniswap V3 caps it far below
        // that, so the subtraction cannot underflow.
        expected = (expected * (FEE_DENOMINATOR - uint256(pool.fee()))) / FEE_DENOMINATOR;
        if (expected == 0) return 0;
        return (expected * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
    }

    /// @dev `max(quote floor, pool-anchored floor)`. The quote floor alone is
    ///      defeated by moving the routed venue; the pool floor alone would be
    ///      defeated by a routed venue that is legitimately cheaper than the LP
    ///      pool. Taking the max means an attacker must beat BOTH, and a
    ///      mis-scaled or unreadable pool read can only ever raise the bar.
    function _floorFor(address tokenIn, address tokenOut, uint256 amountIn, uint256 slippageBps)
        private
        returns (uint256 minOut)
    {
        minOut = _quoteMinOut(tokenIn, tokenOut, amountIn, slippageBps);
        uint256 anchored = _poolAnchoredMinOut(tokenIn, amountIn, slippageBps);
        if (anchored > minOut) minOut = anchored;
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

    // ── Governance-allowlist binding (see check (0) in `_initialize`) ──

    /// @dev Reverts unless `adapter` carries ADAPTER standing in `registry` —
    ///      the strong grant, which additionally licenses appearing in
    ///      proposer-authored governor-batch calldata.
    ///
    ///      For the swap adapter only, and NOT because it is the only address
    ///      here that receives approvals — every bound address does; see the
    ///      correction in check (0). It is because `PortfolioStrategy` binds the
    ///      same role through the same predicate, and keeping two templates
    ///      asking one question of one role is worth the extra registry entry.
    ///
    ///      Mirrors `PortfolioStrategy._requireAllowedAdapter`, but takes the registry
    ///      as an argument since `_initialize` binds several counterparties and
    ///      re-walking `vault() -> governor() -> tierRegistry()` per address
    ///      would be redundant staticcall pairs.
    function _requireAllowedAdapter(address registry, address adapter) private view {
        if (!_readAllowed(registry, abi.encodeCall(ITierBindingPath.isAdapterAllowed, (adapter)))) {
            revert CounterpartyNotAllowed(adapter, registry);
        }
    }

    /// @dev Reverts unless `counterparty` carries COUNTERPARTY standing — the
    ///      weak grant: a CERTIFIED TEMPLATE may bind and approve this address
    ///      from inside its own reviewed code path, and proposer-authored batch
    ///      calldata may NOT name it as a callee, approve spender or transfer
    ///      recipient.
    ///
    ///      READ THAT BOUNDARY PRECISELY, because the obvious reading is wrong.
    ///      It is not "this address never receives funds" — `_postCollateral`,
    ///      `_mintPosition` and `_repayAndWithdraw` all `forceApprove` addresses
    ///      bound through here. It is that the approving code is fixed at
    ///      certification time rather than written by the proposer per proposal.
    ///      Every `isAdapterAllowed` read in `SyndicateVault` sits inside
    ///      `_guardBatchCalls` iterating `calls[]`; none of them gates what a
    ///      clone does with capital already delegated to it.
    ///
    ///      This is the predicate the lending market, the position manager and
    ///      the collateral token bind through. Binding them on the adapter axis
    ///      instead would force an owner to make an entry that axis explicitly
    ///      forbids — `setAdapterAllowed` says exotic-asset contracts, naming
    ///      LP-position NFTs, MUST NOT be listed there, and a Uniswap position
    ///      manager is one — and would widen the vault's batch guard for Morpho
    ///      and the position manager as a side effect of a strategy decision.
    ///      `isCounterpartyAllowed` is implied by adapter standing, so a
    ///      registry already configured the old way keeps working unchanged.
    function _requireAllowedCounterparty(address registry, address counterparty) private view {
        if (!_readAllowed(registry, abi.encodeCall(ITierBindingPath.isCounterpartyAllowed, (counterparty)))) {
            revert CounterpartyNotAllowed(counterparty, registry);
        }
    }

    /// @dev The `vault() -> governor() -> tierRegistry()` walk. `address(0)`
    ///      when unresolved (no `governor()` surface, a governor predating the
    ///      getter, or `tierRegistry() == 0`); `_initialize` treats that as
    ///      fatal rather than as a skip.
    function _resolveTierRegistry() private view returns (address registry) {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return address(0);
        registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
    }

    /// @dev RE-CERTIFY AT EVERY FUND-MOVING ENTRYPOINT, not just at init.
    ///      `_initialize` was the only place this template consulted the tier
    ///      registry, so a counterparty revoked AFTERWARDS still received
    ///      `forceApprove` of this clone's whole balance — and revocation needs
    ///      no governance action at all: `TierRegistry.poke` and
    ///      `demoteByChallenge` are both permissionless, and the owner's
    ///      `setAdapterAllowed(x, false)` is one call. Both sibling templates
    ///      already do this and spell out why —
    ///      `MorphoSupplyStrategy._execute`'s `_requireAllowedMorpho` ("a
    ///      singleton demoted between clone-init and execute ... would still
    ///      receive `forceApprove` of the whole supply, one hop outside the
    ///      vault's batch gate") and `PortfolioStrategy`'s
    ///      `_requireAllowedAdapter` at `_execute`/`rebalance`/`rebalanceDelta`.
    ///      This template was the one left on a point-in-time check, and it is
    ///      the one where the exposure is largest: `_rebalanceToTarget` discards
    ///      the swap's return value entirely and takes `minOut` enforcement from
    ///      inside the adapter, so a revoked adapter can take `toSwap` and
    ///      deliver nothing with no local check firing.
    ///
    ///      The vault's batch guard cannot substitute, as `_initialize`'s own
    ///      note already records: the approvals that move money are issued
    ///      INSIDE this contract, one hop past anything the governor batch names.
    ///
    ///      SCOPED TO THE ENTRY PATHS ON PURPOSE. `_settle`, `sweep` and
    ///      `releaseUnconvertible` stay unguarded under the existing
    ///      capital-hostage rationale: blocking an EXIT because a counterparty
    ///      was demoted strands the very funds the demotion is meant to protect.
    ///      Unresolved registry → skip, matching `_requireAllowedAdapter`'s own
    ///      shape; resolved-but-unvouched → revert.
    function _requireCounterpartiesStillAllowed() private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        _requireAllowedAdapter(registry, address(swapAdapter));
        _requireAllowedCounterparty(registry, address(positionManager));
        _requireAllowedCounterparty(registry, address(morpho));
        // The volatile leg re-checks on the same terms as the rest: `rerange()`
        // is permissionless and re-issues `forceApprove(otherToken, …)` to both
        // the adapter and the position manager on every call, so a leg demoted
        // after init would otherwise keep receiving them.
        _requireAllowedCounterparty(registry, otherToken);
        address coll = _marketParams.collateralToken;
        if (coll != asset) _requireAllowedCounterparty(registry, coll);
        // `uniswapFactory` is DELIBERATELY ABSENT, and the asymmetry with
        // `otherToken` above is the reason to say so. Every address re-checked
        // here keeps receiving vault funds or approvals for the clone's whole
        // life. The factory receives neither: it is asked one question, once, at
        // init — "did you create this pool?" — and the answer is a fact about
        // the past that a later demotion cannot retract. Re-checking it would
        // let a demotion freeze `execute()` and the permissionless `rerange()`
        // over a pool whose provenance is still exactly as established, which is
        // the capital-hostage failure the exit paths are ungated to avoid.
    }

    /// @dev Staticcall-safe boolean read, shared by both allowlist axes.
    ///      Unreadable → `false`, so a registry that cannot answer has not
    ///      vouched.
    ///
    ///      The word is read directly rather than via `abi.decode(ret, (bool))`:
    ///      decoding a bool REVERTS on any word that is not 0 or 1, and that
    ///      revert would land in this frame with nothing to catch it — turning
    ///      the documented "unreadable means not vouched for" into "unreadable
    ///      bricks `_initialize` undecodably", which is the exact failure this
    ///      whole helper is written in raw-staticcall form to avoid. Non-zero is
    ///      true, matching how the EVM itself reads a boolean return.
    ///
    ///      Takes encoded calldata rather than a selector-plus-address so the
    ///      two axes cannot diverge in their failure handling: there is exactly
    ///      one place that decides what an unanswerable registry means.
    function _readAllowed(address registry, bytes memory data) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) = registry.staticcall(data);
        if (!ok || ret.length != 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        return word != 0;
    }

    /// @dev Staticcall-safe address read: codeless target, revert, short
    ///      return, or dirty upper bits all resolve to `address(0)`.
    function _readAddress(address target, bytes memory data) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return address(0);
        uint256 word;
        // Reads the first return word directly: `abi.decode` cannot express
        // "leading word of a longer payload".
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    /// @dev The collateral's worth in vault-asset units, READ FROM THE CHAIN.
    ///
    ///      This is the denominator of the LLTV-buffer gate, which the constant
    ///      above calls the only on-chain control over liquidation before
    ///      settlement. A denominator taken from init data is not a control at
    ///      all: a proposer who overstates it drives the computed LTV toward
    ///      zero and clears any buffer unconditionally. So it is derived, and
    ///      `InitParams` no longer carries a field for it.
    ///
    ///      Direct case: the market takes the vault asset, so the value IS the
    ///      amount. Wrapper case: `previewRedeem(previewDeposit(amount))` is the
    ///      round trip this strategy will actually perform — deposit at execute,
    ///      redeem at settle — priced by the wrapper itself, in vault-asset
    ///      units, with no oracle. It reads slightly BELOW `amount` whenever the
    ///      wrapper charges a round-trip fee, which is the conservative
    ///      direction for a gate on leverage.
    ///
    ///      Both previews are typed calls, and reverting is correct: the caller
    ///      has already proven this token answers `asset()` as an ERC-4626, and
    ///      an init failure only fails the PROPOSAL, which is recoverable.
    ///      Fails closed on a zero value so the division below cannot panic.
    function _collateralValueOf(address collateralToken, address vaultAsset, uint256 amount)
        private
        view
        returns (uint256 value)
    {
        if (collateralToken == vaultAsset) return amount;
        IERC4626 wrapper = IERC4626(collateralToken);
        value = wrapper.previewRedeem(wrapper.previewDeposit(amount));
        if (value == 0) revert CollateralValueUnavailable();
    }

    function _requireValidRange(int24 lower, int24 upper, int24 spacing) private pure {
        if (lower >= upper) revert InvalidTickRange();
        if (spacing <= 0) revert InvalidTickRange();
        if (lower % spacing != 0 || upper % spacing != 0) revert InvalidTickRange();
    }

    function _requireValidBounds(InitParams memory p) private pure {
        if (p.twapWindow < MIN_TWAP_WINDOW) revert InvalidBound();
        if (p.maxTwapDeviationBps == 0 || p.maxTwapDeviationBps > MAX_TWAP_DEVIATION_BPS) revert InvalidBound();
        // ZERO IS THE STRICTEST SETTING, NOT THE LOOSEST (pashov 2026-08
        // findings #16 and #9's first trigger). It reads as a safe default and
        // is the one value that cannot work: `_mintPosition` derives
        // `amountXMin` from the amounts OFFERED, so zero demands the pool
        // consume every wei of both legs, which a two-sided mint never does.
        // The mint reverts, `_execute` reverts with it, and the proposal
        // expires at `executeBy` with the bond still locked. Same bar as
        // `settleSlippageBps` below, and for the same reason.
        if (p.mintSlippageBps == 0 || p.mintSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidBound();
        // ZERO IS NOT A LEGAL INIT VALUE, because `_updateParams` reads zero as
        // "keep current" and is otherwise a one-way ratchet. A clone
        // initialized at 0 could therefore never be corrected: every later
        // `slippageBps > 0` trips `ImmutableParam` against a stored 0, and the
        // sentinel path leaves it at 0. The keep-sentinel closes the
        // pass-0-to-change-only-the-deadline trap; this closes the init one.
        if (p.settleSlippageBps == 0 || p.settleSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidBound();
        if (p.swapFractionBps > BPS_DENOMINATOR) revert InvalidBound();
    }

    function _requireValidRerangePolicy(RerangePolicy memory r, int24 spacing, int24 lower, int24 upper) private pure {
        // A half-width below one tick spacing cannot snap to a non-empty range.
        if (r.halfWidthTicks < spacing) revert InvalidRerangePolicy();
        // THE RERANGE BAND MAY NOT BE NARROWER THAN THE APPROVED ONE (pashov
        // 2026-08 finding #17, structural half).
        //
        // `_execute` enforces `MAX_POOL_SHARE_BPS` on the liquidity it actually
        // mints; `rerange` re-mints through the same `_mintPosition` and cannot
        // re-check it without introducing a permanent brick (see the block in
        // `rerange`). So the cap is preserved HERE instead, at bind time, where
        // refusing costs a re-proposal rather than stranding a live position.
        //
        // For fixed token amounts, liquidity scales inversely with band width:
        // `L ≈ amount / (sqrt(Pu) - sqrt(Pl))`. A rerange band at least as wide
        // as the initial one therefore mints at most the liquidity the initial
        // mint did, and that figure already cleared the cap at `_execute`. This
        // closes the structural case the finding turns on — a wide initial
        // range plus `halfWidthTicks == tickSpacing`, which passed every check
        // and then concentrated the same notional into a single spacing.
        //
        // What it does NOT close, stated so the gap is not mistaken for
        // covered: venue depth FALLING between execute and rerange breaches the
        // cap with an unchanged band, and no bind-time rule can see that. That
        // residual needs the runtime check, which needs the zero-liquidity
        // brick solved first.
        if (uint256(int256(r.halfWidthTicks)) * 2 < uint256(int256(upper - lower))) {
            revert InvalidRerangePolicy();
        }
        if (r.halfWidthTicks > MAX_HALF_WIDTH_TICKS) revert InvalidRerangePolicy();
        if (r.triggerBps == 0 || r.triggerBps > BPS_DENOMINATOR) revert InvalidRerangePolicy();
        if (r.maxReranges > MAX_RERANGE_LIMIT) revert InvalidRerangePolicy();
        // ZERO IS A PERMANENT SELF-BRICK (pashov 2026-08 finding #16).
        // `_quoteMinOut` computes `expected * (BPS_DENOMINATOR - slippageBps) /
        // BPS_DENOMINATOR`, so zero puts the floor exactly ON the quote — and
        // the quote is read BEFORE the swap moves the pool, so no honest fill
        // clears it. Every `rerange()` then reverts for this clone's whole
        // life: `_updateParams` reaches only `settleSlippageBps` and
        // `settleDeadline` and is a one-way ratchet, so this field can never be
        // corrected. The position sits frozen in its initial band for up to
        // `ABSOLUTE_MAX_STRATEGY_DURATION`, earning no fees while the borrow
        // accrues. Refusing the input costs a re-proposal instead.
        if (r.slippageBps == 0 || r.slippageBps > MAX_SLIPPAGE_BPS) revert InvalidRerangePolicy();
        if (r.swapFractionBps > BPS_DENOMINATOR) revert InvalidRerangePolicy();
    }

    /// @dev `poolLiquidity` is passed rather than read so the post-mint call
    ///      site can measure against a PRE-MINT snapshot — see
    ///      `MAX_POOL_SHARE_BPS`.
    function _requireWithinPoolShare(uint256 poolLiquidity, uint128 liquidity) private pure {
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
        (int24 tick, bool ok) = _tryTwapTick();
        if (!ok) revert TwapUnavailable();
        return tick;
    }

    /// @dev The read itself, reporting availability instead of reverting.
    ///      Exists for `_spotNearTwap`, which asks the same question on a path
    ///      that must not revert (see there). `_twapTick` is the fail-closed
    ///      wrapper and remains the only form the minting paths use — the
    ///      difference is which caller is allowed to survive an unavailable
    ///      TWAP, never how the TWAP itself is computed.
    ///
    ///      The `ret.length` floor bounds `abi.decode` to payloads that can at
    ///      least carry two dynamic-array heads; beyond that the decode assumes
    ///      well-formed ABI, which `pool` earns by being factory-verified at
    ///      `_initialize`. What this path defends against is a manipulated
    ///      PRICE, not a hostile pool ABI.
    function _tryTwapTick() private view returns (int24, bool) {
        // Cardinality 1 means the ring holds only the current observation:
        // there is no history to average, so `observe` would answer with spot.
        (,,, uint16 cardinality,,,) = pool.slot0();
        if (cardinality < 2) return (0, false);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (bool ok, bytes memory ret) = address(pool).staticcall(abi.encodeCall(IUniswapV3Pool.observe, (secondsAgos)));
        if (!ok || ret.length < 128) return (0, false);
        (int56[] memory tickCumulatives,) = abi.decode(ret, (int56[], uint160[]));
        if (tickCumulatives.length != 2) return (0, false);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        // The quotient is a mean of two ticks, so it is bounded by the tick
        // range itself (±887272) and cannot overflow int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 avg = int24(delta / int56(uint56(twapWindow)));
        // Upstream `OracleLibrary` floors toward negative infinity; mirror it so
        // a re-centered range derived here matches an off-chain simulation.
        if (delta < 0 && (delta % int56(uint56(twapWindow)) != 0)) avg--;
        return (avg, true);
    }

    /// @dev `_requireSpotNearTwap` as a QUESTION rather than an assertion: true
    ///      only when the TWAP is readable AND spot sits inside
    ///      `maxTwapDeviationBps` of it. Same tick-space comparison, same
    ///      first-order bps↔tick mapping, same permissive-erring direction.
    ///
    ///      Exists because `_trySwapToAsset` needs to know whether the pool
    ///      price is trustworthy WITHOUT that question being able to revert the
    ///      vault's exit. An unreadable TWAP answers false, so the pool anchor
    ///      is simply not applied — never a settlement veto.
    function _spotNearTwap() private view returns (bool) {
        (int24 twap, bool ok) = _tryTwapTick();
        if (!ok) return false;
        (, int24 spot,,,,,) = pool.slot0();
        return _withinTwapBound(spot, twap);
    }

    /// @dev Reverts unless spot sits within `maxTwapDeviationBps` of the TWAP.
    ///      Shares `_withinTwapBound` with `_spotNearTwap` — see there for the
    ///      tick-space reasoning and the first-order bps↔tick mapping.
    function _requireSpotNearTwap() private view returns (int24 twap) {
        twap = _twapTick();
        (, int24 spot,,,,,) = pool.slot0();
        if (!_withinTwapBound(spot, twap)) revert SpotOutsideTwapBound();
    }

    /// @dev THE comparison, in one place. `_requireSpotNearTwap` asserts it and
    ///      `_spotNearTwap` asks it; holding the arithmetic in two copies would
    ///      let the assertion and the question drift apart, and they must answer
    ///      identically — the settle path's decision to swap at all is only
    ///      sound while it means exactly what the minting paths enforce.
    ///
    ///      Compared in TICK space, not price space: a tick is a log of price,
    ///      so a bound on tick distance is a bound on the RATIO of the two
    ///      prices, which is what "deviation" means here. Doing it in price
    ///      space would need the exp this contract deliberately does not carry.
    ///
    ///      One tick is a factor of 1.0001, i.e. ~1 bps, so a bound expressed in
    ///      bps maps onto ticks one-for-one. The mapping is a FIRST-ORDER
    ///      approximation and drifts as the bound grows: at the
    ///      `MAX_TWAP_DEVIATION_BPS` ceiling of 1_000, `1.0001^1000 = 1.1052`,
    ///      so the check actually admits ~10.5% rather than exactly 10%. It errs
    ///      PERMISSIVE, never strict, which is why the ceiling is the real
    ///      control and this conversion is not asked to be exact (design
    ///      Decision 2).
    function _withinTwapBound(int24 spot, int24 twap) private view returns (bool) {
        int24 diff = spot > twap ? spot - twap : twap - spot;
        // `diff` is non-negative by construction above, so the cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint24(diff)) <= maxTwapDeviationBps;
    }

    // ── Execute ──

    function _execute() internal override nonReentrant {
        _requireCounterpartiesStillAllowed();
        _requireSpotNearTwap();

        // Snapshot the venue BEFORE this strategy touches it. Read back after
        // the mint it would include this position in its own denominator, and
        // the swap below can cross a tick and move it too.
        uint256 poolLiquidityBefore = pool.liquidity();

        // Pull, then post as collateral. The wrapper deposit happens here rather
        // than at init because init moves no funds.
        _pullFromVault(asset, collateralAmount);
        uint256 posted = _postCollateral(collateralAmount);

        morpho.borrow(_marketParams, borrowAmount, 0, address(this), address(this));

        (uint256 tid, uint128 liquidity) = _mintPosition(tickLower, tickUpper, swapFractionBps, mintSlippageBps);
        tokenId = tid;

        // Anchor the rerange clock. Without this it stays 0, and `minInterval`
        // — which the rerange gate documents as running "since execute or the
        // last rerange" — would not gate the FIRST rerange at all: a keeper
        // could rerange in execute's own block the moment the trigger is met.
        lastRerangeAt = block.timestamp;

        // Post-execute invariants, asserted in-contract because they are cheap
        // here and expensive to reconstruct after the fact.
        _requireWithinPoolShare(poolLiquidityBefore, liquidity);

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
            uint256 minOut = _floorFor(asset, otherToken, toSwap, slippageBps);
            IERC20(asset).forceApprove(address(swapAdapter), toSwap);
            swapAdapter.swap(asset, otherToken, toSwap, minOut, swapExtraData);
            // Leave no standing allowance to an adapter that consumed less than
            // it was offered.
            IERC20(asset).forceApprove(address(swapAdapter), 0);
        } else {
            // NOTHING HELD MEANS NOTHING TO SELL, and it must be answered BEFORE
            // the division below rather than by the `toSwap == 0` guard after
            // it. `otherValue` stays 0 whenever `otherBal` is 0 (the quote is
            // skipped), and this branch is still reached in that state because
            // `targetOtherValue > otherValue` is `0 > 0` — false. The single-
            // sided LP configuration `_requireValidBounds` accepts
            // (`swapFractionBps == 0`) lands here on its very first mint, so
            // without this the whole of `execute()` panics 0x12 with the
            // proposer's bond already locked, and permissionless `rerange()`
            // panics the same way on a position holding only the vault asset.
            if (otherValue == 0) return;
            uint256 excessValue = otherValue - targetOtherValue; // asset units
            // Convert the excess back into `otherToken` units proportionally —
            // `otherValue` is the adapter's price for exactly `otherBal`, so the
            // ratio is the conversion and no separate price read is needed.
            uint256 toSwap = (otherBal * excessValue) / otherValue;
            if (toSwap == 0) return;
            uint256 minOut = _floorFor(otherToken, asset, toSwap, slippageBps);
            IERC20(otherToken).forceApprove(address(swapAdapter), toSwap);
            swapAdapter.swap(otherToken, asset, toSwap, minOut, swapExtraData);
            IERC20(otherToken).forceApprove(address(swapAdapter), 0);
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

        // A mint consumes only the side the range actually needs, so the offered
        // balances are routinely larger than what is taken. Retire the rest
        // rather than leaving a standing allowance between reranges.
        IERC20(asset).forceApprove(address(positionManager), 0);
        IERC20(otherToken).forceApprove(address(positionManager), 0);
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

    /// @dev Widened to `int256` before the clamp. A band that is legitimate in
    ///      the middle of the domain still runs past `MIN_TICK`/`MAX_TICK` when
    ///      the TWAP sits near an extreme, and `center ± half` in `int24` would
    ///      REVERT on overflow there — bricking `rerange()` permanently for a
    ///      policy that init accepted. Clamping to the domain keeps the position
    ///      re-centerable at every tick the pool can reach; the init-time
    ///      `MAX_HALF_WIDTH_TICKS` ceiling is what stops the clamp from being
    ///      reached by a band nobody meant to approve.
    function _derivedRange(int24 center) private view returns (int24 newLower, int24 newUpper) {
        int24 spacing = tickSpacing;
        int256 half = int256(_rerange.halfWidthTicks);
        int256 lo = int256(center) - half;
        int256 hi = int256(center) + half;

        // Snap the domain bounds INWARD so a clamped edge is still alignable.
        int24 minAligned = _snapUp(MIN_TICK, spacing);
        int24 maxAligned = _snapDown(MAX_TICK, spacing);

        newLower = lo <= int256(minAligned) ? minAligned : _snapDown(int24(lo), spacing);
        newUpper = hi >= int256(maxAligned) ? maxAligned : _snapUp(int24(hi), spacing);
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
    ///         GUARDED. `rerange()` hands control to the adapter, to the
    ///         position manager and to `otherToken` — any ERC-20 for which a
    ///         real pool exists, so a transfer hook is a live possibility. A
    ///         reentrant call currently happens to revert on the already-burned
    ///         `tokenId`, which is an accident of ordering rather than a
    ///         property; `nonReentrant` makes it a property.
    function rerange() external nonReentrant returns (uint256 newTokenId) {
        // (1) Executed.
        if (_state != State.Executed) revert NotExecutedForRerange();
        // (1b) The counterparties are STILL certified. See
        //      `_requireCounterpartiesStillAllowed` — this entrypoint is
        //      permissionless and re-issues `forceApprove` to `swapAdapter` on
        //      every call, so a demoted adapter could otherwise drive the drain
        //      itself, up to `maxReranges` times.
        _requireCounterpartiesStillAllowed();
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

        // PASHOV 2026-08 FINDING #17 IS REAL AND IS NOT FIXED HERE. `_execute`
        // ends with `_requireWithinPoolShare` on the actually-minted liquidity;
        // this path re-mints through the same `_mintPosition` and does not, so
        // a wide initial range plus a `halfWidthTicks` of one tick spacing
        // clears init and execute and then concentrates the same notional far
        // above `MAX_POOL_SHARE_BPS`. Depth falling between execute and rerange
        // breaches it on its own.
        //
        // The obvious enforcement — `_requireWithinPoolShare(snapshot,
        // liquidityAfter)` right here — was written, tested, reviewed and
        // WITHDRAWN. It reverts, and both of its revert paths are permanent:
        //
        //   1. The breach it names as its motivating case is STRUCTURAL, not
        //      transient. `_requireValidRerangePolicy` accepts
        //      `halfWidthTicks == tickSpacing` and nothing couples that policy
        //      to `MAX_POOL_SHARE_BPS`, so the same notability in the same one
        //      spacing produces the same over-cap L on EVERY attempt. The clone
        //      is then dead on arrival: every `rerange()` reverts for the whole
        //      proposal lifetime, the position sits out of range earning no
        //      fees, and the Morpho borrow keeps accruing against it.
        //   2. `_requireWithinPoolShare` treats `poolLiquidity == 0` as
        //      unsatisfiable. On a live pool `_closePosition`'s
        //      `decreaseLiquidity` removes this position from
        //      `pool.liquidity()`, so a strategy that is the only in-range LP
        //      reads zero after the close and is bricked. `MockUniswapV3Pool`
        //      exposes `liquidity` as a plain settable field that
        //      `decreaseLiquidity` never touches, so NO test against these
        //      mocks can reach that branch — it is not merely uncovered, it is
        //      structurally untestable here.
        //
        // Trading an over-cap position for a permanently frozen one is not a
        // fix. The enforcement this needs is at BIND time — reject a rerange
        // policy that cannot satisfy the cap — which requires coupling
        // `halfWidthTicks` to `MAX_POOL_SHARE_BPS` through liquidity math this
        // template deliberately does not carry, plus a fork test for (2).
        // Left open rather than closed badly.
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
    function _settle() internal override nonReentrant {
        _tryUnwindPosition();

        _trySwapToAsset(settleSlippageBps);

        (uint256 debtRemaining, uint256 collateralRemaining) = _repayAndWithdraw();
        if (debtRemaining != 0 || collateralRemaining != 0) {
            emit SettlementIncomplete(debtRemaining, collateralRemaining);
        }

        _pushAllToVault(asset);
    }

    /// @notice Unwind the live position. Callable only by this contract.
    /// @dev    External ONLY so `_settle` can wrap it in `try/catch` as a unit.
    ///         The four position-manager calls behind it are typed, and a typed
    ///         call that reverts takes the whole settlement with it — which is
    ///         the vault-wide redemption veto this design exists to remove. A
    ///         self-call is the cheapest way to make the entire unwind atomic
    ///         AND recoverable: on failure the inner state changes roll back,
    ///         `tokenId` survives, and `sweep()` retries the identical call.
    ///         Guarding the four calls individually would instead leave the
    ///         position half-closed with no record of how far it got.
    function unwindPosition() external {
        if (msg.sender != address(this)) revert NotSelf();
        _closePosition(tokenId);
        tokenId = 0;
    }

    /// @dev `catch` is empty on purpose: the position stays held, the residue is
    ///      reported by the `SettlementIncomplete` emitted downstream, and
    ///      `sweep()` is the retry.
    function _tryUnwindPosition() private {
        if (tokenId == 0) return;
        try this.unwindPosition() {} catch {}
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
        // The exit leg was the one swap with NO anchor at all: unlike `_execute`
        // and `rerange`, `_settle`/`sweep` never call `_requireSpotNearTwap`, so
        // this floor was purely the routed venue quoting itself. Raise it to the
        // configured pool's own price when that is higher.
        //
        // AN UNVERIFIED POOL MEANS NO SWAP, NOT A CHEAPER SWAP. This is the one
        // place the anchor's safety is not inherited from its caller:
        // `_execute`/`rerange` assert spot against the TWAP and revert
        // otherwise, so for them a pushed pool never reaches the floor at all.
        // `_settle`/`sweep` assert nothing, which leaves exactly two options for
        // a pool whose spot is outside `maxTwapDeviationBps` — and only one of
        // them is safe:
        //
        //   SKIP THE ANCHOR and swap on the quote floor alone. Rejected. It
        //   hands the attacker who pushed the pool the ORIGINAL finding back:
        //   with the anchor off, `minOut` is the routed venue quoting itself,
        //   so the same actor moves both and the skim clears. Measured, not
        //   argued: a venue paying half the pool price converted the entire
        //   position with the pool pushed 23,000 ticks off its TWAP.
        //
        //   SKIP THE SWAP. Taken. It is what this function already does for
        //   every other unusable floor — "the swap is NEVER attempted without a
        //   floor; it is skipped instead" — and the residue is recoverable by
        //   the permissionless `sweep()`, so the cost of a pushed pool is delay,
        //   not loss.
        //
        // The denial that buys is bounded and self-defeating: holding spot
        // outside the bound costs the attacker capital every block, while the
        // TWAP walks toward spot over `twapWindow`, so the deviation they are
        // paying to maintain closes underneath them. `sweep()` and
        // `settleProposal` are both retryable by anyone at any later honest
        // moment. Trading a bounded, unprofitable delay for a profitable,
        // unbounded skim is the wrong direction on the vault's exit.
        if (!_spotNearTwap()) return;
        uint256 anchored = _poolAnchoredMinOut(otherToken, bal, slippageBps);
        if (anchored > minOut) minOut = anchored;

        IERC20(otherToken).forceApprove(address(swapAdapter), bal);
        // The swap itself is also allowed to fail: a quote that stood a moment
        // ago can be gone by the time the swap lands, and that must not revert
        // settlement either.
        (bool swapped,) = address(swapAdapter)
            .call(abi.encodeCall(ISwapAdapter.swap, (otherToken, asset, bal, minOut, swapExtraData)));
        // Retire the allowance either way: on failure it must not stand, and on
        // success an adapter that took less than offered must not keep the rest.
        IERC20(otherToken).forceApprove(address(swapAdapter), 0);
        if (!swapped) return; // residue stays converted-nothing; `sweep()` retries
    }

    /// @dev Repays by SHARES when the position can afford the whole debt, and by
    ///      ASSETS only when taking the deliverable maximum. Shares-mode is what
    ///      clears the debt EXACTLY — a single dust share left behind blocks
    ///      `withdrawCollateral` entirely, which would turn a full settlement
    ///      into a stranded one.
    function _repayAndWithdraw() private returns (uint256 debtRemaining, uint256 collateralRemaining) {
        // GUARDED: `accrueInterest` calls the market's IRM, and the IRM address
        // is part of the proposer-supplied `MarketParams`. A reverting IRM would
        // otherwise be a settlement veto handed to the proposer.
        (bool accrued,) = address(morpho).call(abi.encodeCall(IMorpho.accrueInterest, (_marketParams)));

        uint128 borrowShares = morpho.position(marketId, address(this)).borrowShares;

        if (borrowShares != 0) {
            Market memory m = morpho.market(marketId);
            uint256 owed = _sharesToAssetsUp(borrowShares, m.totalBorrowAssets, m.totalBorrowShares);
            uint256 held = IERC20(asset).balanceOf(address(this));

            if (accrued && held >= owed) {
                // Shares-mode is what clears the debt EXACTLY — a single dust
                // share left behind blocks `withdrawCollateral` entirely. It is
                // only trustworthy on FRESH totals, which is why it is gated on
                // the accrual above having landed: against stale totals the
                // mirrored `owed` understates what Morpho will actually pull.
                _tryRepay(held, abi.encodeCall(IMorpho.repay, (_marketParams, 0, borrowShares, address(this), "")));
            } else if (held != 0) {
                // Deliverable maximum. Capped at `owed` because repaying more
                // assets than the position owes underflows Morpho's share math.
                uint256 amount = held < owed ? held : owed;
                if (amount != 0) {
                    _tryRepay(amount, abi.encodeCall(IMorpho.repay, (_marketParams, amount, 0, address(this), "")));
                }
            }
        }

        uint128 collateral = morpho.position(marketId, address(this)).collateral;
        uint128 outstanding = morpho.position(marketId, address(this)).borrowShares;
        if (collateral != 0) {
            if (outstanding == 0) {
                _tryWithdrawCollateral(collateral);
            } else {
                // PASHOV FINDING #8. Gating the withdrawal on `outstanding == 0`
                // is strictly stronger than the rule Morpho enforces
                // (`LTV <= LLTV`), so a position that came back a few units
                // short of its accrued interest kept its ENTIRE collateral
                // locked behind trivial residual debt — traced in
                // `CLStrategy_partialCollateralRecovery.t.sol`: ~412 of debt
                // stranding 100,000 of collateral, a ~243x disproportion, from
                // an ordinary interest-outran-fees outcome with no attacker.
                //
                // It is also unrecoverable once it happens: the partial repay
                // above leaves this clone's asset balance at zero, so `sweep()`
                // never re-enters the repay branch and the withdrawal stays
                // gated forever. Only a third party volunteering to repay
                // someone else's dust would unblock it.
                //
                // So take the health-preserving maximum instead of nothing.
                uint256 freeable = _withdrawableWhileHealthy(collateral);
                if (freeable != 0) _tryWithdrawCollateral(uint128(freeable));
            }
        }

        // Retried UNCONDITIONALLY, not only under the branch above. A previous
        // call can have pulled the shares out of Morpho and then failed to
        // redeem them; Morpho's collateral is zero at that point, so gating the
        // retry on it would strand the shares on this clone forever.
        _tryRedeemWrapper();

        // Re-read rather than reasoning from the branch taken: a partial repay
        // that rounded, or a capped withdrawal, must be reported as it actually
        // landed and not as it was intended.
        borrowShares = morpho.position(marketId, address(this)).borrowShares;
        collateral = morpho.position(marketId, address(this)).collateral;
        if (borrowShares != 0) {
            Market memory m2 = morpho.market(marketId);
            debtRemaining = _sharesToAssetsUp(borrowShares, m2.totalBorrowAssets, m2.totalBorrowShares);
        }
        // Counts wrapper shares still sitting on the clone, not just what Morpho
        // still holds — both are collateral this settlement failed to deliver,
        // in the same units, and reporting only the first would call a stranded
        // settlement complete.
        collateralRemaining = collateral;
        address collateralToken = _marketParams.collateralToken;
        if (collateralToken != asset) {
            collateralRemaining += IERC20(collateralToken).balanceOf(address(this));
        }
    }

    /// @dev Approves, calls, then retires the allowance whatever happened. The
    ///      approval is the amount HELD rather than the amount computed: the
    ///      computed figure comes from a local mirror of Morpho's share math, so
    ///      approving exactly it makes settlement depend on that mirror agreeing
    ///      to the wei. It is already known that `held` covers the call.
    ///      Returns whether the repay landed; callers deliberately ignore it,
    ///      because the authoritative answer is the position re-read afterwards.
    function _tryRepay(uint256 approveAmount, bytes memory callData) private returns (bool ok) {
        IERC20(asset).forceApprove(address(morpho), approveAmount);
        (ok,) = address(morpho).call(callData);
        IERC20(asset).forceApprove(address(morpho), 0);
    }

    /// @dev The collateral this position can release while still satisfying
    ///      Morpho's own health rule against the debt that is STILL OUTSTANDING
    ///      (pashov finding #8). Morpho requires
    ///        collateral * price / ORACLE_PRICE_SCALE * lltv / WAD  >=  borrowed
    ///      so the collateral that must STAY is the smallest value satisfying it,
    ///      rounded UP at every step, and everything above that is freeable.
    ///
    ///      KEEPS `MIN_LLTV_BUFFER_BPS` OF HEADROOM rather than unwinding to the
    ///      liquidation threshold exactly. Landing on the bar would leave the
    ///      residual position one interest-accrual block away from liquidation,
    ///      which trades the bug for a worse one; the same buffer the entry-side
    ///      LTV gate enforces is the natural bar to reuse.
    ///
    ///      THE ORACLE READ IS RAW AND GUARDED, matching this file's standing
    ///      treatment of proposer-supplied `MarketParams` members (`accrueInterest`
    ///      above, `_tryRedeemWrapper`, `_feedPriceX8` in `ExposureLedger`): the
    ///      oracle address is part of the proposer's market declaration, so a
    ///      typed call would hand whoever controls it a settlement veto — a
    ///      revert in this frame with no returndata to catch. DECISION ON
    ///      FAILURE: return 0, i.e. degrade to the pre-fix behaviour of leaving
    ///      the collateral for `sweep()`. This is a liveness path, so it fails
    ///      to the OLD outcome, never to a withdrawal sized off an unread price.
    ///
    ///      NOT GATED ON THE `accrued` FLAG, unlike the shares-mode repay in the
    ///      caller — and that asymmetry is deliberate, not an oversight. Both
    ///      read the same `totalBorrowAssets`, which is STALE when
    ///      `accrueInterest` failed, and a stale read understates `owed` and so
    ///      oversizes the result here. It cannot land, though: Morpho re-accrues
    ///      INSIDE `withdrawCollateral` before its health check, so the same
    ///      reverting IRM that left these totals stale also reverts the
    ///      withdrawal, `_tryWithdrawCollateral` swallows it, and the outcome is
    ///      the pre-fix one. Shares-mode repay needs the gate because a stale
    ///      `owed` there makes Morpho pull MORE than expected; there is no
    ///      matching hazard on this side.
    ///
    ///      A COROLLARY WORTH PINNING: `MIN_LLTV_BUFFER_BPS` above therefore
    ///      does exactly the one job its own paragraph claims. It is NOT also
    ///      absorbing un-accrued interest, because no withdrawal ever lands with
    ///      un-accrued interest outstanding. Do not shrink it on the theory that
    ///      it is carrying slack for this case.
    function _withdrawableWhileHealthy(uint128 collateral) private view returns (uint256) {
        MarketParams memory mp = _marketParams;
        uint128 borrowShares = morpho.position(marketId, address(this)).borrowShares;
        if (borrowShares == 0 || mp.lltv == 0) return 0;

        address oracle = mp.oracle;
        if (oracle.code.length == 0) return 0;
        (bool ok, bytes memory ret) = oracle.staticcall(abi.encodeWithSelector(IMorphoOracle.price.selector));
        if (!ok || ret.length < 32) return 0;
        uint256 price = abi.decode(ret, (uint256));
        if (price == 0) return 0;

        Market memory m = morpho.market(marketId);
        uint256 owed = _sharesToAssetsUp(borrowShares, m.totalBorrowAssets, m.totalBorrowShares);

        // Effective LTV ceiling, held `MIN_LLTV_BUFFER_BPS` under the market's.
        uint256 bufferWad = (MIN_LLTV_BUFFER_BPS * 1e18) / BPS_DENOMINATOR;
        if (mp.lltv <= bufferWad) return 0;
        uint256 effLltv = mp.lltv - bufferWad;

        // required = ceil(ceil(owed * ORACLE_PRICE_SCALE / price) * WAD / effLltv)
        // Split so the intermediate never needs 1e36 * 1e18 at once.
        uint256 required = Math.mulDiv(owed, ORACLE_PRICE_SCALE, price, Math.Rounding.Ceil);
        required = Math.mulDiv(required, 1e18, effLltv, Math.Rounding.Ceil);

        if (required >= collateral) return 0;
        return collateral - required;
    }

    /// @dev Degrades rather than reverting. A collateral withdrawal can fail for
    ///      reasons outside this proposal's control; taking the shortfall as an
    ///      incomplete settlement keeps the vault's redemption path open, and
    ///      `sweep()` recovers it once the condition clears.
    function _tryWithdrawCollateral(uint128 amount) private returns (bool ok) {
        (ok,) = address(morpho)
            .call(abi.encodeCall(IMorpho.withdrawCollateral, (_marketParams, amount, address(this), address(this))));
    }

    /// @dev Redeem the ERC-4626 collateral wrapper back into the vault asset.
    ///      GUARDED, and that guard is the point. This is the one call on the
    ///      settlement path that a third party routinely controls: the wrappers
    ///      this template is built for (spUSDG and its class) gate redemption
    ///      behind pauses, caps, queues and underlying liquidity, none of which
    ///      this proposal can influence. A typed call here would let whoever
    ///      operates the wrapper freeze the vault's ONLY exit by pausing their
    ///      own product — a settlement veto handed to an unrelated third party,
    ///      which is exactly what the deliverable-maximum design exists to
    ///      remove. On failure the shares stay on the clone and `sweep()`
    ///      retries; `_repayAndWithdraw` reports them as `collateralRemaining`
    ///      in the meantime.
    ///
    ///      `maxRedeem` is honoured rather than assumed: a wrapper that will
    ///      serve part of the balance should serve that part now instead of
    ///      failing whole and deferring everything to `sweep()`.
    function _tryRedeemWrapper() private returns (bool ok) {
        address collateralToken = _marketParams.collateralToken;
        if (collateralToken == asset) return true;

        uint256 shares = IERC20(collateralToken).balanceOf(address(this));
        if (shares == 0) return true;

        (bool maxOk, bytes memory maxRet) =
            collateralToken.staticcall(abi.encodeCall(IERC4626.maxRedeem, (address(this))));
        if (maxOk && maxRet.length == 32) {
            uint256 redeemable = abi.decode(maxRet, (uint256));
            if (redeemable < shares) shares = redeemable;
        }
        if (shares == 0) return false;

        (ok,) = collateralToken.call(abi.encodeCall(IERC4626.redeem, (shares, address(this), address(this))));
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
    /// @dev    VAULT-ONLY, THOUGH THE VALUE ONLY EVER MOVES THE RIGHT WAY. This
    ///         was permissionless on the reasoning that a one-directional push
    ///         needs no gate. The push is fine; the ACCOUNTING is what breaks —
    ///         `SyndicateVault.collectResidue` measures the arrival as a balance
    ///         delta and pays the exited redeem cohort their frozen share of it,
    ///         and a delta only measures everything if it is the only door.
    ///         Called directly, the cohort is credited nothing and the arrival
    ///         lifts the stayers' price instead, unrepairably. See the twin note
    ///         on `MorphoSupplyStrategy.sweep`. The permissionless entry point
    ///         is `collectResidue`, which calls this.
    ///
    ///         Post-settlement only. Idempotent and safe to call with nothing to
    ///         move.
    ///         RETRIES EVERY STEP `_settle` CAN FAIL AT, in the same order. The
    ///         set of residues this can recover must not be narrower than the
    ///         set `_settle` can create, or the "recoverable later" claim above
    ///         is false for whichever step was left out — so the position
    ///         unwind is retried here too, not just the repay and the withdraw.
    function sweep() external onlyVault nonReentrant returns (uint256 assets) {
        if (_state != State.Settled) revert NotSettled();

        _tryUnwindPosition();
        _trySwapToAsset(settleSlippageBps);

        (uint256 debtRemaining, uint256 collateralRemaining) = _repayAndWithdraw();
        if (debtRemaining != 0 || collateralRemaining != 0) {
            // Loud on the same terms `_settle` is: a sweep that recovers only
            // part of the residue must not read as a completed recovery.
            emit SettlementIncomplete(debtRemaining, collateralRemaining);
        }

        assets = IERC20(asset).balanceOf(address(this));
        if (assets != 0) {
            _pushAllToVault(asset);
            emit ResidualSwept(assets);
        }
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev True while a settled proposal still has value on this clone that a
    ///      `sweep()` or `releaseUnconvertible()` would move. The vault reads it
    ///      to keep deposits shut over that window, since `totalAssets()` prices
    ///      anything held here at zero.
    ///
    ///      Covers every leg this template can strand, which is more than the
    ///      Morpho case: an open LP position, the ERC-4626 collateral wrapper,
    ///      the `otherToken` side, and plain idle `asset`. `_settle` reports the
    ///      first two through `SettlementIncomplete`; the last two are what
    ///      `sweep`/`releaseUnconvertible` exist to return.
    ///
    ///      Reads BALANCES, not deliverability. Whether a wrapper will redeem or
    ///      a pool will quote right now is the manipulable part; value the vault
    ///      is not counting is the part that matters here.
    function hasUndeliveredValue() public view override returns (bool) {
        // `Settled` ONLY, and that is a deliberate reversal. Answering for
        // `Executed` too was tried, to cover a clone left holding everything by
        // `finalizeEmergencySettle`. It WEDGES the vault: `sweep()` is itself
        // `Settled`-gated, so such a clone reports residue forever, cannot be
        // swept, and deposits shut permanently with no permissionless way out —
        // and a proposer can reach it cheaply by omitting `settle()` from a
        // `maxDrawdownBps == 10_000` batch. A permanent DoS is worse than the
        // fail-open it was closing, and it would have falsified
        // `depositsLocked`'s "NOBODY IS WEDGED" doctrine.
        //
        // Closing the emergency-path gap needs `sweep()` reachable for a
        // terminal-but-`Executed` clone first — either by relaxing its gate or
        // by a permissionless `forceSettle()`. Tracked with the NAV work in
        // issue #233 / `docs/nav-residue-design.md`. Until then this stays
        // narrow.
        if (_state != State.Settled) return false;
        if (tokenId != 0) return true;
        if (IERC20(asset).balanceOf(address(this)) > RESIDUE_DUST) return true;
        if (IERC20(otherToken).balanceOf(address(this)) > RESIDUE_DUST) return true;
        // THE MORPHO POSITION, which is the residue this template most often
        // strands: `_repayAndWithdraw` defines `collateralRemaining` as exactly
        // this, `_tryWithdrawCollateral` degrades rather than reverting, and
        // collateral cannot leave while debt remains. The canonical strand — LP
        // burned, loose balances pushed, collateral stuck behind residual debt —
        // answered false without this and reopened deposits.
        Position memory pos = morpho.position(marketId, address(this));
        // Dust-floored for the same reason: `supplyCollateral` also takes
        // `onBehalf` and needs no authorization. The floor is on COLLATERAL and
        // the `borrowShares` clause is gone deliberately: debt with zero
        // collateral is not a reachable steady state, because Morpho's bad-debt
        // realization zeroes both sides together. So the collateral floor
        // subsumes it rather than merely ignoring it.
        if (pos.collateral > RESIDUE_DUST) return true;
        address coll = _marketParams.collateralToken;
        if (coll != asset && IERC20(coll).balanceOf(address(this)) > RESIDUE_DUST) return true;
        return false;
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev DELIBERATELY PARTIAL, AND BIASED LOW. Reports only what this
    ///      template can value in vault-asset units WITHOUT consulting a price
    ///      an attacker could move inside the settlement transaction: the idle
    ///      vault-asset balance, plus the Morpho collateral net of debt when the
    ///      collateral token IS the vault asset (the fee-free 1:1 wrapper case
    ///      this template is built for).
    ///
    ///      NOT counted: a live LP position (`tokenId != 0`), the volatile leg,
    ///      and a collateral token that is not the vault asset. Valuing those
    ///      needs a pool or oracle read, and a stamp that trusts one is exactly
    ///      the unrealized, strategy-influenced NAV the frozen-price design
    ///      exists to avoid — the same lever findings #2/#3 pull.
    ///
    ///      UNDER-REPORTING IS NO LONGER SAFE ON ITS OWN, and that changed
    ///      under this function rather than inside it. While the vault only
    ///      needed a boolean, omitting a leg cost nothing: the lock covered
    ///      every residue shape and the price stayed float-only. The vault now
    ///      prices MINTS against this figure, so an omission is exactly the
    ///      finding-#3 skim — a depositor mints against a price missing the LP
    ///      leg, sweeps it in, and takes the difference from the incumbents.
    ///
    ///      What keeps the narrowing safe is `hasUnvaluedResidue()` below, which
    ///      declares every shape this omits. The vault refuses to mint at all
    ///      while any of them is outstanding, so the partial figure is only ever
    ///      used when it is also COMPLETE.
    function undeliveredValue() public view override returns (uint256) {
        if (_state != State.Settled) return 0;
        uint256 v = IERC20(asset).balanceOf(address(this));
        if (_marketParams.collateralToken != asset) return v;

        // ONE read of the struct, not two.
        Position memory pos = morpho.position(marketId, address(this));
        // SAME FLOOR AS THE BOOL. Without it a 1-wei donated collateral gives
        // `hasUndeliveredValue() == false` while this returns non-zero — the
        // bool/amount divergence that was finding #1. Free to close now; it
        // would not be obvious once #233 wires a consumer.
        if (pos.collateral <= RESIDUE_DUST) return v;
        uint256 owed;
        if (pos.borrowShares != 0) {
            // ACCRUED totals, not raw. A raw `morpho.market` read excludes
            // interest since `lastUpdate`, which understates `owed` and pushes
            // `collateral - owed` HIGH — the one direction this stamp must
            // never err in. The same-tx accrual in `_repayAndWithdraw` is a
            // guarded call allowed to fail, so it is not a guarantee.
            (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(_marketParams);
            owed = _sharesToAssetsUp(pos.borrowShares, totalBorrowAssets, totalBorrowShares);
        }
        // Net equity only, and never negative: an underwater position
        // contributes nothing rather than subtracting from the stamp.
        if (uint256(pos.collateral) > owed) v += uint256(pos.collateral) - owed;
        return v;
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev THE EXACT COMPLEMENT OF WHAT `undeliveredValue()` ABOVE CAN PRICE.
    ///      That figure is deliberately partial: it reports the idle vault-asset
    ///      balance, plus Morpho collateral net of debt ONLY when the collateral
    ///      token IS the vault asset. Everything else needs a price this
    ///      template refuses to consult, because the venue quoting it is one the
    ///      proposal can trade — the lever finding #3 was exploited through.
    ///
    ///      So this reports the residue shapes that figure omits, and the vault
    ///      refuses to mint at all while any of them is outstanding. Under a
    ///      boolean lock the omission was harmless (the lock covered every
    ///      shape); once the figure sets the price a mint pays, an omission IS
    ///      the skim — a depositor mints against a price missing the LP leg,
    ///      sweeps it in, and takes the difference from the incumbents.
    ///
    ///      Every shape here is unwindable by the permissionless `sweep()`:
    ///      burning an LP position always returns its tokens, there is no
    ///      illiquid market to wait on, and `releaseUnconvertible` hands off
    ///      whatever cannot be swapped. So this cannot wedge the vault the way
    ///      an unclearable Morpho supply could.
    function hasUnvaluedResidue() public view override returns (bool) {
        if (_state != State.Settled) return false;
        // A live LP position — valuing it means reading the pool.
        if (tokenId != 0) return true;
        // The volatile leg, which is by construction not the vault asset.
        if (IERC20(otherToken).balanceOf(address(this)) > RESIDUE_DUST) return true;
        address coll = _marketParams.collateralToken;
        if (coll != asset) {
            // Loose collateral, and collateral still posted to Morpho — both in
            // a token `undeliveredValue()` bails out on rather than converting.
            if (IERC20(coll).balanceOf(address(this)) > RESIDUE_DUST) return true;
            if (morpho.position(marketId, address(this)).collateral > RESIDUE_DUST) return true;
        }
        return false;
    }

    /// @notice Hand an `otherToken` residue this clone cannot convert to the
    ///         vault, unconverted.
    /// @dev    THE ESCAPE HATCH OF LAST RESORT, deliberately NOT folded into
    ///         `sweep()`. `sweep()` retries the conversion and can be called
    ///         forever, so a transient adapter outage needs no escape — and
    ///         pushing on every sweep would FORECLOSE the conversion, moving the
    ///         residue somewhere this contract can no longer sell it. The case
    ///         this exists for is the other one: an adapter that will never
    ///         quote this pair again, where `sweep()` alone leaves the residue
    ///         on the clone permanently, because nothing on this contract can
    ///         move a token that is neither the vault asset nor swappable.
    ///
    ///         The vault is the strictly better custodian for that: it carries
    ///         an owner-gated `rescueERC20`, and this clone carries nothing.
    ///
    ///         VAULT-ONLY, LIKE `sweep()`, AND FOR THE SAME ACCOUNTING REASON.
    ///         The conversion below is attempted before the release, so this
    ///         function can push VAULT ASSET home — which makes it a second door
    ///         onto the balance delta `SyndicateVault._payCohortShare` splits,
    ///         and a delta only measures everything if it is the only door.
    ///         Called directly, the exited redeem cohort is credited nothing and
    ///         the arrival lifts the stayers' price instead, unrepairably: the
    ///         delta is spent, so a later vault-side call measures zero. The
    ///         permissionless entry point is `SyndicateVault
    ///         .releaseUnconvertible(strategy)`, which calls this — so the
    ///         capital-hostage property is unchanged, anyone may still trigger
    ///         it at any time.
    ///
    ///         The conversion is attempted first every time — so the worst a
    ///         caller can do is release during an outage that would have
    ///         cleared. That trades a recoverable inconvenience (the owner sells
    ///         it manually) against an unrecoverable loss, which is the right
    ///         direction.
    ///
    ///         NOT counted as swept proceeds: the governor prices this proposal
    ///         from the vault's realized float in the VAULT ASSET, and this is
    ///         not that. It books as a loss here and is recovered off-path.
    function releaseUnconvertible() external onlyVault nonReentrant returns (uint256 released) {
        if (_state != State.Settled) revert NotSettled();

        // Retry the wrapper first: redemption may have reopened since settle,
        // and unwrapped collateral leaves as `asset` below, which is strictly
        // better for the vault than receiving the shares.
        _tryRedeemWrapper();

        _trySwapToAsset(settleSlippageBps);

        // Deliver whatever the conversion DID produce before releasing the rest.
        // Skipping this would leave converted proceeds sitting on the clone —
        // the one outcome this path must never produce, since it exists to get
        // value off the clone.
        uint256 assets = IERC20(asset).balanceOf(address(this));
        if (assets != 0) {
            _pushAllToVault(asset);
            emit ResidualSwept(assets);
        }

        // THE COLLATERAL WRAPPER TOO — not just `otherToken`. This hatch was
        // built for the LP-fee-sized `otherToken` residue and omitted the ERC-4626
        // collateral shares, which are the proposal's ENTIRE principal. Those
        // shares are only ever disposed of by `_tryRedeemWrapper`, and this
        // template's own note concedes the wrappers it targets "gate redemption
        // behind pauses, caps, queues and underlying liquidity, none of which
        // this proposal can influence" — so a wrapper that stops redeeming for
        // good stranded the whole principal on a clone that carries no rescue
        // surface, while `SyndicateVault.rescueERC20` can only reach tokens the
        // VAULT holds. The argument this function already makes for itself
        // applies verbatim and with far larger stakes: the vault is the strictly
        // better custodian, because it has an owner-gated rescue and this clone
        // has none.
        address coll = _marketParams.collateralToken;
        if (coll != asset) {
            uint256 collBal = IERC20(coll).balanceOf(address(this));
            if (collBal != 0) {
                _pushAllToVault(coll);
                emit UnconvertibleReleased(coll, collBal);
            }
        }

        released = IERC20(otherToken).balanceOf(address(this));
        if (released == 0) return 0;
        _pushAllToVault(otherToken);
        emit UnconvertibleReleased(otherToken, released);
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
    ///         RISK-REDUCING IS ENFORCED, NOT ASSERTED. The ceiling alone is not
    ///         that claim: it lets a proposal reviewed at a tight settlement band
    ///         be widened all the way to `MAX_SLIPPAGE_BPS` after approval, and
    ///         `settleProposal` is proposer-callable an hour after execute — so
    ///         the same address that widened the band is the one that then
    ///         settles through it, into a sandwich it controls, with nobody
    ///         reviewing the change. `settleSlippageBps` is therefore
    ///         TIGHTEN-ONLY, mirroring `PortfolioStrategy._updateParams`, which
    ///         names the identical adversary.
    ///
    ///         NO FLOOR, deliberately, and this is where it departs from
    ///         `PortfolioStrategy`'s `MIN_SLIPPAGE_BPS`. There an over-tight
    ///         value is irreversible AND bricks `rebalanceDelta`. Here the only
    ///         consumer is `_trySwapToAsset`, which DEGRADES: a floor nothing
    ///         can fill skips the conversion and leaves the residue to `sweep()`
    ///         and `releaseUnconvertible()`. Self-inflicted and recoverable does
    ///         not need to be a rejected input.
    ///
    ///         `settleDeadline` needs no such rule: `_deadline()` returns
    ///         `max(settleDeadline, block.timestamp)`, so the field can never
    ///         resolve to the past and lowering it only narrows how late a
    ///         settlement batch may land — the risk-reducing direction already.
    function _updateParams(bytes calldata data) internal override {
        (uint256 slippageBps, uint256 deadline) = abi.decode(data, (uint256, uint256));
        // ZERO KEEPS THE CURRENT BAND — it does not set a zero one.
        //
        // `PortfolioStrategy._updateParams` documents this repo's convention as
        // "Pass empty arrays / 0 to keep current values", and without the
        // sentinel the tighten-only ratchet below turns that convention into a
        // one-way trap: a proposer shortening only the deadline writes
        // `abi.encode(0, newDeadline)`, pins `settleSlippageBps` at 0 for the
        // clone's lifetime, and every later call reverts `ImmutableParam`
        // unless it also passes 0. `_trySwapToAsset` then computes
        // `minOut = expected * (10_000 - 0) / 10_000 == expected`, a
        // zero-tolerance floor no real fill clears, so the volatile leg stops
        // converting at settlement and is left to `sweep()` every time.
        //
        // The sibling's answer to the same hazard is `MIN_SLIPPAGE_BPS`, which
        // makes a too-low value a REJECTED input rather than a permanent
        // self-brick. A keep-sentinel is the better fit here because this
        // template's consumer degrades rather than reverts, so there is no
        // value worth rejecting outright — only one worth not writing by
        // accident.
        if (slippageBps != 0) {
            // Ceiling first, so an out-of-range value keeps answering
            // `InvalidBound` rather than being absorbed by the ratchet below.
            if (slippageBps > MAX_SLIPPAGE_BPS) revert InvalidBound();
            if (slippageBps > settleSlippageBps) revert ImmutableParam();
            settleSlippageBps = slippageBps;
        }
        settleDeadline = deadline;
    }
}
