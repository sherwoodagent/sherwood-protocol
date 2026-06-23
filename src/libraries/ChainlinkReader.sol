// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @notice Fail-closed Chainlink USD reads for Base: staleness + round-completeness
///         + L2 sequencer-uptime + grace period. (Hardens Mamo SlippagePriceChecker._readFeed,
///         which checks staleness only.)
library ChainlinkReader {
    error StaleOracle();
    error SequencerDown();
    error GracePeriodNotOver();

    function readUsd(address feed, address sequencerUptimeFeed, uint256 maxDelay, uint256 gracePeriod)
        internal
        view
        returns (uint256 price, uint8 decimals)
    {
        (, int256 up, uint256 seqStartedAt,,) = IAggregatorV3(sequencerUptimeFeed).latestRoundData();
        if (up != 0) revert SequencerDown();
        if (block.timestamp - seqStartedAt <= gracePeriod) revert GracePeriodNotOver();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert StaleOracle();
        if (answeredInRound < roundId) revert StaleOracle();
        if (startedAt == 0) revert StaleOracle();
        if (block.timestamp - updatedAt > maxDelay) revert StaleOracle();

        price = uint256(answer);
        decimals = IAggregatorV3(feed).decimals();
    }
}
