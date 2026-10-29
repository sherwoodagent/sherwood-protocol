// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {DeploySalts} from "../DeploySalts.sol";
import {RobinhoodParams} from "./RobinhoodParams.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {WoodV3TwapFeed, IEthUsdAggregator} from "../../src/pricing/WoodV3TwapFeed.sol";
import {IUniswapV3Pool} from "../../src/vendor/uniswap/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "../../src/vendor/uniswap/IUniswapV3Factory.sol";

interface IUniswapV3PoolObservations {
    function observations(uint256 index) external view returns (uint32, int56, uint160, bool initialized);
}

interface IUniswapV2PairSpot {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IWoodFeedLedger {
    function setWoodFeed(address feed, uint256 maxDelay) external;
    function setWoodUsdPrice(uint256 newPriceX8) external;
    function woodPriceX8() external view returns (uint256);
}

/**
 * @title  SwapWoodFeed
 * @notice SHE-398: replace the ledger's WOOD/USD source with `WoodV3TwapFeed`. Three
 *         broadcasts, in order: `growRing` (any key), `deployFeed` (the Create3Factory
 *         owner), then, a window later, `swap` (the ledger owner).
 * @dev    Addresses come from `chains/{chainId}.json`, numbers from `RobinhoodParams`.
 */
contract SwapWoodFeed is ScriptBase {
    string internal constant FEED_KEY = "WOOD_USD_TWAP_FEED";

    struct Params {
        address pool;
        address factory;
        address wood;
        address weth;
        address ethUsdFeed;
        address v2Pair;
        address ledger;
    }

    // ── Entry points ──

    function growRing() external {
        Params memory p = _params();
        vm.startBroadcast();
        growRingTo(p.pool, RobinhoodParams.WOOD_TWAP_RING);
        vm.stopBroadcast();
    }

    function deployFeed() external {
        Params memory p = _params();
        vm.startBroadcast();
        address feed = address(mintFeed(p));
        vm.stopBroadcast();
        _patchAddress(FEED_KEY, feed);
        console.log("WoodV3TwapFeed: %s (answers one window after the pool's oldest observation)", feed);
    }

    function swap() external {
        Params memory p = _params();
        WoodV3TwapFeed feed = WoodV3TwapFeed(_readAddress(FEED_KEY));
        vm.startBroadcast();
        uint256 capX8 = swapFeed(p, feed);
        vm.stopBroadcast();
        console.log("ledger WOOD feed swapped; cap seated at (X8): %s", capX8);
    }

    /// @notice Shadow run: one CSV line of the old feed, the new feed and V2 spot. Sends nothing.
    function compare() external view {
        Params memory p = _params();
        (uint256 oldX8, uint256 newX8, uint256 spotX8) =
            readBoth(p, _readAddress("WOOD_USD_FEED"), _readAddress(FEED_KEY));
        console.log("CSV,%s,%s,%s", block.timestamp, oldX8, string.concat(vm.toString(newX8), ",", vm.toString(spotX8)));
    }

    // ── Phases (public so the tests drive them) ──

    /// @notice Raise the pool's ring target to `target`, at most one transaction's worth per call.
    function growRingTo(address pool, uint16 target) public {
        (,,,, uint16 next,,) = IUniswapV3Pool(pool).slot0();
        while (next < target) {
            uint256 step = uint256(next) + RobinhoodParams.WOOD_TWAP_RING_GROW_PER_TX;
            // Bounded by `target`, a uint16.
            // forge-lint: disable-next-line(unsafe-typecast)
            next = step < target ? uint16(step) : target;
            IUniswapV3Pool(pool).increaseObservationCardinalityNext(next);
        }
    }

    /// @notice Pre-flights, then mint (or adopt) the feed at its CREATE3 address.
    function mintFeed(Params memory p) public returns (WoodV3TwapFeed feed) {
        preflightFeed(p);
        Create3Factory c3 = _c3Factory(msg.sender);
        bytes memory initcode = abi.encodePacked(
            type(WoodV3TwapFeed).creationCode,
            abi.encode(
                p.pool,
                p.wood,
                p.weth,
                p.ethUsdFeed,
                RobinhoodParams.ETH_USD_MAX_AGE,
                RobinhoodParams.WOOD_TWAP_WINDOW,
                _minV3Liquidity()
            )
        );
        feed = WoodV3TwapFeed(_c3(c3, DeploySalts.WOOD_USD_TWAP_FEED, initcode));
        _requireFeedMatches(p, feed);
    }

    /// @notice Point the ledger at `feed` and seat the cap at `CAP_OVER_SPOT_BPS` of its answer.
    /// @dev    The caller must own the ledger. The cap comes from the TWAP, not from spot.
    function swapFeed(Params memory p, WoodV3TwapFeed feed) public returns (uint256 capX8) {
        uint256 feedX8 = preflightSwap(p, feed);
        capX8 = (feedX8 * RobinhoodParams.CAP_OVER_SPOT_BPS) / 10_000;

        IWoodFeedLedger(p.ledger).setWoodFeed(address(feed), RobinhoodParams.WOOD_TWAP_FEED_MAX_DELAY);
        IWoodFeedLedger(p.ledger).setWoodUsdPrice(capX8);
        require(IWoodFeedLedger(p.ledger).woodPriceX8() != 0, "the ledger does not price WOOD after the swap");
    }

    /// @notice Both feeds' answers and V2 spot, at 8 decimals. A feed that reverts reads as 0.
    function readBoth(Params memory p, address oldFeed, address newFeed)
        public
        view
        returns (uint256 oldX8, uint256 newX8, uint256 spotX8)
    {
        return (_answerOrZero(oldFeed), _answerOrZero(newFeed), v2SpotX8(p));
    }

    // ── Pre-flights ──

    /// @notice Everything the feed's constructor cannot see: decimals, provenance, the ETH leg, the ring.
    function preflightFeed(Params memory p) public view {
        require(
            IERC20Metadata(p.wood).decimals() == IERC20Metadata(p.weth).decimals(),
            "PRE-FLIGHT: WOOD and WETH decimals differ - the feed does not normalise them"
        );

        IUniswapV3Pool pool = IUniswapV3Pool(p.pool);
        require(pool.factory() == p.factory, "PRE-FLIGHT: the pool names a different factory");
        require(
            IUniswapV3Factory(p.factory).getPool(pool.token0(), pool.token1(), pool.fee()) == p.pool,
            "PRE-FLIGHT: the booked factory does not know this pool"
        );
        require(pool.liquidity() >= _minV3Liquidity(), "PRE-FLIGHT: pool is below MIN_V3_LIQUIDITY");

        (, int256 answer,, uint256 updatedAt,) = IEthUsdAggregator(p.ethUsdFeed).latestRoundData();
        require(answer > 0, "PRE-FLIGHT: ETH/USD answer is not positive");
        require(block.timestamp <= updatedAt + RobinhoodParams.ETH_USD_MAX_AGE, "PRE-FLIGHT: ETH/USD round is too old");

        (,,,, uint16 ringTarget,,) = pool.slot0();
        require(
            ringTarget > RobinhoodParams.WOOD_TWAP_WINDOW, "PRE-FLIGHT: ring target below window + 1 - run growRing"
        );
        require(ringCannotEvict(p.pool), "PRE-FLIGHT: the ring wrapped at a smaller size - wait until it expands");
    }

    /// @notice The feed is the one this script mints, it answers, and its TWAP sits near V2 spot.
    function preflightSwap(Params memory p, WoodV3TwapFeed feed) public view returns (uint256 feedX8) {
        require(address(feed).code.length != 0, "PRE-FLIGHT: no feed at WOOD_USD_TWAP_FEED - run deployFeed");
        _requireFeedMatches(p, feed);
        require(ringCannotEvict(p.pool), "PRE-FLIGHT: the ring wrapped at a smaller size - wait until it expands");

        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            // The feed reverts on a non-positive price.
            // forge-lint: disable-next-line(unsafe-typecast)
            feedX8 = uint256(answer);
        } catch {
            revert("PRE-FLIGHT: the feed does not answer yet - one window after the pool's oldest observation");
        }

        uint256 spotX8 = v2SpotX8(p);
        uint256 gap = feedX8 > spotX8 ? feedX8 - spotX8 : spotX8 - feedX8;
        require(
            gap * 10_000 <= feedX8 * RobinhoodParams.MAX_FEED_SPOT_DEVIATION_BPS,
            "PRE-FLIGHT: the feed's TWAP and V2 spot disagree - a pump or a fall is in progress"
        );
    }

    /// @notice True when no write can overwrite an observation younger than the window.
    /// @dev    The ring's length reaches its target only when the index is on the last slot;
    ///         until then a ring that already wrapped keeps overwriting (PR #386 re-review, F1).
    function ringCannotEvict(address pool) public view returns (bool) {
        (,, uint16 index, uint16 length, uint16 target,,) = IUniswapV3Pool(pool).slot0();
        if (target <= RobinhoodParams.WOOD_TWAP_WINDOW) return false;
        if (length > RobinhoodParams.WOOD_TWAP_WINDOW) return true;
        (,,, bool nextWritten) = IUniswapV3PoolObservations(pool).observations((uint256(index) + 1) % length);
        // On the last slot the next write expands the ring instead of overwriting.
        return index == length - 1 || !nextWritten;
    }

    /// @notice WOOD/USD at 8 decimals off the V2 pair's reserves. A sanity reference, never a price.
    function v2SpotX8(Params memory p) public view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairSpot(p.v2Pair).getReserves();
        bool woodIsToken0 = IUniswapV2PairSpot(p.v2Pair).token0() == p.wood;
        (uint256 woodReserve, uint256 wethReserve) =
            woodIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        (, int256 answer,,,) = IEthUsdAggregator(p.ethUsdFeed).latestRoundData();
        require(answer > 0, "PRE-FLIGHT: ETH/USD answer is not positive");
        uint8 dec = IEthUsdAggregator(p.ethUsdFeed).decimals();
        // forge-lint: disable-next-line(unsafe-typecast)
        return (wethReserve * uint256(answer) * 1e8) / (woodReserve * 10 ** dec);
    }

    // ── Internals ──

    function _params() internal view returns (Params memory) {
        return Params({
            pool: _readAddress("WOOD_WETH_UNISWAP_V3_POOL"),
            factory: _readAddress("WOOD_WETH_UNISWAP_V3_FACTORY"),
            wood: _readAddress("WOOD_TOKEN"),
            weth: _readAddress("WETH"),
            ethUsdFeed: _readAddress("CHAINLINK_ETH_USD_FEED"),
            v2Pair: _readAddress("WOOD_WETH_V2_PAIR"),
            ledger: _readAddress("EXPOSURE_LEDGER")
        });
    }

    function _answerOrZero(address feed) internal view returns (uint256) {
        try IEthUsdAggregator(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return answer > 0 ? uint256(answer) : 0;
        } catch {
            return 0;
        }
    }

    function _minV3Liquidity() internal pure returns (uint128) {
        // A constant well under 2**128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(RobinhoodParams.MIN_V3_LIQUIDITY);
    }

    /// @dev CREATE3 adoption does not re-check bytecode, so the immutables are read back.
    function _requireFeedMatches(Params memory p, WoodV3TwapFeed feed) internal view {
        require(
            feed.pool() == p.pool && feed.wood() == p.wood && feed.weth() == p.weth && feed.ethUsdFeed() == p.ethUsdFeed
                && feed.window() == RobinhoodParams.WOOD_TWAP_WINDOW
                && feed.ethUsdMaxAge() == RobinhoodParams.ETH_USD_MAX_AGE && feed.minV3Liquidity() == _minV3Liquidity(),
            "PRE-FLIGHT: the feed's parameters are not the booked ones"
        );
    }
}
