// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WoodPoolFeedFixture} from "test/pricing/WoodPoolFeed.t.sol";

contract WoodPoolFeedFreshnessTest is WoodPoolFeedFixture {
    uint256 internal constant MAX_DELAY = WINDOW + 2 hours + 1; // RobinhoodParams.WOOD_FEED_MAX_DELAY

    function setUp() public {
        _deployFeed();
    }

    /// @notice A V3 crash that begins just before a roll moves the mark the
    ///         ledger still accepts as fresh, with no further roll.
    function test_aCrashJustBeforeARollIsTrackedBeforeTheNextRoll() public {
        _prime();
        assertApproxEqRel(_answer(), V2_ANSWER_X8, 1e13, "control: pre-crash mark");

        // WOOD crashes 4x on the V3 pool 60 s before the keeper's next roll, and stays there.
        _advance(WINDOW - 60);
        v3.setTicks(TICK_QUARTER_V2, TICK_QUARTER_V2);
        uint256 crashAt = vm.getBlockTimestamp();
        _advance(61);
        feed.update(); // the keeper rolls on time; only 61 s of the crash are in the stored span

        // A window minus one second later nothing has rolled, yet the crash already weighs in.
        _advance(WINDOW - 1);
        feed.update(); // no-op: span < window
        assertLe(vm.getBlockTimestamp() - _updatedAt(), MAX_DELAY, "the ledger accepts this reading as fresh");
        assertLt(_answer(), (V2_ANSWER_X8 * 3) / 4, "the crash is tracked, diluted over the span");

        // One second on, the far end is the post-crash snapshot and the mark IS the crash.
        _advance(1);
        assertGe(vm.getBlockTimestamp() - crashAt, WINDOW, "the crash has stood a full window");
        assertLe(vm.getBlockTimestamp() - _updatedAt(), MAX_DELAY, "still fresh");
        assertApproxEqRel(_answer(), QUARTER_ANSWER_X8, 1e15, "the mark is the pool's standing price");
    }
}
