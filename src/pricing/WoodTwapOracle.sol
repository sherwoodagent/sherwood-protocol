// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWoodTwapOracle} from "../interfaces/IWoodTwapOracle.sol";

/// @dev The exact slice of `UniswapV2Pair` this oracle reads. The live pair
///      (`0xBF3BB81de6285b8310A028d1C2Cd38F9419d54C1` on chain 4663) was PROVEN
///      byte-identical to canonical `UniswapV2Pair` by CREATE2 derivation —
///      `CREATE2(factory 0x8bcE…937f, keccak(WETH‖WOOD), canonical init-code
///      hash 0x96e8ac42…845f)` reproduces the deployed address, and a CREATE2
///      address commits to the exact creation bytecode. So `_update` advancing
///      the accumulator once per block, the UQ112x112 encoding, and the 2^32
///      timestamp wrap are all standard here (design.md risks, task 1).
///      RE-RUN THAT DERIVATION IF THE PAIR ADDRESS EVER CHANGES.
interface IUniswapV2PairMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IAggregatorMinimal {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/**
 * @title  WoodTwapOracle
 * @notice Time-weighted WOOD/USD price derived from the WOOD/WETH
 *         Uniswap-V2-style pair on Robinhood Chain, converted to USD through
 *         the chain's ETH/USD Chainlink feed.
 *
 * @dev    WHAT THIS IS FOR, AND WHAT IT IS NOT FOR. There is no Chainlink
 *         WOOD/USD feed on chain 4663 and none is expected by launch, which
 *         left `ExposureLedger.woodUsdPriceX8` — a manually maintained scalar —
 *         as the *primary* valuation for every guardian bond. The dangerous
 *         failure of that arrangement is silent: a manual number sitting above
 *         market makes guardians look better collateralised than they are and
 *         clears `requireApproveQuorum` on collateral that does not exist.
 *
 *         Under the revision-2 design (`design-revision-2026-08-01.md`) this
 *         contract is the ledger's PRIMARY valuation whenever no Chainlink WOOD
 *         feed is wired, and `woodUsdPriceX8` is demoted to a pure CAP that is
 *         never served as a price. The TWAP is admitted ONLY through a `min`
 *         against that cap, so the market may lower the WOOD price and never
 *         raise it:
 *
 *           - TWAP pushed UP   → the `min` ignores it; the attack is inert.
 *           - TWAP pushed DOWN → bonds are valued lower and quorums get harder.
 *                                A denial-of-service with no payoff.
 *
 *         The pool is ~$437k total depth (measured 2026-08-01). Moving its spot
 *         price 2x costs ~$90.7k committed instantaneously plus a sustained
 *         arbitrage bleed for the whole averaging window. That is affordable
 *         enough that this must NEVER become an unbounded price source, and
 *         costly enough that the one-directional use is sound.
 *
 * @dev    THREE INDEPENDENT WAYS TO BECOME UNAVAILABLE, all of which report
 *         `ok == false` rather than reverting or serving a bad number:
 *           1. no completed observation pair, or one whose span sits outside
 *              [`twapWindow`, `MAX_TWAP_SPAN`];
 *           2. the newest snapshot older than `maxTwapAge`;
 *           3. the ETH/USD feed unset, codeless, reverting, non-positive or
 *              stale — the USD leg cannot be reconstructed from pair data.
 *
 *         UNAVAILABLE IS NO LONGER A FREE PASS. Revision 1 could fall through to
 *         a maintained fallback price; revision 2 deleted it, so an unavailable
 *         TWAP with no Chainlink WOOD feed makes `ExposureLedger._woodPrice`
 *         revert `NoWoodPrice`. That is still fail-SAFE rather than fail-open —
 *         `recordApproval` catches it and books nothing, while propose and
 *         execute halt — but it means this contract's liveness is now the
 *         protocol's liveness, and every bound below is sized with that in mind:
 *         each one must be tight enough to be meaningful and loose enough that a
 *         healthy chain never trips it.
 *
 * @dev    ══ ACCEPTED RISK: THE TWO LEGS DESCRIBE DIFFERENT PERIODS ══
 *
 *         This price is a product of two numbers that are NOT contemporaneous:
 *
 *           - the WOOD/ETH leg is a time-weighted average over `twapWindow`,
 *             ending at a snapshot at most `maxTwapAge` old — near-real-time;
 *           - the ETH/USD leg is a single Chainlink answer that may be up to
 *             one heartbeat old. The live 4663 feed was measured 10.7 HOURS
 *             old WHILE PERFECTLY HEALTHY, so this is the normal case, not a
 *             degraded one.
 *
 *         THE CONCRETE EXPOSURE. During an ETH drawdown inside that heartbeat,
 *         WOOD/ETH rises (WOOD falls less than ETH, or holds) while the stale,
 *         pre-drawdown ETH/USD price is still the multiplier. The product reads
 *         HIGH by roughly the size of the ETH move, and bonds are over-valued
 *         for the remainder of the heartbeat. NO ATTACKER CAPITAL IS REQUIRED —
 *         this is ordinary market movement against a slow feed, which makes it
 *         more likely than any manipulation scenario, not less.
 *
 *         WHY IT IS ACCEPTED RATHER THAN FIXED. The obvious remedy — require
 *         the ETH/USD answer to be no older than `twapWindow` — is
 *         UNSATISFIABLE against the measured heartbeat: it forces
 *         `twapWindow >= ~12h`, and a 12-hour averaging window means the oracle
 *         needs half a day to reflect a WOOD crash. That trade is strictly
 *         worse. A crash-tracking blind spot is unbounded in magnitude and
 *         lasts a fixed half-day; the staleness overstatement is bounded in
 *         magnitude by the ETH move and by the two controls below. The whole
 *         purpose of this contract is to track a drawdown without waiting on a
 *         human, and a 12-hour window gives most of that purpose back.
 *
 *         WHAT BOUNDS IT (both already exist, neither is new):
 *
 *           1. `ExposureLedger.woodUsdPriceX8` — the cap. The overstatement is
 *              admitted only through `min(source, cap)`, so anything above the
 *              cap is truncated outright. An ETH move large enough to matter is
 *              exactly the move likely to push the product past the cap.
 *           2. `ExposureLedger.woodHaircutBps` — the allowance. It discounts
 *              every price by a fixed factor, pre-funding headroom for an
 *              overstatement of that size. THIS PARAMETER IS NOW LOAD-BEARING:
 *              at its 10_000 default (no haircut) the allowance is ZERO. 5_000
 *              absorbs a 50% error. It is also the compensating control for the
 *              residual crash lag of up to `twapWindow + maxTwapAge`.
 *
 *         `ethUsdMaxDelay` is therefore bounded ONLY by
 *         `MAX_ETH_USD_DELAY_LIMIT` and is deliberately independent of
 *         `twapWindow`, so the window can be short. Owner decision 2026-08-02;
 *         see `design-revision-2026-08-01.md` finding 4.
 */
contract WoodTwapOracle is Ownable2Step, IWoodTwapOracle {
    /// @dev UQ112x112 scaling factor, the fixed-point format `UniswapV2Pair`
    ///      accumulates prices in.
    uint256 internal constant Q112 = 2 ** 112;

    /// @dev Averaging window floor. Manipulation cost scales with the window —
    ///      a window short enough to hold for a couple of blocks is bought for
    ///      the price of a single swap — so the setter may not shrink it below
    ///      an hour (design.md decision 3).
    uint256 public constant MIN_TWAP_WINDOW = 1 hours;

    /// @dev Ceiling on `maxTwapAge`. Small values are safe (they only make the
    ///      oracle unavailable more readily); large ones are the dangerous
    ///      direction, because a snapshot nobody refreshed is exactly the state
    ///      where the ceiling stops reflecting the market.
    uint256 public constant MAX_SNAPSHOT_AGE_LIMIT = 1 days;

    /// @dev Averaging window ceiling. Bounded on BOTH sides: an excessively
    ///      long window stops tracking a real drawdown, which is the entire
    ///      thing this oracle exists to notice.
    ///
    ///      TIED TO `MAX_SNAPSHOT_AGE_LIMIT` (finding 5). `consult()` requires
    ///      `span >= twapWindow` AND `age <= maxTwapAge`, and `maxTwapAge` can
    ///      never exceed `MAX_SNAPSHOT_AGE_LIMIT`. A window above that limit is
    ///      therefore not merely unusual, it is STRUCTURALLY UNSATISFIABLE:
    ///      `update()` refuses to roll a second snapshot before the window has
    ///      elapsed, by which point the first is already older than any legal
    ///      `maxTwapAge`. The old 3-day ceiling admitted exactly that
    ///      configuration and produced a permanently unavailable oracle with no
    ///      error to point at.
    uint256 public constant MAX_TWAP_WINDOW = MAX_SNAPSHOT_AGE_LIMIT;

    /// @dev Hard cap on the span `consult()` will average over, independent of
    ///      `twapWindow`. `update()` only ever widens a span (it snapshots once
    ///      at least `twapWindow` has passed, not exactly at it), so a keeper
    ///      outage produces a pair straddling days of history. Averaging across
    ///      that is not conservative, it is merely old — so the oracle reports
    ///      unavailable until two fresh snapshots re-establish a sane span.
    uint256 public constant MAX_TWAP_SPAN = 7 days;

    /// @dev Ceiling on `ethUsdMaxDelay`. Sized to admit a slow, deviation-driven
    ///      heartbeat — the live 4663 ETH/USD feed was measured 10.7 HOURS old
    ///      while healthy on 2026-08-01 — without letting an operator disable
    ///      the staleness check outright.
    ///
    ///      LOWERED 7 DAYS -> 24 HOURS. Staleness COMPOUNDS across the two legs:
    ///      `consult()` may serve a snapshot up to `maxTwapAge` old converted by
    ///      an ETH/USD answer up to `ethUsdMaxDelay` old, so the old pairing
    ///      admitted a "current" WOOD/USD price assembled from data up to eight
    ///      days stale. At 24 hours the compound bound is two days.
    ///
    ///      THIS IS A FLOOR, NOT A PREFERENCE. Going tighter than the measured
    ///      10.7-hour heartbeat would make the USD leg permanently unavailable
    ///      on a HEALTHY feed, which under design revision 2 is a protocol halt
    ///      rather than a skipped ceiling. 24 hours is the smallest value that
    ///      clears the heartbeat with margin. It is deliberately NOT tied to
    ///      `twapWindow` — see the ACCEPTED RISK note on the contract.
    uint256 public constant MAX_ETH_USD_DELAY_LIMIT = 1 days;

    /// @dev Upper bound on the ETH/USD feed's own `decimals()`, re-checked at
    ///      READ time rather than trusted from construction.
    ///      `_ethUsdFeedDecimals` is captured once from
    ///      `IAggregatorMinimal(ethUsdFeed_).decimals()` and is a `uint8`, so
    ///      nothing structurally stops it being 255 — and `10 ** 255` panics on
    ///      overflow.
    ///
    ///      THIS WAS ALREADY AN UNCATCHABLE REVERT BEFORE THE `staticcall`
    ///      REWRITE, and it is worth being precise about why, because the
    ///      intuitive reading is wrong. The exponentiation sat inside
    ///      `_ethUsdX8`'s `try` block, which looks like it was covered by the
    ///      adjacent `catch`. It was not: `catch` covers the EXTERNAL CALL
    ///      only, never the success-block body, which executes in this
    ///      contract's own frame. So a feed reporting absurd `decimals()`
    ///      panicked straight out of `consult()` even with the `try` in place —
    ///      a second, independent violation of the "reports `ok == false`
    ///      rather than reverting" contract, living beside the decode one that
    ///      audit #181 finding 22 describes. Verified by mutation: restoring
    ///      the typed `try` version fails
    ///      `test_ethUsdLeg_absurdFeedDecimals_reportsUnavailableInsteadOfReverting`
    ///      with `panic 0x11`, not with a graceful `ok == false`.
    ///
    ///      Mirrors `ExposureLedger.MAX_FEED_DECIMALS`, which re-checks for the
    ///      same reason.
    uint8 internal constant MAX_FEED_DECIMALS = 18;

    /// @dev How much of the averaging window a single extrapolated tail may
    ///      account for, as a divisor: `idle * MAX_IDLE_SPAN_DIVISOR <=
    ///      twapWindow`, i.e. at most `1/20` of the window.
    ///
    ///      WHY THE WINDOW AND NOT `maxTwapAge` (finding 8). `_currentCumulative`
    ///      fills the gap since the pair's last interaction at CURRENT SPOT.
    ///      Bounding that gap against `maxTwapAge` was vacuous, because
    ///      `maxTwapAge >= twapWindow`: a pair that had not traded for the whole
    ///      window passed the guard and produced a "TWAP" that was 100 % spot —
    ///      exactly reproducing the manipulable quantity while still reporting
    ///      `ok == true`. Exact accumulator math is not a defence when its
    ///      inputs are all spot.
    ///
    ///      WHY 20. Each of the two snapshots carries at most one tail, and the
    ///      difference `latest - prev` averaged over `span >= twapWindow` gives
    ///      each tail a weight of at most `idle / span <= 1/20`, so a
    ///      manipulator who owns both endpoints moves the average by at most
    ///      ~10 % — small enough that the `min` against the cap plus the
    ///      haircut absorbs it, and cheap enough to satisfy: at the 1-hour
    ///      minimum window the pair may be idle for 3 minutes, four times the
    ///      44 s idleness measured on the live pair, and at a 12-hour
    ///      production window for 36 minutes. Availability is not at risk from
    ///      a tight value either, because `update()` NO-OPS rather than
    ///      reverting when the guard bites, so a keeper simply snapshots on the
    ///      next block in which the pair has traded.
    uint256 public constant MAX_IDLE_SPAN_DIVISOR = 20;

    struct Observation {
        uint256 cumulative;
        uint32 timestamp;
    }

    /// @notice The WOOD/WETH pair, proven canonical `UniswapV2Pair` (see the
    ///         interface note above). Immutable: re-pointing an oracle at a
    ///         different pool would silently reinterpret the stored
    ///         accumulator, so a new pair means a new oracle and a deliberate
    ///         re-wire at the ledger.
    address public immutable pair;
    address public immutable wood;
    address public immutable weth;
    /// @notice Which side of the pair WOOD sits on, fixed at construction from
    ///         the pair's own `token0()`/`token1()`. Selects `price0` vs
    ///         `price1`: the accumulator we want is the price of WOOD
    ///         DENOMINATED IN WETH, which is `price1Cumulative` when WOOD is
    ///         token1. Getting this backwards would price WOOD at ~414,000 ETH
    ///         instead of ~0.0000024 ETH, so it is derived, never configured.
    bool public immutable woodIsToken0;
    address public immutable ethUsdFeed;
    uint8 internal immutable _ethUsdFeedDecimals;

    /// @notice Averaging window: the minimum span `update()` requires before it
    ///         rolls a new observation in, and the minimum span `consult()`
    ///         will price off.
    uint256 public twapWindow;
    /// @notice How stale the newest snapshot may be before the TWAP is reported
    ///         unavailable. Constrained to be at least `twapWindow`, since a
    ///         shorter age bound describes a window that can never be fresh.
    uint256 public maxTwapAge;
    /// @notice Staleness bound on the ETH/USD leg. INDEPENDENT of `twapWindow`
    ///         — this answer may legitimately be older than the average it
    ///         converts, because the live feed's healthy heartbeat is ~10.7h.
    ///         See the ACCEPTED RISK note on the contract.
    uint256 public ethUsdMaxDelay;

    /// @notice The two snapshots `consult()` averages between. `previous` is
    ///         the older; a zero `timestamp` on either means "no completed
    ///         window yet".
    Observation public previousObservation;
    Observation public latestObservation;

    constructor(
        address initialOwner,
        address pair_,
        address wood_,
        address weth_,
        address ethUsdFeed_,
        uint256 twapWindow_,
        uint256 maxTwapAge_,
        uint256 ethUsdMaxDelay_
    ) Ownable(initialOwner) {
        if (pair_ == address(0) || wood_ == address(0) || weth_ == address(0) || ethUsdFeed_ == address(0)) {
            revert ZeroAddress();
        }
        if (wood_ == weth_) revert InvalidParameter();

        pair = pair_;
        wood = wood_;
        weth = weth_;

        // Token ordering is DERIVED FROM THE PAIR, and the pair is required to
        // hold exactly {WOOD, WETH}. This is what stops a wrong or empty pool
        // being adopted by address alone: the four V3 WOOD/WETH pools on this
        // chain are initialised-but-never-traded shells whose `getPool` returns
        // a non-zero address, and the same class of mistake at V2 — a pair of
        // the right shape holding the wrong tokens — would price guardian
        // collateral off an unrelated market.
        address t0 = IUniswapV2PairMinimal(pair_).token0();
        address t1 = IUniswapV2PairMinimal(pair_).token1();
        if (t0 == wood_ && t1 == weth_) {
            woodIsToken0 = true;
        } else if (t0 == weth_ && t1 == wood_) {
            woodIsToken0 = false;
        } else {
            revert PairNotUsable();
        }

        ethUsdFeed = ethUsdFeed_;
        _ethUsdFeedDecimals = IAggregatorMinimal(ethUsdFeed_).decimals();

        // ORDER IS LOAD-BEARING, not stylistic. `twapWindow <= maxTwapAge`
        // (finding 5) is checked inside `_setTwapWindow` against the CURRENT
        // `maxTwapAge`, which is zero until seated — so `maxTwapAge` must land
        // FIRST or the comparison is made against a zero and passes vacuously.
        // Widest-first is that order.
        //
        // Constructing under the same guards the setters use is finding 5's
        // other half: the deploy could otherwise seat a pair that no setter
        // would ever accept, and nothing downstream revalidates it.
        //
        // `ethUsdMaxDelay` is order-independent — it is bounded only by
        // `MAX_ETH_USD_DELAY_LIMIT` and constrains nothing else (owner decision
        // 2026-08-02; see the ACCEPTED RISK note on the contract).
        _setMaxTwapAge(maxTwapAge_);
        _setTwapWindow(twapWindow_);
        _setEthUsdMaxDelay(ethUsdMaxDelay_);

        // Non-zero reserves and a live accumulator, asserted at construction
        // rather than assumed. A pool that has never traded accumulates
        // nothing, so its "TWAP" would be whatever spot the first swap sets.
        if (!validatePair()) revert PairNotUsable();
    }

    // ── Snapshotting ──

    /// @inheritdoc IWoodTwapOracle
    ///
    /// @dev NO-OP RATHER THAN REVERT on an early or unreadable call. A keeper
    ///      bot calling on a fixed schedule must not have its transaction
    ///      reverted by whoever happened to call one block earlier — reverting
    ///      would hand a griefer a way to make the honest keeper's calls fail,
    ///      and a failing keeper is how the oracle goes stale, which is the
    ///      state this whole design exists to avoid.
    ///
    ///      THE SPACING RULE IS WHAT GUARANTEES THE WINDOW. A snapshot is only
    ///      rolled in once `twapWindow` has elapsed since the last one, so the
    ///      `(previous, latest)` pair always spans at least the configured
    ///      window by construction. If `update()` instead always overwrote,
    ///      anyone could shrink the span to a single block for the price of two
    ///      calls, and either cheapen manipulation or knock the oracle offline.
    function update() external returns (bool recorded) {
        (uint256 cumulative, uint32 nowTs, bool ok) = _currentCumulative();
        if (!ok) return false;

        Observation memory latest = latestObservation;
        if (latest.timestamp == 0) {
            latestObservation = Observation({cumulative: cumulative, timestamp: nowTs});
            emit ObservationRecorded(cumulative, nowTs, 0);
            return true;
        }

        uint32 span;
        // `UniswapV2Pair` timestamps wrap at 2^32 and so do these; the wrapping
        // subtraction is the correct span for anything under ~136 years.
        unchecked {
            span = nowTs - latest.timestamp;
        }
        if (span < twapWindow) return false;

        previousObservation = latest;
        latestObservation = Observation({cumulative: cumulative, timestamp: nowTs});
        emit ObservationRecorded(cumulative, nowTs, span);
        return true;
    }

    // ── Reads ──

    /// @inheritdoc IWoodTwapOracle
    ///
    /// @dev PRICED OFF STORED SNAPSHOTS ONLY. It deliberately does not
    ///      extrapolate to the current block: doing so would blend live spot —
    ///      the manipulable quantity — into the answer, and the whole value of
    ///      this contract is that its number cannot be moved within one block.
    function consult() external view returns (uint256 twapUsdX8, bool ok) {
        Observation memory prev = previousObservation;
        Observation memory latest = latestObservation;
        if (prev.timestamp == 0 || latest.timestamp == 0) return (0, false);

        uint32 span;
        uint32 age;
        unchecked {
            span = latest.timestamp - prev.timestamp;
            // forge-lint: disable-next-line(unsafe-typecast)
            age = uint32(block.timestamp) - latest.timestamp;
        }
        if (span < twapWindow || span > MAX_TWAP_SPAN) return (0, false);
        if (age > maxTwapAge) return (0, false);

        uint256 avgX112;
        // The accumulator wraps at 2^256 in `UniswapV2Pair` (it adds
        // unchecked), so the difference must be taken unchecked to stay correct
        // across a wrap.
        unchecked {
            avgX112 = (latest.cumulative - prev.cumulative) / span;
        }
        if (avgX112 == 0) return (0, false);

        (uint256 ethUsdX8, bool ethOk) = _ethUsdX8();
        if (!ethOk) return (0, false);

        // `mulDiv` rather than `avgX112 * ethUsdX8 / Q112`: the product of a
        // UQ112x112 price and an 8-decimal USD figure can exceed 2^256 for a
        // high-priced token even though the quotient never does. Shifting first
        // is not an option either — WOOD is ~2.4e-6 ETH, so `avgX112 >> 112`
        // floors to zero and the price would read $0.
        twapUsdX8 = Math.mulDiv(avgX112, ethUsdX8, Q112);
        // A price that floors to zero at 8 decimals must NOT be served: the
        // ledger takes `min(source, ceiling)`, and a zero source would drag
        // every bond's valuation to nothing exactly as silently as the failure
        // this contract was built to remove.
        if (twapUsdX8 == 0) return (0, false);
        return (twapUsdX8, true);
    }

    /// @inheritdoc IWoodTwapOracle
    function validatePair() public view returns (bool) {
        address expected0 = woodIsToken0 ? wood : weth;
        address expected1 = woodIsToken0 ? weth : wood;
        if (IUniswapV2PairMinimal(pair).token0() != expected0) return false;
        if (IUniswapV2PairMinimal(pair).token1() != expected1) return false;
        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(pair).getReserves();
        if (r0 == 0 || r1 == 0) return false;
        return _storedCumulative() != 0;
    }

    // ── Owner setters ──

    function setTwapWindow(uint256 newWindow) external onlyOwner {
        _setTwapWindow(newWindow);
    }

    function setMaxTwapAge(uint256 newAge) external onlyOwner {
        _setMaxTwapAge(newAge);
    }

    function setEthUsdMaxDelay(uint256 newDelay) external onlyOwner {
        _setEthUsdMaxDelay(newDelay);
    }

    // ── Internals ──

    /// @dev ONE CROSS-CONSTRAINT, AND IT IS FINDING 5: `newWindow <=
    ///      maxTwapAge`. `consult()` demands a span of at least `twapWindow`
    ///      and an age of at most `maxTwapAge`, and `update()` will not roll a
    ///      second snapshot before the window elapses — so a window longer than
    ///      the age bound describes an oracle that can never be fresh and never
    ///      says why. Lengthening the window past `maxTwapAge` therefore
    ///      requires raising that first: one extra owner transaction, and it
    ///      cannot be got wrong silently.
    ///
    ///      DELIBERATELY NOT TIED TO `ethUsdMaxDelay`. An earlier revision
    ///      required `newWindow >= ethUsdMaxDelay` so the USD leg could never
    ///      be staler than the average it converts. Against the MEASURED 10.7-
    ///      hour ETH/USD heartbeat that forces a window of ~12 hours, which
    ///      costs the oracle half a day of crash-tracking — a strictly worse
    ///      exposure than the overstatement it prevented. The window must be
    ///      free to be SHORT. See the ACCEPTED RISK note on the contract.
    function _setTwapWindow(uint256 newWindow) internal {
        if (newWindow < MIN_TWAP_WINDOW || newWindow > MAX_TWAP_WINDOW) revert InvalidParameter();
        if (newWindow > maxTwapAge) revert InvalidParameter();
        emit TwapWindowSet(twapWindow, newWindow);
        twapWindow = newWindow;
    }

    /// @dev Refuses to drop below `twapWindow` — the other side of the finding-5
    ///      invariant, so the pair cannot be inverted by moving the age instead
    ///      of the window.
    function _setMaxTwapAge(uint256 newAge) internal {
        if (newAge == 0 || newAge > MAX_SNAPSHOT_AGE_LIMIT) revert InvalidParameter();
        if (newAge < twapWindow) revert InvalidParameter();
        emit MaxTwapAgeSet(maxTwapAge, newAge);
        maxTwapAge = newAge;
    }

    /// @dev BOUNDED ONLY BY `MAX_ETH_USD_DELAY_LIMIT`, independently of the
    ///      window. It has to admit the measured 10.7-hour heartbeat, and
    ///      coupling it to `twapWindow` would drag the window up with it. See
    ///      the ACCEPTED RISK note on the contract for what that costs and what
    ///      bounds it instead.
    function _setEthUsdMaxDelay(uint256 newDelay) internal {
        if (newDelay == 0 || newDelay > MAX_ETH_USD_DELAY_LIMIT) revert InvalidParameter();
        emit EthUsdMaxDelaySet(ethUsdMaxDelay, newDelay);
        ethUsdMaxDelay = newDelay;
    }

    function _storedCumulative() internal view returns (uint256) {
        return woodIsToken0
            ? IUniswapV2PairMinimal(pair).price0CumulativeLast()
            : IUniswapV2PairMinimal(pair).price1CumulativeLast();
    }

    /// @dev The pair's accumulator brought forward to this block, the same way
    ///      `UniswapV2OracleLibrary.currentCumulativePrices` does it: the pair
    ///      only advances its accumulator on the first interaction of a block,
    ///      so the gap since `blockTimestampLast` has to be filled in at the
    ///      current spot price.
    ///
    ///      THAT EXTRAPOLATION IS THE ONE PLACE SPOT LEAKS IN, and it is why a
    ///      quiet pair is refused rather than tolerated. On a pair traded every
    ///      few seconds (the live one was 44 s old when measured on 2026-08-01)
    ///      the filled-in tail is negligible. On a pair that has not traded for
    ///      hours the tail dominates and the "TWAP" quietly degrades into a spot
    ///      oracle — the manipulable quantity — while still looking healthy.
    ///
    ///      THE TAIL IS BOUNDED AGAINST THE SPAN, NOT AGAINST `maxTwapAge`
    ///      (finding 8). The original guard compared `idle` to `maxTwapAge`,
    ///      which is `>= twapWindow` by construction and so permitted a snapshot
    ///      whose ENTIRE contribution was extrapolated at spot. See
    ///      `MAX_IDLE_SPAN_DIVISOR` for the weight argument and the choice of 20.
    function _currentCumulative() internal view returns (uint256 cumulative, uint32 nowTs, bool ok) {
        // forge-lint: disable-next-line(unsafe-typecast)
        nowTs = uint32(block.timestamp);
        (uint112 r0, uint112 r1, uint32 tsLast) = IUniswapV2PairMinimal(pair).getReserves();
        if (r0 == 0 || r1 == 0) return (0, 0, false);

        uint32 idle;
        unchecked {
            idle = nowTs - tsLast;
        }
        // Widened to `uint256` before multiplying: `idle` is a `uint32` and the
        // divisor would overflow it for an idleness above ~6.8 years, which a
        // wrapped `tsLast` can produce.
        if (uint256(idle) * MAX_IDLE_SPAN_DIVISOR > twapWindow) return (0, 0, false);

        cumulative = _storedCumulative();
        if (idle != 0) {
            // UQ112x112 spot: the OTHER reserve over WOOD's reserve, i.e. the
            // price of one WOOD denominated in WETH.
            uint256 spotX112 = woodIsToken0 ? (uint256(r1) << 112) / r0 : (uint256(r0) << 112) / r1;
            // Matches the pair's own unchecked accumulation, wrap included.
            unchecked {
                cumulative += spotX112 * idle;
            }
        }
        return (cumulative, nowTs, true);
    }

    /// @dev The USD leg, normalised to 8 decimals. Structurally identical to
    ///      `ExposureLedger._feedPriceX8`, deliberately so: `code.length` first
    ///      (a high-level call to a codeless address reverts in THIS frame,
    ///      which `try` could not catch either), then a RAW `staticcall` with
    ///      an explicit returndata-length check and a wide-type decode, then
    ///      non-positive, stale, over-precision, and truncated-to-zero. Every
    ///      one of them reports unavailable rather than reverting, so a sick
    ///      ETH/USD feed costs this contract its answer rather than reverting
    ///      inside the ledger's price path.
    ///
    ///      The raw-`staticcall` shape is load-bearing, not stylistic. This
    ///      function previously used a typed `try ... returns (uint80, int256,
    ///      uint256, uint256, uint80)` and claimed parity with the ledger's
    ///      read while not having it: the declared `uint80`s are decoded after
    ///      the call succeeds, outside `catch`'s reach, so short or
    ///      dirty-padded returndata reverted uncatchably and broke the
    ///      never-reverts contract this comment asserts. See the decode note
    ///      inside the body and `MAX_FEED_DECIMALS`.
    ///
    /// @dev THE STALENESS BOUND IS `ethUsdMaxDelay` ALONE, and this answer may
    ///      therefore be OLDER THAN `twapWindow` — the two legs are not
    ///      contemporaneous, by design. That is the accepted risk documented on
    ///      the contract: bounding it here instead would force a ~12-hour
    ///      averaging window and cost the oracle half a day of crash tracking.
    ///      The overstatement it admits is bounded downstream by the ledger's
    ///      price cap and by `woodHaircutBps`.
    function _ethUsdX8() internal view returns (uint256 priceX8, bool ok) {
        address feed = ethUsdFeed;
        if (feed.code.length == 0) return (0, false);
        uint256 maxDelay = ethUsdMaxDelay;
        (bool success, bytes memory ret) = feed.staticcall(abi.encodeCall(IAggregatorMinimal.latestRoundData, ()));
        // latestRoundData returns (uint80, int256, uint256, uint256, uint80):
        // 5 words, 160 bytes. Short/absent data is rejected before any decode
        // is attempted.
        if (!success || ret.length < 160) return (0, false);
        // Decoded as uint256/int256 throughout, NOT the narrower uint80 the
        // interface declares. A sub-256-bit unsigned type is
        // validity-constrained at decode time (the ABI decoder rejects a word
        // whose unused high bits are not clean padding), and that decode runs
        // AFTER the call returns — outside any `catch`'s reach. A typed
        // `try ... returns (uint80, ...)` therefore cannot uphold this
        // function's documented "reports ok == false rather than reverting"
        // contract against a feed that answers with short or dirty-padded
        // data. uint256/int256 accept any 32-byte word, so nothing below this
        // line can revert on account of decoding. This is audit #181 finding
        // 22, whose fix landed in `ExposureLedger._feedPriceX8` and
        // `PortfolioStrategy._tryPushFeedPrice` but originally missed this
        // contract.
        (, int256 answer,, uint256 updatedAt,) = abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        if (answer <= 0) return (0, false);
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > maxDelay) return (0, false);
        // Bounded before the exponentiation: see `MAX_FEED_DECIMALS`. Without
        // this, a feed reporting an absurd `decimals()` makes
        // `10 ** _ethUsdFeedDecimals` overflow and panic. That was true of the
        // previous typed-`try` version too — `catch` never covered this line,
        // only the external call — so this closes a pre-existing hole rather
        // than compensating for one the rewrite opened.
        if (_ethUsdFeedDecimals > MAX_FEED_DECIMALS) return (0, false);
        // `answer > 0` checked above; the cast cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        priceX8 = (uint256(answer) * 1e8) / (10 ** _ethUsdFeedDecimals);
        // A source that truncated to zero is reported UNAVAILABLE rather than
        // as a healthy zero price, matching `_feedPriceX8`. `consult` already
        // rejects a zero product downstream; failing here is the same outcome
        // reached one step earlier and without claiming `ok` for a price that
        // is not one.
        return (priceX8, priceX8 != 0);
    }
}
