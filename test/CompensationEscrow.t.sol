// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CompensationEscrow} from "src/CompensationEscrow.sol";
import {ICompensationEscrow} from "src/interfaces/ICompensationEscrow.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @dev Vault stand-in exposing the ERC20Votes reads the escrow apportions
///      against. Mirrors SyndicateVault's auto-delegated behaviour, where
///      `getPastVotes(h, t)` equals that holder's share balance at `t`.
contract MockVotesVault {
    mapping(address => mapping(uint256 => uint256)) public votesAt;
    mapping(uint256 => uint256) public totalAt;

    function setVotes(address holder, uint256 ts, uint256 v) external {
        votesAt[holder][ts] = v;
    }

    function setTotal(uint256 ts, uint256 v) external {
        totalAt[ts] = v;
    }

    function getPastVotes(address holder, uint256 ts) external view returns (uint256) {
        return votesAt[holder][ts];
    }

    function getPastTotalSupply(uint256 ts) external view returns (uint256) {
        return totalAt[ts];
    }
}

contract CompensationEscrowTest is Test {
    CompensationEscrow internal escrow;
    ERC20Mock internal wood;
    MockVotesVault internal vault;

    address internal owner = makeAddr("owner");
    address internal slasher = makeAddr("slasher");
    address internal backstop = makeAddr("backstop");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal snapTs;

    function setUp() public {
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        vault = new MockVotesVault();
        escrow = new CompensationEscrow(owner, address(wood));
        vm.startPrank(owner);
        escrow.setAuthorizedFunder(slasher);
        escrow.setBackstop(backstop);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 30 days);
        snapTs = vm.getBlockTimestamp() - 1 days; // a past block

        // Alice 70%, Bob 30% of a 1,000-share supply at the snapshot.
        vault.setTotal(snapTs, 1_000e18);
        vault.setVotes(alice, snapTs, 700e18);
        vault.setVotes(bob, snapTs, 300e18);

        wood.mint(slasher, 1_000_000e18);
        vm.prank(slasher);
        wood.approve(address(escrow), type(uint256).max);
    }

    function test_openCase_pullsProceedsAndRecords() public {
        vm.prank(slasher);
        uint256 caseId = escrow.openCase(address(vault), snapTs, 10_000e18);

        assertEq(wood.balanceOf(address(escrow)), 10_000e18);
        (address v, uint256 ts, uint256 proceeds, uint256 redeemed,, bool swept) = escrow.caseOf(caseId);
        assertEq(v, address(vault));
        assertEq(ts, snapTs);
        assertEq(proceeds, 10_000e18);
        assertEq(redeemed, 0);
        assertFalse(swept);
    }

    function test_openCase_rejectsZeroVault() public {
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.ZeroAddress.selector);
        escrow.openCase(address(0), snapTs, 10_000e18);
    }

    function test_openCase_onlyAuthorizedFunder() public {
        vm.expectRevert(ICompensationEscrow.NotAuthorizedFunder.selector);
        escrow.openCase(address(vault), snapTs, 10_000e18);
    }

    function test_openCase_rejectsFutureSnapshot() public {
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.SnapshotNotPast.selector);
        escrow.openCase(address(vault), vm.getBlockTimestamp(), 10_000e18);
    }

    function test_openCase_rejectsZeroProceeds() public {
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.NothingToCompensate.selector);
        escrow.openCase(address(vault), snapTs, 0);
    }

    /// @notice A snapshot with no supply can apportion nothing — reject it at
    ///         open rather than stranding WOOD in a case nobody can redeem.
    function test_openCase_rejectsEmptySnapshotSupply() public {
        uint256 emptyTs = snapTs - 1; // never populated
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.EmptySnapshot.selector);
        escrow.openCase(address(vault), emptyTs, 10_000e18);
    }

    function _open(uint256 proceeds) internal returns (uint256) {
        vm.prank(slasher);
        return escrow.openCase(address(vault), snapTs, proceeds);
    }

    function test_claimable_isProRataAtSnapshot() public {
        uint256 caseId = _open(10_000e18);
        assertEq(escrow.claimable(caseId, alice), 7_000e18); // 70%
        assertEq(escrow.claimable(caseId, bob), 3_000e18); // 30%
    }

    function test_redeem_paysHolderAndMarksRedeemed() public {
        uint256 caseId = _open(10_000e18);
        vm.prank(alice);
        uint256 got = escrow.redeem(caseId);
        assertEq(got, 7_000e18);
        assertEq(wood.balanceOf(alice), 7_000e18);
        assertEq(escrow.claimable(caseId, alice), 0, "claim consumed");
        assertEq(escrow.totalEscrowed(), 3_000e18, "only bob's share still owed");
    }

    function test_redeem_twiceReverts() public {
        uint256 caseId = _open(10_000e18);
        vm.prank(alice);
        escrow.redeem(caseId);
        vm.prank(alice);
        vm.expectRevert(ICompensationEscrow.AlreadyRedeemed.selector);
        escrow.redeem(caseId);
    }

    function test_redeem_nonHolderReverts() public {
        uint256 caseId = _open(10_000e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ICompensationEscrow.NoClaim.selector);
        escrow.redeem(caseId);
    }

    /// @notice THE F1 PROPERTY. A coalition that drains, lets honest holders exit
    ///         at the depressed NAV, and accumulates their shares AFTERWARDS gets
    ///         nothing: the claim is pinned to the pre-drain snapshot, where the
    ///         coalition held zero. Paying the live NAV instead would have refunded
    ///         the attacker its own slash.
    function test_postDrainAccumulatorGetsNothing() public {
        address coalition = makeAddr("coalition");
        // Coalition held NOTHING at the snapshot...
        vault.setVotes(coalition, snapTs, 0);
        uint256 caseId = _open(10_000e18);

        // ...and buys up the whole supply afterwards (a LATER timestamp).
        uint256 nowTs = vm.getBlockTimestamp();
        vault.setTotal(nowTs, 1_000e18);
        vault.setVotes(coalition, nowTs, 1_000e18);

        assertEq(escrow.claimable(caseId, coalition), 0, "no pre-drain claim");
        vm.prank(coalition);
        vm.expectRevert(ICompensationEscrow.NoClaim.selector);
        escrow.redeem(caseId);

        // The pre-drain holders still hold the entire entitlement.
        assertEq(escrow.claimable(caseId, alice) + escrow.claimable(caseId, bob), 10_000e18);
    }

    /// @notice Claims are a mapping, not a token — there is no transfer surface, so
    ///         a claim cannot be bought from an exiting honest holder.
    /// @dev Asserted against the DEPLOYED DISPATCH TABLE, not by calling an
    ///      undefined selector: a call to any absent selector reverts on a
    ///      contract with no fallback, so the old "the call failed" form passed
    ///      whether or not a claim-transfer function existed. Solidity's
    ///      dispatcher embeds each external function's selector as a PUSH4
    ///      constant in runtime code, so a selector's ABSENCE from the bytecode
    ///      is real evidence the function is absent. The POSITIVE CONTROL below
    ///      is what makes that evidence trustworthy: if the scan could not find
    ///      selectors that demonstrably ARE exposed, it fails instead of passing
    ///      vacuously.
    /// @dev Only selectors the escrow could never emit as an OUTBOUND call are
    ///      listed. `transfer` / `transferFrom` / `approve` are deliberately
    ///      excluded: SafeERC20 encodes those against WOOD, so their selectors
    ///      legitimately appear in this contract's code.
    function test_claimsHaveNoTransferSurface() public view {
        bytes memory code = address(escrow).code;

        // Positive control: the scan can find functions that ARE exposed.
        assertTrue(_codeHasSelector(code, escrow.redeem.selector), "scan is broken: redeem(uint256) not found");
        assertTrue(_codeHasSelector(code, escrow.claimable.selector), "scan is broken: claimable not found");

        // The actual property: no claim ever changes hands.
        bytes4[5] memory forbidden = [
            bytes4(keccak256("transferClaim(uint256,address)")),
            bytes4(keccak256("transferClaim(uint256,address,uint256)")),
            bytes4(keccak256("assignClaim(uint256,address)")),
            bytes4(keccak256("setApprovalForAll(address,bool)")),
            bytes4(keccak256("safeTransferFrom(address,address,uint256)"))
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            assertFalse(_codeHasSelector(code, forbidden[i]), "escrow must expose no claim-transfer surface");
        }
    }

    /// @dev Scans runtime bytecode for a 4-byte selector constant.
    function _codeHasSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    // ── Per-case fund isolation ───────────────────────────────────────────

    /// @dev A vault whose reported votes EXCEED the snapshot supply. Nothing at
    ///      this layer stops a funder naming such a vault — it may be hostile,
    ///      or merely a non-standard `getPastVotes` implementation — so the
    ///      escrow has to survive one without the OTHER cases noticing.
    function _skewedVault(uint256 supply, uint256 aliceVotes) internal returns (MockVotesVault v) {
        v = new MockVotesVault();
        v.setTotal(snapTs, supply);
        v.setVotes(alice, snapTs, aliceVotes);
    }

    /// @notice THE FUND-ISOLATION PROPERTY. A 1-WOOD case whose vault reports
    ///         alice at 50x the snapshot supply must pay her at most the 1 WOOD
    ///         it was funded with. Uncapped it would pay 50 WOOD, taken from the
    ///         sibling 100,000-WOOD case's funds.
    function test_hostileVaultCannotReachASiblingCase() public {
        uint256 sibling = _open(100_000e18); // honest vault, honest holders

        MockVotesVault skew = _skewedVault(1e18, 50e18); // alice "holds" 5,000%
        vm.prank(slasher);
        uint256 hostile = escrow.openCase(address(skew), snapTs, 1e18);

        assertEq(escrow.claimable(hostile, alice), 1e18, "capped at the case's own funding");

        vm.prank(alice);
        uint256 got = escrow.redeem(hostile);
        assertEq(got, 1e18, "alice takes the hostile case's whole 1 WOOD, and not an atom more");

        // The sibling case is untouched: its holders still own all of it.
        assertEq(escrow.claimable(sibling, alice), 70_000e18, "sibling claim intact");
        assertEq(escrow.claimable(sibling, bob), 30_000e18, "sibling claim intact");
        assertEq(escrow.totalEscrowed(), 100_000e18);
        assertGe(wood.balanceOf(address(escrow)), escrow.totalEscrowed());

        // ...and both sibling holders can actually be paid.
        vm.prank(alice);
        escrow.redeem(sibling);
        vm.prank(bob);
        escrow.redeem(sibling);
        assertEq(escrow.totalEscrowed(), 0);
    }

    /// @notice Cases opened side by side do not interfere: redeeming one moves
    ///         neither the other's `claimable` nor its accounting.
    function test_twoCasesCoexistWithoutInterference() public {
        uint256 c1 = _open(10_000e18);
        uint256 c2 = _open(1_000e18);
        assertEq(escrow.totalEscrowed(), 11_000e18);

        vm.prank(alice);
        escrow.redeem(c1);

        assertEq(escrow.claimable(c1, alice), 0, "c1 claim spent");
        assertEq(escrow.claimable(c2, alice), 700e18, "c2 claim untouched");
        assertEq(escrow.claimable(c2, bob), 300e18, "c2 claim untouched");
        (,,, uint256 redeemed2,,) = escrow.caseOf(c2);
        assertEq(redeemed2, 0, "c2 has paid nothing");
        assertEq(escrow.totalEscrowed(), 4_000e18, "10,000 - 7,000 + 1,000");
        assertGe(wood.balanceOf(address(escrow)), escrow.totalEscrowed());
    }

    /// @notice Fuzzes fund isolation across THREE concurrently open cases in a
    ///         fuzzed redemption order, one of them funded against a vault that
    ///         over-reports votes by a fuzzed factor.
    /// @dev The single-case predecessor could not catch the isolation bug: with
    ///      one case there is no sibling to drain into, and the shortfall only
    ///      shows up as an underflow at extreme skew. Here the assertions bite
    ///      directly — with the `claimable` cap removed, the skewed case pays
    ///      out more than it was funded with (`redeemed > proceeds`) and the
    ///      overpay comes out of the honest cases (balance < totalEscrowed), or
    ///      `totalEscrowed -= amount` underflows and reverts outright.
    function testFuzz_balanceCoversOutstanding(uint96 pA, uint96 pB, uint96 pC, uint8 skew, uint8 orderSeed) public {
        uint256 a = uint256(pA) % 100_000e18 + 1e18;
        uint256 b = uint256(pB) % 100_000e18 + 1e18;
        uint256 c = uint256(pC) % 1e18 + 1; // deliberately small next to its siblings
        uint256 skewX = uint256(skew) % 50 + 2; // votes are 2x..51x the snapshot supply

        MockVotesVault skewVault = _skewedVault(1e18, skewX * 1e18);

        vm.startPrank(slasher);
        uint256 idA = escrow.openCase(address(vault), snapTs, a);
        uint256 idB = escrow.openCase(address(vault), snapTs, b);
        uint256 idC = escrow.openCase(address(skewVault), snapTs, c);
        vm.stopPrank();

        // All 6 orderings of three ids: rotate, then optionally reverse.
        uint256[3] memory ids = [idA, idB, idC];
        uint256 rot = orderSeed % 3;
        bool rev = (orderSeed / 3) % 2 == 1;
        for (uint256 i = 0; i < 3; i++) {
            uint256 j = rev ? 2 - i : i;
            uint256 id = ids[(j + rot) % 3];
            _tryRedeem(id, alice);
            _tryRedeem(id, bob);
        }

        // 1. The escrow is never short of what it still owes.
        assertGe(wood.balanceOf(address(escrow)), escrow.totalEscrowed(), "balance covers outstanding");

        // 2. No case ever pays out more than it was funded with — the property
        //    that keeps one case's holders out of another case's money.
        uint256 outstanding;
        for (uint256 i = 0; i < 3; i++) {
            (,, uint256 proceeds, uint256 redeemed,,) = escrow.caseOf(ids[i]);
            assertLe(redeemed, proceeds, "a case paid out more than its own proceeds");
            outstanding += proceeds - redeemed;
        }
        // 3. ...and the aggregate ledger agrees with the per-case books.
        assertEq(escrow.totalEscrowed(), outstanding, "totalEscrowed is the sum of per-case remainders");
    }

    function _tryRedeem(uint256 caseId, address who) internal {
        if (escrow.claimable(caseId, who) == 0) return;
        vm.prank(who);
        escrow.redeem(caseId);
    }

    // ── Lookup / window guards ────────────────────────────────────────────

    function test_redeem_nonexistentCaseReverts() public {
        vm.prank(alice);
        vm.expectRevert(ICompensationEscrow.CaseNotFound.selector);
        escrow.redeem(999);
    }

    function test_sweepResidue_nonexistentCaseReverts() public {
        vm.expectRevert(ICompensationEscrow.CaseNotFound.selector);
        escrow.sweepResidue(999);
    }

    /// @notice Sweeping to an unset backstop would burn the residue to
    ///         `address(0)`; refuse it explicitly instead.
    function test_sweepResidue_revertsWhenBackstopUnset() public {
        CompensationEscrow bare = new CompensationEscrow(owner, address(wood));
        vm.prank(owner);
        bare.setAuthorizedFunder(slasher);
        vm.startPrank(slasher);
        wood.approve(address(bare), type(uint256).max);
        uint256 caseId = bare.openCase(address(vault), snapTs, 10_000e18);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 180 days + 1);
        vm.expectRevert(ICompensationEscrow.ZeroAddress.selector);
        bare.sweepResidue(caseId);
    }

    function test_setResidueWindow_acceptsTheBounds() public {
        vm.startPrank(owner);
        escrow.setResidueWindow(30 days);
        assertEq(escrow.residueWindow(), 30 days);
        escrow.setResidueWindow(365 days);
        assertEq(escrow.residueWindow(), 365 days);
        vm.stopPrank();
    }

    function test_setResidueWindow_rejectsOutOfBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(ICompensationEscrow.InvalidWindow.selector);
        escrow.setResidueWindow(30 days - 1);
        vm.expectRevert(ICompensationEscrow.InvalidWindow.selector);
        escrow.setResidueWindow(365 days + 1);
        vm.stopPrank();
    }

    function test_setResidueWindow_onlyOwner() public {
        vm.expectRevert();
        escrow.setResidueWindow(90 days);
    }

    /// @notice The window is fixed AT OPEN. Lowering it afterwards must not
    ///         shorten the redemption rights of a case already open — otherwise
    ///         the owner could drop to the 30-day floor and sweep funds from
    ///         holders who were promised 180 days.
    function test_setResidueWindow_doesNotApplyRetroactively() public {
        uint256 caseId = _open(10_000e18); // opened under the 180-day default
        uint256 openedAtTs = vm.getBlockTimestamp();

        vm.prank(owner);
        escrow.setResidueWindow(30 days);

        // Past the NEW window, well short of the one the case was opened under.
        vm.warp(openedAtTs + 30 days + 1);
        vm.expectRevert(ICompensationEscrow.ResidueWindowOpen.selector);
        escrow.sweepResidue(caseId);

        // Alice can still claim, because her original window has not run out.
        vm.prank(alice);
        assertEq(escrow.redeem(caseId), 7_000e18);

        // The ORIGINAL window still governs.
        vm.warp(openedAtTs + 180 days + 1);
        assertEq(escrow.sweepResidue(caseId), 3_000e18);
    }

    /// @notice ...and the new window does govern cases opened after the change.
    function test_setResidueWindow_appliesToLaterCases() public {
        vm.prank(owner);
        escrow.setResidueWindow(30 days);

        uint256 caseId = _open(10_000e18);
        vm.warp(vm.getBlockTimestamp() + 30 days + 1);
        assertEq(escrow.sweepResidue(caseId), 10_000e18, "the case took the window in force at ITS open");
    }

    function test_sweepResidue_beforeWindowReverts() public {
        uint256 caseId = _open(10_000e18);
        vm.expectRevert(ICompensationEscrow.ResidueWindowOpen.selector);
        escrow.sweepResidue(caseId);
    }

    function test_sweepResidue_afterWindowPaysBackstop() public {
        uint256 caseId = _open(10_000e18);
        vm.prank(alice);
        escrow.redeem(caseId); // 7,000 claimed; 3,000 left unredeemed

        vm.warp(vm.getBlockTimestamp() + 180 days + 1);
        uint256 swept = escrow.sweepResidue(caseId);

        assertEq(swept, 3_000e18);
        assertEq(wood.balanceOf(backstop), 3_000e18, "residue goes to the backstop, never live NAV");
        assertEq(escrow.totalEscrowed(), 0);
    }

    function test_sweepResidue_isPermissionlessAndOnce() public {
        uint256 caseId = _open(10_000e18);
        vm.warp(vm.getBlockTimestamp() + 180 days + 1);
        vm.prank(makeAddr("keeper")); // anyone may trigger it; funds go to the backstop
        escrow.sweepResidue(caseId);
        vm.expectRevert(ICompensationEscrow.NothingToCompensate.selector);
        escrow.sweepResidue(caseId);
    }

    /// @notice A holder that sat on its claim past the window loses it — the sweep
    ///         is what bounds the escrow's liability, so redemption must fail after.
    function test_redeem_afterSweepReverts() public {
        uint256 caseId = _open(10_000e18);
        vm.warp(vm.getBlockTimestamp() + 180 days + 1);
        escrow.sweepResidue(caseId);
        vm.prank(alice);
        vm.expectRevert(ICompensationEscrow.NoClaim.selector);
        escrow.redeem(caseId);
    }
}
