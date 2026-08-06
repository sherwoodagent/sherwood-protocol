// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PortfolioStrategyTest} from "../PortfolioStrategy.t.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";

/// @title PortfolioStrategy — the Data Streams price anchor
/// @notice Audit findings #6 and #25. Both come from one structural fact: in
///         Data Streams mode the contract cannot fetch its own price.
///
///         In push mode `_sellFloor`/`_buyFloor` read the aggregator on every
///         swap and re-stamp the anchor, so it ages only during a real outage.
///         That whole block sits behind `chainlinkVerifier == address(0)`, so in
///         DS mode it is skipped and `_verifyPrice` — reachable only from the
///         proposer-only `rebalanceDelta` — was the sole writer. `execute()`,
///         `settle()` and `rebalance()` carry no report at all.
///
///         #6: the anchor is ZERO at `_execute`, so the buy floor degrades to
///         `_quoteMinOut` — a quote from the very pool the swap is about to hit,
///         on a permissionless entrypoint.
///         #25: after execute the anchor ages purely because the proposer
///         declines to refresh it, ramping the accepted loss toward 30%.
contract PashovFinalDsAnchorTest is PortfolioStrategyTest {
    // ── #6: capital must not move without an anchor ──

    /// @notice THE PIN. Deploying in DS mode with no anchor is refused, so the
    ///         buy floor can never fall through to a pool-quoted one.
    function test_finding6_executeRefusedWithoutAnAnchor() public {
        assertTrue(strategy.chainlinkVerifier() != address(0), "fixture must be in DS mode");
        (, uint256 recordedAt) = strategy.priceAnchorOf(0);
        assertEq(recordedAt, 0, "fixture already seeded an anchor, the branch could not show");

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(PortfolioStrategy.PriceAnchorMissingOrStale.selector, 0));
        strategy.execute();
    }

    /// @notice And with an anchor it proceeds — the guard is a precondition, not
    ///         a ban. Without this the test above would pass against a strategy
    ///         that refused every execute.
    function test_finding6_executeProceedsOnceAnchored() public {
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);

        _seedAnchors();
        vm.prank(vault);
        strategy.execute();
        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Executed), "anchored execute lands");
    }

    /// @notice An anchor older than the bound is refused too — the requirement
    ///         is freshness, not mere presence. A once-anchored clone left for a
    ///         day is exactly the #25 shape arriving at #6's door.
    function test_finding6_staleAnchorIsRefused() public {
        _seedAnchors();
        vm.warp(block.timestamp + strategy.PRICE_ANCHOR_MAX_AGE_AT_EXECUTE() + 1);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(PortfolioStrategy.PriceAnchorMissingOrStale.selector, 0));
        strategy.execute();
    }

    /// @notice The bound is inclusive at its edge, so an execution landing
    ///         exactly at the limit is not refused for being one second late.
    function test_finding6_anchorAtExactlyTheBoundIsAccepted() public {
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);

        _seedAnchors();
        vm.warp(block.timestamp + strategy.PRICE_ANCHOR_MAX_AGE_AT_EXECUTE());

        vm.prank(vault);
        strategy.execute();
        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Executed));
    }

    // ── #25: refreshing is not the proposer's private lever ──

    /// @notice THE PIN FOR #25. `submitPriceReports` is permissionless, so a
    ///         proposer cannot widen the band by simply declining to refresh —
    ///         any LP, guardian or keeper closes it instead.
    ///
    ///         Safe because `_verifyPrice` demands a DON signature through the
    ///         governance-bound verifier, a feed id matching THIS slot, an
    ///         unexpired report and a positive price. The most an adversarial
    ///         caller can do here is tell the truth on time.
    function test_finding25_anyoneCanRefreshTheAnchor() public {
        address stranger = makeAddr("passingKeeper");

        (, uint256 before_) = strategy.priceAnchorOf(0);
        assertEq(before_, 0, "precondition: unanchored");

        bytes[] memory reports = new bytes[](3);
        reports[0] = _signedReport(0, int192(int256(0.01e18)));
        reports[1] = _signedReport(1, int192(int256(0.02e18)));
        reports[2] = _signedReport(2, int192(int256(0.005e18)));

        vm.prank(stranger);
        strategy.submitPriceReports(reports);

        (uint256 price, uint256 at) = strategy.priceAnchorOf(0);
        assertEq(price, 0.01e18, "a stranger's report anchors the slot");
        assertEq(at, block.timestamp, "and stamps it now, so the band is tight");
    }

    /// @notice A report for the WRONG SLOT cannot be replayed into another's
    ///         anchor — the feed-id match is what makes the open door safe.
    function test_finding25_reportCannotBeReplayedAcrossSlots() public {
        bytes[] memory reports = new bytes[](3);
        reports[0] = _signedReport(1, int192(int256(0.02e18))); // slot 1's feed in slot 0
        reports[1] = _signedReport(1, int192(int256(0.02e18)));
        reports[2] = _signedReport(2, int192(int256(0.005e18)));

        vm.expectRevert();
        strategy.submitPriceReports(reports);
    }

    /// @notice Wrong array length is refused rather than partially applied, so a
    ///         caller cannot anchor a subset and leave the rest stale while
    ///         still clearing `_execute`'s per-slot check.
    function test_finding25_lengthMismatchIsRefused() public {
        bytes[] memory reports = new bytes[](2);
        reports[0] = _signedReport(0, int192(int256(0.01e18)));
        reports[1] = _signedReport(1, int192(int256(0.02e18)));

        vm.expectRevert(PortfolioStrategy.LengthMismatch.selector);
        strategy.submitPriceReports(reports);
    }

    /// @notice Push mode refuses reports outright. The contract reads its own
    ///         aggregator there, so a report is meaningless — and saying so
    ///         explicitly tells a caller the MODE is wrong rather than the
    ///         report.
    function test_finding25_pushModeRefusesReports() public {
        (PortfolioStrategy pushStrategy,,,) = _initPushStrategy();
        bytes[] memory reports = new bytes[](3);
        reports[0] = _signedReport(0, int192(int256(1e18)));
        reports[1] = _signedReport(1, int192(int256(1e18)));
        reports[2] = _signedReport(2, int192(int256(1e18)));

        vm.expectRevert(PortfolioStrategy.PushModeNeedsNoReports.selector);
        pushStrategy.submitPriceReports(reports);
    }

    /// @notice The discovery views the permissionless refresh needs. Without
    ///         them only whoever kept the init calldata could know which feed to
    ///         fetch, which would hand the proposer back the control the open
    ///         function exists to remove.
    function test_finding25_feedIdAndAnchorAreDiscoverable() public {
        assertEq(strategy.feedIdOf(0), keccak256(abi.encode("portfolio.feed", uint256(0))), "feed id is readable");

        _seedAnchors();
        (uint256 price, uint256 at) = strategy.priceAnchorOf(1);
        assertEq(price, 0.02e18);
        assertEq(at, block.timestamp);
    }
}
