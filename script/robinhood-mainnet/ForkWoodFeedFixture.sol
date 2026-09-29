// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RobinhoodParams} from "./RobinhoodParams.sol";

/// @title  ForkWoodFeedFixture
/// @notice AggregatorV3-shaped WOOD/USD feed for the FORK ceremony, where the pools stop
///         trading at the fork point and no keeper can ever prime `WoodPoolFeed`.
///
/// @dev REFUSED ON 4663: a fixture feed on mainnet would price every guardian bond off a
///      number the deployer wrote. The price is DERIVED by the caller from the fork's own
///      pair reserves x ETH/USD (`DeployWoodPoolFeed._spotWoodUsdX8`), never invented.
///
///      `updatedAt` is `block.timestamp`, not a stored value, so the price survives the
///      time travel a governance traversal needs. Staleness is therefore untestable
///      through this feed — the real staleness gate is the Chainlink asset feeds.
///      Lives under script/ so the 96 KiB size gate ignores it.
contract ForkWoodFeedFixture {
    uint8 public constant decimals = 8;
    uint256 public constant version = 1;
    /// @notice WOOD/USD, 8 decimals, fixed at construction.
    int256 public immutable answer;

    constructor(uint256 priceX8) {
        require(block.chainid != RobinhoodParams.MAINNET_CHAIN_ID, "ForkWoodFeedFixture: refused on 4663");
        require(priceX8 != 0, "ForkWoodFeedFixture: price is zero");
        require(priceX8 <= uint256(type(int256).max), "ForkWoodFeedFixture: price out of range");
        // Bounded above, so the cast cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = int256(priceX8);
    }

    function description() external pure returns (string memory) {
        return "WOOD / USD (fork fixture)";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}
