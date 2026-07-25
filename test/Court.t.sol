// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Court} from "src/Court.sol";
import {ICourt} from "src/interfaces/ICourt.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @dev Governor stub. The court reads exactly one field off `getProposal`:
///      `executedAt`, from which D2's snapshot instant (`executedAt - 1`) is
///      derived once, at referral. `setExecuted` is deliberately re-callable so
///      a test can MOVE the proposal after referral and prove the case kept the
///      snapshot it stored rather than re-deriving it.
contract MockCourtGovernor {
    mapping(uint256 proposalId => ISyndicateGovernor.StrategyProposal) internal _proposals;

    function setExecuted(uint256 proposalId, uint256 executedAt) external {
        _proposals[proposalId].executedAt = executedAt;
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
    }
}

/// @dev A HOSTILE governor. `ch.governor` is an address the challenger handed
///      `ChallengeGame.file`, so `refer` reads a proposal from a contract the
///      accuser may control — this stub re-enters `refer` from `getProposal` to
///      prove one challenge can never open two cases.
contract MockReentrantGovernor {
    ICourt public court;
    uint256 public challengeId;
    bool public tried;
    bool public innerSucceeded;

    function arm(address court_, uint256 challengeId_) external {
        court = ICourt(court_);
        challengeId = challengeId_;
    }

    function getProposal(uint256) external returns (ISyndicateGovernor.StrategyProposal memory p) {
        if (!tried) {
            tried = true;
            try court.refer(challengeId) {
                innerSucceeded = true;
            } catch {}
        }
        p.executedAt = block.timestamp - 1 days;
    }
}

/// @dev Challenge-game stub exposing the single view the court reads at
///      referral (`challengeOf`) plus a setter for the status it gates on.
///      `rule` is NOT stubbed here: Task 3 deliberately never calls it — the
///      final outcome drives `ChallengeGame.rule` from Task 4's
///      `finalizeAppeal`/`finalizeUnappealed`.
contract MockCourtChallengeGame {
    mapping(uint256 challengeId => IChallengeGame.Challenge) internal _challenges;

    function setChallenge(uint256 challengeId, address governor, uint256 proposalId, IChallengeGame.Status status)
        external
    {
        IChallengeGame.Challenge storage c = _challenges[challengeId];
        c.governor = governor;
        c.proposalId = proposalId;
        c.status = status;
    }

    function setStatus(uint256 challengeId, IChallengeGame.Status status) external {
        _challenges[challengeId].status = status;
    }

    function challengeOf(uint256 challengeId) external view returns (IChallengeGame.Challenge memory) {
        return _challenges[challengeId];
    }
}

/// @dev Exposes the two internal hooks Tasks 3-5 will drive, so this task can
///      PROVE the roster/bond guards bite rather than merely asserting they are
///      present. `_lockPanelBond` is the only writer of `panelBondLockedUntil`;
///      once Task 3's `panelRule` and Task 5's `openBadFaith` call it, this
///      harness stops being the only path in — the guards do not change.
contract CourtHarness is Court {
    constructor(address initialOwner, address wood_, uint256 panelBondWood_)
        Court(initialOwner, wood_, panelBondWood_)
    {}

    function lockPanelBond(address member, uint256 until) external {
        _lockPanelBond(member, until);
    }

    function requireReadyToRule(address member) external view {
        _requireReadyToRule(member);
    }
}

contract CourtTest is Test {
    CourtHarness internal court;
    ERC20Mock internal wood;
    MockCourtChallengeGame internal game;
    MockCourtGovernor internal governor;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice"); // panelist
    address internal bob = makeAddr("bob"); // panelist
    address internal carol = makeAddr("carol"); // panelist
    address internal dave = makeAddr("dave"); // outsider / replacement

    uint256 internal constant BOND = 1_000e18;
    uint256 internal constant CHALLENGE_ID = 3;
    uint256 internal constant PROPOSAL_ID = 7;

    function setUp() public {
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        court = new CourtHarness(owner, address(wood), BOND);
        game = new MockCourtChallengeGame();
        governor = new MockCourtGovernor();

        // Somewhere well past genesis so `block.timestamp - x` is safe.
        vm.warp(vm.getBlockTimestamp() + 365 days);

        vm.prank(owner);
        court.setChallengeGame(address(game));

        address[4] memory funded = [alice, bob, carol, dave];
        for (uint256 i; i < funded.length; ++i) {
            wood.mint(funded[i], 1_000_000e18);
            vm.prank(funded[i]);
            wood.approve(address(court), type(uint256).max);
        }
    }

    // ── helpers ──

    function _seat(address[] memory members) internal {
        vm.prank(owner);
        court.setPanel(members);
    }

    function _three() internal view returns (address[] memory m) {
        m = new address[](3);
        m[0] = alice;
        m[1] = bob;
        m[2] = carol;
    }

    function _one(address a) internal pure returns (address[] memory m) {
        m = new address[](1);
        m[0] = a;
    }

    function _empty() internal pure returns (address[] memory m) {
        m = new address[](0);
    }

    /// @dev Bit `i` of `mask`. Extracted because Solidity binds `&` LOOSER than
    ///      `!=`, so the inline form silently mis-parses.
    function _bit(uint8 mask, uint256 i) internal pure returns (bool) {
        return ((uint256(mask) >> i) & 1) == 1;
    }

    /// @dev Seat `members` and post every one of their bonds, i.e. a panel that
    ///      is actually READY to rule.
    function _seatBonded(address[] memory members) internal {
        _seat(members);
        for (uint256 i; i < members.length; ++i) {
            vm.prank(members[i]);
            court.postPanelBond();
        }
    }

    /// @dev A `Disputed` challenge whose proposal executed `age` ago, ready to
    ///      be referred. Returns the executed instant so a test can assert the
    ///      stored snapshot is exactly `executedAt - 1` (D2).
    function _disputedChallenge(uint256 age) internal returns (uint256 executedAt) {
        executedAt = vm.getBlockTimestamp() - age;
        governor.setExecuted(PROPOSAL_ID, executedAt);
        game.setChallenge(CHALLENGE_ID, address(governor), PROPOSAL_ID, IChallengeGame.Status.Disputed);
    }

    /// @dev Permissionless referral — called by the test contract itself, which
    ///      is neither the owner nor a panelist, so every case in these tests
    ///      proves `refer` needs no privilege.
    function _refer() internal returns (uint256 caseId) {
        _disputedChallenge(1 days);
        caseId = court.refer(CHALLENGE_ID);
    }

    // ─────────────────────────── roster (D1) ───────────────────────────

    /// @notice D1: elections are off-chain; the owner is the governance
    ///         multisig executing the result. Nobody else may seat a panel.
    function test_setPanel_onlyOwner() public {
        address[] memory m = _three();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setPanel(m);
    }

    function test_setPanel_seatsMembers() public {
        address[] memory m = _three();
        vm.expectEmit(true, false, false, false);
        emit ICourt.PanelistSeated(alice);
        _seat(m);

        assertTrue(court.isPanelist(alice));
        assertTrue(court.isPanelist(bob));
        assertTrue(court.isPanelist(carol));
        assertFalse(court.isPanelist(dave));
        assertEq(court.panelSize(), 3);

        address[] memory seated = court.panel();
        assertEq(seated.length, 3);
        assertEq(seated[0], alice);
        assertEq(seated[1], bob);
        assertEq(seated[2], carol);
    }

    /// @notice A later `setPanel` REPLACES the roster: members absent from the
    ///         new list are unseated, members present in both stay seated
    ///         (bond and lock untouched), new members are seated.
    function test_setPanel_replacesRoster() public {
        _seat(_three());

        address[] memory next = new address[](2);
        next[0] = carol;
        next[1] = dave;
        _seat(next);

        assertFalse(court.isPanelist(alice));
        assertFalse(court.isPanelist(bob));
        assertTrue(court.isPanelist(carol));
        assertTrue(court.isPanelist(dave));
        assertEq(court.panelSize(), 2);
    }

    function test_setPanel_rejectsZeroAddress() public {
        address[] memory m = _one(address(0));
        vm.expectRevert(ICourt.ZeroAddress.selector);
        vm.prank(owner);
        court.setPanel(m);
    }

    /// @notice A duplicate would double-count in `panelSize`, which Task 3's
    ///         majority and "everyone has voted" arithmetic divides by.
    function test_setPanel_rejectsDuplicates() public {
        address[] memory m = new address[](2);
        m[0] = alice;
        m[1] = alice;
        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setPanel(m);
    }

    function test_setPanel_rejectsOversizedPanel() public {
        uint256 n = court.MAX_PANEL_SIZE() + 1;
        address[] memory m = new address[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = address(uint160(0x5000 + i));
        }
        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setPanel(m);
    }

    /// @notice An empty roster is legal and decommissions the court. Task 7's
    ///         deploy pre-flight — not this setter — is what refuses to wire a
    ///         court with no seated, bonded panel into `ChallengeGame`.
    function test_setPanel_emptyRosterDecommissions() public {
        _seat(_three());
        _seat(_empty());
        assertEq(court.panelSize(), 0);
        assertFalse(court.isPanelist(alice));
    }

    /// @notice THE GUARD. Unseating a panelist that still has an open ruling
    ///         would let its bond walk out of the bad-faith track (Task 5),
    ///         and the binding incentive on panel behaviour evaporates.
    function test_setPanel_cannotUnseatPanelistWithOpenRuling() public {
        _seat(_three());
        court.lockPanelBond(alice, vm.getBlockTimestamp() + 7 days);

        address[] memory next = new address[](2);
        next[0] = bob;
        next[1] = carol;
        vm.expectRevert(ICourt.PanelistHasOpenRuling.selector);
        vm.prank(owner);
        court.setPanel(next);
    }

    /// @notice The guard fires only on UNSEATING. Re-seating a member that has
    ///         an open ruling is fine — its bond stays exactly where the
    ///         bad-faith track can reach it.
    function test_setPanel_mayReseatPanelistWithOpenRuling() public {
        _seat(_three());
        court.lockPanelBond(alice, vm.getBlockTimestamp() + 7 days);

        address[] memory next = new address[](2);
        next[0] = alice;
        next[1] = dave;
        _seat(next);

        assertTrue(court.isPanelist(alice));
        assertFalse(court.isPanelist(bob));
        assertEq(court.panelSize(), 2);
    }

    /// @notice Once the bad-faith window has elapsed the member is free to be
    ///         rotated out — the guard is a delay, not a life sentence.
    function test_setPanel_mayUnseatOnceRulingWindowElapses() public {
        _seat(_three());
        uint256 until = vm.getBlockTimestamp() + 7 days;
        court.lockPanelBond(alice, until);

        vm.warp(until);
        address[] memory next = new address[](2);
        next[0] = bob;
        next[1] = carol;
        _seat(next);
        assertFalse(court.isPanelist(alice));
    }

    /// @notice Unseating does NOT return the bond. The bond leaves only through
    ///         `withdrawPanelBond`, which has its own guard.
    function test_setPanel_unseatingKeepsBondEscrowed() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();

        _seat(_empty());

        assertEq(court.panelBondOf(alice), BOND);
        assertEq(court.bondedWood(), BOND);
        assertEq(wood.balanceOf(address(court)), BOND);
    }

    // ─────────────────────────── posting bonds ───────────────────────────

    function test_postPanelBond_pullsWoodAndRecords() public {
        _seat(_one(alice));
        uint256 before = wood.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelBondPosted(alice, BOND);
        vm.prank(alice);
        court.postPanelBond();

        assertEq(wood.balanceOf(alice), before - BOND);
        assertEq(wood.balanceOf(address(court)), BOND);
        assertEq(court.panelBondOf(alice), BOND);
        assertEq(court.bondedWood(), BOND);
    }

    function test_postPanelBond_onlyPanelist() public {
        vm.expectRevert(ICourt.NotPanelist.selector);
        vm.prank(dave);
        court.postPanelBond();
    }

    function test_postPanelBond_twiceReverts() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();

        vm.expectRevert(ICourt.PanelBondAlreadyPosted.selector);
        vm.prank(alice);
        court.postPanelBond();
    }

    /// @notice SafeERC20 pull: no approval, no bond, no accounting drift.
    function test_postPanelBond_revertsWithoutApproval() public {
        _seat(_one(alice));
        vm.prank(alice);
        wood.approve(address(court), 0);

        vm.expectRevert();
        vm.prank(alice);
        court.postPanelBond();

        assertEq(court.bondedWood(), 0);
    }

    /// @notice Raising the requirement pulls only the SHORTFALL, so the member
    ///         is never double-charged and `bondedWood` stays exact.
    function test_postPanelBond_topsUpShortfallAfterRaise() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();

        vm.prank(owner);
        court.setPanelBondWood(BOND * 3);

        uint256 before = wood.balanceOf(alice);
        vm.prank(alice);
        court.postPanelBond();

        assertEq(wood.balanceOf(alice), before - BOND * 2);
        assertEq(court.panelBondOf(alice), BOND * 3);
        assertEq(court.bondedWood(), BOND * 3);
        assertEq(wood.balanceOf(address(court)), BOND * 3);
    }

    // ────────────────── readiness: unbonded cannot rule ──────────────────

    /// @notice A seated but UNBONDED panelist is not ready to rule. Task 3's
    ///         `panelRule` gates on exactly this — a panel with no posted skin
    ///         is not a bonded panel.
    function test_isReadyToRule_falseUntilBonded() public {
        _seat(_one(alice));
        assertFalse(court.isReadyToRule(alice));

        vm.expectRevert(ICourt.PanelBondNotPosted.selector);
        court.requireReadyToRule(alice);

        vm.prank(alice);
        court.postPanelBond();
        assertTrue(court.isReadyToRule(alice));
        court.requireReadyToRule(alice); // no revert
    }

    function test_isReadyToRule_falseForNonPanelist() public {
        assertFalse(court.isReadyToRule(dave));
        vm.expectRevert(ICourt.NotPanelist.selector);
        court.requireReadyToRule(dave);
    }

    /// @notice A bonded member that falls BELOW a raised requirement stops
    ///         being ready until it tops up. Readiness is measured against the
    ///         live requirement, never against "posted something once".
    function test_isReadyToRule_falseAfterRequirementRaised() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();
        assertTrue(court.isReadyToRule(alice));

        vm.prank(owner);
        court.setPanelBondWood(BOND * 2);
        assertFalse(court.isReadyToRule(alice));
    }

    /// @notice An unseated member is never ready, bonded or not.
    function test_isReadyToRule_falseOnceUnseated() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();
        _seat(_empty());
        assertFalse(court.isReadyToRule(alice));
    }

    // ────────────────────────── withdrawing bonds ──────────────────────────

    function test_withdrawPanelBond_afterUnseated() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();
        _seat(_empty());

        uint256 before = wood.balanceOf(alice);
        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelBondWithdrawn(alice, BOND);
        vm.prank(alice);
        uint256 amount = court.withdrawPanelBond();

        assertEq(amount, BOND);
        assertEq(wood.balanceOf(alice), before + BOND);
        assertEq(court.panelBondOf(alice), 0);
        assertEq(court.bondedWood(), 0);
        assertEq(wood.balanceOf(address(court)), 0);
    }

    /// @notice A SEATED member cannot pull its bond — that would leave a
    ///         sitting panelist with nothing at stake.
    function test_withdrawPanelBond_revertsWhileSeated() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();

        vm.expectRevert(ICourt.StillSeated.selector);
        vm.prank(alice);
        court.withdrawPanelBond();
    }

    /// @notice THE SECOND GUARD. Unseated but with a bad-faith window still
    ///         open against one of its rulings, the bond stays put.
    function test_withdrawPanelBond_revertsWhileBadFaithWindowOpen() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();
        uint256 until = vm.getBlockTimestamp() + 7 days;
        court.lockPanelBond(alice, until);

        // Unseat it the only way the roster guard allows: after the window.
        vm.warp(until);
        _seat(_empty());
        // ...then push the lock forward again, as Task 5's `openBadFaith` does.
        court.lockPanelBond(alice, vm.getBlockTimestamp() + 3 days);

        vm.expectRevert(ICourt.PanelistHasOpenRuling.selector);
        vm.prank(alice);
        court.withdrawPanelBond();
    }

    function test_withdrawPanelBond_succeedsOnceLockExpires() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();
        uint256 until = vm.getBlockTimestamp() + 7 days;
        court.lockPanelBond(alice, until);

        vm.warp(until);
        _seat(_empty());

        vm.prank(alice);
        uint256 amount = court.withdrawPanelBond();
        assertEq(amount, BOND);
        assertEq(court.bondedWood(), 0);
    }

    function test_withdrawPanelBond_revertsWithNoBond() public {
        vm.expectRevert(ICourt.PanelBondNotPosted.selector);
        vm.prank(dave);
        court.withdrawPanelBond();
    }

    /// @notice Lowering the requirement does not strand the excess: withdraw
    ///         returns what was POSTED, not what is currently required.
    function test_withdrawPanelBond_returnsPostedNotRequired() public {
        _seat(_one(alice));
        vm.prank(alice);
        court.postPanelBond();

        vm.prank(owner);
        court.setPanelBondWood(BOND / 4);
        _seat(_empty());

        vm.prank(alice);
        uint256 amount = court.withdrawPanelBond();
        assertEq(amount, BOND);
        assertEq(court.bondedWood(), 0);
        assertEq(wood.balanceOf(address(court)), 0);
    }

    /// @notice Two withdrawals cannot drain a sibling's bond.
    function test_withdrawPanelBond_isPerMember() public {
        address[] memory m = new address[](2);
        m[0] = alice;
        m[1] = bob;
        _seat(m);
        vm.prank(alice);
        court.postPanelBond();
        vm.prank(bob);
        court.postPanelBond();
        assertEq(court.bondedWood(), BOND * 2);

        _seat(_one(bob));
        vm.prank(alice);
        court.withdrawPanelBond();

        assertEq(court.bondedWood(), BOND);
        assertEq(wood.balanceOf(address(court)), BOND);
        assertEq(court.panelBondOf(bob), BOND);

        vm.expectRevert(ICourt.PanelBondNotPosted.selector);
        vm.prank(alice);
        court.withdrawPanelBond();
    }

    // ────────────────────────── owner parameters ──────────────────────────

    function test_setPanelBondWood_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setPanelBondWood(1);
    }

    /// @notice A zero bond is a panel with no skin in the game — the entire
    ///         binding incentive. Refuse it at the setter, not just at deploy.
    function test_setPanelBondWood_rejectsZero() public {
        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setPanelBondWood(0);
    }

    function test_setPanelBondWood_updates() public {
        vm.expectEmit(false, false, false, true);
        emit ICourt.PanelBondWoodSet(BOND, 42e18);
        vm.prank(owner);
        court.setPanelBondWood(42e18);
        assertEq(court.panelBondWood(), 42e18);
    }

    function test_constructor_rejectsZeroWood() public {
        vm.expectRevert(ICourt.ZeroAddress.selector);
        new Court(owner, address(0), BOND);
    }

    function test_constructor_rejectsZeroBond() public {
        vm.expectRevert(ICourt.InvalidParameter.selector);
        new Court(owner, address(wood), 0);
    }

    function test_constructor_setsOwnerAndParams() public {
        Court fresh = new Court(owner, address(wood), BOND);
        assertEq(fresh.owner(), owner);
        assertEq(address(fresh.wood()), address(wood));
        assertEq(fresh.panelBondWood(), BOND);
        assertEq(fresh.bondedWood(), 0);
        assertEq(fresh.panelSize(), 0);
    }

    /// @notice Tasks 3-6 all branch on this enum; pin the ordering so a later
    ///         reordering cannot silently flip a verdict. `None` must be the
    ///         zero value so an unset ruling is never `Guilty`.
    function test_rulingEnumOrdering() public pure {
        assertEq(uint256(ICourt.Ruling.None), 0);
        assertEq(uint256(ICourt.Ruling.Guilty), 1);
        assertEq(uint256(ICourt.Ruling.NotGuilty), 2);
    }

    // ─────────────────── §4 invariant: bondedWood accounting ───────────────────

    function test_bondedWood_tracksPostedBondsAcrossMembers() public {
        _seat(_three());
        assertEq(court.bondedWood(), 0);

        vm.prank(alice);
        court.postPanelBond();
        assertEq(court.bondedWood(), BOND);
        vm.prank(bob);
        court.postPanelBond();
        assertEq(court.bondedWood(), BOND * 2);
        vm.prank(carol);
        court.postPanelBond();
        assertEq(court.bondedWood(), BOND * 3);
        assertEq(wood.balanceOf(address(court)), court.bondedWood());
    }

    /// @notice Spec §4 requires one invariant per new accounting path. For this
    ///         task the court's whole balance is posted panel bonds; Tasks 4
    ///         and 5 extend `bondedWood` with open appeal and bad-faith bonds
    ///         and must keep this equality holding.
    function testFuzz_invariant_balanceEqualsBondedWood(uint96 bondAmount, uint8 postMask, uint8 withdrawMask) public {
        uint256 required = bound(uint256(bondAmount), 1, 100_000e18);
        vm.prank(owner);
        court.setPanelBondWood(required);

        address[] memory members = new address[](4);
        for (uint256 i; i < 4; ++i) {
            members[i] = address(uint160(0x9000 + i));
            wood.mint(members[i], required);
            vm.prank(members[i]);
            wood.approve(address(court), type(uint256).max);
        }
        _seat(members);

        uint256 expected;
        for (uint256 i; i < 4; ++i) {
            if (_bit(postMask, i)) {
                vm.prank(members[i]);
                court.postPanelBond();
                expected += required;
            }
        }
        assertEq(court.bondedWood(), expected);
        assertEq(wood.balanceOf(address(court)), court.bondedWood());

        _seat(_empty());

        for (uint256 i; i < 4; ++i) {
            if (_bit(postMask, i) && _bit(withdrawMask, i)) {
                vm.prank(members[i]);
                court.withdrawPanelBond();
                expected -= required;
            }
        }
        assertEq(court.bondedWood(), expected);
        assertEq(wood.balanceOf(address(court)), court.bondedWood());
    }

    // ═══════════════════ Task 3: layer 1 — the panel rules ═══════════════════

    // ────────────────────────────── referral ──────────────────────────────

    /// @notice D2: the snapshot is `executedAt - 1` — the same instant §3.8's
    ///         compensation claims and Plan D's `slashToEscrow` use — and it is
    ///         computed HERE, once, so the electorate that judges guilt is
    ///         identical to the set compensated from the resulting slash.
    function test_refer_opensCaseWithStoredSnapshot() public {
        uint256 executedAt = _disputedChallenge(1 days);

        vm.expectEmit(true, true, true, true);
        emit ICourt.CaseReferred(1, CHALLENGE_ID, address(governor), PROPOSAL_ID, executedAt - 1);
        uint256 caseId = court.refer(CHALLENGE_ID);

        assertEq(caseId, 1);
        assertEq(court.caseCount(), 1);
        assertEq(court.caseOfChallenge(CHALLENGE_ID), caseId);

        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(c.challengeId, CHALLENGE_ID);
        assertEq(c.snapshotTs, executedAt - 1);
        assertEq(c.referredAt, vm.getBlockTimestamp());
        assertEq(uint256(c.phase), uint256(ICourt.Phase.Panel));
        assertEq(uint256(c.panelRuling), uint256(ICourt.Ruling.None));
    }

    /// @notice THE POINT OF STORING IT (D2). Move the proposal underneath the
    ///         case and the snapshot does not budge: every later vote — the
    ///         merits appeal and the bad-faith vote alike — reads one value, so
    ///         no two of them can disagree about who the electorate is.
    function test_refer_snapshotIsStoredNotRederived() public {
        uint256 executedAt = _disputedChallenge(1 days);
        uint256 caseId = court.refer(CHALLENGE_ID);

        governor.setExecuted(PROPOSAL_ID, executedAt + 12 hours);

        assertEq(court.caseOf(caseId).snapshotTs, executedAt - 1);
    }

    /// @notice A case cannot be referred twice — a second case over one
    ///         challenge would run two panels at two snapshots toward two
    ///         verdicts on the same accusation.
    function test_refer_twiceReverts() public {
        _refer();
        vm.expectRevert(ICourt.AlreadyReferred.selector);
        court.refer(CHALLENGE_ID);
    }

    /// @notice Only a DISPUTED challenge is escalated. A `Filed` one is still
    ///         inside its own auto-slash clock and has not been contested.
    function test_refer_revertsOnNonDisputedChallenge() public {
        governor.setExecuted(PROPOSAL_ID, vm.getBlockTimestamp() - 1 days);
        game.setChallenge(CHALLENGE_ID, address(governor), PROPOSAL_ID, IChallengeGame.Status.Filed);

        vm.expectRevert(ICourt.ChallengeNotDisputed.selector);
        court.refer(CHALLENGE_ID);
    }

    /// @notice ...including a challenge that already reached a terminal state:
    ///         there is nothing left for the court to decide.
    function test_refer_revertsOnTerminalChallenge() public {
        _disputedChallenge(1 days);
        game.setStatus(CHALLENGE_ID, IChallengeGame.Status.Failed);

        vm.expectRevert(ICourt.ChallengeNotDisputed.selector);
        court.refer(CHALLENGE_ID);
    }

    /// @notice The governor is CHALLENGER-SUPPLIED — `ChallengeGame.file` takes
    ///         it as an argument — so `refer` reads a proposal from a contract
    ///         the accuser may control. It cannot re-enter: both reads are
    ///         `view` in their interfaces, so the court makes them with
    ///         STATICCALL and a governor that so much as writes a flag reverts
    ///         the referral instead of opening a second case over one
    ///         accusation. No case is left half-open behind it.
    function test_refer_hostileGovernorCannotReenter() public {
        MockReentrantGovernor hostile = new MockReentrantGovernor();
        hostile.arm(address(court), CHALLENGE_ID);
        game.setChallenge(CHALLENGE_ID, address(hostile), PROPOSAL_ID, IChallengeGame.Status.Disputed);

        vm.expectRevert();
        court.refer(CHALLENGE_ID);

        assertFalse(hostile.innerSucceeded());
        assertEq(court.caseCount(), 0);
        assertEq(court.caseOfChallenge(CHALLENGE_ID), 0);
    }

    function test_refer_revertsWithoutChallengeGameWired() public {
        Court fresh = new Court(owner, address(wood), BOND);
        vm.expectRevert(ICourt.ZeroAddress.selector);
        fresh.refer(CHALLENGE_ID);
    }

    /// @notice Fail closed on a proposal that never executed: `executedAt - 1`
    ///         would otherwise underflow into a snapshot at `type(uint256).max`
    ///         — an electorate nobody has voting power in.
    function test_refer_revertsOnUnexecutedProposal() public {
        game.setChallenge(CHALLENGE_ID, address(governor), PROPOSAL_ID, IChallengeGame.Status.Disputed);
        vm.expectRevert(ICourt.InvalidParameter.selector);
        court.refer(CHALLENGE_ID);
    }

    // ──────────────────────────── panelRule ────────────────────────────

    function test_panelRule_nonPanelistCannotRule() public {
        _seatBonded(_three());
        uint256 caseId = _refer();

        vm.expectRevert(ICourt.NotPanelist.selector);
        vm.prank(dave);
        court.panelRule(caseId, true);
    }

    /// @notice A seated but UNBONDED panelist cannot rule: an unbonded panel is
    ///         a panel with nothing the bad-faith track can reach.
    function test_panelRule_unbondedPanelistCannotRule() public {
        _seat(_three());
        uint256 caseId = _refer();

        vm.expectRevert(ICourt.PanelBondNotPosted.selector);
        vm.prank(alice);
        court.panelRule(caseId, true);
    }

    /// @notice A member that falls below a RAISED requirement stops being able
    ///         to rule until it tops up — readiness is live, not historical.
    function test_panelRule_underBondedAfterRaiseCannotRule() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.prank(owner);
        court.setPanelBondWood(BOND * 2);

        vm.expectRevert(ICourt.PanelBondNotPosted.selector);
        vm.prank(alice);
        court.panelRule(caseId, true);
    }

    function test_panelRule_recordsVote() public {
        _seatBonded(_three());
        uint256 caseId = _refer();

        vm.expectEmit(true, true, false, true);
        emit ICourt.PanelVoteCast(caseId, alice, true);
        vm.prank(alice);
        court.panelRule(caseId, true);

        assertEq(uint256(court.panelVoteOf(caseId, alice)), uint256(ICourt.Ruling.Guilty));
        assertEq(uint256(court.panelVoteOf(caseId, bob)), uint256(ICourt.Ruling.None));
        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(c.panelGuiltyVotes, 1);
        assertEq(c.panelNotGuiltyVotes, 0);
    }

    function test_panelRule_doubleVoteReverts() public {
        _seatBonded(_three());
        uint256 caseId = _refer();

        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.expectRevert(ICourt.AlreadyRuled.selector);
        vm.prank(alice);
        court.panelRule(caseId, false);
    }

    function test_panelRule_afterWindowReverts() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        uint256 deadline = court.caseOf(caseId).referredAt + court.panelWindow();

        vm.warp(deadline);
        vm.expectRevert(ICourt.WindowClosed.selector);
        vm.prank(alice);
        court.panelRule(caseId, true);
    }

    function test_panelRule_onUnreferredCaseReverts() public {
        _seatBonded(_three());
        vm.expectRevert(ICourt.WrongPhase.selector);
        vm.prank(alice);
        court.panelRule(1, true);
    }

    /// @notice Once the panel phase is closed the vote is closed with it, even
    ///         if the window itself has not elapsed.
    function test_panelRule_afterFinalizeReverts() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.prank(bob);
        court.panelRule(caseId, true);
        vm.prank(carol);
        court.panelRule(caseId, true);
        court.finalizePanel(caseId);

        vm.expectRevert(ICourt.WrongPhase.selector);
        vm.prank(alice);
        court.panelRule(caseId, false);
    }

    // ─────────────── the bond lock: F6's defence, not decoration ───────────────

    /// @notice RULING LOCKS THE BOND. Without this a panelist could rule, be
    ///         rotated off the roster and withdraw before anyone could open a
    ///         bad-faith vote against the ruling — the whole F6 track would be
    ///         decorative. The lock covers the rest of the panel window plus a
    ///         full `badFaithWindow`; Tasks 4-5 extend it from the case's actual
    ///         finalization.
    function test_panelRule_locksPanelistBond() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        uint256 referredAt = court.caseOf(caseId).referredAt;
        uint256 expected = referredAt + court.panelWindow() + court.badFaithWindow();

        assertEq(court.panelBondLockedUntil(alice), 0);
        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelBondLocked(alice, expected);
        vm.prank(alice);
        court.panelRule(caseId, true);

        assertEq(court.panelBondLockedUntil(alice), expected);
        // A panelist that did NOT rule is not locked.
        assertEq(court.panelBondLockedUntil(bob), 0);
    }

    /// @notice The consequence that matters: having ruled, the panelist can
    ///         neither be rotated off the roster nor pull its bond out of the
    ///         bad-faith track's reach until the lock expires.
    function test_panelRule_lockedBondCannotEscape() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, true);

        address[] memory next = new address[](2);
        next[0] = bob;
        next[1] = carol;
        vm.expectRevert(ICourt.PanelistHasOpenRuling.selector);
        vm.prank(owner);
        court.setPanel(next);

        // Even seated, the bond is unreachable; and it stays unreachable for
        // the whole lock, which is what the bad-faith track needs.
        vm.expectRevert(ICourt.StillSeated.selector);
        vm.prank(alice);
        court.withdrawPanelBond();

        vm.warp(court.panelBondLockedUntil(alice));
        vm.prank(owner);
        court.setPanel(next);
        vm.prank(alice);
        assertEq(court.withdrawPanelBond(), BOND);
    }

    /// @notice The lock only ever extends. A second, EARLIER ruling must not
    ///         pull an existing deadline back and release a bond the first one
    ///         still needs.
    function test_panelRule_lockNeverShortens() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        uint256 far = vm.getBlockTimestamp() + 3650 days;
        court.lockPanelBond(alice, far);

        vm.prank(alice);
        court.panelRule(caseId, true);
        assertEq(court.panelBondLockedUntil(alice), far);
    }

    // ──────────────────────────── finalizePanel ────────────────────────────

    function test_finalizePanel_majorityGuilty() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.prank(bob);
        court.panelRule(caseId, true);
        vm.prank(carol);
        court.panelRule(caseId, false);

        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelFinalized(caseId, ICourt.Ruling.Guilty, 2, 1);
        court.finalizePanel(caseId);

        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(uint256(c.panelRuling), uint256(ICourt.Ruling.Guilty));
        assertEq(uint256(c.phase), uint256(ICourt.Phase.AppealWindow));
        assertEq(c.panelFinalizedAt, vm.getBlockTimestamp());
    }

    function test_finalizePanel_majorityNotGuilty() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, false);
        vm.prank(bob);
        court.panelRule(caseId, false);
        vm.prank(carol);
        court.panelRule(caseId, true);
        court.finalizePanel(caseId);

        assertEq(uint256(court.caseOf(caseId).panelRuling), uint256(ICourt.Ruling.NotGuilty));
    }

    /// @notice A TIE IS AN ACQUITTAL, and that is a property rather than an
    ///         accident: a panel that cannot agree has not established the
    ///         ground truth §3.5 requires before a 100% slash, so the court
    ///         fails safe toward not slashing (Plan D's D5).
    function test_finalizePanel_tieIsNotGuilty() public {
        address[] memory four = new address[](4);
        four[0] = alice;
        four[1] = bob;
        four[2] = carol;
        four[3] = dave;
        _seatBonded(four);
        uint256 caseId = _refer();

        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.prank(bob);
        court.panelRule(caseId, true);
        vm.prank(carol);
        court.panelRule(caseId, false);
        vm.prank(dave);
        court.panelRule(caseId, false);

        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelFinalized(caseId, ICourt.Ruling.NotGuilty, 2, 2);
        court.finalizePanel(caseId);
        assertEq(uint256(court.caseOf(caseId).panelRuling), uint256(ICourt.Ruling.NotGuilty));
    }

    /// @notice SILENCE IS AN ACQUITTAL, same fail-safe. The cost is stated
    ///         rather than hidden: an inactive panel acquits instead of
    ///         convicting, so panel liveness is an operational requirement.
    function test_finalizePanel_silencePastWindowIsNotGuilty() public {
        _seatBonded(_three());
        uint256 caseId = _refer();

        vm.warp(court.caseOf(caseId).referredAt + court.panelWindow());
        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelFinalized(caseId, ICourt.Ruling.NotGuilty, 0, 0);
        court.finalizePanel(caseId);

        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(uint256(c.panelRuling), uint256(ICourt.Ruling.NotGuilty));
        assertEq(uint256(c.phase), uint256(ICourt.Phase.AppealWindow));
    }

    /// @notice A minority cannot close the panel phase early and freeze out the
    ///         members who have not voted yet.
    function test_finalizePanel_beforeWindowWithVotesOutstandingReverts() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.prank(bob);
        court.panelRule(caseId, true);

        vm.expectRevert(ICourt.WindowOpen.selector);
        court.finalizePanel(caseId);
    }

    /// @notice ...but once every seated member has voted there is nothing left
    ///         to wait for, so the case moves on without burning the window.
    function test_finalizePanel_earlyOnceEverySeatHasVoted() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.prank(bob);
        court.panelRule(caseId, false);
        vm.prank(carol);
        court.panelRule(caseId, true);

        court.finalizePanel(caseId);
        assertEq(uint256(court.caseOf(caseId).panelRuling), uint256(ICourt.Ruling.Guilty));
        assertLt(vm.getBlockTimestamp(), court.caseOf(caseId).referredAt + court.panelWindow());
    }

    function test_finalizePanel_twiceReverts() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.warp(court.caseOf(caseId).referredAt + court.panelWindow());
        court.finalizePanel(caseId);

        vm.expectRevert(ICourt.WrongPhase.selector);
        court.finalizePanel(caseId);
    }

    function test_finalizePanel_onUnreferredCaseReverts() public {
        vm.expectRevert(ICourt.WrongPhase.selector);
        court.finalizePanel(1);
    }

    /// @notice Ruling does NOT touch the WOOD accounting: the §4 equality holds
    ///         across a whole panel phase, because a ruling escrows the bond it
    ///         already holds rather than moving any.
    function test_panelPhase_leavesBondAccountingUntouched() public {
        _seatBonded(_three());
        uint256 caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.prank(bob);
        court.panelRule(caseId, false);
        vm.warp(court.caseOf(caseId).referredAt + court.panelWindow());
        court.finalizePanel(caseId);

        assertEq(court.bondedWood(), BOND * 3);
        assertEq(wood.balanceOf(address(court)), court.bondedWood());
    }

    // ─────────────────────────── owner parameters ───────────────────────────

    function test_setChallengeGame_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setChallengeGame(address(game));
    }

    function test_setChallengeGame_rejectsZero() public {
        vm.expectRevert(ICourt.ZeroAddress.selector);
        vm.prank(owner);
        court.setChallengeGame(address(0));
    }

    function test_setPanelWindow_onlyOwnerAndBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setPanelWindow(1 days);

        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setPanelWindow(0);

        uint256 max = court.MAX_PANEL_WINDOW();
        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setPanelWindow(max + 1);

        vm.prank(owner);
        court.setPanelWindow(max);
        assertEq(court.panelWindow(), max);
    }

    /// @notice A zero bad-faith window would mean the F6 track can never open,
    ///         leaving a bribable panel — refuse it at the setter, not only at
    ///         Task 7's deploy pre-flight.
    function test_setBadFaithWindow_onlyOwnerAndBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setBadFaithWindow(1 days);

        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setBadFaithWindow(0);

        uint256 max = court.MAX_BAD_FAITH_WINDOW();
        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setBadFaithWindow(max + 1);

        vm.prank(owner);
        court.setBadFaithWindow(max);
        assertEq(court.badFaithWindow(), max);
    }

    /// @notice Pin the phase ordering the way Task 2 pinned `Ruling`'s: Tasks
    ///         4-6 branch on it, and `None` must stay the zero value so an
    ///         unreferred case is never mistaken for a live one.
    function test_phaseEnumOrdering() public pure {
        assertEq(uint256(ICourt.Phase.None), 0);
        assertEq(uint256(ICourt.Phase.Panel), 1);
        assertEq(uint256(ICourt.Phase.AppealWindow), 2);
        assertEq(uint256(ICourt.Phase.Appeal), 3);
        assertEq(uint256(ICourt.Phase.Resolved), 4);
    }
}
