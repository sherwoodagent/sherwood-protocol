// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Court} from "src/Court.sol";
import {ICourt} from "src/interfaces/ICourt.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockStakedWood} from "./mocks/MockStakedWood.sol";

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

/// @dev Challenge-game stub exposing the view the court reads at referral
///      (`challengeOf`) plus the `rule` entrypoint Task 1 built and Task 4
///      finally drives. `rule` mirrors the real contract's two load-bearing
///      properties — `Disputed`-only, and terminal once ruled — so a test that
///      double-resolves a case fails here rather than passing against a stub
///      more permissive than production.
contract MockCourtChallengeGame {
    mapping(uint256 challengeId => IChallengeGame.Challenge) internal _challenges;

    uint256 public ruleCallCount;
    uint256 public lastRuledChallengeId;
    bool public lastRuledGuilty;

    function rule(uint256 challengeId, bool guilty) external {
        IChallengeGame.Challenge storage c = _challenges[challengeId];
        if (c.status != IChallengeGame.Status.Disputed) revert IChallengeGame.WrongStatus();
        ruleCallCount++;
        lastRuledChallengeId = challengeId;
        lastRuledGuilty = guilty;
        c.status = guilty ? IChallengeGame.Status.Settled : IChallengeGame.Status.Failed;
    }

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
    MockStakedWood internal swood;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice"); // panelist
    address internal bob = makeAddr("bob"); // panelist
    address internal carol = makeAddr("carol"); // panelist
    address internal dave = makeAddr("dave"); // outsider / replacement
    address internal appellant = makeAddr("appellant");
    address internal whale = makeAddr("whale"); // large pre-exploit staker
    address internal minnow = makeAddr("minnow"); // small pre-exploit staker
    address internal newbie = makeAddr("newbie"); // staked only AFTER the snapshot
    address internal backstop = makeAddr("backstop");

    uint256 internal constant BOND = 1_000e18;
    uint256 internal constant CHALLENGE_ID = 3;
    uint256 internal constant PROPOSAL_ID = 7;

    /// @dev The electorate's total age-weighted vote weight at the snapshot.
    ///      At the default 1_000 bps floor, an appeal must muster 100_000e18.
    uint256 internal constant TOTAL_VOTES = 1_000_000e18;

    function setUp() public {
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        court = new CourtHarness(owner, address(wood), BOND);
        game = new MockCourtChallengeGame();
        governor = new MockCourtGovernor();
        swood = new MockStakedWood();

        // Somewhere well past genesis so `block.timestamp - x` is safe.
        vm.warp(vm.getBlockTimestamp() + 365 days);

        vm.startPrank(owner);
        court.setChallengeGame(address(game));
        court.setStakedWood(address(swood));
        vm.stopPrank();

        address[5] memory funded = [alice, bob, carol, dave, appellant];
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

    // ═════════════════ Task 4: layer 2 — the token-vote appeal ═════════════════

    // ── helpers ──

    /// @dev Populate the electorate AT THE CASE'S STORED SNAPSHOT. Weights are
    ///      whatever `getPastVotes` returns — sWOOD has ALREADY applied the age
    ///      curve §3.5 asks for (D3), so neither this fixture nor the court
    ///      re-weights them.
    ///
    ///      `newbie` is the point of the fixture: it holds a large position, but
    ///      only from AFTER the snapshot instant. That is the post-drain buyer
    ///      and the flash-loan borrower — anyone who acquired WOOD once the
    ///      exploit was visible — and at `snapshotTs` it has nothing.
    function _setElectorate(uint256 caseId) internal {
        uint256 ts = court.caseOf(caseId).snapshotTs;
        swood.setPastTotalVotes(ts, TOTAL_VOTES);
        swood.setPastVotes(whale, ts, 200_000e18); // 20% — clears the 10% floor alone
        swood.setPastVotes(dave, ts, 200_000e18); // 20% — the whale's mirror image
        swood.setPastVotes(minnow, ts, 10_000e18); // 1% — cannot clear it alone
        swood.setPastVotes(newbie, ts + 1 days, 500_000e18); // bought in after the drain
    }

    /// @dev A finalized panel ruling sitting in `AppealWindow`, with the
    ///      electorate loaded. Every seat votes the same way, so `finalizePanel`
    ///      closes early and `panelFinalizedAt == referredAt`.
    function _panelRuled(bool guilty) internal returns (uint256 caseId) {
        _seatBonded(_three());
        caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, guilty);
        vm.prank(bob);
        court.panelRule(caseId, guilty);
        vm.prank(carol);
        court.panelRule(caseId, guilty);
        court.finalizePanel(caseId);
        _setElectorate(caseId);
    }

    /// @dev Same, but CAROL ABSTAINS and the panel window is burnt down before
    ///      `finalizePanel`. Two consequences the lock tests need: only alice
    ///      and bob are in `panelVoters`, and the case finalizes late enough
    ///      that `finalizedAt + badFaithWindow` genuinely EXTENDS the lock
    ///      `panelRule` set from `referredAt`.
    function _panelRuledWithAbstention(bool guilty) internal returns (uint256 caseId) {
        _seatBonded(_three());
        caseId = _refer();
        vm.prank(alice);
        court.panelRule(caseId, guilty);
        vm.prank(bob);
        court.panelRule(caseId, guilty);
        vm.warp(court.caseOf(caseId).referredAt + court.panelWindow());
        court.finalizePanel(caseId);
        _setElectorate(caseId);
    }

    function _appeal(uint256 caseId) internal {
        vm.prank(appellant);
        court.appeal(caseId);
    }

    /// @dev Warp past the vote window and close layer 2.
    function _finalizeAppeal(uint256 caseId) internal {
        vm.warp(court.caseOf(caseId).appealedAt + court.appealVoteWindow());
        court.finalizeAppeal(caseId);
    }

    // ──────────────────────────── appeal (filing) ────────────────────────────

    function test_appeal_movesCaseToAppealPhase() public {
        uint256 caseId = _panelRuled(true);
        uint256 bondedBefore = court.bondedWood();
        uint256 balanceBefore = wood.balanceOf(appellant);
        uint256 bond = court.appealBondWood();

        vm.expectEmit(true, true, false, true);
        emit ICourt.AppealFiled(caseId, appellant, bond, vm.getBlockTimestamp() + court.appealVoteWindow());
        _appeal(caseId);

        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(uint256(c.phase), uint256(ICourt.Phase.Appeal));
        assertEq(c.appellant, appellant);
        assertEq(c.appealBond, bond);
        assertEq(c.appealedAt, vm.getBlockTimestamp());
        assertEq(wood.balanceOf(appellant), balanceBefore - bond);
        assertEq(court.bondedWood(), bondedBefore + bond);
        assertEq(wood.balanceOf(address(court)), court.bondedWood() + court.forfeitedWood());
    }

    /// @notice The appeal window is finite, and it runs from `panelFinalizedAt`
    ///         — the court's whole process has to fit inside the challenge's own
    ///         `disputeTimeout`.
    function test_appeal_afterWindowReverts() public {
        uint256 caseId = _panelRuled(true);
        vm.warp(court.caseOf(caseId).panelFinalizedAt + court.appealWindow());

        vm.expectRevert(ICourt.WindowClosed.selector);
        vm.prank(appellant);
        court.appeal(caseId);
    }

    /// @notice There is nothing to appeal until layer 1 has actually ruled.
    function test_appeal_beforePanelFinalizedReverts() public {
        _seatBonded(_three());
        uint256 caseId = _refer();

        vm.expectRevert(ICourt.WrongPhase.selector);
        vm.prank(appellant);
        court.appeal(caseId);
    }

    /// @notice One appeal per case. A second would either re-open a closed vote
    ///         or overwrite the first appellant's bond record.
    function test_appeal_twiceReverts() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);

        vm.expectRevert(ICourt.WrongPhase.selector);
        vm.prank(dave);
        court.appeal(caseId);
    }

    /// @notice FAIL AT THE DOOR, not at the vote. A court with no electorate
    ///         wired would take the appeal, then have no way to finalize it, and
    ///         the case would sit in `Appeal` until the challenge's own
    ///         `disputeTimeout` acquitted the accused — the precise hole Plan E
    ///         exists to close. Refusing the appeal instead leaves the ruling
    ///         unappealed, which `finalizeUnappealed` can still resolve.
    function test_appeal_revertsWithoutStakedWoodWired() public {
        CourtHarness fresh = new CourtHarness(owner, address(wood), BOND);
        address[] memory m = _one(alice);
        vm.startPrank(owner);
        fresh.setChallengeGame(address(game));
        fresh.setPanel(m);
        vm.stopPrank();

        vm.startPrank(alice);
        wood.approve(address(fresh), type(uint256).max);
        fresh.postPanelBond();
        vm.stopPrank();

        _disputedChallenge(1 days);
        uint256 caseId = fresh.refer(CHALLENGE_ID);
        vm.prank(alice);
        fresh.panelRule(caseId, true);
        fresh.finalizePanel(caseId);

        vm.prank(appellant);
        wood.approve(address(fresh), type(uint256).max);

        vm.expectRevert(ICourt.ZeroAddress.selector);
        vm.prank(appellant);
        fresh.appeal(caseId);
    }

    /// @notice An acquittal is appealable too — the appeal checks the panel in
    ///         BOTH directions, or it would only ever be a tool for the accused.
    function test_appeal_worksOnAnAcquittal() public {
        uint256 caseId = _panelRuled(false);
        _appeal(caseId);
        assertEq(uint256(court.caseOf(caseId).phase), uint256(ICourt.Phase.Appeal));
    }

    // ────────────────────────────── voteAppeal ──────────────────────────────

    /// @notice Weight is `getPastVotes` at the case's STORED snapshot, tallied
    ///         as stake — layer 2 weighs WOOD where layer 1 counted seats. The
    ///         court does not re-weight it: sWOOD's return value is already the
    ///         age-weighted number §3.5 asks for (D3).
    function test_voteAppeal_tallyIsStakeAtTheStoredSnapshot() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);

        vm.expectEmit(true, true, false, true);
        emit ICourt.AppealVoteCast(caseId, whale, false, 200_000e18);
        vm.prank(whale);
        court.voteAppeal(caseId, false);

        vm.prank(minnow);
        court.voteAppeal(caseId, true);

        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(c.appealNotGuiltyVotes, 200_000e18);
        assertEq(c.appealGuiltyVotes, 10_000e18);
        assertEq(uint256(court.appealVoteOf(caseId, whale)), uint256(ICourt.Ruling.NotGuilty));
        assertEq(uint256(court.appealVoteOf(caseId, minnow)), uint256(ICourt.Ruling.Guilty));
    }

    /// @notice THE FLASH-LOAN / POST-DRAIN-BUYER DEFENCE. `newbie` holds half
    ///         the electorate's weight — but only from AFTER `snapshotTs`, so at
    ///         the instant before the challenged proposal executed it had
    ///         nothing, and it cannot vote on whether the drain it bought into
    ///         was a crime. The defence is the stored snapshot itself, not a
    ///         separate check: no borrow, purchase or stake reaches back past a
    ///         timestamp fixed at referral.
    function test_voteAppeal_postSnapshotStakerHasNoVotingPower() public {
        uint256 caseId = _panelRuled(true);
        uint256 snapshotTs = court.caseOf(caseId).snapshotTs;
        _appeal(caseId);

        // The position is real, and large — just not at the snapshot.
        assertEq(swood.getPastVotes(newbie, snapshotTs), 0);
        assertEq(swood.getPastVotes(newbie, snapshotTs + 1 days), 500_000e18);

        vm.expectRevert(ICourt.NoVotingPower.selector);
        vm.prank(newbie);
        court.voteAppeal(caseId, false);

        // ...and it moved no tally on its way out.
        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(c.appealGuiltyVotes, 0);
        assertEq(c.appealNotGuiltyVotes, 0);
    }

    /// @notice An address that never staked at all is refused by the same
    ///         branch — zero weight is zero weight.
    function test_voteAppeal_strangerHasNoVotingPower() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);

        vm.expectRevert(ICourt.NoVotingPower.selector);
        vm.prank(makeAddr("stranger"));
        court.voteAppeal(caseId, true);
    }

    function test_voteAppeal_doubleVoteReverts() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);

        vm.prank(whale);
        court.voteAppeal(caseId, true);

        vm.expectRevert(ICourt.AlreadyVoted.selector);
        vm.prank(whale);
        court.voteAppeal(caseId, false);
    }

    /// @notice ...and the second attempt cannot double-count the weight either,
    ///         which is the reason the guard exists.
    function test_voteAppeal_doubleVoteDoesNotDoubleCount() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);

        vm.prank(whale);
        court.voteAppeal(caseId, true);
        vm.expectRevert(ICourt.AlreadyVoted.selector);
        vm.prank(whale);
        court.voteAppeal(caseId, true);

        assertEq(court.caseOf(caseId).appealGuiltyVotes, 200_000e18);
    }

    function test_voteAppeal_afterWindowReverts() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.warp(court.caseOf(caseId).appealedAt + court.appealVoteWindow());

        vm.expectRevert(ICourt.WindowClosed.selector);
        vm.prank(whale);
        court.voteAppeal(caseId, true);
    }

    /// @notice No voting on a ruling nobody appealed — the phase gate, not the
    ///         clock, is what says layer 2 is open.
    function test_voteAppeal_beforeAppealReverts() public {
        uint256 caseId = _panelRuled(true);

        vm.expectRevert(ICourt.WrongPhase.selector);
        vm.prank(whale);
        court.voteAppeal(caseId, true);
    }

    function test_voteAppeal_afterResolutionReverts() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        _finalizeAppeal(caseId);

        vm.expectRevert(ICourt.WrongPhase.selector);
        vm.prank(whale);
        court.voteAppeal(caseId, true);
    }

    // ────── finalizeAppeal: the participation floor (D6) — THE KEY TEST ──────

    /// @notice **THE ANTI-CAPTURE PROPERTY (D6), AND THE MOST IMPORTANT TEST IN
    ///         TASK 4.** The panel convicted. An appeal was filed and the votes
    ///         actually cast went the OTHER WAY — unanimously not-guilty — but
    ///         they came to 1% of the snapshot electorate against a 10% floor.
    ///         The appeal is therefore a NON-EVENT: the cast votes are
    ///         discarded, the PANEL'S RULING STANDS, and `ChallengeGame.rule`
    ///         receives `true` exactly as if nobody had appealed at all.
    ///
    ///         This is what removes §3.5's "swing a single-digit-turnout appeal
    ///         cheaply at a ~$15M mcap" path. Without it, an attacker holding
    ///         1% of the electorate could overturn any conviction.
    function test_finalizeAppeal_belowFloorPanelRulingStandsDespiteContraryVotes() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);

        // Every vote cast says NOT guilty — and it is not enough to matter.
        vm.prank(minnow);
        court.voteAppeal(caseId, false);

        uint256 floor = TOTAL_VOTES * court.participationFloorBps() / 10_000;
        assertLt(10_000e18, floor, "fixture must be below the floor");

        vm.warp(court.caseOf(caseId).appealedAt + court.appealVoteWindow());
        vm.expectEmit(true, false, false, true);
        emit ICourt.AppealBelowFloor(caseId, 10_000e18, floor, ICourt.Ruling.Guilty, BOND);
        court.finalizeAppeal(caseId);

        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(uint256(c.finalRuling), uint256(ICourt.Ruling.Guilty), "panel ruling must stand");
        assertEq(uint256(c.panelRuling), uint256(ICourt.Ruling.Guilty));
        assertEq(uint256(c.phase), uint256(ICourt.Phase.Resolved));

        // ...and the guilty bit reached the challenge game.
        assertEq(game.ruleCallCount(), 1);
        assertEq(game.lastRuledChallengeId(), CHALLENGE_ID);
        assertTrue(game.lastRuledGuilty());
    }

    /// @notice The mirror image, so the property is not an artefact of the
    ///         panel having convicted: a below-floor appeal cannot turn an
    ///         ACQUITTAL into a conviction either. A non-event is a non-event in
    ///         both directions.
    function test_finalizeAppeal_belowFloorLeavesAcquittalStanding() public {
        uint256 caseId = _panelRuled(false);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, true);

        _finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.NotGuilty));
        assertEq(game.ruleCallCount(), 1);
        assertFalse(game.lastRuledGuilty());
    }

    /// @notice A below-floor appellant FORFEITS its bond — not for being wrong,
    ///         but for escalating and then failing to raise the electorate that
    ///         would have made the escalation mean anything. The WOOD moves out
    ///         of `bondedWood` (claimable) into `forfeitedWood` (protocol-owned)
    ///         in one step, so the §4 equality holds across the transition.
    function test_finalizeAppeal_belowFloorForfeitsTheAppealBond() public {
        uint256 caseId = _panelRuled(true);
        uint256 balanceBefore = wood.balanceOf(appellant);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false);

        _finalizeAppeal(caseId);

        assertEq(wood.balanceOf(appellant), balanceBefore - BOND, "bond is gone");
        assertEq(court.forfeitedWood(), BOND);
        assertEq(court.bondedWood(), BOND * 3, "only the three panel bonds remain claimable");
        assertEq(wood.balanceOf(address(court)), court.bondedWood() + court.forfeitedWood());
        assertEq(court.caseOf(caseId).appealBond, 0);
    }

    /// @notice A ZERO-TURNOUT APPEAL LEAVES THE PANEL STANDING even in the
    ///         degenerate case where the floor itself computes to zero because
    ///         the snapshot's total vote weight is zero. Without the explicit
    ///         `turnout == 0` branch the arithmetic would take `0 >= 0` as
    ///         quorate and flip a conviction to an acquittal on an empty tally.
    function test_finalizeAppeal_zeroTurnoutStandsEvenWithAZeroFloor() public {
        uint256 caseId = _panelRuled(true);
        swood.setPastTotalVotes(court.caseOf(caseId).snapshotTs, 0);
        _appeal(caseId);

        vm.warp(court.caseOf(caseId).appealedAt + court.appealVoteWindow());
        vm.expectEmit(true, false, false, true);
        emit ICourt.AppealBelowFloor(caseId, 0, 0, ICourt.Ruling.Guilty, BOND);
        court.finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.Guilty));
        assertTrue(game.lastRuledGuilty());
        assertEq(court.forfeitedWood(), BOND);
    }

    // ───────────── finalizeAppeal: above the floor, the vote decides ─────────────

    /// @notice Quorate, and the electorate disagreed with the panel: the
    ///         conviction is OVERTURNED and the challenge game is told
    ///         not-guilty. This is the check §3.5 put above a bribable panel.
    function test_finalizeAppeal_aboveFloorOverturnsConviction() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, false);

        uint256 floor = TOTAL_VOTES * court.participationFloorBps() / 10_000;
        vm.warp(court.caseOf(caseId).appealedAt + court.appealVoteWindow());
        vm.expectEmit(true, false, false, true);
        emit ICourt.AppealFinalized(caseId, ICourt.Ruling.NotGuilty, 0, 200_000e18, floor);
        court.finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.NotGuilty));
        assertEq(game.ruleCallCount(), 1);
        assertFalse(game.lastRuledGuilty());
    }

    /// @notice ...and in the other direction, which is the arc that actually
    ///         closes Plan D's hole: layer 1 was silent or wrong and acquitted,
    ///         and a quorate electorate CONVICTS anyway. A guilty approver
    ///         cannot escape by capturing five panelists.
    function test_finalizeAppeal_aboveFloorOverturnsAcquittalIntoConviction() public {
        uint256 caseId = _panelRuled(false);
        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, true);

        _finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.Guilty));
        assertEq(game.ruleCallCount(), 1);
        assertTrue(game.lastRuledGuilty());
    }

    /// @notice A quorate appeal that UPHOLDS the panel still returns the bond.
    ///         The bond prices failing to raise a quorum, not being wrong —
    ///         charging good-faith appellants who lose would deter exactly the
    ///         check §3.5 placed above the panel. Note the event: this is
    ///         `AppealFinalized`, not `AppealBelowFloor`, even though the
    ///         outcome matches the panel's.
    function test_finalizeAppeal_aboveFloorUpholdingStillReturnsTheBond() public {
        uint256 caseId = _panelRuled(true);
        uint256 balanceBefore = wood.balanceOf(appellant);
        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, true);

        vm.warp(court.caseOf(caseId).appealedAt + court.appealVoteWindow());
        vm.expectEmit(true, true, false, true);
        emit ICourt.AppealBondReturned(caseId, appellant, BOND);
        court.finalizeAppeal(caseId);

        assertEq(wood.balanceOf(appellant), balanceBefore, "bond returned in full");
        assertEq(court.forfeitedWood(), 0);
        assertEq(court.bondedWood(), BOND * 3);
        assertEq(wood.balanceOf(address(court)), court.bondedWood());
        assertTrue(game.lastRuledGuilty());
    }

    /// @notice A TIE ABOVE THE FLOOR ACQUITS — the same fail-safe
    ///         `finalizePanel` applies, for the same reason: an electorate split
    ///         down the middle has not established the ground truth §3.5
    ///         requires before a 100% slash.
    function test_finalizeAppeal_tieAboveFloorIsNotGuilty() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, true);
        vm.prank(dave);
        court.voteAppeal(caseId, false);

        _finalizeAppeal(caseId);

        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(c.appealGuiltyVotes, c.appealNotGuiltyVotes, "fixture must be a tie");
        assertEq(uint256(c.finalRuling), uint256(ICourt.Ruling.NotGuilty));
        assertFalse(game.lastRuledGuilty());
    }

    /// @notice Turnout EXACTLY AT the floor is quorate — the comparison is
    ///         `turnout < floor`, so the boundary decides rather than voids.
    function test_finalizeAppeal_turnoutExactlyAtFloorIsQuorate() public {
        uint256 caseId = _panelRuled(true);
        uint256 ts = court.caseOf(caseId).snapshotTs;
        uint256 floor = TOTAL_VOTES * court.participationFloorBps() / 10_000;
        swood.setPastVotes(minnow, ts, floor);
        _appeal(caseId);

        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.NotGuilty));
        assertEq(court.forfeitedWood(), 0, "quorate, so the bond returns");
    }

    function test_finalizeAppeal_beforeVoteWindowReverts() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);

        vm.expectRevert(ICourt.WindowOpen.selector);
        court.finalizeAppeal(caseId);
    }

    function test_finalizeAppeal_twiceReverts() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        _finalizeAppeal(caseId);

        vm.expectRevert(ICourt.WrongPhase.selector);
        court.finalizeAppeal(caseId);
        assertEq(game.ruleCallCount(), 1, "the challenge game is ruled on exactly once");
    }

    function test_finalizeAppeal_onUnappealedCaseReverts() public {
        uint256 caseId = _panelRuled(true);
        vm.expectRevert(ICourt.WrongPhase.selector);
        court.finalizeAppeal(caseId);
    }

    // ───────────────────────── finalizeUnappealed ─────────────────────────

    /// @notice The quiet path, and the one that closes Plan D's hole in the
    ///         common case: nobody appealed, so layer 1's conviction is the
    ///         court's, and the guilty bit reaches `ChallengeGame.rule` before
    ///         the challenge's own timeout could acquit the accused.
    function test_finalizeUnappealed_convictionReachesTheChallengeGame() public {
        uint256 caseId = _panelRuled(true);
        vm.warp(court.caseOf(caseId).panelFinalizedAt + court.appealWindow());

        vm.expectEmit(true, true, false, true);
        emit ICourt.CaseResolved(caseId, CHALLENGE_ID, ICourt.Ruling.Guilty);
        court.finalizeUnappealed(caseId);

        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(uint256(c.finalRuling), uint256(ICourt.Ruling.Guilty));
        assertEq(uint256(c.phase), uint256(ICourt.Phase.Resolved));
        assertEq(c.finalizedAt, vm.getBlockTimestamp());
        assertEq(game.ruleCallCount(), 1);
        assertEq(game.lastRuledChallengeId(), CHALLENGE_ID);
        assertTrue(game.lastRuledGuilty());
    }

    /// @notice An unappealed ACQUITTAL fails the challenge, so the challenger's
    ///         bond forfeits to the accused — the same bit, the other way.
    function test_finalizeUnappealed_acquittalReachesTheChallengeGame() public {
        uint256 caseId = _panelRuled(false);
        vm.warp(court.caseOf(caseId).panelFinalizedAt + court.appealWindow());
        court.finalizeUnappealed(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.NotGuilty));
        assertEq(game.ruleCallCount(), 1);
        assertFalse(game.lastRuledGuilty());
    }

    /// @notice The appeal window must actually elapse: finalizing early would
    ///         let anyone front-run an appellant and make the panel final.
    function test_finalizeUnappealed_beforeWindowReverts() public {
        uint256 caseId = _panelRuled(true);
        vm.expectRevert(ICourt.WindowOpen.selector);
        court.finalizeUnappealed(caseId);
    }

    /// @notice Once appealed, this path is closed — the appeal decides.
    function test_finalizeUnappealed_afterAppealReverts() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.warp(court.caseOf(caseId).panelFinalizedAt + court.appealWindow());

        vm.expectRevert(ICourt.WrongPhase.selector);
        court.finalizeUnappealed(caseId);
    }

    function test_finalizeUnappealed_twiceReverts() public {
        uint256 caseId = _panelRuled(true);
        vm.warp(court.caseOf(caseId).panelFinalizedAt + court.appealWindow());
        court.finalizeUnappealed(caseId);

        vm.expectRevert(ICourt.WrongPhase.selector);
        court.finalizeUnappealed(caseId);
        assertEq(game.ruleCallCount(), 1);
    }

    // ───── the seam Task 5 depends on: the bond lock survives a long case ─────

    /// @notice **THE SEAM FOR TASK 5, ON THE UNAPPEALED PATH.** `panelRule`
    ///         could only lock to `referredAt + panelWindow + badFaithWindow`,
    ///         because the instant the CASE finalizes did not exist yet. Task
    ///         5's bad-faith window opens at `finalizedAt`, so resolution must
    ///         re-lock every member that ruled to `finalizedAt +
    ///         badFaithWindow`. Without it a panelist escapes the bad-faith
    ///         slash by outlasting the case, and F6 is decorative.
    function test_finalizeUnappealed_extendsRulingPanelistsBondLock() public {
        uint256 caseId = _panelRuledWithAbstention(true);
        uint256 panelPhaseLock = court.panelBondLockedUntil(alice);

        vm.warp(court.caseOf(caseId).panelFinalizedAt + court.appealWindow());
        court.finalizeUnappealed(caseId);

        uint256 expected = court.caseOf(caseId).finalizedAt + court.badFaithWindow();
        assertGt(expected, panelPhaseLock, "fixture must actually extend the lock");
        assertEq(court.panelBondLockedUntil(alice), expected);
        assertEq(court.panelBondLockedUntil(bob), expected);
        // Carol abstained, so she has no ruling to answer for.
        assertEq(court.panelBondLockedUntil(carol), 0);
    }

    /// @notice **THE SAME SEAM ON THE APPEAL PATH**, which is where it actually
    ///         bites: an appeal pushes the case's finalization days past the
    ///         panel phase, and it is precisely that gap a corrupt panelist
    ///         would sit out to get its bond back before anyone could vote on
    ///         its conduct.
    function test_finalizeAppeal_extendsRulingPanelistsBondLock() public {
        uint256 caseId = _panelRuledWithAbstention(true);
        uint256 panelPhaseLock = court.panelBondLockedUntil(alice);
        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        uint256 expected = court.caseOf(caseId).finalizedAt + court.badFaithWindow();
        assertGt(expected, panelPhaseLock, "the appeal must push finalization out");
        assertEq(court.panelBondLockedUntil(alice), expected);
        assertEq(court.panelBondLockedUntil(bob), expected);
        assertEq(court.panelBondLockedUntil(carol), 0);
    }

    /// @notice OVERTURNED ON THE MERITS IS NOT BAD FAITH (D4). The appeal above
    ///         reversed alice's ruling and her bond is still whole and still
    ///         escrowed — the merits vote never slashes. Task 5's separate
    ///         bad-faith vote is the only thing that can, which is what stops an
    ///         attacker who controls the cheap appeal from making a corrupt
    ///         ruling safe, and stops panelists ruling to predict the vote.
    function test_finalizeAppeal_overturningDoesNotSlashThePanel() public {
        uint256 caseId = _panelRuledWithAbstention(true);
        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.NotGuilty));
        assertEq(court.panelBondOf(alice), BOND, "the merits vote must not slash");
        assertEq(court.panelBondOf(bob), BOND);
        assertEq(court.bondedWood(), BOND * 3);
    }

    /// @notice The re-lock NEVER SHORTENS. A case that closes early — panel
    ///         unanimous, appeal filed and resolved quickly — finalizes sooner
    ///         than `referredAt + panelWindow`, so the panel-phase lock is the
    ///         later of the two and must survive. The effective deadline is the
    ///         max of the two, not the last one written.
    function test_resolve_bondLockNeverShortens() public {
        uint256 caseId = _panelRuled(true);
        uint256 referredAt = court.caseOf(caseId).referredAt;
        uint256 panelPhaseLock = referredAt + court.panelWindow() + court.badFaithWindow();
        assertEq(court.panelBondLockedUntil(alice), panelPhaseLock);

        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        uint256 fromFinalization = court.caseOf(caseId).finalizedAt + court.badFaithWindow();
        assertLt(fromFinalization, panelPhaseLock, "fixture must resolve early");
        assertEq(court.panelBondLockedUntil(alice), panelPhaseLock, "the later deadline wins");
    }

    /// @notice `panelVoters` is stored per case rather than derived from the
    ///         live roster — Task 5 opens bad-faith votes against exactly this
    ///         set, and a roster scan would lose a member rotated off after its
    ///         lock expired.
    function test_panelVoters_recordsOnlyTheMembersThatRuled() public {
        uint256 caseId = _panelRuledWithAbstention(true);
        address[] memory voters = court.panelVoters(caseId);
        assertEq(voters.length, 2);
        assertEq(voters[0], alice);
        assertEq(voters[1], bob);
    }

    // ────────────────────── windows against the challenge clock ──────────────────────

    /// @notice THE COURT MUST FINISH BEFORE THE CHALLENGE TIMES OUT. Plan D's
    ///         `resolve` acquits a disputed challenge to the accused once
    ///         `disputeTimeout` (30 days by default) elapses from `filedAt`, so
    ///         the court's three windows have to run back to back inside it. Pin
    ///         the arithmetic here: raising any one ceiling without re-checking
    ///         the total would hand a guilty approver the timeout acquittal Plan
    ///         E exists to take away.
    function test_windowCeilings_fitInsideDefaultDisputeTimeout() public view {
        uint256 ceilings = court.MAX_PANEL_WINDOW() + court.MAX_APPEAL_WINDOW() + court.MAX_APPEAL_VOTE_WINDOW();
        assertEq(ceilings, 28 days);
        assertLt(ceilings, 30 days, "must fit inside ChallengeGame's default disputeTimeout");

        uint256 defaults = court.panelWindow() + court.appealWindow() + court.appealVoteWindow();
        assertEq(defaults, 15 days);
        assertLt(defaults, ceilings);
    }

    // ─────────────────────────── owner parameters ───────────────────────────

    function test_setStakedWood_onlyOwnerAndRejectsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setStakedWood(address(swood));

        vm.expectRevert(ICourt.ZeroAddress.selector);
        vm.prank(owner);
        court.setStakedWood(address(0));

        address next = makeAddr("swood2");
        vm.expectEmit(true, true, false, false);
        emit ICourt.StakedWoodSet(address(swood), next);
        vm.prank(owner);
        court.setStakedWood(next);
        assertEq(court.stakedWood(), next);
    }

    function test_setAppealWindow_onlyOwnerAndBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setAppealWindow(1 days);

        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setAppealWindow(0);

        uint256 max = court.MAX_APPEAL_WINDOW();
        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setAppealWindow(max + 1);

        vm.prank(owner);
        court.setAppealWindow(max);
        assertEq(court.appealWindow(), max);
    }

    function test_setAppealVoteWindow_onlyOwnerAndBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setAppealVoteWindow(1 days);

        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setAppealVoteWindow(0);

        uint256 max = court.MAX_APPEAL_VOTE_WINDOW();
        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setAppealVoteWindow(max + 1);

        vm.prank(owner);
        court.setAppealVoteWindow(max);
        assertEq(court.appealVoteWindow(), max);
    }

    /// @notice A zero appeal bond would make appeals free and delete the only
    ///         price on failing to raise a quorum. It is never zero: the
    ///         constructor seeds it from the panel bond and the setter refuses
    ///         zero, so there is no window in the contract's life where an
    ///         appeal costs nothing.
    function test_setAppealBondWood_onlyOwnerAndRejectsZero() public {
        assertEq(court.appealBondWood(), BOND, "seeded non-zero at construction");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setAppealBondWood(1);

        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setAppealBondWood(0);

        vm.prank(owner);
        court.setAppealBondWood(7e18);
        assertEq(court.appealBondWood(), 7e18);
    }

    /// @notice An open appeal is owed the bond it ACTUALLY POSTED. Re-pricing
    ///         mid-flight must not let governance shrink a refund or inflate a
    ///         forfeit under an appellant who already paid.
    function test_setAppealBondWood_doesNotRepriceAnOpenAppeal() public {
        uint256 caseId = _panelRuled(true);
        uint256 balanceBefore = wood.balanceOf(appellant);
        _appeal(caseId);

        vm.prank(owner);
        court.setAppealBondWood(BOND * 5);

        vm.prank(whale);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        assertEq(wood.balanceOf(appellant), balanceBefore, "refunded exactly what was posted");
    }

    /// @notice A ZERO FLOOR SILENTLY DELETES D6 — every appeal, including one
    ///         swung by a handful of tokens bought for the purpose, would
    ///         override the panel. Refuse it at the setter, not only at Task 7's
    ///         deploy pre-flight.
    function test_setParticipationFloorBps_onlyOwnerAndBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setParticipationFloorBps(500);

        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setParticipationFloorBps(0);

        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setParticipationFloorBps(10_001);

        vm.expectEmit(false, false, false, true);
        emit ICourt.ParticipationFloorBpsSet(1_000, 2_500);
        vm.prank(owner);
        court.setParticipationFloorBps(2_500);
        assertEq(court.participationFloorBps(), 2_500);
    }

    /// @notice The floor is LIVE, not snapshotted with the case: raising it
    ///         turns a turnout that would have been quorate into a non-event,
    ///         and the panel ruling stands.
    function test_participationFloor_isReadAtFinalization() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(whale); // 20% — quorate under the 10% default
        court.voteAppeal(caseId, false);

        vm.prank(owner);
        court.setParticipationFloorBps(3_000); // now needs 30%

        _finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.Guilty));
        assertEq(court.forfeitedWood(), BOND);
    }

    // ─────────────────────── forfeited WOOD (Task 5's sink) ───────────────────────

    /// @dev The dead address `burnForfeited` sends to. Mirrors the private
    ///      constant in `Court`, and `StakedWood` burns to the same one.
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice **THE OWNER HAS NO PATH TO FORFEITED FUNDS, AND NEEDS NO
    ///         PERMISSION TO BE ROUTED AROUND.** `alice` is not the owner and
    ///         holds no privileged role, and she can still destroy the pot. This
    ///         is the whole point of the change: `forfeitedWood` is fed by failed
    ///         appeals and slashed panel bonds, so an owner who could direct it
    ///         was an owner who profited from the court failing. Burning removes
    ///         the beneficiary; permissionless removes the ability to sit on the
    ///         pot instead, which would be the same discretion by inaction.
    function test_burnForfeited_isPermissionlessAndBurnsTheUnreservedSurplus() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false); // below the floor: the bond is forfeited
        _finalizeAppeal(caseId);
        assertEq(court.forfeitedWood(), BOND);
        assertEq(court.reservedRewards(), 0, "rewards are off, so nothing is spoken for");
        assertEq(wood.balanceOf(BURN_ADDRESS), 0);

        vm.expectEmit(true, false, false, true);
        emit ICourt.ForfeitedWoodBurned(alice, BOND);
        vm.prank(alice); // NOT the owner
        uint256 amount = court.burnForfeited();

        assertEq(amount, BOND, "exactly the unreserved surplus");
        assertEq(wood.balanceOf(BURN_ADDRESS), BOND, "and it went to the dead address");
        assertEq(court.forfeitedWood(), 0);
        assertEq(wood.balanceOf(backstop), 0, "no beneficiary anywhere");
        _assertWoodBalances();
    }

    /// @notice The owner is not special here — it may call the burn like anybody
    ///         else, but it gains nothing by doing so: the WOOD goes to the dead
    ///         address, not to it.
    function test_burnForfeited_givesTheOwnerNothing() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        vm.prank(owner);
        court.burnForfeited();

        assertEq(wood.balanceOf(owner), 0, "the owner cannot profit from a forfeit");
        assertEq(wood.balanceOf(BURN_ADDRESS), BOND);
        _assertWoodBalances();
    }

    /// @notice **NO LIVE BOND IS EVER BURNABLE.** Three posted panel bonds and an
    ///         OPEN appeal bond sit in the court alongside a forfeited one from
    ///         an earlier case; the burn takes the forfeited one and leaves all
    ///         four positions whole. `burnForfeited` never reads `bondedWood`,
    ///         and the §4 equality is what makes that checkable.
    function test_burnForfeited_cannotTouchBondedWood() public {
        // Case 1 forfeits a bond into the pot.
        uint256 first = _panelRuled(true);
        _appeal(first);
        vm.prank(minnow);
        court.voteAppeal(first, false);
        _finalizeAppeal(first);
        assertEq(court.forfeitedWood(), BOND);

        // Case 2 is left with a LIVE appeal bond posted and unresolved.
        uint256 second = _panelRuledOn(11, true);
        _appeal(second);
        uint256 bondedBefore = court.bondedWood();
        assertEq(bondedBefore, BOND * 4, "three panel bonds + one open appeal bond");
        _assertWoodBalances();

        vm.prank(dave);
        uint256 burned = court.burnForfeited();

        assertEq(burned, BOND, "only the forfeited bond, never a live one");
        assertEq(court.bondedWood(), bondedBefore, "every posted bond survives untouched");
        assertEq(court.panelBondOf(alice), BOND);
        assertEq(court.panelBondOf(bob), BOND);
        assertEq(court.panelBondOf(carol), BOND);
        assertEq(court.caseOf(second).appealBond, BOND, "the open appeal bond is still posted");
        _assertWoodBalances();

        // ...and the appellant still gets it back when the appeal clears the floor.
        vm.prank(whale);
        court.voteAppeal(second, false);
        uint256 appellantBefore = wood.balanceOf(appellant);
        _finalizeAppeal(second);
        assertEq(wood.balanceOf(appellant), appellantBefore + BOND, "refunded in full after the burn");
        _assertWoodBalances();
    }

    /// @notice An empty surplus REVERTS rather than no-opping, matching
    ///         `claimPanelReward`'s `NothingToClaim` treatment of the same
    ///         situation. A no-op would emit a zero-amount burn event that
    ///         indexers would have to filter.
    function test_burnForfeited_revertsWhenThereIsNoSurplus() public {
        vm.expectRevert(ICourt.NothingToBurn.selector);
        vm.prank(alice);
        court.burnForfeited();
    }

    /// @notice Reverts the same way when the pot is non-empty but ENTIRELY
    ///         reserved — there is no unreserved surplus, so there is nothing
    ///         this function is allowed to take.
    function test_burnForfeited_revertsWhenThePotIsFullyReserved() public {
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        // Burn the surplus away, leaving a pot that is non-empty but entirely
        // reserved for the panel that already earned it.
        vm.prank(dave);
        court.burnForfeited();
        assertEq(court.forfeitedWood(), REWARD * 3, "the pot still holds real WOOD");
        assertEq(court.reservedRewards(), REWARD * 3, "every unit of it is spoken for");

        vm.expectRevert(ICourt.NothingToBurn.selector);
        vm.prank(alice);
        court.burnForfeited();

        assertEq(court.forfeitedWood(), REWARD * 3, "and the reserve is still there");
        _assertWoodBalances();
    }

    /// @notice **THE REGRESSION THE OLD SWEEP WOULD HAVE FAILED.** A case
    ///         resolves and accrues rewards for all three panelists; then the pot
    ///         is burned. Every panelist can still claim IN FULL. Under the old
    ///         `sweepForfeited` the owner could have taken the pot and the
    ///         panel's pay would simply not have happened — which is not just a
    ///         bookkeeping defect, because an unpaid panel is an absent panel and
    ///         a panel that does not rule inside `panelWindow` acquits by
    ///         default. Reward funding is a liveness property of layer 1.
    function test_burnForfeited_cannotTakeRewardsAlreadyAccrued() public {
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false); // forfeits BOND into the pot
        _finalizeAppeal(caseId);

        assertEq(court.forfeitedWood(), BOND, "the pot still HOLDS the rewards");
        assertEq(court.reservedRewards(), REWARD * 3, "...but three of them are reserved");
        assertEq(_outstandingRewards(), REWARD * 3, "the accumulator matches the credits");
        _assertWoodBalances();

        vm.prank(dave);
        uint256 burned = court.burnForfeited();
        assertEq(burned, BOND - REWARD * 3, "the surplus only");
        assertEq(wood.balanceOf(BURN_ADDRESS), BOND - REWARD * 3);
        assertEq(court.forfeitedWood(), REWARD * 3, "exactly the reserve is left standing");
        assertEq(court.reservedRewards(), REWARD * 3);
        _assertWoodBalances();

        // The whole panel claims IN FULL, after the burn.
        address[3] memory panel = [alice, bob, carol];
        for (uint256 i; i < panel.length; ++i) {
            uint256 before = wood.balanceOf(panel[i]);
            vm.prank(panel[i]);
            assertEq(court.claimPanelReward(), REWARD, "reserved pay survived the burn");
            assertEq(wood.balanceOf(panel[i]), before + REWARD);
            _assertWoodBalances();
        }

        assertEq(court.forfeitedWood(), 0, "the reserve is exactly drained, no dust");
        assertEq(court.reservedRewards(), 0);
        assertEq(court.bondedWood(), BOND * 3, "and the panel bonds were never involved");
    }

    /// @notice A second burn after the panel has claimed finds nothing left —
    ///         the reserve was spent by its payees, not left burnable.
    function test_burnForfeited_isIdempotentOnceTheSurplusIsGone() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        vm.prank(alice);
        court.burnForfeited();

        vm.expectRevert(ICourt.NothingToBurn.selector);
        vm.prank(alice);
        court.burnForfeited();
        _assertWoodBalances();
    }

    /// @notice **THE FULL LIFECYCLE: credit → reserve → burn → claim**, with the
    ///         §4 identity and the `forfeitedWood >= reservedRewards`
    ///         containment asserted at every single step.
    function test_invariant_holdsAcrossCreditReserveBurnAndClaim() public {
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        _assertWoodBalances();

        // CREDIT: a below-floor appeal forfeits its bond into the pot.
        uint256 caseId = _panelRuled(true);
        _assertWoodBalances();
        _appeal(caseId);
        _assertWoodBalances();
        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _assertWoodBalances();

        // RESERVE: resolution accrues three rewards out of that pot.
        _finalizeAppeal(caseId);
        _assertWoodBalances();
        assertEq(court.forfeitedWood(), BOND);
        assertEq(court.reservedRewards(), REWARD * 3);

        // BURN: the unreserved surplus, and only that.
        vm.prank(dave);
        court.burnForfeited();
        _assertWoodBalances();
        assertEq(court.forfeitedWood(), REWARD * 3);

        // CLAIM: the reserve draws down in lockstep with the pot.
        vm.prank(alice);
        court.claimPanelReward();
        _assertWoodBalances();
        assertEq(court.reservedRewards(), REWARD * 2);
        assertEq(court.forfeitedWood(), REWARD * 2, "pot and reserve move together");

        vm.prank(bob);
        court.claimPanelReward();
        _assertWoodBalances();
        vm.prank(carol);
        court.claimPanelReward();
        _assertWoodBalances();

        assertEq(court.forfeitedWood(), 0);
        assertEq(court.reservedRewards(), 0);
        assertEq(_outstandingRewards(), 0);
        assertEq(wood.balanceOf(address(court)), court.bondedWood(), "only posted bonds remain");
    }

    /// @notice A reserve made by case 1 is NOT available to fund case 2. Counting
    ///         it would let the second panel be credited against the first
    ///         panel's money and leave whichever claimed second unable to
    ///         withdraw.
    function test_panelReward_doesNotFundOneCaseOutOfAnotherCasesReserve() public {
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        _seatBonded(_three());

        // Case 1 forfeits exactly enough to reserve one panel's rewards.
        uint256 first = _panelRuledOn(11, true);
        _appeal(first);
        vm.prank(minnow);
        court.voteAppeal(first, false);
        _finalizeAppeal(first);
        assertEq(court.reservedRewards(), REWARD * 3);

        // Drain the surplus so ONLY the reserve is left in the pot.
        vm.prank(dave);
        court.burnForfeited();
        assertEq(court.forfeitedWood(), REWARD * 3, "the pot is now entirely reserved");

        // Case 2 resolves against an empty SURPLUS, so it pays nobody.
        uint256 second = _panelRuledOn(12, true);
        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelRewardUnfunded(second, REWARD * 3, 0);
        _resolveUnappealed(second);

        assertEq(court.reservedRewards(), REWARD * 3, "case 1's reserve is untouched");
        assertEq(_outstandingRewards(), REWARD * 3, "no second credit was invented");
        _assertWoodBalances();

        // Case 1's panel is still paid in full.
        vm.prank(alice);
        assertEq(court.claimPanelReward(), REWARD);
        _assertWoodBalances();
    }

    // ────────────────── §4 invariant across the whole two-layer flow ──────────────────

    /// @notice Spec §4's accounting identity, extended for layer 2:
    ///         `balance == bondedWood + forfeitedWood` at EVERY step of a case
    ///         that runs both layers. `bondedWood` is what somebody can still
    ///         claim; `forfeitedWood` is what the protocol now owns.
    function test_invariant_balanceEqualsBondedPlusForfeitedAcrossAnAppeal() public {
        uint256 caseId = _panelRuled(true);
        _assertWoodBalances();

        _appeal(caseId);
        _assertWoodBalances();
        assertEq(court.bondedWood(), BOND * 4, "three panel bonds + the appeal bond");

        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _assertWoodBalances();

        _finalizeAppeal(caseId);
        _assertWoodBalances();
        assertEq(court.bondedWood(), BOND * 3);
        assertEq(court.forfeitedWood(), BOND);

        vm.prank(dave); // permissionless: no owner path to forfeited funds exists
        court.burnForfeited();
        _assertWoodBalances();
    }

    /// @dev The §4 identity, plus the containment that keeps it a TWO-term
    ///      identity. `reservedRewards` is a subset of `forfeitedWood`, so it
    ///      must never exceed it — if it ever did, reserved rewards would be
    ///      backed by WOOD the court does not hold and the burn's
    ///      `forfeitedWood - reservedRewards` would underflow.
    function _assertWoodBalances() internal view {
        assertEq(wood.balanceOf(address(court)), court.bondedWood() + court.forfeitedWood());
        assertLe(court.reservedRewards(), court.forfeitedWood(), "reserved rewards must stay inside the pot");
    }

    /// @dev Every outstanding credit, summed. `reservedRewards` is supposed to
    ///      equal exactly this — it is the accumulator behind the per-member
    ///      mapping, and drift between the two is either a reward the court
    ///      cannot pay or WOOD stranded forever.
    function _outstandingRewards() internal view returns (uint256) {
        return
            court.panelRewardOf(alice) + court.panelRewardOf(bob) + court.panelRewardOf(carol)
                + court.panelRewardOf(dave);
    }

    // ═════════════ Task 5: the bad-faith track (D4, finding F6) ═════════════

    /// @dev The flat per-ruling reward these tests configure. Small enough that
    ///      one forfeited appeal bond covers a three-member panel.
    uint256 internal constant REWARD = 100e18;

    // ── helpers ──

    /// @dev A second, third, … case on an ALREADY-BONDED panel. `_panelRuled`
    ///      seats and bonds, and `postPanelBond` may only be called once, so
    ///      every multi-case test comes through here instead.
    function _referOn(uint256 challengeId) internal returns (uint256 caseId) {
        uint256 proposalId = PROPOSAL_ID + challengeId;
        governor.setExecuted(proposalId, vm.getBlockTimestamp() - 1 days);
        game.setChallenge(challengeId, address(governor), proposalId, IChallengeGame.Status.Disputed);
        caseId = court.refer(challengeId);
        _setElectorate(caseId);
    }

    function _panelRuledOn(uint256 challengeId, bool guilty) internal returns (uint256 caseId) {
        caseId = _referOn(challengeId);
        vm.prank(alice);
        court.panelRule(caseId, guilty);
        vm.prank(bob);
        court.panelRule(caseId, guilty);
        vm.prank(carol);
        court.panelRule(caseId, guilty);
        court.finalizePanel(caseId);
    }

    /// @dev Let the appeal window lapse and resolve on the panel's ruling.
    function _resolveUnappealed(uint256 caseId) internal {
        vm.warp(court.caseOf(caseId).panelFinalizedAt + court.appealWindow());
        court.finalizeUnappealed(caseId);
    }

    /// @dev A RESOLVED conviction: the panel convicted unanimously and nobody
    ///      appealed. The starting point for most of this section, because the
    ///      bad-faith track only opens once the CASE itself is terminal.
    function _resolvedConviction() internal returns (uint256 caseId) {
        caseId = _panelRuled(true);
        _resolveUnappealed(caseId);
    }

    function _openBadFaith(uint256 caseId, address panelist, address opener) internal {
        vm.prank(opener);
        court.openBadFaith(caseId, panelist);
    }

    function _voteBadFaith(uint256 caseId, address panelist, address voter, bool badFaith) internal {
        vm.prank(voter);
        court.voteBadFaith(caseId, panelist, badFaith);
    }

    /// @dev Burn the vote window down and close the proceeding.
    function _finalizeBadFaith(uint256 caseId, address panelist) internal {
        uint256 openedAt = court.badFaithOf(caseId, panelist).openedAt;
        vm.warp(openedAt + court.appealVoteWindow());
        court.finalizeBadFaith(caseId, panelist);
    }

    // ───── the two directions of independence: THE POINT OF THIS TASK ─────

    /// @notice **DIRECTION 1 (D4/F6): OVERTURNING THE MERITS DOES NOT SLASH.**
    ///         The whole panel convicted and the whole panel was reversed by a
    ///         quorate appeal, and not one member loses a wei. This is the
    ///         property the first draft of §3.5 got wrong: if the merits appeal
    ///         slashed, an attacker who controls the cheap appeal layer would
    ///         collect twice — a corrupt ruling made safe AND the honest
    ///         panelists who voted against it punished for it — and every
    ///         panelist would have a beauty-contest incentive to predict the
    ///         token vote rather than read the evidence. WITHOUT THIS TEST THE
    ///         F6 FIX IS UNVERIFIED.
    function test_badFaith_meritsOverturnNeverSlashesThePanelBond() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, false); // 20% of the electorate: quorate, and it overturns
        _finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.NotGuilty), "the appeal overturned");
        assertEq(court.panelBondOf(alice), BOND, "the merits vote has no slashing power");
        assertEq(court.panelBondOf(bob), BOND);
        assertEq(court.panelBondOf(carol), BOND);
        assertEq(court.bondedWood(), BOND * 3);
        assertEq(court.forfeitedWood(), 0, "being overturned forfeits nothing");
        // Nor does an overturn implicitly open the other track: the bad-faith
        // proceeding is something a human must file, on its own question.
        assertEq(court.badFaithOf(caseId, alice).openedAt, 0);
        assertEq(court.openBadFaithVotes(alice), 0);
        _assertWoodBalances();
    }

    /// @notice **DIRECTION 2 (D4/F6): WINNING THE MERITS APPEAL DOES NOT
    ///         IMMUNIZE.** The appeal reached quorum and UPHELD alice's ruling —
    ///         on the merits she was vindicated — and the separate bad-faith vote
    ///         still takes her bond. An attacker who captures the cheap appeal
    ///         layer therefore buys a safe verdict and nothing else; the conduct
    ///         of the panelists who delivered it is still answerable to a vote it
    ///         did not win. The mirror image of the test above, and the half that
    ///         stops "control the appeal" from being a complete defence.
    function test_badFaith_slashesEvenWhenTheMeritsAppealUpheldTheRuling() public {
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(whale);
        court.voteAppeal(caseId, true); // quorate, and it UPHOLDS the conviction
        _finalizeAppeal(caseId);
        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.Guilty), "the panel was upheld");

        _openBadFaith(caseId, alice, dave);
        _voteBadFaith(caseId, alice, whale, true);
        _finalizeBadFaith(caseId, alice);

        assertEq(court.panelBondOf(alice), 0, "winning on the merits must not immunize");
        assertTrue(court.badFaithOf(caseId, alice).slashed);
        assertEq(court.forfeitedWood(), BOND, "the slashed bond is the protocol's");
        // Per-panelist conduct, not collective punishment: her colleagues ruled
        // exactly the same way and are untouched.
        assertEq(court.panelBondOf(bob), BOND);
        assertEq(court.panelBondOf(carol), BOND);
        assertEq(court.bondedWood(), BOND * 2);
        assertFalse(court.isReadyToRule(alice), "a stripped member must re-post before it can rule again");
        _assertWoodBalances();
    }

    /// @notice The same independence from the other end of the case: an
    ///         UNAPPEALED conviction is not a shield either. Nothing about the
    ///         merits — appealed, unappealed, upheld, overturned — enters this
    ///         proceeding's arithmetic.
    function test_badFaith_slashesAnUnappealedRulingToo() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);
        _voteBadFaith(caseId, alice, whale, true);
        _finalizeBadFaith(caseId, alice);

        assertEq(court.panelBondOf(alice), 0);
        assertEq(court.forfeitedWood(), BOND);
        _assertWoodBalances();
    }

    // ───────────── the participation floor, on this track too ─────────────

    /// @notice A BELOW-FLOOR PROCEEDING DOES NOT SLASH. The bad-faith track
    ///         reads the SAME floor against the SAME stored `snapshotTs` as the
    ///         appeal (D6): a handful of tokens must not be able to take an
    ///         honest panelist's bond any more than they can overturn a ruling.
    ///         The floor in the log is computed from the case's stored snapshot,
    ///         never recomputed at finalization time.
    function test_badFaith_belowTheFloorDoesNotSlash() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);
        uint256 openerBalance = wood.balanceOf(dave);
        _voteBadFaith(caseId, alice, minnow, true); // 1% against a 10% floor

        uint256 expectedFloor = TOTAL_VOTES * court.participationFloorBps() / 10_000;
        vm.warp(court.badFaithOf(caseId, alice).openedAt + court.appealVoteWindow());
        vm.expectEmit(true, true, false, true);
        emit ICourt.BadFaithFinalized(caseId, alice, false, 10_000e18, 0, expectedFloor);
        court.finalizeBadFaith(caseId, alice);

        assertEq(court.panelBondOf(alice), BOND, "below the floor the proceeding decides nothing");
        assertFalse(court.badFaithOf(caseId, alice).slashed);
        assertEq(court.forfeitedWood(), 0);
        assertEq(wood.balanceOf(dave), openerBalance + BOND, "the opener's bond returns on every branch");
        _assertWoodBalances();
    }

    /// @notice A quorate electorate that says GOOD faith leaves the bond whole —
    ///         a real vindication, distinguishable in the log from the
    ///         below-floor non-event above by its tally.
    function test_badFaith_quorateGoodFaithMajorityLeavesTheBondWhole() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);
        _voteBadFaith(caseId, alice, whale, false); // 20% says good faith
        _voteBadFaith(caseId, alice, minnow, true);
        _finalizeBadFaith(caseId, alice);

        assertEq(court.panelBondOf(alice), BOND);
        assertFalse(court.badFaithOf(caseId, alice).slashed);
        assertEq(court.badFaithOf(caseId, alice).goodFaithVotes, 200_000e18);
        assertEq(court.badFaithOf(caseId, alice).badFaithVotes, 10_000e18);
    }

    /// @notice A TIE ABOVE THE FLOOR LEAVES THE BOND WHOLE — the same fail-safe
    ///         direction every other verdict in this contract takes. An
    ///         electorate split down the middle has not established that a
    ///         ruling was corrupt.
    function test_badFaith_tieAboveTheFloorLeavesTheBondWhole() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, appellant);
        _voteBadFaith(caseId, alice, whale, true); // 200_000e18
        _voteBadFaith(caseId, alice, dave, false); // 200_000e18 — a dead heat
        _finalizeBadFaith(caseId, alice);

        assertEq(court.panelBondOf(alice), BOND, "a split electorate has not established bad faith");
    }

    /// @notice THE SAME ELECTORATE AS THE MERITS APPEAL, from the same stored
    ///         snapshot (D2/D3). `newbie` bought in after the drain, so it has no
    ///         weight in EITHER vote — nobody who accumulated WOOD once the
    ///         exploit was visible can vote to punish, or to protect, the panel
    ///         that judged it.
    function test_voteBadFaith_postSnapshotStakerHasNoVotingPower() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);

        vm.expectRevert(ICourt.NoVotingPower.selector);
        vm.prank(newbie);
        court.voteBadFaith(caseId, alice, true);

        vm.expectRevert(ICourt.NoVotingPower.selector);
        vm.prank(makeAddr("stranger"));
        court.voteBadFaith(caseId, alice, true);
    }

    // ───────── the bond stays in reach for the whole proceeding ─────────

    /// @notice **THE BOND MUST NOT ESCAPE MID-VOTE.** `panelBondLockedUntil` is a
    ///         deadline, and a deadline can expire while a proceeding is still
    ///         running: governance may lengthen `badFaithWindow` after a case
    ///         resolved (the stored lock does not move with it), and a vote
    ///         opened near the end of the window outlives it by a full
    ///         `appealVoteWindow` regardless. The open-proceeding counter is what
    ///         covers that gap — without it a panelist front-runs the
    ///         `finalizeBadFaith` that was about to slash it and walks away with
    ///         the bond.
    function test_withdrawPanelBond_revertsWhileABadFaithVoteIsOpen() public {
        uint256 caseId = _resolvedConviction();
        uint256 deadlineLock = court.panelBondLockedUntil(alice);

        vm.prank(owner);
        court.setBadFaithWindow(60 days);
        vm.warp(deadlineLock + 1);

        // The deadline has expired, so alice can be rotated off and would
        // otherwise be free to take her bond straight back.
        address[] memory rest = new address[](2);
        rest[0] = bob;
        rest[1] = carol;
        _seat(rest);
        assertFalse(court.isPanelist(alice));

        _openBadFaith(caseId, alice, dave);
        vm.expectRevert(ICourt.PanelistHasOpenRuling.selector);
        vm.prank(alice);
        court.withdrawPanelBond();

        // And waiting does not release it either: what holds the bond now is the
        // live proceeding, not the clock.
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.expectRevert(ICourt.PanelistHasOpenRuling.selector);
        vm.prank(alice);
        court.withdrawPanelBond();

        court.finalizeBadFaith(caseId, alice); // nobody voted: no slash
        assertEq(court.openBadFaithVotes(alice), 0);
        vm.prank(alice);
        assertEq(court.withdrawPanelBond(), BOND, "vindicated and unseated, the bond is hers again");
        _assertWoodBalances();
    }

    /// @notice The same guard on the roster side: the owner cannot rotate a
    ///         panelist out from under a live proceeding, which would make its
    ///         bond withdrawable before the vote could take it.
    function test_setPanel_cannotUnseatAPanelistWithAnOpenBadFaithVote() public {
        uint256 caseId = _resolvedConviction();
        uint256 deadlineLock = court.panelBondLockedUntil(alice);
        vm.prank(owner);
        court.setBadFaithWindow(60 days);
        vm.warp(deadlineLock + 1);
        _openBadFaith(caseId, alice, dave);

        address[] memory rest = new address[](2);
        rest[0] = bob;
        rest[1] = carol;
        vm.expectRevert(ICourt.PanelistHasOpenRuling.selector);
        vm.prank(owner);
        court.setPanel(rest);
    }

    // ─────────────────────── opening a proceeding ───────────────────────

    function test_openBadFaith_pullsTheBondAndLocksTheTarget() public {
        uint256 caseId = _resolvedConviction();
        uint256 bondedBefore = court.bondedWood();
        uint256 openerBefore = wood.balanceOf(dave);
        uint256 bond = court.badFaithBondWood();
        uint256 deadline = vm.getBlockTimestamp() + court.appealVoteWindow();

        vm.expectEmit(true, true, true, true);
        emit ICourt.BadFaithOpened(caseId, alice, dave, bond, deadline);
        vm.prank(dave);
        court.openBadFaith(caseId, alice);

        assertEq(court.bondedWood(), bondedBefore + bond);
        assertEq(wood.balanceOf(dave), openerBefore - bond);
        assertEq(court.openBadFaithVotes(alice), 1);
        assertEq(court.badFaithOf(caseId, alice).opener, dave);
        assertEq(court.badFaithOf(caseId, alice).bond, bond);
        _assertWoodBalances();
    }

    /// @notice There is no ruling to answer for until the COURT has spoken: an
    ///         appeal can still change what the panel's ruling meant, and a
    ///         panelist must not be put on trial for a case still in flight.
    function test_openBadFaith_beforeTheCaseResolvesReverts() public {
        uint256 caseId = _panelRuled(true); // still sitting in AppealWindow
        vm.expectRevert(ICourt.WrongPhase.selector);
        vm.prank(dave);
        court.openBadFaith(caseId, alice);
    }

    function test_openBadFaith_afterTheWindowReverts() public {
        uint256 caseId = _resolvedConviction();
        vm.warp(court.caseOf(caseId).finalizedAt + court.badFaithWindow());
        vm.expectRevert(ICourt.WindowClosed.selector);
        vm.prank(dave);
        court.openBadFaith(caseId, alice);
    }

    /// @notice THE TARGET SET IS `panelVoters`, NOT THE ROSTER. Carol sat on the
    ///         panel for this case and abstained, so she has no ruling to answer
    ///         for and no bond at risk.
    function test_openBadFaith_againstAMemberThatDidNotRuleReverts() public {
        uint256 caseId = _panelRuledWithAbstention(true);
        _resolveUnappealed(caseId);

        vm.expectRevert(ICourt.PanelistDidNotRule.selector);
        vm.prank(dave);
        court.openBadFaith(caseId, carol);

        // ...and neither has a bystander who never sat at all.
        vm.expectRevert(ICourt.PanelistDidNotRule.selector);
        vm.prank(dave);
        court.openBadFaith(caseId, appellant);
    }

    /// @notice ONE PROCEEDING PER (CASE, PANELIST) PAIR, EVER — including after
    ///         the first one resolved. Re-running a lost accusation would let an
    ///         attacker keep an honest panelist's bond escrowed indefinitely, one
    ///         vote at a time, since every open proceeding re-locks it.
    function test_openBadFaith_cannotBeOpenedTwice() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);

        vm.expectRevert(ICourt.BadFaithAlreadyOpened.selector);
        vm.prank(appellant);
        court.openBadFaith(caseId, alice);

        _finalizeBadFaith(caseId, alice);
        vm.expectRevert(ICourt.BadFaithAlreadyOpened.selector);
        vm.prank(dave);
        court.openBadFaith(caseId, alice);
    }

    // ──────────────────────── voting and finalizing ────────────────────────

    function test_voteBadFaith_tallyIsStakeWeighted() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);

        vm.expectEmit(true, true, true, true);
        emit ICourt.BadFaithVoteCast(caseId, alice, whale, true, 200_000e18);
        vm.prank(whale);
        court.voteBadFaith(caseId, alice, true);

        assertEq(court.badFaithOf(caseId, alice).badFaithVotes, 200_000e18);
        assertEq(uint256(court.badFaithVoteOf(caseId, alice, whale)), uint256(ICourt.Ruling.Guilty));
    }

    function test_voteBadFaith_doubleVoteReverts() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);
        _voteBadFaith(caseId, alice, whale, true);

        vm.expectRevert(ICourt.AlreadyVoted.selector);
        vm.prank(whale);
        court.voteBadFaith(caseId, alice, false);
        assertEq(court.badFaithOf(caseId, alice).badFaithVotes, 200_000e18, "and no double-count");
    }

    function test_voteBadFaith_beforeOpeningReverts() public {
        uint256 caseId = _resolvedConviction();
        vm.expectRevert(ICourt.BadFaithNotOpen.selector);
        vm.prank(whale);
        court.voteBadFaith(caseId, alice, true);
    }

    function test_voteBadFaith_afterTheWindowReverts() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);
        vm.warp(court.badFaithOf(caseId, alice).openedAt + court.appealVoteWindow());

        vm.expectRevert(ICourt.WindowClosed.selector);
        vm.prank(whale);
        court.voteBadFaith(caseId, alice, true);
    }

    function test_finalizeBadFaith_beforeTheWindowClosesReverts() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);
        vm.warp(court.badFaithOf(caseId, alice).openedAt + court.appealVoteWindow() - 1);

        vm.expectRevert(ICourt.WindowOpen.selector);
        court.finalizeBadFaith(caseId, alice);
    }

    function test_finalizeBadFaith_twiceReverts() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);
        _finalizeBadFaith(caseId, alice);

        vm.expectRevert(ICourt.BadFaithNotOpen.selector);
        court.finalizeBadFaith(caseId, alice);
    }

    function test_finalizeBadFaith_onAProceedingThatWasNeverOpenedReverts() public {
        uint256 caseId = _resolvedConviction();
        vm.expectRevert(ICourt.BadFaithNotOpen.selector);
        court.finalizeBadFaith(caseId, alice);
    }

    /// @notice A member already stripped of its bond has nothing left to take.
    ///         The second proceeding still CONCLUDES and still returns its
    ///         opener's bond — a no-op slash rather than a revert, which would
    ///         strand both that bond and the member's lock forever.
    function test_finalizeBadFaith_slashingAStrippedMemberIsANoOp() public {
        _seatBonded(_three());
        uint256 first = _panelRuledOn(11, true);
        _resolveUnappealed(first);
        uint256 second = _panelRuledOn(12, true);
        _resolveUnappealed(second);

        _openBadFaith(first, alice, dave);
        _voteBadFaith(first, alice, whale, true);
        _finalizeBadFaith(first, alice);
        assertEq(court.panelBondOf(alice), 0);
        assertEq(court.forfeitedWood(), BOND);

        uint256 openerBefore = wood.balanceOf(appellant);
        _openBadFaith(second, alice, appellant);
        _voteBadFaith(second, alice, whale, true);
        _finalizeBadFaith(second, alice);

        assertTrue(court.badFaithOf(second, alice).slashed);
        assertEq(court.forfeitedWood(), BOND, "nothing left to take, and nothing conjured");
        assertEq(wood.balanceOf(appellant), openerBefore, "the second opener is still made whole");
        _assertWoodBalances();
    }

    // ───────────────── §4 invariant across the new path ─────────────────

    /// @notice Spec §4's accounting identity across a bad-faith slash, at every
    ///         step: `balance == bondedWood + forfeitedWood`. The slashed bond
    ///         crosses from the claimable bucket to the protocol-owned one in a
    ///         single statement, so the equality never has an intermediate state,
    ///         and it lands in the EXISTING sink rather than a second one.
    function test_invariant_balanceEqualsBondedPlusForfeitedAcrossABadFaithSlash() public {
        uint256 caseId = _resolvedConviction();
        _assertWoodBalances();

        _openBadFaith(caseId, alice, dave);
        _assertWoodBalances();
        assertEq(court.bondedWood(), BOND * 4, "three panel bonds + the bad-faith bond");

        _voteBadFaith(caseId, alice, whale, true);
        _assertWoodBalances();

        _finalizeBadFaith(caseId, alice);
        _assertWoodBalances();
        assertEq(court.bondedWood(), BOND * 2, "bob's and carol's");
        assertEq(court.forfeitedWood(), BOND, "alice's is the protocol's now");

        vm.prank(dave);
        court.burnForfeited();
        _assertWoodBalances();
        assertEq(wood.balanceOf(BURN_ADDRESS), BOND, "one sink, and its only exit has no beneficiary");
        assertEq(wood.balanceOf(backstop), 0, "nobody collects a slashed bond, governance included");
    }

    // ─────────────────── the flat panelist reward (D5) ───────────────────

    /// @notice **D5: THE REWARD IS FLAT ACROSS VERDICTS.** One case, a SPLIT
    ///         panel: alice and carol convict, bob acquits, and all three are
    ///         paid exactly the same. This is what stops the reward itself from
    ///         biasing verdicts — a reward that paid more for landing on the
    ///         winning side would pay panelists to predict the eventual vote
    ///         instead of reading the evidence, which is the same beauty-contest
    ///         failure D4 removes from the slashing side.
    function test_panelReward_isIdenticalWhicheverWayAMemberRuled() public {
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        _seatBonded(_three());
        uint256 caseId = _refer();
        _setElectorate(caseId);

        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.prank(bob);
        court.panelRule(caseId, false);
        vm.prank(carol);
        court.panelRule(caseId, true);
        court.finalizePanel(caseId);

        // A below-floor appeal forfeits its bond, which is what funds the pot:
        // bad conduct pays the honest panel's sitting fee.
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        assertEq(uint256(court.caseOf(caseId).finalRuling), uint256(ICourt.Ruling.Guilty));
        assertEq(court.panelRewardOf(alice), REWARD, "ruled with the majority");
        assertEq(court.panelRewardOf(bob), REWARD, "ruled AGAINST it - identical pay (D5)");
        assertEq(court.panelRewardOf(carol), REWARD);
        // Reserved, not moved: the WOOD stays in the protocol-owned pot and is
        // merely fenced off there until it is claimed.
        assertEq(court.forfeitedWood(), BOND, "still in the pot");
        assertEq(court.reservedRewards(), REWARD * 3, "...but spoken for");
        _assertWoodBalances();
    }

    /// @notice ...and it does not depend on which way the CASE came out either.
    ///         Alice earns the same for a conviction and for an acquittal, so
    ///         there is no verdict she is paid to prefer.
    function test_panelReward_doesNotDependOnHowTheCaseCameOut() public {
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        _seatBonded(_three());

        uint256 convicted = _panelRuledOn(11, true);
        _appeal(convicted);
        vm.prank(minnow);
        court.voteAppeal(convicted, false); // below the floor: funds the pot
        _finalizeAppeal(convicted);
        uint256 afterConviction = court.panelRewardOf(alice);

        uint256 acquitted = _panelRuledOn(12, false);
        _appeal(acquitted);
        vm.prank(minnow);
        court.voteAppeal(acquitted, true);
        _finalizeAppeal(acquitted);

        assertEq(afterConviction, REWARD);
        assertEq(court.panelRewardOf(alice) - afterConviction, REWARD, "the same pay for an acquittal");
        _assertWoodBalances();
    }

    /// @notice A member that ABSTAINED earns nothing: the reward is for ruling,
    ///         which is what makes it a fee for the work rather than a stipend
    ///         for the seat.
    function test_panelReward_onlyAccruesToTheMembersThatRuled() public {
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        _seatBonded(_three());
        uint256 caseId = _refer();
        _setElectorate(caseId);
        vm.prank(alice);
        court.panelRule(caseId, true);
        vm.prank(bob);
        court.panelRule(caseId, true);
        vm.warp(court.caseOf(caseId).referredAt + court.panelWindow());
        court.finalizePanel(caseId);

        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        assertEq(court.panelRewardOf(alice), REWARD);
        assertEq(court.panelRewardOf(bob), REWARD);
        assertEq(court.panelRewardOf(carol), 0, "carol abstained");
    }

    /// @notice ALL OR NOTHING when the pot is short. Paying it down in vote order
    ///         would make the reward depend on WHEN a member ruled — a race to
    ///         vote first, which is a bias on panel behaviour of exactly the kind
    ///         D5 exists to remove.
    function test_panelReward_paysNoneWhenThePotCannotPayEveryMember() public {
        vm.prank(owner);
        court.setPanelRewardWood(BOND); // three members => 3 * BOND required
        uint256 caseId = _panelRuled(true);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false); // forfeits ONE bond into the pot

        vm.warp(court.caseOf(caseId).appealedAt + court.appealVoteWindow());
        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelRewardUnfunded(caseId, BOND * 3, BOND);
        court.finalizeAppeal(caseId);

        assertEq(court.panelRewardOf(alice), 0);
        assertEq(court.panelRewardOf(bob), 0);
        assertEq(court.forfeitedWood(), BOND, "the pot is left exactly as it was");
        _assertWoodBalances();
    }

    /// @notice Rewards are off by default, so a court deployed with an empty pot
    ///         accrues nothing and the §4 equality is untouched.
    function test_panelReward_isOffByDefault() public {
        assertEq(court.panelRewardWood(), 0);
        uint256 caseId = _resolvedConviction();
        assertEq(court.panelRewardOf(alice), 0);
        assertEq(caseId, 1);
        _assertWoodBalances();
    }

    function test_claimPanelReward_paysTheMemberAndKeepsTheInvariant() public {
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        _seatBonded(_three());
        uint256 caseId = _panelRuledOn(11, true);
        _appeal(caseId);
        vm.prank(minnow);
        court.voteAppeal(caseId, false);
        _finalizeAppeal(caseId);

        uint256 bondedBefore = court.bondedWood();
        uint256 forfeitedBefore = court.forfeitedWood();
        uint256 reservedBefore = court.reservedRewards();
        uint256 balanceBefore = wood.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit ICourt.PanelRewardClaimed(alice, REWARD);
        vm.prank(alice);
        assertEq(court.claimPanelReward(), REWARD);

        assertEq(wood.balanceOf(alice), balanceBefore + REWARD);
        // The claim is paid out of the RESERVE inside the protocol-owned pot,
        // not out of `bondedWood` — the reward was never a posted bond.
        assertEq(court.bondedWood(), bondedBefore, "posted bonds are not the source");
        assertEq(court.forfeitedWood(), forfeitedBefore - REWARD);
        assertEq(court.reservedRewards(), reservedBefore - REWARD, "pot and reserve draw down together");
        assertEq(court.panelRewardOf(alice), 0);
        _assertWoodBalances();

        // The reward is not the bond: claiming it does not touch what answers to
        // the bad-faith track.
        assertEq(court.panelBondOf(alice), BOND);
        vm.expectRevert(ICourt.NothingToClaim.selector);
        vm.prank(alice);
        court.claimPanelReward();
    }

    function test_claimPanelReward_revertsWithNothingAccrued() public {
        vm.expectRevert(ICourt.NothingToClaim.selector);
        vm.prank(alice);
        court.claimPanelReward();
    }

    // ─────────────────────────── owner parameters ───────────────────────────

    /// @notice A free proceeding is a free way to escrow an honest panelist's
    ///         bond for a full vote window, so zero is refused here even though
    ///         the bond returns on every branch.
    function test_setBadFaithBondWood_onlyOwnerAndRejectsZero() public {
        assertEq(court.badFaithBondWood(), BOND, "seeded from the panel bond, never zero");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setBadFaithBondWood(1);

        vm.expectRevert(ICourt.InvalidParameter.selector);
        vm.prank(owner);
        court.setBadFaithBondWood(0);

        vm.expectEmit(false, false, false, true);
        emit ICourt.BadFaithBondWoodSet(BOND, 5e18);
        vm.prank(owner);
        court.setBadFaithBondWood(5e18);
        assertEq(court.badFaithBondWood(), 5e18);
    }

    /// @notice An open proceeding is owed the bond it ACTUALLY posted, whatever
    ///         governance re-prices it to afterwards.
    function test_setBadFaithBondWood_doesNotRepriceAnOpenProceeding() public {
        uint256 caseId = _resolvedConviction();
        _openBadFaith(caseId, alice, dave);
        uint256 openerBalance = wood.balanceOf(dave);

        vm.prank(owner);
        court.setBadFaithBondWood(1e18);

        _finalizeBadFaith(caseId, alice);
        assertEq(wood.balanceOf(dave), openerBalance + BOND, "returned at the posted price");
        _assertWoodBalances();
    }

    /// @notice Zero is legal here — it turns rewards off. The shape this setter
    ///         cannot express is a reward that varies with the verdict (D5):
    ///         there is no argument for one.
    function test_setPanelRewardWood_onlyOwnerAndZeroDisables() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        court.setPanelRewardWood(REWARD);

        vm.expectEmit(false, false, false, true);
        emit ICourt.PanelRewardWoodSet(0, REWARD);
        vm.prank(owner);
        court.setPanelRewardWood(REWARD);
        assertEq(court.panelRewardWood(), REWARD);

        vm.prank(owner);
        court.setPanelRewardWood(0);
        assertEq(court.panelRewardWood(), 0);
    }
}
