// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {RobinhoodParams} from "./robinhood-mainnet/RobinhoodParams.sol";
import {Create3Factory} from "./utils/Create3Factory.sol";
import {WoodPoolFeed, IUniswapV2PairMinimal, IAggregatorMinimal} from "../src/pricing/WoodPoolFeed.sol";
import {IUniswapV3Pool} from "../src/vendor/uniswap/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "../src/vendor/uniswap/IUniswapV3Factory.sol";

/// @dev The largest `increaseObservationCardinalityNext(N)` one transaction can
///      carry: every new slot is initialised inside the call at ~22.4k gas, and
///      the chain's 32M transaction gas cap admits 1,437 of them. A larger ring
///      is reached by repeating the step.
uint16 constant MAX_GROW_PER_TX = 1_400;
/// @dev Gas per slot initialised, for the estimate the cardinality pre-flight
///      prints. Measured against the booked pool: N=200 -> 4.49M, N=1,000 ->
///      22.4M, N=1,437 -> 32.2M.
uint256 constant GAS_PER_OBSERVATION_SLOT = 22_400;

/**
 * @title  DeployWoodPoolFeed
 * @notice Mainnet WOOD price phase. An abstract mixin — `DeployAll` owns `run()`,
 *         the broadcast and the address book.
 *
 *         There is no Chainlink WOOD/USD feed on chain 4663. This contract is
 *         one: it reads WOOD priced in ETH off two WOOD/WETH venues — a
 *         Uniswap-V2-style pair's cumulative-price accumulators and a Uniswap V3
 *         pool's observation ring — takes the LOWER of the two long-window
 *         averages, and converts to USD through the chain's ETH/USD Chainlink
 *         feed. It is wired at the ledger with `setWoodFeed`, exactly like a real
 *         aggregator.
 *
 *         The feed answers only a full window AFTER its baseline snapshot, so the
 *         ceremony stops at `Checkpoint.AwaitingWoodFeed` until `_feedAnswers`
 *         turns true. A fork gets `ForkWoodFeedFixture` instead.
 *
 *         `GrowV3Cardinality` below is a SEPARATE, EARLIER ceremony step: the V3
 *         pool's observation ring must already span the window when this phase
 *         runs, and growing it is permissionless and not instant.
 *
 * @dev NOT OWNED. Every parameter is immutable, so there is no owner, no setter
 *      and no handoff: a different window, depth floor or venue means a new feed
 *      and a deliberate `setWoodFeed` at the ledger.
 */
abstract contract DeployWoodPoolFeed is ScriptBase {
    /// @dev Observations asked for beyond the window's own worth, so an
    ///      unusually busy stretch cannot clip the tail.
    uint256 constant CARDINALITY_SLACK = 10;

    /// @notice The `WOOD_FEED_MAX_DELAY` an operator should seat for a feed with
    ///         this window: a snapshot rolls at most once per window, so the
    ///         bound has to clear a whole window plus the keeper's cadence.
    function suggestedWoodFeedMaxDelay(uint256 window) public pure returns (uint256) {
        return window + RobinhoodParams.KEEPER_CADENCE_SLACK + 1;
    }

    /// @notice The `increaseObservationCardinalityNext(N)` a pool needs to hold a
    ///         whole `window` of history, and whether that N was cut down to what
    ///         one transaction can initialise.
    /// @dev    `capped == true` is not a smaller ask, it is a DIFFERENT claim: the
    ///         window needs more slots than `MAX_GROW_PER_TX`, so the ring has to
    ///         be grown in repeated steps and this N is only the first of them.
    ///         Either way the pre-flight below asks the pool itself rather than
    ///         trusting this number.
    function requiredCardinality(uint256 window_, uint256 writeInterval) public pure returns (uint16 n, bool capped) {
        require(writeInterval != 0, "PRE-FLIGHT: V3_WRITE_INTERVAL_SECONDS zero");
        uint256 needed = (window_ + writeInterval - 1) / writeInterval + CARDINALITY_SLACK;
        capped = needed > MAX_GROW_PER_TX;
        // Bounded by `MAX_GROW_PER_TX` on the capped branch; the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        n = capped ? MAX_GROW_PER_TX : uint16(needed);
    }

    /// @notice `MIN_V3_LIQUIDITY` narrowed to the width a pool reports liquidity
    ///         in.
    /// @dev    A silent truncation here WEAKENS the floor — 2**128 would wrap to
    ///         zero, i.e. no floor at all — so it is refused rather than clamped.
    function toMinV3Liquidity(uint256 raw) public pure returns (uint128) {
        require(raw <= type(uint128).max, "PRE-FLIGHT: MIN_V3_LIQUIDITY above uint128");
        // Bounded directly above; the cast cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(raw);
    }

    struct Params {
        address uniPair;
        address v3Pool;
        address v3Factory;
        address wood;
        address weth;
        address ethUsdFeed;
        uint256 window;
        uint256 ethUsdMaxAge;
        uint256 minWethReserve;
        uint128 minV3Liquidity;
    }

    /// @notice Pre-flights, mint (or adopt), first snapshot. Public so the tests can
    ///         drive the real thing without the process environment.
    /// @dev The caller must be the `Create3Factory` owner — `_c3Factory` bootstraps it
    ///      at `msg.sender`, exactly as `deployCore` does.
    function deploy(Params memory p) public returns (WoodPoolFeed feed) {
        _preflight(p);

        Create3Factory c3 = _c3Factory(msg.sender);
        // The constructor derives which side of each venue holds WOOD from the
        // venue itself, and refuses one that is not exactly {WOOD, WETH}.
        bytes memory initcode = abi.encodePacked(
            type(WoodPoolFeed).creationCode,
            abi.encode(
                p.uniPair,
                p.v3Pool,
                p.wood,
                p.weth,
                p.ethUsdFeed,
                p.ethUsdMaxAge,
                p.window,
                p.minWethReserve,
                p.minV3Liquidity
            )
        );
        bool fresh = _predict(c3, DeploySalts.WOOD_USD_FEED).code.length == 0;
        feed = WoodPoolFeed(_c3(c3, DeploySalts.WOOD_USD_FEED, initcode));

        // BASELINE ONLY, AND ONLY ON THE MINTING RUN, and only on the V2 leg.
        // `latestRoundData` still needs a SECOND snapshot a full window later (the
        // keeper's job); on a resumed run the feed is already primed and another
        // snapshot would roll it for no reason.
        if (fresh) feed.update();

        console.log("WoodPoolFeed:      %s", address(feed));
        console.log("uni pair:          %s", p.uniPair);
        console.log("v3 pool:           %s", p.v3Pool);
        console.log("window (s):        %s", p.window);
        console.log("minWethReserve:    %s", p.minWethReserve);
        console.log("minV3Liquidity:    %s", p.minV3Liquidity);

        // INSTANTANEOUS SPOT, FOR SIZING THE CAP ONLY — the manipulable quantity
        // the averaging exists to defeat, never a price. It is printed because the
        // operator's next decision is `WOOD_PRICE_CAP_X8`, which the runbook
        // requires to sit 1.25-2x ABOVE market.
        uint256 spotX8 = _spotWoodUsdX8(p, p.uniPair);
        console.log("spot WOOD/USD x8 (cap-sizing only, NOT a price): %s", spotX8);
        console.log("suggested WOOD_PRICE_CAP_X8 band 1.25-2x: %s .. %s", (spotX8 * 125) / 100, spotX8 * 2);

        console.log("\nNOTE: this deploy transaction's update() WRITES to the live V2 pair");
        console.log("      (permissionless sync()), it does not only read it. The V3 leg is");
        console.log("      read-only: it stores nothing here and needs no keeper.");
        console.log("\nNEXT, IN ORDER:");
        console.log("  1. Run the keeper: WoodPoolFeed.update(), permissionless, at least");
        console.log(
            "     once per window + %s s. That single call is the whole job:", RobinhoodParams.KEEPER_CADENCE_SLACK
        );
        console.log("     update() sync()s THE V2 PAIR itself, so a pair that has not traded");
        console.log("     still snapshots and the keeper never has to sync anything first.");
        console.log("     A snapshot ROLLS AT MOST ONCE PER WINDOW, so extra calls in");
        console.log("     between are no-ops for the feed's snapshots (each one still");
        console.log("     syncs the V2 pair) and updatedAt does not advance: a stale");
        console.log("     reading is NoWoodPrice, and nothing proposes.");
        console.log("  2. Wait for latestRoundData() to answer (needs a second snapshot");
        console.log("     one full window after the baseline this script just recorded).");
        console.log("  3. DeployPlanB with WOOD_USD_FEED=<above> and a WOOD_FEED_MAX_DELAY");
        console.log(
            "     that EXCEEDS window + %s s, i.e. above %s.",
            RobinhoodParams.KEEPER_CADENCE_SLACK,
            p.window + RobinhoodParams.KEEPER_CADENCE_SLACK
        );
        console.log("     Suggested WOOD_FEED_MAX_DELAY: %s", suggestedWoodFeedMaxDelay(p.window));
        console.log("     A tighter bound halts every read BETWEEN rolls, for up to a window.");
        console.log("     Pre-flight 8 enforces step 2; pre-flight 12 enforces this bound.");
    }

    // ── Pre-flights (all PRE-broadcast: fail before anything is deployed) ──

    function _preflight(Params memory p) internal view {
        require(p.uniPair != address(0), "PRE-FLIGHT: WOOD_WETH_V2_PAIR unset");
        require(p.v3Pool != address(0), "PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL unset");
        require(p.v3Factory != address(0), "PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_FACTORY unset");
        require(p.uniPair != p.v3Pool, "PRE-FLIGHT: the V2 pair and the V3 pool are the same address");
        require(p.wood != address(0), "PRE-FLIGHT: WOOD_TOKEN unset");
        require(p.weth != address(0), "PRE-FLIGHT: WETH unset");
        require(p.ethUsdFeed != address(0), "PRE-FLIGHT: CHAINLINK_ETH_USD_FEED unset");

        require(p.window >= 24 hours, "PRE-FLIGHT: TWAP_WINDOW below MIN_WINDOW (24h)");
        require(p.window <= 7 days, "PRE-FLIGHT: TWAP_WINDOW above MAX_SNAPSHOT_SPAN (7d)");
        require(p.ethUsdMaxAge != 0, "PRE-FLIGHT: ETH_USD_MAX_AGE zero");
        require(p.minWethReserve != 0, "PRE-FLIGHT: MIN_WETH_RESERVE zero");
        require(p.minV3Liquidity != 0, "PRE-FLIGHT: MIN_V3_LIQUIDITY zero");

        // WOOD AND WETH MUST SHARE A DECIMALS COUNT: the feed multiplies a raw
        // UQ112x112 ratio by ETH/USD with no decimals normalisation. That is the
        // pair's accumulator directly, and the V3 pool's tick once `_tickToX112`
        // has converted it to the same format.
        require(
            IERC20Metadata(p.wood).decimals() == IERC20Metadata(p.weth).decimals(),
            "PRE-FLIGHT: WOOD and WETH decimals differ - the feed does not normalise them"
        );

        _preflightPair(p, p.uniPair);
        _preflightV3Pool(p);
        _preflightEthLeg(p);
    }

    /// @dev The pair must hold exactly {WOOD, WETH}, clear the depth floor, and
    ///      be trading. The feed itself never needs a recent trade — `update()`
    ///      syncs the pair — but a pair with no trade in the last
    ///      `MAX_PAIR_IDLE` has no live market behind it, and the average of a
    ///      spot nobody is standing behind is a number, not a price. That is the
    ///      standing condition on a FORK, where the pools stop trading at the
    ///      fork point.
    function _preflightPair(Params memory p, address pair) internal view {
        address t0 = IUniswapV2PairMinimal(pair).token0();
        address t1 = IUniswapV2PairMinimal(pair).token1();
        require(
            (t0 == p.wood && t1 == p.weth) || (t0 == p.weth && t1 == p.wood),
            "PRE-FLIGHT: pair does not hold exactly {WOOD, WETH}"
        );

        (uint112 r0, uint112 r1, uint32 last) = IUniswapV2PairMinimal(pair).getReserves();
        require(r0 != 0 && r1 != 0, "PRE-FLIGHT: pair has a zero reserve");
        uint256 wethReserve = t0 == p.weth ? uint256(r0) : uint256(r1);
        require(wethReserve >= p.minWethReserve, "PRE-FLIGHT: pair is below MIN_WETH_RESERVE");

        uint256 idle = block.timestamp > last ? block.timestamp - uint256(last) : 0;
        require(
            idle <= RobinhoodParams.MAX_PAIR_IDLE,
            "PRE-FLIGHT: pair has no trade in the last 5m - no live market is standing behind "
            "it. On a fork/vnet the pool does not trade at all: generate swaps, or wire a plain "
            "Chainlink-shaped WOOD feed instead."
        );
    }

    /// @dev The V3 leg carries no reserves and no last-trade stamp: its depth is
    ///      the in-range liquidity standing behind the tick, and its liveness is
    ///      the observation ring, asked here rather than assumed.
    function _preflightV3Pool(Params memory p) internal view {
        require(p.v3Pool.code.length != 0, "PRE-FLIGHT: V3 pool has no code");

        address t0 = IUniswapV3Pool(p.v3Pool).token0();
        address t1 = IUniswapV3Pool(p.v3Pool).token1();
        require(
            (t0 == p.wood && t1 == p.weth) || (t0 == p.weth && t1 == p.wood),
            "PRE-FLIGHT: V3 pool does not hold exactly {WOOD, WETH}"
        );
        require(
            IUniswapV3Pool(p.v3Pool).liquidity() >= p.minV3Liquidity, "PRE-FLIGHT: V3 pool is below MIN_V3_LIQUIDITY"
        );

        // `fee()` answering is what separates a V3 pool from any contract that
        // happens to carry the two token getters.
        uint24 fee = IUniswapV3Pool(p.v3Pool).fee();
        console.log("v3 pool fee (1e-6):        %s", fee);

        // PROVENANCE, both directions. The operator is the party who can book the
        // wrong venue here, and the two-leg `min` is the manipulation control, so
        // a pool from some other deployment silently removes it.
        require(
            IUniswapV3Factory(p.v3Factory).getPool(t0, t1, fee) == p.v3Pool,
            "PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL is not the factory's pool for (WOOD, WETH, fee)"
        );
        require(
            IUniswapV3Pool(p.v3Pool).factory() == p.v3Factory,
            "PRE-FLIGHT: V3 pool does not name WOOD_WETH_UNISWAP_V3_FACTORY as its factory"
        );

        _preflightV3Cardinality(p);
    }

    /// @dev THE CHECK THE CEREMONY'S CARDINALITY STEP EXISTS FOR. A ring that
    ///      cannot serve `window` deploys a feed whose V3 leg reverts from every
    ///      read, i.e. no WOOD price at all. The remedy is printed FIRST, and
    ///      unconditionally, because it is also what an operator sizes
    ///      `V3_CARDINALITY` from on the happy path.
    function _preflightV3Cardinality(Params memory p) internal view {
        (,,, uint16 cardinality, uint16 cardinalityNext,,) = IUniswapV3Pool(p.v3Pool).slot0();
        uint256 writeInterval = RobinhoodParams.V3_WRITE_INTERVAL_SECONDS;
        (uint16 n, bool capped) = requiredCardinality(p.window, writeInterval);

        console.log("v3 observationCardinality: %s (next %s)", cardinality, cardinalityNext);
        console.log("required for a %s s window at one write per %s s: %s", p.window, writeInterval, n);
        console.log("  RE-MEASURE V3_WRITE_INTERVAL_SECONDS before the ceremony: binary-search");
        console.log("  observe([S, 0]) for the largest S that does not revert OLD, then divide");
        console.log("  by the pool's current cardinality. The ring stores one observation per");
        console.log("  BLOCK IN WHICH THE POOL IS TOUCHED, not per block.");
        if (capped) {
            console.log("  ^ THAT IS THE PER-TRANSACTION BOUND (%s), NOT THE DERIVATION. Every", n);
            console.log("    new slot is initialised inside increaseObservationCardinalityNext, so");
            console.log("    a larger N cannot be broadcast at all: grow in repeated steps.");
        }
        console.log("  remedy (permissionless): increaseObservationCardinalityNext(%s), i.e.", n);
        console.log("    V3_CARDINALITY=%s forge script script/DeployWoodPoolFeed.s.sol:GrowV3Cardinality \\", n);
        console.log("      --rpc-url robinhood --account sherwood-deployer --broadcast --slow");
        console.log(
            "    estimated gas for that call: ~%s (the GROWER pays it, up front)", uint256(n) * GAS_PER_OBSERVATION_SLOT
        );
        console.log("    then WAIT: `next` is a target the ring reaches only as the pool is traded.");

        // THE CURRENT ring, not the target: a ring of length one holds only the
        // live observation, and upstream's `observe` answers such a pool with
        // spot instead of reverting. The order is grow, then wait for writes,
        // then deploy.
        require(
            cardinality >= 2,
            "PRE-FLIGHT: V3 pool has no observation history (cardinality < 2); grow the ring and wait for writes"
        );

        uint32[] memory secondsAgos = new uint32[](2);
        // `p.window` is bounded by MAX_SNAPSHOT_SPAN (7d) above.
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsAgos[0] = uint32(p.window);
        try IUniswapV3Pool(p.v3Pool).observe(secondsAgos) returns (int56[] memory cumulatives, uint160[] memory) {
            require(cumulatives.length == 2, "PRE-FLIGHT: V3 pool cannot span TWAP_WINDOW");
        } catch {
            revert("PRE-FLIGHT: V3 pool cannot span TWAP_WINDOW");
        }
    }

    /// @dev The constructor reads only `decimals()` on the ETH leg. A feed that is
    ///      dead or negative constructs fine and then reverts from every read.
    function _preflightEthLeg(Params memory p) internal view {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(p.ethUsdFeed).latestRoundData();
        require(answer > 0, "PRE-FLIGHT: ETH/USD feed answer is not positive");
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        require(age <= p.ethUsdMaxAge, "PRE-FLIGHT: ETH/USD feed is already staler than ETH_USD_MAX_AGE");
    }

    /// @notice The cap the ledger bounds the governance WOOD price with sits 1.25-2x
    ///         ABOVE spot: below market it binds on every read, far above it bounds
    ///         nothing. Takes both figures so the caller names its own spot source.
    function _requireCapAboveSpot(uint256 capX8, uint256 spotX8) internal pure {
        require(spotX8 != 0, "PRE-FLIGHT: WOOD spot is zero");
        require(capX8 >= (spotX8 * 125) / 100, "PRE-FLIGHT: WOOD_PRICE_CAP_X8 is below 1.25x spot");
        require(capX8 <= spotX8 * 2, "PRE-FLIGHT: WOOD_PRICE_CAP_X8 is above 2x spot");
    }

    /// @notice The cap is sized off manipulable spot; this vouches that spot against the
    ///         24h TWAP it will bound. Run 1 mints a feed that does not answer yet and
    ///         discards its cap at the stage gate, so the no-answer case is a no-op.
    function _requireSpotNearFeed(address feed, uint256 spotX8) internal view {
        if (!_feedAnswers(feed)) return;
        (, int256 answer,,,) = IAggregatorMinimal(feed).latestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 twapX8 = uint256(answer);
        require(
            spotX8 <= twapX8 * 2 && twapX8 <= spotX8 * 2,
            "PRE-FLIGHT: WOOD spot diverges more than 2x from the feed TWAP"
        );
    }

    // ── Helpers ──

    /// @notice The stage gate: does this feed price yet? A freshly minted `WoodPoolFeed`
    ///         holds one snapshot and reverts `PriceUnavailable` until the keeper rolls
    ///         a second one a full window later.
    function _feedAnswers(address feed) internal view returns (bool) {
        if (feed == address(0) || feed.code.length == 0) return false;
        try IAggregatorMinimal(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            return answer > 0;
        } catch {
            return false;
        }
    }

    /// @dev Instantaneous spot, 8 decimals. Both tokens share a decimals count
    ///      (asserted in `_preflight`), so only the feed's own decimals scale.
    function _spotWoodUsdX8(Params memory p, address pair) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(pair).getReserves();
        bool woodIsToken0 = IUniswapV2PairMinimal(pair).token0() == p.wood;
        uint256 woodReserve = woodIsToken0 ? uint256(r0) : uint256(r1);
        uint256 wethReserve = woodIsToken0 ? uint256(r1) : uint256(r0);

        (, int256 answer,,,) = IAggregatorMinimal(p.ethUsdFeed).latestRoundData();
        uint8 dec = IAggregatorMinimal(p.ethUsdFeed).decimals();
        // `answer > 0` is asserted in `_preflightEthLeg`, so the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(answer);
        uint256 ethUsdX8 = dec >= 8 ? raw / (10 ** (uint256(dec) - 8)) : raw * (10 ** (8 - uint256(dec)));

        return (wethReserve * ethUsdX8) / woodReserve;
    }
}
