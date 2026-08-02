// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceAdapter, Position} from "../interfaces/IPriceRouter.sol";
import {PositionKinds} from "../libraries/PositionKinds.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @notice Minimal Chainlink push-feed (AggregatorV3) surface the adapter reads.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Minimal strategy/vault surface used to bind the valuation to the
///         holder's vault asset (see the numeraire-binding guard in `value`).
interface IHolderStrategy {
    function vault() external view returns (address);
}

interface IVaultAsset {
    function asset() external view returns (address);
}

/// @notice Minimal Uniswap-v3-style pool surface for the oracle-vs-pool
///         divergence gate. Used typed at registration (loud) and via raw
///         staticcall at valuation (revert-free).
interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title  Erc20SpotAdapter
/// @notice First production `IPriceAdapter`: values plain ERC-20 spot holdings
///         (tokenized stocks and similar) held by a strategy, using
///         governance-registered Chainlink push feeds. Consumed by the
///         `PriceRouter` for `Position.kind == PositionKinds.ERC20_SPOT`.
///
///         UNIT CONVENTION (the precondition `PriceRouter`'s header says every
///         adapter must uphold): the returned `value` is denominated in this
///         adapter's `numeraire` token at `numeraireDecimals` — the vault asset
///         the router aggregates into `SyndicateVault.totalAssets()`. Every
///         registered feed MUST therefore quote `token` in `numeraire` terms
///         (e.g. TSLA/USDG when the vaults' asset is USDG). Deploy one adapter
///         per vault-asset numeraire; the deploy script must assert that every
///         consuming vault's `asset()` equals `numeraire`. As defense-in-depth
///         `value` additionally checks `IStrategy(holder).vault().asset() ==
///         numeraire` and fails closed on mismatch, so an honestly-misdeployed
///         wiring degrades to Lane B instead of aggregating mixed units.
///
///         FAIL-CLOSED CONTRACT: `value` NEVER reverts. Any doubt about
///         quantity, price, freshness, or units returns `(0, false)`, which the
///         router maps onto instant-ineligible (Lane B). Adversary: a strategy
///         publishing a poisoned position to make `totalAssets()` revert and
///         freeze exits — every external read below is a length-checked raw
///         staticcall so no venue or feed can force a revert into NAV reads.
///
///         VALUE vs EXECUTABILITY — why the per-token depth cap is published
///         here but NOT enforced here. `value` answers one question: what is
///         this position worth. It never sees an exit size; quantity is
///         `IERC20(venue).balanceOf(holder)`, so a cap enforced in this
///         function bounds the POSITION, not the exit, and the only lever it
///         has to enforce it is to declare the position unpriceable. Both ends
///         of that are worse than the risk it prices:
///           - Donation DoS. `balanceOf` is inflatable by anyone: a transfer to
///             the strategy raises it. `PriceRouter.valueStrategy` requires
///             EVERY position to be ok, so one slot pushed over its cap closes
///             Lane A — instant deposits AND instant exits — for the whole
///             vault until settlement. Adversary: a griefer donating ~$101 of
///             TSLA to a strategy holding $7,400 against the seeded $7,500 cap.
///             The donated tokens are swept to the vault at settle, so the
///             griefer's true cost is the time value of the transfer, and the
///             vault's LPs pay with a closed lane.
///           - No adversary required. A price rally past the cap, or a proposer
///             sizing a sleeve above it, closes Lane A with nobody attacking.
///         Clamping (`v = cap`) is NOT the alternative: it would UNDER-report
///         `totalAssets()`, and `SyndicateVault._deposit` mints Lane A shares
///         against that understated NAV — the same one-sided-mark wealth
///         transfer `PriceRouter.setHaircutBps` documents, trading a liveness
///         bug for a value-transfer bug. So value stays truthful and the size
///         bound moves to where exits are actually sized; the cap is published
///         by `instantCapAssets` for that consumer.
///
///         WHERE THE BOUND LIVES: `PortfolioStrategy.availableLiquidity`
///         (consumed by `SyndicateVault.maxWithdraw`) reads `instantCapAssets`
///         and caps instant-exit capacity so no single pro-rata unwind leg
///         exceeds its token's cap; a slot with no registered cap degrades that
///         strategy to idle-only capacity. Any future Lane A strategy must
///         apply the same bound in its own `availableLiquidity` — this adapter
///         publishes the number but cannot enforce it, because valuation never
///         sees an exit size.
contract Erc20SpotAdapter is Ownable, IPriceAdapter {
    /// @notice Per-token pricing config. Packs into two storage slots.
    /// @param aggregator       Chainlink AggregatorV3 proxy quoting token/numeraire.
    /// @param maxAge           Max accepted `updatedAt` age in seconds.
    /// @param feedDecimals     `aggregator.decimals()` snapshotted at registration;
    ///                         re-checked live at valuation (proxy-upgrade guard).
    /// @param tokenDecimals    `token.decimals()` snapshotted at registration;
    ///                         re-checked live at valuation.
    /// @param maxDivergenceBps Max accepted oracle-vs-pool divergence (bps).
    ///                         Meaningful only when `referencePool` is set.
    /// @param referencePool    Uniswap-v3-style token/numeraire pool whose spot
    ///                         gates the feed price. `address(0)` = gate off.
    /// @param capAssets        Per-token instant-EXIT depth bound in numeraire
    ///                         units: the most of this token that may be sold
    ///                         into one instant unwind. The router's
    ///                         `instantCap` is per-KIND; measured safe DEX
    ///                         depths differ ~13× across tokens (design D9b),
    ///                         so the per-token bound lives here. Registry data
    ///                         only — read via `instantCapAssets` by the
    ///                         consumer that sizes exits, NEVER enforced by
    ///                         `value` (see "VALUE vs EXECUTABILITY" above).
    struct FeedConfig {
        address aggregator;
        uint48 maxAge;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        uint16 maxDivergenceBps;
        address referencePool;
        uint96 capAssets;
    }

    /// @notice Floor for a registered `maxAge`. Blocks a fat-fingered bound so
    ///         tight (seconds) that Lane A would flap closed on every heartbeat
    ///         gap and read as a permanent outage rather than a config error.
    uint256 public constant MIN_FEED_MAX_AGE = 1 hours;
    /// @notice Cap for a registered `maxAge`. Adversary: an over-generous bound
    ///         (misconfig or captured owner) letting instant exits execute
    ///         against a price the market abandoned weeks ago, at remaining
    ///         LPs' expense. Mirrors `PortfolioStrategy.MAX_PUSH_PRICE_AGE_CAP`.
    uint256 public constant MAX_FEED_MAX_AGE = 30 days;
    /// @notice Max supported token/feed decimals. Bounds the `10 **` scaling
    ///         math well inside uint256 so exponentiation can never overflow.
    uint8 public constant MAX_SUPPORTED_DECIMALS = 36;

    /// @notice Averaging window for the reference pool's TWAP, in seconds.
    /// @dev    The divergence gate MUST NOT read an instantaneous price. `slot0`
    ///         is the endpoint of the last swap in the current block, so the
    ///         caller consuming the gate can set the value the gate checks
    ///         against — in the SAME transaction as their exit. Adversary: move
    ///         the pool onto a held/stale weekend equity mark, redeem at that
    ///         mark, move it back (a round trip costing ~2x the pool fee); or,
    ///         inverted, shove the pool off the mark to force `(0,false)` and
    ///         revert a victim's exit. A time-weighted average over this window
    ///         makes both directions cost sustained inventory risk across many
    ///         blocks instead of one atomic swap. Registration proves the pool
    ///         can actually serve the window (`observe` reverts `OLD` when its
    ///         observation buffer is shorter).
    uint32 public constant TWAP_WINDOW = 1800;

    /// @notice The vault asset every valuation is denominated in.
    address public immutable numeraire;
    /// @notice `numeraire.decimals()`, read once at deploy.
    uint8 public immutable numeraireDecimals;

    /// @notice token => registered feed config. Owner (governance) maintained;
    ///         `Position.ref` can NEVER select or override the feed. Adversary:
    ///         a malicious strategy pricing token X's real balance with token
    ///         Y's higher feed to inflate live NAV — feed selection is keyed by
    ///         the venue token alone, from this registry alone.
    mapping(address token => FeedConfig) public feedOf;

    /// @notice Bps denominator for the divergence bound.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    error ZeroAddress();
    error InvalidMaxAge();
    error InvalidDecimals();
    error InvalidCap();
    error InvalidDivergenceBound();
    error InvalidPool();

    event FeedSet(
        address indexed token,
        address indexed aggregator,
        uint256 maxAge,
        uint256 capAssets,
        address referencePool,
        uint256 maxDivergenceBps
    );
    event FeedRemoved(address indexed token);

    /// @param owner_     Governance owner of the feed registry. The adapter is
    ///                   deliberately non-upgradeable — it is replaceable
    ///                   wholesale via `PriceRouter.registerAdapter`.
    /// @param numeraire_ The vault asset valuations are denominated in.
    constructor(address owner_, address numeraire_) Ownable(owner_) {
        if (numeraire_ == address(0)) revert ZeroAddress();
        uint8 dec = IERC20Metadata(numeraire_).decimals();
        if (dec > MAX_SUPPORTED_DECIMALS) revert InvalidDecimals();
        numeraire = numeraire_;
        numeraireDecimals = dec;
    }

    // ── Registry (governance) ──

    /// @notice Register (or update) the feed pricing `token` in `numeraire`.
    /// @dev    Registration is loud where valuation is silent: bad config
    ///         reverts here so it can never be half-installed. Reads both
    ///         `decimals()` live and probes `latestRoundData()` so a wrong
    ///         address (EOA, non-feed contract) is rejected at wiring time.
    /// @param capAssets        Per-token instant-EXIT depth bound in numeraire
    ///                         units, published by `instantCapAssets` for the
    ///                         exit sizer — NOT a pricing guard (see "VALUE vs
    ///                         EXECUTABILITY" in the header). Required nonzero:
    ///                         every listed token has a measured depth, and a
    ///                         zero here reads as "no instant capacity" to the
    ///                         consumer; "unlimited" is expressed explicitly as
    ///                         a huge bound, never by omission.
    /// @param referencePool    Uniswap-v3-style token/numeraire pool for the
    ///                         divergence gate; `address(0)` disables the gate
    ///                         (valid for non-equity tokens whose feeds track
    ///                         continuously).
    /// @param maxDivergenceBps Divergence bound; required nonzero and ≤ 100%
    ///                         when the pool is set, required zero when off.
    function setFeed(
        address token,
        address aggregator,
        uint256 maxAge,
        uint256 capAssets,
        address referencePool,
        uint256 maxDivergenceBps
    ) external onlyOwner {
        if (token == address(0) || aggregator == address(0)) revert ZeroAddress();
        if (maxAge < MIN_FEED_MAX_AGE || maxAge > MAX_FEED_MAX_AGE) revert InvalidMaxAge();
        if (capAssets == 0 || capAssets > type(uint96).max) revert InvalidCap();
        uint8 tokenDec = IERC20Metadata(token).decimals();
        uint8 feedDec = IAggregatorV3(aggregator).decimals();
        if (tokenDec > MAX_SUPPORTED_DECIMALS || feedDec > MAX_SUPPORTED_DECIMALS) revert InvalidDecimals();
        // Shape probe: a non-feed target reverts registration here instead of
        // silently degrading every future valuation.
        IAggregatorV3(aggregator).latestRoundData();
        if (referencePool != address(0)) {
            if (maxDivergenceBps == 0 || maxDivergenceBps > BPS_DENOMINATOR) revert InvalidDivergenceBound();
            // The pool must be exactly the token/numeraire pair, or the gate
            // would compare the feed against an unrelated market.
            address t0 = IUniswapV3PoolMinimal(referencePool).token0();
            address t1 = IUniswapV3PoolMinimal(referencePool).token1();
            bool pairMatches = (t0 == token && t1 == numeraire) || (t0 == numeraire && t1 == token);
            if (!pairMatches) revert InvalidPool();
            // Prove the pool can actually serve the TWAP window NOW: a pool
            // whose observation buffer is shorter than `TWAP_WINDOW` reverts
            // `OLD` here, so an under-provisioned pool is rejected loudly at
            // registration instead of silently pinning its token to Lane B
            // forever. Governance must grow `observationCardinalityNext` first.
            uint32[] memory probe = new uint32[](2);
            probe[0] = TWAP_WINDOW;
            probe[1] = 0;
            IUniswapV3PoolMinimal(referencePool).observe(probe);
        } else if (maxDivergenceBps != 0) {
            revert InvalidDivergenceBound();
        }
        feedOf[token] = FeedConfig({
            aggregator: aggregator,
            maxAge: uint48(maxAge),
            feedDecimals: feedDec,
            tokenDecimals: tokenDec,
            maxDivergenceBps: uint16(maxDivergenceBps),
            referencePool: referencePool,
            capAssets: uint96(capAssets)
        });
        emit FeedSet(token, aggregator, maxAge, capAssets, referencePool, maxDivergenceBps);
    }

    /// @notice Delist a token: its positions immediately value `(0, false)` and
    ///         the router degrades any strategy holding it to Lane B.
    function removeFeed(address token) external onlyOwner {
        delete feedOf[token];
        emit FeedRemoved(token);
    }

    /// @notice The registered per-token instant-EXIT depth bound for `token`, in
    ///         numeraire units — the published half of the value/executability
    ///         split (see the header). The consumer that sizes instant exits
    ///         reads this and bounds capacity so that no single unwind leg
    ///         exceeds its token's measured depth.
    /// @dev    Zero means "unregistered": a consumer MUST read it as "no
    ///         instant-exit capacity for this token", never as "unlimited" —
    ///         `setFeed` rejects a zero cap, so a registered token always
    ///         publishes a positive bound. The numeraire itself is never
    ///         registered (it prices at par and needs no sale to be returned),
    ///         so a consumer must treat `token == numeraire` as uncapped rather
    ///         than reading a zero here.
    function instantCapAssets(address token) external view returns (uint256) {
        return feedOf[token].capAssets;
    }

    // ── Valuation ──

    /// @inheritdoc IPriceAdapter
    /// @dev View-only and revert-free. Quantity comes exclusively from
    ///      `IERC20(p.venue).balanceOf(holder)` — never from the strategy or
    ///      `ref`. Adversary per guard:
    ///        - kind mismatch: a router misregistration mapping a foreign kind
    ///          here would price non-spot semantics as spot; fail closed.
    ///        - non-empty `ref`: the only `ref` this adapter understands is
    ///          empty — anything else is an attempt to smuggle a feed locator
    ///          past the registry (or garbage), so it is instant-ineligible.
    ///        - numeraire binding: a holder whose vault asset != `numeraire`
    ///          would aggregate mixed units into `totalAssets()`; fail closed.
    ///        - registry miss / decimals drift / stale, incomplete, or
    ///          non-positive round: pricing doubt → `(0, false)`, Lane B.
    ///      Every guard here answers "can this be priced truthfully". Position
    ///      SIZE is not such a question and is not gated here — see "VALUE vs
    ///      EXECUTABILITY" in the header and `instantCapAssets`.
    function value(Position calldata p, address holder) external view returns (uint256, bool) {
        if (p.kind != PositionKinds.ERC20_SPOT) return (0, false);
        if (p.venue == address(0) || holder == address(0)) return (0, false);
        if (p.ref.length != 0) return (0, false);

        // Bind the valuation to the holder's vault asset (see header). Read
        // via raw staticcalls: a holder without the surface fails closed.
        if (!_holderAssetIsNumeraire(holder)) return (0, false);

        (bool okBal, uint256 bal) = _readBalance(p.venue, holder);
        if (!okBal) return (0, false);

        // The numeraire itself is the unit of account: its price is 1 by
        // definition, no feed entry required (resolves the design doc's USDG
        // open question).
        if (p.venue == numeraire) return (bal, true);

        FeedConfig memory cfg = feedOf[p.venue];
        if (cfg.aggregator == address(0)) return (0, false);

        // Live decimals re-check against the registration snapshot: a token or
        // feed proxy upgraded to a different scale would otherwise silently
        // mis-scale NAV by orders of magnitude.
        (bool okTd, uint256 liveTokenDec) = _readDecimals(p.venue);
        if (!okTd || liveTokenDec != cfg.tokenDecimals) return (0, false);
        (bool okFd, uint256 liveFeedDec) = _readDecimals(cfg.aggregator);
        if (!okFd || liveFeedDec != cfg.feedDecimals) return (0, false);

        (bool okPrice, uint256 price) = _readFreshPrice(cfg.aggregator, cfg.maxAge);
        if (!okPrice) return (0, false);

        (uint256 v, bool okScale) = _scale(bal, price, cfg.tokenDecimals, cfg.feedDecimals);
        if (!okScale) return (0, false);

        // NO per-token cap check here, deliberately (see "VALUE vs
        // EXECUTABILITY" in the header). `cfg.capAssets` bounds an EXIT and
        // this function never sees one, so enforcing it here would bound the
        // position instead — and enforcing it the only way `value` can, by
        // declaring the position unpriceable, lets a ~$101 donation close the
        // whole vault's Lane A. The bound is published by `instantCapAssets`
        // and belongs to the consumer that sizes exits.

        // Oracle-vs-pool divergence gate (design D9c). Adversary: 24/5 equity
        // feeds hold the last price over weekends while pools keep trading —
        // a held mark above executable price lets exiters harvest the basis,
        // and the 200bps fee ceiling cannot cover a stale-mark regime. A mark
        // diverging beyond the bound closes Lane A instead of mispricing it.
        if (cfg.referencePool != address(0)) {
            (bool okDiv, uint256 divBps) = _divergenceBps(cfg, p.venue, price);
            if (!okDiv || divBps > cfg.maxDivergenceBps) return (0, false);
        }

        return (v, true);
    }

    // ── Internal reads (revert-free) ──

    /// @dev True iff `holder` exposes `vault()` and that vault's `asset()` is
    ///      this adapter's numeraire. Both reads are raw staticcalls with
    ///      strict length + address-range checks so a hostile holder cannot
    ///      revert or type-confuse the valuation.
    function _holderAssetIsNumeraire(address holder) private view returns (bool) {
        (bool okV, address vault_) = _readAddress(holder, abi.encodeCall(IHolderStrategy.vault, ()));
        if (!okV || vault_ == address(0)) return false;
        (bool okA, address asset_) = _readAddress(vault_, abi.encodeCall(IVaultAsset.asset, ()));
        return okA && asset_ == numeraire;
    }

    /// @dev Staticcall-safe `balanceOf`. Codeless venue, revert, or malformed
    ///      return data all fail closed instead of bubbling into NAV reads.
    function _readBalance(address token, address holder) private view returns (bool, uint256) {
        if (token.code.length == 0) return (false, 0);
        (bool s, bytes memory d) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (holder)));
        if (!s || d.length != 32) return (false, 0);
        return (true, abi.decode(d, (uint256)));
    }

    /// @dev Staticcall-safe `decimals()`, decoded as a full word (no uint8
    ///      decode that could revert on dirty upper bits).
    function _readDecimals(address target) private view returns (bool, uint256) {
        if (target.code.length == 0) return (false, 0);
        (bool s, bytes memory d) = target.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!s || d.length != 32) return (false, 0);
        return (true, abi.decode(d, (uint256)));
    }

    /// @dev Staticcall-safe address read (strict 32-byte return, clean upper
    ///      96 bits) — used for the holder→vault→asset binding chain.
    function _readAddress(address target, bytes memory data) private view returns (bool, address) {
        if (target.code.length == 0) return (false, address(0));
        (bool s, bytes memory d) = target.staticcall(data);
        if (!s || d.length != 32) return (false, address(0));
        uint256 word = abi.decode(d, (uint256));
        if (word >> 160 != 0) return (false, address(0));
        return (true, address(uint160(word)));
    }

    /// @dev Staticcall-safe `latestRoundData` with the full freshness gauntlet.
    ///      All five words decode as uint256 (revert-free for any 160-byte
    ///      payload), then:
    ///        - `answer <= 0`: broken/paused feed must not price as free/short.
    ///        - `startedAt == 0`: round never started — incomplete round data.
    ///        - `answeredInRound < roundId`: answer carried over from a stale
    ///          round the aggregator has already superseded.
    ///        - `updatedAt` zero, in the future, or older than `maxAge`: a
    ///          stale or clock-skewed price lets instant exits execute at a
    ///          mark the market has moved away from.
    function _readFreshPrice(address aggregator, uint256 maxAge) private view returns (bool, uint256) {
        (bool s, bytes memory d) = aggregator.staticcall(abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!s || d.length != 160) return (false, 0);
        (uint256 roundId, uint256 rawAnswer, uint256 startedAt, uint256 updatedAt, uint256 answeredInRound) =
            abi.decode(d, (uint256, uint256, uint256, uint256, uint256));
        int256 answer = int256(rawAnswer);
        if (answer <= 0) return (false, 0);
        if (startedAt == 0) return (false, 0);
        if (answeredInRound < roundId) return (false, 0);
        if (updatedAt == 0 || updatedAt > block.timestamp) return (false, 0);
        if (block.timestamp - updatedAt > maxAge) return (false, 0);
        return (true, uint256(answer));
    }

    /// @dev value = bal × price × 10^numeraireDecimals / 10^(tokenDec+feedDec),
    ///      i.e. numeraire units at `numeraireDecimals`. Decimals are bounded
    ///      by `MAX_SUPPORTED_DECIMALS` (and live-checked equal to the
    ///      registration snapshot) so the exponents stay ≤ 10^72; the two
    ///      multiplications are overflow-guarded and fail closed — a venue
    ///      minting an absurd balance must degrade to Lane B, not revert NAV.
    function _scale(uint256 bal, uint256 price, uint8 tokenDec, uint8 feedDec) private view returns (uint256, bool) {
        uint256 e = uint256(tokenDec) + uint256(feedDec);
        uint256 nd = numeraireDecimals;
        if (bal != 0 && price > type(uint256).max / bal) return (0, false);
        uint256 raw = bal * price;
        if (e >= nd) {
            return (raw / 10 ** (e - nd), true);
        }
        uint256 up = 10 ** (nd - e);
        if (raw != 0 && up > type(uint256).max / raw) return (0, false);
        return (raw * up, true);
    }

    // ── Oracle-vs-pool divergence gate ──

    /// @dev |pool spot − oracle| in bps of the oracle price, both expressed as
    ///      numeraire raw units per whole token. Fails soft on any doubt:
    ///      unreadable pool, zero prices, or out-of-range magnitudes.
    function _divergenceBps(FeedConfig memory cfg, address token, uint256 price) private view returns (bool, uint256) {
        // Oracle price per whole token in numeraire raw units:
        //   oracleNum = price × 10^numeraireDecimals / 10^feedDecimals.
        uint256 nd = numeraireDecimals;
        uint256 fd = cfg.feedDecimals;
        uint256 oracleNum;
        if (nd >= fd) {
            uint256 up = 10 ** (nd - fd);
            if (price > type(uint256).max / up) return (false, 0);
            oracleNum = price * up;
        } else {
            oracleNum = price / 10 ** (fd - nd);
        }
        if (oracleNum == 0) return (false, 0);

        (bool okPool, uint256 poolNum) = _poolPrice(cfg.referencePool, token, cfg.tokenDecimals);
        if (!okPool || poolNum == 0) return (false, 0);

        uint256 diff = poolNum > oracleNum ? poolNum - oracleNum : oracleNum - poolNum;
        if (diff > type(uint256).max / BPS_DENOMINATOR) return (false, 0);
        return (true, (diff * BPS_DENOMINATOR) / oracleNum);
    }

    /// @dev Pool price in numeraire raw units per whole token, time-weighted
    ///      over `TWAP_WINDOW` via a raw `observe()` staticcall — NEVER the
    ///      instantaneous `slot0` (see `TWAP_WINDOW` for the adversary).
    ///      token0/token1 ordering follows the Uniswap invariant token0 <
    ///      token1, and registration proved the pair is exactly {token,
    ///      numeraire}, so the side is derived from the addresses alone — a
    ///      lying `token0()` cannot flip the quote direction. Decoding and the
    ///      checked arithmetic live in an external self-call so malformed
    ///      return data, an out-of-range tick, or an overflow on adversarial
    ///      magnitudes is caught and fails closed instead of reverting NAV.
    function _poolPrice(address pool, address token, uint8 tokenDec) private view returns (bool, uint256) {
        if (pool.code.length == 0) return (false, 0);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;
        (bool s, bytes memory d) = pool.staticcall(abi.encodeCall(IUniswapV3PoolMinimal.observe, (secondsAgos)));
        if (!s || d.length < 64) return (false, 0);
        bool tokenIsToken0 = token < numeraire;
        try this.poolTwapSpotPerWholeToken(d, tokenDec, tokenIsToken0) returns (uint256 spot) {
            return (spot != 0, spot);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Decode an `observe()` return payload and convert the resulting
    ///         time-weighted tick to numeraire raw units per whole token.
    ///         External ONLY so `_poolPrice` can contain decode/arithmetic
    ///         reverts in a try/catch (fail-closed contract); harmless to call
    ///         directly.
    /// @dev    Mirrors Uniswap's `OracleLibrary.consult` averaging: the mean
    ///         tick is the cumulative-tick delta over the window, floored
    ///         toward negative infinity so the average is never rounded up
    ///         into a friendlier price.
    function poolTwapSpotPerWholeToken(bytes memory observeReturn, uint8 tokenDec, bool tokenIsToken0)
        external
        pure
        returns (uint256)
    {
        (int56[] memory tickCumulatives,) = abi.decode(observeReturn, (int56[], uint160[]));
        require(tickCumulatives.length == 2, "bad observe arity");
        int56 window = int56(uint56(TWAP_WINDOW));
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 avg = delta / window;
        if (delta < 0 && delta % window != 0) avg--;
        require(avg >= TickMath.MIN_TICK && avg <= TickMath.MAX_TICK, "tick out of range");
        uint256 sqrtPriceX96 = uint256(TickMath.getSqrtRatioAtTick(int24(avg)));
        return _spotFromSqrtPrice(sqrtPriceX96, tokenDec, tokenIsToken0);
    }

    /// @notice Q64.96 → numeraire-raw-per-whole-token conversion. External
    ///         ONLY so `_poolPrice` can contain arithmetic overflow reverts in
    ///         a try/catch (fail-closed contract); harmless to call directly.
    /// @dev    price(token1 per token0, raw) = sqrtPriceX96² / 2^192. With the
    ///         supported bound sqrtPriceX96 < 2^128 (raw ratios beyond ~1.8e19
    ///         are out of scope and fail closed), ratioX128 = sqrtP² >> 64
    ///         fits uint256. token side:
    ///           token == token0: spot = ratioX128 × 10^tokenDec / 2^128
    ///           token == token1: spot = 10^tokenDec × 2^128 / ratioX128
    function poolSpotPerWholeToken(uint256 sqrtPriceX96, uint8 tokenDec, bool tokenIsToken0)
        external
        pure
        returns (uint256)
    {
        return _spotFromSqrtPrice(sqrtPriceX96, tokenDec, tokenIsToken0);
    }

    /// @dev Shared Q64.96 → numeraire-raw-per-whole-token conversion. Reverts
    ///      on out-of-range magnitudes; every caller reaches it through a
    ///      try/catch so a revert degrades to Lane B rather than reverting NAV.
    function _spotFromSqrtPrice(uint256 sqrtPriceX96, uint8 tokenDec, bool tokenIsToken0)
        private
        pure
        returns (uint256)
    {
        require(sqrtPriceX96 != 0 && sqrtPriceX96 < (1 << 128), "sqrtP out of range");
        uint256 ratioX128 = (sqrtPriceX96 * sqrtPriceX96) >> 64;
        if (tokenIsToken0) {
            return (ratioX128 * (10 ** tokenDec)) >> 128; // checked mul: overflow reverts → caught
        }
        require(ratioX128 != 0, "zero ratio");
        return ((10 ** tokenDec) << 128) / ratioX128;
    }
}
