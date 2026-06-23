// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkReader} from "../src/libraries/ChainlinkReader.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @dev External wrapper so vm.expectRevert can intercept ChainlinkReader reverts.
///      Internal library calls inline into the caller frame — expectRevert needs an
///      external call boundary to catch them.
contract ChainlinkReaderHarness {
    function readUsd(address feed, address seq, uint256 maxDelay, uint256 gracePeriod)
        external
        view
        returns (uint256 price, uint8 decimals)
    {
        return ChainlinkReader.readUsd(feed, seq, maxDelay, gracePeriod);
    }
}

contract LeveragedAeroValuationTest is Test {
    ChainlinkReaderHarness internal harness;

    function setUp() public {
        vm.warp(block.timestamp + 7 days);
        harness = new ChainlinkReaderHarness();
    }

    // --- ChainlinkReader tests ---

    function test_readUsd_returnsPriceAndDecimals() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 65_000e8); // cbBTC/USD
        MockAggregatorV3 seq = new MockAggregatorV3(0, 0); // sequencer up (answer 0)
        seq.setStartedAt(block.timestamp - 7200); // grace elapsed
        (uint256 p, uint8 d) = harness.readUsd(address(feed), address(seq), 26 hours, 3600);
        assertEq(p, 65_000e8);
        assertEq(d, 8);
    }

    function test_readUsd_revertsOnStale() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 65_000e8);
        feed.setUpdatedAt(block.timestamp - 27 hours);
        MockAggregatorV3 seq = _upSequencer();
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        harness.readUsd(address(feed), address(seq), 26 hours, 3600);
    }

    function test_readUsd_revertsWhenSequencerDown() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 65_000e8);
        MockAggregatorV3 seq = new MockAggregatorV3(0, 1); // answer 1 = down
        vm.expectRevert(ChainlinkReader.SequencerDown.selector);
        harness.readUsd(address(feed), address(seq), 26 hours, 3600);
    }

    function test_readUsd_revertsWithinGracePeriod() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 65_000e8);
        MockAggregatorV3 seq = new MockAggregatorV3(0, 0);
        seq.setStartedAt(block.timestamp - 100); // grace NOT elapsed
        vm.expectRevert(ChainlinkReader.GracePeriodNotOver.selector);
        harness.readUsd(address(feed), address(seq), 26 hours, 3600);
    }

    function test_readUsd_revertsOnIncompleteRound() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 65_000e8);
        feed.setAnsweredInRound(feed.roundId() - 1); // answeredInRound < roundId
        MockAggregatorV3 seq = _upSequencer();
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        harness.readUsd(address(feed), address(seq), 26 hours, 3600);
    }

    function test_readUsd_revertsOnNonPositiveAnswer() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 65_000e8);
        feed.setAnswer(0);
        MockAggregatorV3 seq = _upSequencer();
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        harness.readUsd(address(feed), address(seq), 26 hours, 3600);
    }

    function test_readUsd_revertsOnZeroStartedAt() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 65_000e8);
        feed.setStartedAt(0);
        MockAggregatorV3 seq = _upSequencer();
        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        harness.readUsd(address(feed), address(seq), 26 hours, 3600);
    }

    // --- helpers ---

    function _upSequencer() internal returns (MockAggregatorV3) {
        MockAggregatorV3 seq = new MockAggregatorV3(0, 0);
        seq.setStartedAt(block.timestamp - 7200); // well past any grace period
        return seq;
    }
}
