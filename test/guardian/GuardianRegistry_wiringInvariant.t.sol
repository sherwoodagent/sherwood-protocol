// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";

/// @notice Regression tests for audit issue #181, finding #26 (confidence 72):
///
///         `ExposureLedger.setChallengeWindow`, `ExposureLedger
///         .setGuardianRegistry`, and `GuardianRegistry.setReviewPeriod` all
///         enforce `ledger.challengeWindow() >= reviewPeriod +
///         MAX_GOVERNOR_EXECUTION_WINDOW` -- the anti-batching floor described
///         in `ExposureLedger.setChallengeWindow`'s natspec (a challenge
///         window shorter than the approve->execute gap lets one guardian
///         bond cover two live drains). `GuardianRegistry.setExposureLedger`
///         was the fourth door on that same invariant and, before this fix,
///         enforced nothing at all: a zero check, an assignment, no floor
///         read, no event.
///
///         Reachable order (mirrors the audit's own PoC): raise
///         `reviewPeriod` to 7 days while `exposureLedger == address(0)`
///         (`setReviewPeriod`'s cross-check short-circuits on the null
///         ledger), then wire a ledger whose `challengeWindow` sits below the
///         resulting 14-day floor. Nothing revalidates the pair after that --
///         live state under-floors the challenge window against the
///         review-execute gap it exists to outlive.
///
///         Also covers the reciprocal-grant safeguard added alongside the
///         floor check: a ledger already bound (via `setGuardianRegistry`) to
///         some OTHER registry must be rejected, because
///         `ExposureLedger.recordApproval` is `onlyRegistry` and a one-sided
///         re-point would make every future approve-side vote from this
///         registry revert forever. An UNWIRED ledger (`guardianRegistry() ==
///         address(0)`) must still be accepted -- that is the ordinary
///         first-time-wiring case and must not be bricked by the new check.
contract GuardianRegistry_wiringInvariantTest is RegistryTestHarness {
    uint256 internal constant INITIAL_REVIEW_PERIOD = 1 days;
    /// @dev The registry's absolute `reviewPeriod` ceiling. The raise below
    ///      must stay inside it, so this tracks that bound.
    uint256 internal constant RAISED_REVIEW_PERIOD = 3 days;
    uint256 internal constant BLOCK_QUORUM_BPS = 2000;
    /// @dev Mirrors `GuardianRegistry.MAX_GOVERNOR_EXECUTION_WINDOW` /
    ///      `ExposureLedger.MAX_GOVERNOR_EXECUTION_WINDOW` (both `internal`,
    ///      so not readable from the test contract) -- duplicated here the
    ///      same way the two contracts duplicate it from each other.
    uint256 internal constant MAX_GOVERNOR_EXECUTION_WINDOW = 7 days;

    address internal ledgerOwner = makeAddr("ledgerOwner");

    function setUp() public {
        _deployRegistryAndSwood(INITIAL_REVIEW_PERIOD, BLOCK_QUORUM_BPS);
    }

    /// @notice Core finding #26: wiring a ledger whose `challengeWindow` sits
    ///         below `reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW` must
    ///         revert. Against the OLD (unfixed) `setExposureLedger` this
    ///         call succeeds silently -- the assertion below then fails
    ///         because no revert occurred. Against the fix it reverts with
    ///         `InvalidParameter`.
    function test_setExposureLedger_revertsWhenChallengeWindowBelowReviewPeriodFloor() public {
        // Raise reviewPeriod to 3 days while the ledger is still unwired --
        // `setReviewPeriod`'s ledger cross-check short-circuits on
        // `exposureLedger == address(0)`, so this legitimately succeeds and
        // leaves the floor at 3d + 7d = 10d for whatever ledger comes next.
        vm.prank(regOwner);
        registry.setReviewPeriod(RAISED_REVIEW_PERIOD);

        ExposureLedger ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        // Ledger is still unwired to any registry, so `setChallengeWindow`'s
        // own floor check is skipped (`reg == address(0)`) -- this shrink is
        // legal purely from the ledger's own point of view.
        uint256 belowFloor = RAISED_REVIEW_PERIOD + MAX_GOVERNOR_EXECUTION_WINDOW - 1;
        vm.prank(ledgerOwner);
        ledger.setChallengeWindow(belowFloor);

        // `belowFloor` is exactly one second short of `reviewPeriod +
        // MAX_GOVERNOR_EXECUTION_WINDOW` (3d + 7d = 10d): wiring this ledger
        // into the registry must be refused.
        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        registry.setExposureLedger(address(ledger));

        assertEq(
            address(registry.exposureLedger()),
            address(0),
            "a ledger that under-floors the challenge window must never get wired in"
        );
    }

    /// @notice A ledger already bound to a DIFFERENT registry must be
    ///         rejected even though its `challengeWindow` clears the floor --
    ///         wiring it in would make every future `recordApproval` call
    ///         from THIS registry revert (`onlyRegistry`), silently turning
    ///         every review block-only. Against the OLD code this call
    ///         succeeds (no reciprocal check existed at all).
    function test_setExposureLedger_revertsWhenLedgerBoundToDifferentRegistry() public {
        ExposureLedger ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        // Default challengeWindow (14 days) clears the 1d + 7d = 8d floor
        // for this harness's INITIAL_REVIEW_PERIOD, so the floor check is not
        // what trips this test.
        address someOtherRegistry = makeAddr("someOtherRegistry");
        // `someOtherRegistry` has no code, so `setGuardianRegistry`'s own
        // tolerant `code.length != 0` guard skips its floor re-check and lets
        // the (wrong) pointer through -- exactly the ordering mistake this
        // registry-side check exists to catch on the other end.
        vm.prank(ledgerOwner);
        ledger.setGuardianRegistry(someOtherRegistry);

        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        registry.setExposureLedger(address(ledger));

        assertEq(
            address(registry.exposureLedger()),
            address(0),
            "a ledger bound to a different registry must never get wired in"
        );
    }

    /// @notice Sanity: the new checks must NOT brick the ordinary,
    ///         legitimate first-time wiring order -- a fresh ledger, never
    ///         pointed at any registry, with a challengeWindow that clears
    ///         the floor, wires in cleanly and emits `ExposureLedgerSet`.
    function test_setExposureLedger_succeedsOnLegitimateFirstTimeWiring() public {
        ExposureLedger ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        // Default challengeWindow (14 days) >= 3d + 7d = 10d floor.
        // `ledger.guardianRegistry()` is still address(0) -- the untouched,
        // ordinary pre-wiring state.

        vm.prank(regOwner);
        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.ExposureLedgerSet(address(0), address(ledger));
        registry.setExposureLedger(address(ledger));

        assertEq(address(registry.exposureLedger()), address(ledger), "legitimate first-time wiring must succeed");
    }
}
