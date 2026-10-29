// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WoodV3TwapFeed, IEthUsdAggregator} from "../../src/pricing/WoodV3TwapFeed.sol";
import {IUniswapV3Pool} from "../../src/vendor/uniswap/IUniswapV3Pool.sol";

interface IUniswapV3PoolSwap {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256, int256);
}

/// @notice `WoodV3TwapFeed` against the live WOOD/WETH V3 pool on chain 4663, with real swaps.
/// @dev Needs ROBINHOOD_RPC_URL; outside CI's path filter. About 13 minutes: growing the ring
///      reads every new slot over RPC.
contract WoodV3TwapFeedForkTest is Test {
    address constant WOOD = 0xF8BC08092C06dB6148114DCf82AF881F1085f92b;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V3_POOL = 0xF6831AaF374B353757F0dE6B3DD2a74697671C69;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    uint32 constant WINDOW = 1 hours;
    uint128 constant MIN_V3_LIQUIDITY = 1e22;
    /// @dev Looser than the deploy value: the warp ages the live Chainlink round.
    uint256 constant ETH_USD_MAX_AGE = 3 days;
    uint16 constant RING = uint16(WINDOW) + 60;
    /// @dev Each leg moves the pool about two ticks, so every swap is eligible to write.
    uint256 constant WETH_IN = 0.003e18;
    uint256 constant WOOD_IN = 2_200e18;
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    bool internal wethIsToken0;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "not Robinhood mainnet");
        wethIsToken0 = IUniswapV3Pool(V3_POOL).token0() == WETH;
        deal(WETH, address(this), 1_000e18);
        deal(WOOD, address(this), 100_000_000e18);
        return true;
    }

    function _newFeed() internal returns (WoodV3TwapFeed) {
        return new WoodV3TwapFeed(V3_POOL, WOOD, WETH, ETH_USD_FEED, ETH_USD_MAX_AGE, WINDOW, MIN_V3_LIQUIDITY);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == V3_POOL, "not the pool");
        // The positive delta is what the pool is owed.
        if (amount0Delta > 0) IERC20(IUniswapV3Pool(V3_POOL).token0()).transfer(V3_POOL, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IUniswapV3Pool(V3_POOL).token1()).transfer(V3_POOL, uint256(amount1Delta));
    }

    function _swap(bool wethIn) internal {
        bool zeroForOne = wethIn == wethIsToken0;
        IUniswapV3PoolSwap(V3_POOL)
            .swap(
                address(this),
                zeroForOne,
                int256(wethIn ? WETH_IN : WOOD_IN),
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                ""
            );
    }

    /// @dev `secs` seconds of the fastest possible writing: two tick-moving swaps
    ///      in two different blocks of every second.
    function _spam(uint256 secs) internal {
        for (uint256 i = 0; i < secs; i++) {
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.roll(vm.getBlockNumber() + 1);
            _swap(true);
            vm.roll(vm.getBlockNumber() + 1);
            _swap(false);
        }
    }

    /// @notice A ring grown past the window serves it through two swaps in every second.
    function test_fork_ringOfOneSlotPerSecondSurvivesSwapSpam() public {
        if (!_fork()) return;
        (,, uint16 startIndex,,,,) = IUniswapV3Pool(V3_POOL).slot0();
        IUniswapV3Pool(V3_POOL).increaseObservationCardinalityNext(RING);
        WoodV3TwapFeed feed = _newFeed();

        _spam(2 * uint256(WINDOW));

        (uint160 sqrtPriceX96,, uint16 index, uint16 cardinality,,,) = IUniswapV3Pool(V3_POOL).slot0();
        assertEq(cardinality, RING, "the ring reached its target");
        // 14,400 swaps in 7,200 seconds: per-block writing would land on 14400 % RING.
        assertEq(index, (startIndex + 2 * uint256(WINDOW)) % RING, "one write per second, not per block");

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, vm.getBlockTimestamp());

        // Independent of the feed's tick math: spot from sqrtPriceX96, in USD at 8 decimals.
        (, int256 ethUsd,,,) = IEthUsdAggregator(ETH_USD_FEED).latestRoundData();
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        uint256 spotX8 = wethIsToken0
            ? Math.mulDiv(uint256(ethUsd), 1 << 96, priceX96)
            : Math.mulDiv(uint256(ethUsd), priceX96, 1 << 96);
        assertApproxEqRel(uint256(answer), spotX8, 0.02e18, "the hour's mean sits at spot");
    }

    /// @notice Control: at the live ring target the feed refuses to deploy.
    function test_fork_control_theLiveRingRefusesTheFeed() public {
        if (!_fork()) return;
        (,,,, uint16 ringTarget,,) = IUniswapV3Pool(V3_POOL).slot0();
        assertLe(ringTarget, WINDOW, "the live ring was grown: this control no longer applies");

        vm.expectRevert(WoodV3TwapFeed.RingTooShort.selector);
        _newFeed();
    }
}
