// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Vnet-only Chainlink aggregator stand-in. Deployed once per feed with
///         the real feed's last answer/decimals baked as immutables, then its
///         RUNTIME code is copied onto the canonical feed address via
///         `tenderly_setCode`. Storage-free (immutables only) so it works at any
///         address. `updatedAt` tracks block.timestamp, so the feed never goes
///         stale no matter how far the vnet clock advances. For the sequencer
///         uptime feed use answer=0 (up) — `startedAt` is 30 days old so any
///         grace-period check passes.
contract FreshFeed {
    int256 private immutable ANSWER;
    uint8 private immutable DECIMALS;

    constructor(int256 answer_, uint8 decimals_) {
        ANSWER = answer_;
        DECIMALS = decimals_;
    }

    function decimals() external view returns (uint8) {
        return DECIMALS;
    }

    function description() external pure returns (string memory) {
        return "vnet FreshFeed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestAnswer() external view returns (int256) {
        return ANSWER;
    }

    function latestTimestamp() external view returns (uint256) {
        return block.timestamp - 60;
    }

    function latestRound() external pure returns (uint256) {
        return 1000;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1000, ANSWER, block.timestamp - 30 days, block.timestamp - 60, 1000);
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1000, ANSWER, block.timestamp - 30 days, block.timestamp - 60, 1000);
    }
}
