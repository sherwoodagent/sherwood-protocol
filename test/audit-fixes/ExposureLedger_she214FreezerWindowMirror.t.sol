// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExposureLedgerTest} from "../ExposureLedger.t.sol";
import {IExposureLedger} from "../../src/interfaces/IExposureLedger.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {MockCoverageFreezer} from "../mocks/MockCoverageFreezer.sol";

/// @dev Has code, but not the selector — a slot rotated to something that is
///      not a game.
contract MuteFreezer {}

/// @title ExposureLedger — SHE-214, the window floor mirrored into setCoverageFreezer
/// @notice THE BYPASS, AS FILED. `game.challengeWindow <= ledger.challengeWindow`
///         is what keeps coverage slashable for as long as a filing is legal:
///         `retireApproval`'s sweep opens at `bucketEnd + W_ledger`,
///         `ChallengeGame.file` closes at `executedAt + duration + W_game`.
///         The game enforced it at construction and in both of its setters,
///         and `setChallengeWindow` re-checked it when the LEDGER's window
///         moved — but only while a freezer was wired, and `setCoverageFreezer`
///         never checked at all. So `setCoverageFreezer(0)` ->
///         `setChallengeWindow(small)` -> `setCoverageFreezer(game)` seated an
///         inverted pair with nothing objecting, and `DeployPlanD` wires the
///         freezer LAST, so the unwired state is ordinary operation.
///
/// @dev    Both setters now read the game's window STRICTLY: the incoming
///         freezer must answer and fit under the stored window; a new window
///         must cover the wired freezer, which must answer. Fail-closed on an
///         unreadable game, recoverable by unwiring.
contract ExposureLedgerShe214FreezerWindowMirrorTest is ExposureLedgerTest {
    uint256 internal constant W = 14 days; // the ledger's default

    function _game(uint256 window) internal returns (MockCoverageFreezer) {
        return new MockCoverageFreezer(window);
    }

    /// @notice THE PIN. The three-step walk stops at the third step: the
    ///         re-wire sees the game's 14-day window above the ledger's new
    ///         7 days and refuses, leaving the slot unwired rather than
    ///         inverted.
    function test_she214_bypassSequence_revertsAtTheRewire() public {
        MockCoverageFreezer game = _game(W);
        assertEq(ledger.challengeWindow(), W, "precondition: default window");

        vm.startPrank(owner);
        ledger.setCoverageFreezer(address(game)); // equal windows: legal
        ledger.setCoverageFreezer(address(0)); // step 1: unwire
        ledger.setChallengeWindow(7 days); // step 2: legal while unwired
        assertEq(ledger.challengeWindow(), 7 days);

        vm.expectRevert(IExposureLedger.InvalidParameter.selector); // step 3
        ledger.setCoverageFreezer(address(game));
        vm.stopPrank();

        assertEq(ledger.coverageFreezer(), address(0), "the refused re-wire must not have taken effect");
    }

    /// @notice CONTROL for the pin: the same three steps against a game whose
    ///         window fits the new ledger window go through.
    function test_she214_bypassSequence_controlWithAFittingGameSucceeds() public {
        MockCoverageFreezer game = _game(7 days);
        vm.startPrank(owner);
        ledger.setCoverageFreezer(address(game));
        ledger.setCoverageFreezer(address(0));
        ledger.setChallengeWindow(7 days);
        ledger.setCoverageFreezer(address(game));
        vm.stopPrank();
        assertEq(ledger.coverageFreezer(), address(game));
    }

    function test_she214_freezerWindowAboveTheLedgers_reverts() public {
        MockCoverageFreezer game = _game(W + 1);
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setCoverageFreezer(address(game));
        assertEq(ledger.coverageFreezer(), address(0));
    }

    /// @notice The invariant is `<=`: equal is legal (it is what `DeployPlanD`
    ///         asserts), and so is a shorter game window.
    function test_she214_equalOrShorterFreezerWindow_passes() public {
        MockCoverageFreezer equal = _game(W);
        MockCoverageFreezer shorter = _game(W - 1);
        vm.startPrank(owner);
        ledger.setCoverageFreezer(address(equal));
        assertEq(ledger.coverageFreezer(), address(equal));
        ledger.setCoverageFreezer(address(shorter));
        assertEq(ledger.coverageFreezer(), address(shorter));
        vm.stopPrank();
    }

    /// @notice Zero is the unwire switch and is never window-checked — the
    ///         recovery path for every fail-closed branch below.
    function test_she214_zeroFreezer_passesWithoutAWindowRead() public {
        MockCoverageFreezer game = _game(W);
        vm.startPrank(owner);
        ledger.setCoverageFreezer(address(game));
        game.setMuted(true); // would fail a read; zero must not read
        ledger.setCoverageFreezer(address(0));
        vm.stopPrank();
        assertEq(ledger.coverageFreezer(), address(0));
    }

    /// @notice FAIL CLOSED: a codeless freezer is refused. A typed call to an
    ///         EOA reverts in the caller's frame with no data, so the
    ///         `code.length` probe is what turns it into a typed error.
    function test_she214_codelessFreezer_failsClosed() public {
        address eoa = makeAddr("codelessFreezer");
        assertEq(eoa.code.length, 0, "precondition");
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.CoverageFreezerUnreadable.selector);
        ledger.setCoverageFreezer(eoa);
    }

    /// @notice FAIL CLOSED: code without the selector (empty returndata on a
    ///         missing function) is refused the same way.
    function test_she214_muteFreezer_failsClosed() public {
        address mute = address(new MuteFreezer());
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.CoverageFreezerUnreadable.selector);
        ledger.setCoverageFreezer(mute);
    }

    /// @notice FAIL CLOSED: a freezer whose `challengeWindow()` reverts.
    function test_she214_revertingFreezer_failsClosed() public {
        MockCoverageFreezer game = _game(W);
        game.setMuted(true);
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.CoverageFreezerUnreadable.selector);
        ledger.setCoverageFreezer(address(game));
    }

    /// @notice The sibling bound in `setChallengeWindow` is strict too. A
    ///         freezer that answered at wiring and stopped afterwards (an
    ///         upgraded or broken game) blocks the window setter — and the
    ///         unwire switch reopens it, so nothing is bricked.
    function test_she214_setChallengeWindow_unreadableWiredFreezer_failsClosedButIsRecoverable() public {
        MockCoverageFreezer game = _game(W);
        vm.startPrank(owner);
        ledger.setCoverageFreezer(address(game));
        game.setMuted(true);

        vm.expectRevert(IExposureLedger.CoverageFreezerUnreadable.selector);
        ledger.setChallengeWindow(W + 1 days);
        assertEq(ledger.challengeWindow(), W, "the refused change must not have taken effect");

        ledger.setCoverageFreezer(address(0));
        ledger.setChallengeWindow(W + 1 days);
        vm.stopPrank();
        assertEq(ledger.challengeWindow(), W + 1 days);
    }

    /// @notice `setChallengeWindow` still refuses to shrink under the wired
    ///         game (the pre-existing bound, now strict), and still allows
    ///         equal.
    function test_she214_setChallengeWindow_cannotShrinkBelowTheWiredGame() public {
        MockCoverageFreezer game = _game(W);
        vm.startPrank(owner);
        ledger.setCoverageFreezer(address(game));
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(W - 1);
        ledger.setChallengeWindow(W); // equal: legal
        vm.stopPrank();
        assertEq(ledger.challengeWindow(), W);
    }

    /// @notice SHE-231 ORDERING, against the REAL game. Both sides now floor
    ///         against the other's LIVE window — the game refuses to rise above
    ///         the ledger, the ledger refuses to sink below the game — so the
    ///         one order that lowers a wired pair is game first, then ledger.
    ///         Pinned so the strict bound cannot be mistaken for a deadlock.
    function test_she214_loweringSequence_gameFirstThenLedger_succeeds() public {
        ChallengeGame game = new ChallengeGame(owner, makeAddr("wood"), address(ledger), makeAddr("tiers"));
        assertEq(game.challengeWindow(), W, "precondition: the game's default equals the ledger's");
        vm.startPrank(owner);
        ledger.setCoverageFreezer(address(game));

        // Ledger first is the deadlocked order: refused here, not on the game.
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(7 days);

        // Game first, then ledger.
        game.setChallengeWindow(7 days);
        ledger.setChallengeWindow(7 days);
        vm.stopPrank();

        assertEq(game.challengeWindow(), 7 days);
        assertEq(ledger.challengeWindow(), 7 days);
        assertEq(ledger.coverageFreezer(), address(game), "still wired throughout");
    }

    /// @notice And the mirror image for RAISING: ledger first, then game — the
    ///         game's own bound (`newWindow > ledger.challengeWindow()`) is what
    ///         refuses the reverse order there.
    function test_she214_raisingSequence_ledgerFirstThenGame_succeeds() public {
        ChallengeGame game = new ChallengeGame(owner, makeAddr("wood"), address(ledger), makeAddr("tiers"));
        vm.startPrank(owner);
        ledger.setCoverageFreezer(address(game));

        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setChallengeWindow(W + 1 days);

        ledger.setChallengeWindow(W + 1 days);
        game.setChallengeWindow(W + 1 days);
        vm.stopPrank();

        assertEq(game.challengeWindow(), W + 1 days);
        assertEq(ledger.challengeWindow(), W + 1 days);
    }
}
