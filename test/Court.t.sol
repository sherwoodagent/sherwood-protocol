// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Court} from "src/Court.sol";
import {ICourt} from "src/interfaces/ICourt.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

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

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice"); // panelist
    address internal bob = makeAddr("bob"); // panelist
    address internal carol = makeAddr("carol"); // panelist
    address internal dave = makeAddr("dave"); // outsider / replacement

    uint256 internal constant BOND = 1_000e18;

    function setUp() public {
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        court = new CourtHarness(owner, address(wood), BOND);

        // Somewhere well past genesis so `block.timestamp - x` is safe.
        vm.warp(vm.getBlockTimestamp() + 365 days);

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
}
