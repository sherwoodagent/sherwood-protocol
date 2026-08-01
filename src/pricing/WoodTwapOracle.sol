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
 *         This contract exists to bound that number against something that
 *         tracks reality. It is admitted into the ledger ONLY through a `min`,
 *         so it may lower the WOOD price and never raise it:
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
 *         Unavailable is a SAFE state: the ledger skips the ceiling and falls
 *         through to its maintained fallback price.
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

    /// @dev Averaging window ceiling. Bounded on BOTH sides: an excessively
    ///      long window stops tracking a real drawdown, which is the entire
    ///      thing the ceiling exists to notice.
    uint256 public constant MAX_TWAP_WINDOW = 3 days;

    /// @dev Hard cap on the span `consult()` will average over, independent of
    ///      `twapWindow`. `update()` only ever widens a span (it snapshots once
    ///      at least `twapWindow` has passed, not exactly at it), so a keeper
    ///      outage produces a pair straddling days of history. Averaging across
    ///      that is not conservative, it is merely old — so the oracle reports
    ///      unavailable until two fresh snapshots re-establish a sane span.
    uint256 public constant MAX_TWAP_SPAN = 7 days;

    /// @dev Ceiling on `maxTwapAge`. Small values are safe (they only make the
    ///      oracle unavailable more readily); large ones are the dangerous
    ///      direction, because a snapshot nobody refreshed is exactly the state
    ///      where the ceiling stops reflecting the market.
    uint256 public constant MAX_SNAPSHOT_AGE_LIMIT = 1 days;

    /// @dev Ceiling on `ethUsdMaxDelay`. Sized to admit a slow, deviation-driven
    ///      heartbeat — the live 4663 ETH/USD feed was measured 10.7 HOURS old
    ///      while healthy on 2026-08-01 — without letting an operator disable
    ///      the staleness check outright by passing a decade.
    uint256 public constant MAX_ETH_USD_DELAY_LIMIT = 7 days;

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
    ///         unavailable. ALSO bounds how long the pair itself may have gone
    ///         untraded at snapshot time — see `_currentCumulative`.
    uint256 public maxTwapAge;
    /// @notice Staleness bound on the ETH/USD leg.
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

        _setTwapWindow(twapWindow_);
        _setMaxTwapAge(maxTwapAge_);
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

    function _setTwapWindow(uint256 newWindow) internal {
        if (newWindow < MIN_TWAP_WINDOW || newWindow > MAX_TWAP_WINDOW) revert InvalidParameter();
        emit TwapWindowSet(twapWindow, newWindow);
        twapWindow = newWindow;
    }

    function _setMaxTwapAge(uint256 newAge) internal {
        if (newAge == 0 || newAge > MAX_SNAPSHOT_AGE_LIMIT) revert InvalidParameter();
        emit MaxTwapAgeSet(maxTwapAge, newAge);
        maxTwapAge = newAge;
    }

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
    ///      `maxTwapAge` therefore bounds the pair's idleness at snapshot time
    ///      as well as the snapshot's own age.
    function _currentCumulative() internal view returns (uint256 cumulative, uint32 nowTs, bool ok) {
        // forge-lint: disable-next-line(unsafe-typecast)
        nowTs = uint32(block.timestamp);
        (uint112 r0, uint112 r1, uint32 tsLast) = IUniswapV2PairMinimal(pair).getReserves();
        if (r0 == 0 || r1 == 0) return (0, 0, false);

        uint32 idle;
        unchecked {
            idle = nowTs - tsLast;
        }
        if (idle > maxTwapAge) return (0, 0, false);

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

    /// @dev The USD leg, normalised to 8 decimals. Same degraded shapes and the
    ///      same tolerance as `ExposureLedger._woodPrice`: `code.length` first
    ///      (a high-level call to a codeless address reverts in THIS frame,
    ///      which `try` cannot catch), then a wrapped call, then non-positive
    ///      and stale. Every one of them reports unavailable rather than
    ///      reverting, so a sick ETH/USD feed costs the protocol its ceiling,
    ///      not its liveness.
    function _ethUsdX8() internal view returns (uint256 priceX8, bool ok) {
        address feed = ethUsdFeed;
        if (feed.code.length == 0) return (0, false);
        try IAggregatorMinimal(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return (0, false);
            uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
            if (age > ethUsdMaxDelay) return (0, false);
            // `answer > 0` checked above; the cast cannot change the value.
            // forge-lint: disable-next-line(unsafe-typecast)
            return ((uint256(answer) * 1e8) / (10 ** _ethUsdFeedDecimals), true);
        } catch {
            return (0, false);
        }
    }
}
