// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";

/// @notice Regression tests for `GuardianRegistry.setExposureLedger`'s wiring
///         checks, originally filed under audit issue #181, finding #26.
///
///         Finding #26 hardened a `ledger.challengeWindow() >= reviewPeriod +
///         MAX_GOVERNOR_EXECUTION_WINDOW` floor across four setters, this one
///         included. That floor has since been DELETED: it defended a booking
///         rule (`recordApproval` keying on `currentEpoch()`) the ledger no
///         longer uses, and the anti-batching property it existed for holds
///         for every positive window under settlement-dated booking -- see
///         `ExposureLedger.setChallengeWindow`'s natspec and
///         `test_antiBatching_holdsWithChallengeWindowFarBelowTheFloor`. The
///         first test below is the old floor test, flipped: the audit's own
///         reachable order now WIRES rather than reverts.
///
///         Still enforced, and still covered here: the reciprocal-grant
///         safeguard. A ledger already bound (via `setGuardianRegistry`) to
///         some OTHER registry must be rejected, because
///         `ExposureLedger.recordApproval` is `onlyRegistry` and a one-sided
///         re-point would make every future approve-side vote from this
///         registry revert forever. An UNWIRED ledger (`guardianRegistry() ==
///         address(0)`) must still be accepted -- that is the ordinary
///         first-time-wiring case and must not be bricked by the check.
contract GuardianRegistry_wiringInvariantTest is RegistryTestHarness {
    uint256 internal constant INITIAL_REVIEW_PERIOD = 1 days;
    /// @dev The registry's absolute `reviewPeriod` ceiling. The raise below
    ///      must stay inside it, so this tracks that bound.
    uint256 internal constant RAISED_REVIEW_PERIOD = 3 days;
    uint256 internal constant BLOCK_QUORUM_BPS = 2000;
    /// @dev The DELETED floor's execution-window term, kept only to stage the
    ///      exact value the old check refused (one second under it).
    uint256 internal constant OLD_MAX_GOVERNOR_EXECUTION_WINDOW = 7 days;

    address internal ledgerOwner = makeAddr("ledgerOwner");

    function setUp() public {
        _deployRegistryAndSwood(INITIAL_REVIEW_PERIOD, BLOCK_QUORUM_BPS);
    }

    /// @notice Finding #26's reachable order, flipped: wiring a ledger whose
    ///         `challengeWindow` sits one second below the OLD
    ///         `reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW` floor now
    ///         succeeds, and `setReviewPeriod` no longer reads the ledger at
    ///         all once it is wired. Against the pre-deletion code the wiring
    ///         reverts `InvalidParameter`.
    function test_setExposureLedger_acceptsAChallengeWindowBelowTheOldReviewPeriodFloor() public {
        vm.prank(regOwner);
        registry.setReviewPeriod(RAISED_REVIEW_PERIOD);

        ExposureLedger ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        uint256 belowOldFloor = RAISED_REVIEW_PERIOD + OLD_MAX_GOVERNOR_EXECUTION_WINDOW - 1;
        vm.prank(ledgerOwner);
        ledger.setChallengeWindow(belowOldFloor);

        vm.prank(regOwner);
        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.ExposureLedgerSet(address(0), address(ledger));
        registry.setExposureLedger(address(ledger));
        assertEq(address(registry.exposureLedger()), address(ledger), "the old floor must not refuse the wiring");

        // The other side of the old mirror: with the ledger wired, raising
        // `reviewPeriod` to its ceiling is not floored by the ledger's window
        // either. 3 days is already the ceiling, so re-seat it via the floor
        // and back up -- both must pass with the ledger attached.
        vm.startPrank(regOwner);
        registry.setReviewPeriod(INITIAL_REVIEW_PERIOD);
        registry.setReviewPeriod(RAISED_REVIEW_PERIOD);
        vm.stopPrank();
        assertEq(registry.reviewPeriod(), RAISED_REVIEW_PERIOD, "setReviewPeriod must not read the ledger's window");
    }

    /// @notice A ledger already bound to a DIFFERENT registry must be
    ///         rejected even though its `challengeWindow` clears the floor --
    ///         wiring it in would make every future `recordApproval` call
    ///         from THIS registry revert (`onlyRegistry`), silently turning
    ///         every review block-only. Against the OLD code this call
    ///         succeeds (no reciprocal check existed at all).
    function test_setExposureLedger_revertsWhenLedgerBoundToDifferentRegistry() public {
        ExposureLedger ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        address someOtherRegistry = makeAddr("someOtherRegistry");
        // `setGuardianRegistry` admits any nonzero address, so the (wrong)
        // pointer goes through -- exactly the ordering mistake this
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

    /// @notice Sanity: the reciprocal check must NOT brick the ordinary,
    ///         legitimate first-time wiring order -- a fresh ledger, never
    ///         pointed at any registry, wires in cleanly and emits
    ///         `ExposureLedgerSet`.
    function test_setExposureLedger_succeedsOnLegitimateFirstTimeWiring() public {
        ExposureLedger ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        // `ledger.guardianRegistry()` is still address(0) -- the untouched,
        // ordinary pre-wiring state.

        vm.prank(regOwner);
        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.ExposureLedgerSet(address(0), address(ledger));
        registry.setExposureLedger(address(ledger));

        assertEq(address(registry.exposureLedger()), address(ledger), "legitimate first-time wiring must succeed");
    }
}
