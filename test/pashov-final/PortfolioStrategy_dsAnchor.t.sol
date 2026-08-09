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

    /// @notice REPORT SELECTION IS THE ATTACK, and forward-only anchoring is what
    ///         removes it. `submitPriceReports` is permissionless and every report
    ///         it accepts is genuinely DON-signed — so the adversary does not
    ///         forge anything, they CHOOSE among true statements. Within the set
    ///         of still-unexpired reports they would pick the price that suits
    ///         them: the highest to depress a buy floor and sandwich the fill,
    ///         the lowest to push the floor out of reach and grief `execute`
    ///         until `executeBy` lapses.
    ///
    ///         Dating the anchor by `block.timestamp` made every unexpired report
    ///         look equally fresh, so the freshness gate could not tell them
    ///         apart. Dating by `observationsTimestamp` and never moving the
    ///         anchor backwards means the only thing a caller can do is advance it
    ///         to a fresher observation — the honest action.
    ///
    ///         IGNORED, NOT REVERTED. The older report is a valid submission that
    ///         simply loses; refusing it outright would let anyone revert a
    ///         pending `rebalanceDelta` by anchoring in front of it, which
    ///         `test_anchor_aStrangersRefreshCannotRevertTheProposersRebalance`
    ///         pins. What has to hold is that the attacker's price never becomes
    ///         the floor, and that is asserted on the stored anchor rather than on
    ///         the call's success.
    function test_anchor_ignoresAnOlderObservationThanAlreadyAnchored() public {
        // Foundry starts at timestamp 1; a negative observation skew below would
        // underflow rather than model an older report.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes[] memory fresh = new bytes[](3);
        fresh[0] = _signedReport(0, int192(int256(0.01e18)));
        fresh[1] = _signedReport(1, int192(int256(0.02e18)));
        fresh[2] = _signedReport(2, int192(int256(0.005e18)));
        strategy.submitPriceReports(fresh);

        (, uint256 anchoredAt) = strategy.priceAnchorOf(0);
        assertEq(anchoredAt, block.timestamp, "anchored at the observation time");

        // Same signature validity, same expiry window — only OLDER, and
        // carrying whatever price the attacker prefers.
        verifier.setObsSkew(-60);
        bytes[] memory stale = new bytes[](3);
        stale[0] = _signedReport(0, int192(int256(0.05e18)));
        stale[1] = _signedReport(1, int192(int256(0.02e18)));
        stale[2] = _signedReport(2, int192(int256(0.005e18)));

        strategy.submitPriceReports(stale);

        (uint256 price, uint256 at) = strategy.priceAnchorOf(0);
        assertEq(price, 0.01e18, "the cherry-picked older price must not become the anchor");
        assertEq(at, anchoredAt, "nor may its date rewind");
    }

    /// @notice `>=` IS DELIBERATE, AND THIS IS ITS ONLY PIN. Strictly backwards
    ///         is the attack; equal is not. `rebalanceDelta` routinely carries the
    ///         very report `submitPriceReports` just recorded, in the same block,
    ///         so an equal observation has to keep taking.
    ///
    ///         Worth a test of its own precisely because the guard no longer
    ///         reverts: tightening `>=` to `>` would fail nothing loudly, it would
    ///         silently stop the anchor tracking a re-sent report. So the
    ///         assertion has to be that the PRICE moved, which means the second
    ///         report has to carry a different one at the same timestamp.
    function test_anchor_equalObservationStillTakes() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes[] memory first = new bytes[](3);
        first[0] = _signedReport(0, int192(int256(0.01e18)));
        first[1] = _signedReport(1, int192(int256(0.02e18)));
        first[2] = _signedReport(2, int192(int256(0.005e18)));
        strategy.submitPriceReports(first);

        (uint256 price, uint256 at) = strategy.priceAnchorOf(0);
        assertEq(price, 0.01e18);
        assertEq(at, block.timestamp);

        // Same block, same observation time, different price.
        bytes[] memory second = new bytes[](3);
        second[0] = _signedReport(0, int192(int256(0.011e18)));
        second[1] = _signedReport(1, int192(int256(0.02e18)));
        second[2] = _signedReport(2, int192(int256(0.005e18)));
        strategy.submitPriceReports(second);

        (uint256 priceAfter, uint256 atAfter) = strategy.priceAnchorOf(0);
        assertEq(priceAfter, 0.011e18, "an equal observation must still update the anchor");
        assertEq(atAfter, at, "and leave its date where it was");
    }

    /// @notice A ZERO OBSERVATION IS NOT A DATE. `_lastGoodAt[i]` is documented as
    ///         zero exactly when `_lastGoodPrice[i]` is zero, and
    ///         `_staleSlippageBps` reads that invariant rather than re-deriving
    ///         it. Stamping `block.timestamp` kept it true by construction; dating
    ///         from a field of an external report does not, so the zero is refused
    ///         rather than allowed to pair a real price with a missing date —
    ///         which `_execute` would read as "no anchor" while the floors read it
    ///         as maximally stale and hand out the 30% band.
    function test_anchor_zeroObservationIsRefused() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        verifier.setObsSkew(-int256(vm.getBlockTimestamp())); // observation lands on 0

        bytes[] memory reports = new bytes[](3);
        reports[0] = _signedReport(0, int192(int256(0.01e18)));
        reports[1] = _signedReport(1, int192(int256(0.02e18)));
        reports[2] = _signedReport(2, int192(int256(0.005e18)));

        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        strategy.submitPriceReports(reports);

        (uint256 price, uint256 at) = strategy.priceAnchorOf(0);
        assertEq(price, 0, "no price may be recorded against a zero date");
        assertEq(at, 0, "and the slot stays unanchored");
    }

    /// @notice A FUTURE-DATED OBSERVATION IS CLAMPED, NOT REFUSED. The DON's
    ///         clock and an L2's `block.timestamp` are different clocks, and the
    ///         mock models exactly that skew. Refusing on `observationsTimestamp >
    ///         block.timestamp` would mean a seconds-wide lag makes every
    ///         submission revert — and since `_execute` will not deploy without a
    ///         fresh anchor, and only this path can supply one, that is a brick of
    ///         Data Streams mode rather than a degradation.
    ///
    ///         Same convention as `_pushFeedPrice`'s guarded subtraction, which
    ///         documents the identical case for a push feed: a feed clock ahead of
    ///         a lagging chain clock carries the freshest price there is.
    function test_anchor_futureDatedObservationIsClampedNotRefused() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        verifier.setObsSkew(30); // DON observed 30s "ahead" of this chain's clock

        bytes[] memory reports = new bytes[](3);
        reports[0] = _signedReport(0, int192(int256(0.01e18)));
        reports[1] = _signedReport(1, int192(int256(0.02e18)));
        reports[2] = _signedReport(2, int192(int256(0.005e18)));
        strategy.submitPriceReports(reports);

        (uint256 price, uint256 at) = strategy.priceAnchorOf(0);
        assertEq(price, 0.01e18, "a skewed report still anchors");
        assertEq(at, block.timestamp, "clamped to now, an anchor is never dated in the future");

        // And the clamped anchor is usable: no future date means no underflow and
        // no accidental immunity from `PRICE_ANCHOR_MAX_AGE_AT_EXECUTE`.
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(vault);
        strategy.execute();
        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Executed), "skew-clamped anchor executes");
    }

    /// @notice THE ANCHOR'S POSITION MUST NOT BE A WEAPON. `submitPriceReports` is
    ///         permissionless and Data Streams publishes continuously, so if a
    ///         backwards observation REVERTED, anyone watching the mempool could
    ///         advance the anchor in front of a pending `rebalanceDelta` and kill
    ///         it — every block, for the cost of one call, with nothing gained
    ///         except the proposer's gas. Skipping the write instead keeps the
    ///         anchor monotonic without handing out that lever.
    function test_anchor_aStrangersRefreshCannotRevertTheProposersRebalance() public {
        _executeStrategy();

        // A stranger lands a FRESHER observation than the report the proposer is
        // about to submit.
        vm.warp(vm.getBlockTimestamp() + 60);
        bytes[] memory fresher = new bytes[](3);
        fresher[0] = _signedReport(0, int192(int256(0.01e18)));
        fresher[1] = _signedReport(1, int192(int256(0.02e18)));
        fresher[2] = _signedReport(2, int192(int256(0.005e18)));
        vm.prank(makeAddr("frontRunner"));
        strategy.submitPriceReports(fresher);

        (, uint256 anchoredAt) = strategy.priceAnchorOf(0);
        assertEq(anchoredAt, block.timestamp, "the front-runner moved the anchor forward");

        // The proposer's own report — signed before that, still unexpired, now
        // older than the anchor.
        verifier.setObsSkew(-60);
        bytes[] memory proposerReports = new bytes[](3);
        proposerReports[0] = _signedReport(0, int192(int256(0.01e18)));
        proposerReports[1] = _signedReport(1, int192(int256(0.02e18)));
        proposerReports[2] = _signedReport(2, int192(int256(0.005e18)));

        vm.prank(proposer);
        strategy.rebalanceDelta(proposerReports);

        (, uint256 after_) = strategy.priceAnchorOf(0);
        assertEq(after_, anchoredAt, "and the older report still did not rewind the anchor");
    }

    /// @notice The anchor is dated by OBSERVATION, so a report that sat unsent
    ///         is judged on the age of its price rather than on how recently it
    ///         was relayed — which is what `PRICE_ANCHOR_MAX_AGE_AT_EXECUTE` and
    ///         `_staleSlippageBps` both need in order to mean anything.
    function test_anchor_isDatedByObservationNotSubmission() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        verifier.setObsSkew(-30);
        bytes[] memory reports = new bytes[](3);
        reports[0] = _signedReport(0, int192(int256(0.01e18)));
        reports[1] = _signedReport(1, int192(int256(0.02e18)));
        reports[2] = _signedReport(2, int192(int256(0.005e18)));
        strategy.submitPriceReports(reports);

        (, uint256 at) = strategy.priceAnchorOf(0);
        assertEq(at, block.timestamp - 30, "dated by the observation, not the transaction");
    }

    /// @notice THE PIN FOR #25. `submitPriceReports` is permissionless, so a
    ///         proposer cannot widen the band by simply declining to refresh —
    ///         any LP, guardian or keeper closes it instead.
    ///
    ///         Safe because `_verifyPrice` demands a DON signature through the
    ///         governance-bound verifier, a feed id matching THIS slot, an
    ///         unexpired report and a positive price, and then only ever moves the
    ///         anchor forward. The most an adversarial caller can do here is
    ///         advance it to a fresher truth.
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
    /// @dev    Pinned to the exact selector AND its arguments. This is the single
    ///         test standing behind "a valid report cannot be replayed into
    ///         another slot", so a bare `vm.expectRevert()` would let it keep
    ///         passing on an unrelated revert — a changed length check, an
    ///         arithmetic panic, a mock that stopped echoing the feed id.
    function test_finding25_reportCannotBeReplayedAcrossSlots() public {
        bytes[] memory reports = new bytes[](3);
        reports[0] = _signedReport(1, int192(int256(0.02e18))); // slot 1's feed in slot 0
        reports[1] = _signedReport(1, int192(int256(0.02e18)));
        reports[2] = _signedReport(2, int192(int256(0.005e18)));

        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.WrongFeedId.selector, uint256(0), strategy.feedIdOf(0), strategy.feedIdOf(1)
            )
        );
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
