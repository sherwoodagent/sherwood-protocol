// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultInstantLiquidityTest} from "../SyndicateVault.InstantLiquidity.t.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";

/// @dev A settled strategy holding a residue it can price. `deliver` is what a
///      `sweep()` actually hands back — set it below the residue to model a
///      market that can only pay part of what it owes.
contract StubResidueStrategy {
    address public immutable vaultAddr;
    address public immutable assetAddr;
    uint256 public residue;

    constructor(address vault_, address asset_) {
        vaultAddr = vault_;
        assetAddr = asset_;
    }

    function setResidue(uint256 v) external {
        residue = v;
    }

    function hasUndeliveredValue() external view returns (bool) {
        return residue != 0;
    }

    function undeliveredValue() external view returns (uint256) {
        return residue;
    }

    function hasUnvaluedResidue() external pure returns (bool) {
        return false;
    }

    /// @dev Pays whatever it has been funded with, up to what it owes — the
    ///      deliverable-maximum shape the real templates have.
    function sweep() external returns (uint256 sent) {
        uint256 bal = IERC20Like(assetAddr).balanceOf(address(this));
        sent = bal < residue ? bal : residue;
        if (sent != 0) {
            residue -= sent;
            IERC20Like(assetAddr).transfer(vaultAddr, sent);
        }
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @title SyndicateVault — the redeemer's share of value that arrived late
/// @notice Finding #3, FAIRNESS half. A proposal can settle while its strategy
///         still holds value the market could not release. The settle stamp is
///         computed from float alone, so a queued redeemer claiming against it
///         is paid as though that value were worth ZERO — and when it later
///         comes home it lifts the price for whoever STAYED.
///
///         Nobody is attacked and nothing leaves the protocol. The money simply
///         goes to the wrong LPs. That is why this ships separately from the
///         skim (the attack half, closed in #243) and why it is fixed by paying
///         rather than by blocking.
///
///         THE SHAPE: pay the float-only stamp NOW as a fully-backed senior
///         floor, and record what FRACTION of later arrivals the exiting cohort
///         is owed. When `collectResidue` delivers REAL assets, split them by
///         that fraction — the cohort's slice is custodied by the queue, the
///         rest stays in the vault and lifts the stayers' price. Nothing is ever
///         valued, so a cohort can never be paid against value that has not
///         turned up, and with no arrival at all they simply keep the floor.
contract PashovFinalRedeemerResidueTest is VaultInstantLiquidityTest {
    StubResidueStrategy internal resStrat;

    /// @dev Alice and Bob seed the pool, Alice queues a redeem against the live
    ///      proposal, then it settles leaving `residue` undelivered.
    function _settleWithResidue(uint256 residue) internal returns (uint256 requestId) {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(bob);
        vault.deposit(10_000e6, bob);

        resStrat = new StubResidueStrategy(address(vault), address(usdc));
        resStrat.setResidue(residue);
        governor.set(PID, 1, address(resStrat));

        // Alice exits into the queue while the proposal is live. The vault
        // moves her shares into the queue's custody, so it needs the allowance.
        uint256 exiting = vault.balanceOf(alice) / 2;
        vm.startPrank(alice);
        vault.approve(address(vault), exiting);
        requestId = vault.requestRedeem(exiting, alice);
        vm.stopPrank();

        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        governor.set(0, 0, address(0));
    }

    /// @dev Fund the strategy so its `sweep()` can actually deliver.
    function _fundStrategy(uint256 amount) internal {
        usdc.mint(address(resStrat), amount);
    }

    // ── the floor is unchanged ──

    /// @notice THE SENIOR LEG IS EXACTLY TODAY'S BEHAVIOUR. The redeemer is paid
    ///         the float-only stamp, fully backed, and that never regresses —
    ///         everything below is upside on top of it.
    function test_floorIsPaidAtTheFloatOnlyStampAsBefore() public {
        uint256 id = _settleWithResidue(2_000e6);

        uint256 before = usdc.balanceOf(alice);
        uint256 paid = queue.claim(id);
        assertGt(paid, 0, "floor paid");
        assertEq(usdc.balanceOf(alice) - before, paid, "and actually transferred");
    }

    /// @notice WITH NO ARRIVAL THERE IS NOTHING TO SPLIT, and the redeemer is
    ///         exactly where they are today — never stranded behind a promise
    ///         the vault cannot keep.
    function test_nothingArrives_redeemerKeepsTheFloorAndIsOwedNothing() public {
        uint256 id = _settleWithResidue(2_000e6);
        queue.claim(id);

        // The market never pays: sweep delivers nothing.
        vault.collectResidue(address(resStrat));

        assertEq(queue.claimableRemainder(id), 0, "no arrival, no entitlement");
        assertEq(queue.claimRemainder(id), 0, "and claiming is a no-op, not a revert");
    }

    // ── the junior leg ──

    /// @notice THE FIX. The residue comes home after the redeemer has already
    ///         exited, and they receive their share of it instead of it accruing
    ///         entirely to the LPs who stayed.
    function test_lateArrivalIsSharedWithTheExitedCohort() public {
        uint256 id = _settleWithResidue(2_000e6);
        queue.claim(id);

        _fundStrategy(2_000e6);
        uint256 collected = vault.collectResidue(address(resStrat));
        assertEq(collected, 2_000e6, "the residue came home");

        uint256 owed = queue.claimableRemainder(id);
        assertGt(owed, 0, "the exited cohort is owed a share of it");

        uint256 before = usdc.balanceOf(alice);
        assertEq(queue.claimRemainder(id), owed, "paid what was quoted");
        assertEq(usdc.balanceOf(alice) - before, owed, "and actually transferred");
    }

    /// @notice The split is the cohort's fraction of the vault at the stamp —
    ///         not all of it, and not none of it. The stayers keep the rest.
    function test_arrivalIsSplitByTheCohortFractionAtTheStamp() public {
        uint256 id = _settleWithResidue(2_000e6);

        (uint256 shares, uint256 den) = queue.cohortOf(PID);
        assertGt(shares, 0, "a cohort exists");
        uint256 expected = (2_000e6 * shares) / den;

        queue.claim(id);
        _fundStrategy(2_000e6);

        uint256 queueBefore = usdc.balanceOf(address(queue));
        vault.collectResidue(address(resStrat));

        assertEq(usdc.balanceOf(address(queue)) - queueBefore, expected, "cohort's slice custodied by the queue");
        assertEq(queue.cohortAssets(), expected, "and booked as theirs");
    }

    /// @notice A PARTIAL delivery pays a partial share, and a later delivery
    ///         tops it up. The claim is repeatable rather than one-shot.
    function test_partialArrivalsAccumulateAndTopUp() public {
        uint256 id = _settleWithResidue(2_000e6);
        queue.claim(id);

        _fundStrategy(500e6);
        vault.collectResidue(address(resStrat));
        uint256 first = queue.claimRemainder(id);
        assertGt(first, 0, "paid on the first partial arrival");

        _fundStrategy(1_500e6);
        vault.collectResidue(address(resStrat));
        uint256 second = queue.claimRemainder(id);
        assertGt(second, 0, "and again when the rest lands");

        assertEq(queue.claimRemainder(id), 0, "then nothing further is owed");
    }

    /// @notice The junior leg is INDEPENDENT of the floor in both directions: an
    ///         arrival credited before the floor claim is still fully claimable
    ///         afterwards. (This is the ordering bug that would silently zero a
    ///         redeemer's entitlement if the two were coupled.)
    function test_arrivalBeforeFloorClaimIsStillClaimable() public {
        uint256 id = _settleWithResidue(2_000e6);

        _fundStrategy(2_000e6);
        vault.collectResidue(address(resStrat));
        uint256 owedBefore = queue.claimableRemainder(id);
        assertGt(owedBefore, 0, "entitlement exists before the floor is taken");

        queue.claim(id); // take the senior leg second
        assertEq(queue.claimableRemainder(id), owedBefore, "floor claim did not disturb it");
        assertEq(queue.claimRemainder(id), owedBefore, "and it is still payable");
    }

    /// @notice Repeat claims cannot drain the cohort pot — the second is a no-op.
    function test_claimRemainderIsIdempotent() public {
        uint256 id = _settleWithResidue(2_000e6);
        queue.claim(id);
        _fundStrategy(2_000e6);
        vault.collectResidue(address(resStrat));

        uint256 first = queue.claimRemainder(id);
        assertGt(first, 0, "paid once");
        assertEq(queue.claimRemainder(id), 0, "not twice");
        assertEq(queue.claimRemainder(id), 0, "nor three times");
    }

    // ── invariants the junior leg must not break ──

    /// @notice THE MASTER INVARIANT: a cohort can never be paid more than what
    ///         physically arrived for it. Over-payment is unrepresentable
    ///         because nothing is ever valued — only measured.
    function test_cohortNeverPaidMoreThanArrived() public {
        uint256 id = _settleWithResidue(2_000e6);
        queue.claim(id);

        _fundStrategy(2_000e6);
        vault.collectResidue(address(resStrat));

        uint256 arrivedForCohort = queue.cohortAssets();
        uint256 paidOut = queue.claimRemainder(id);
        assertLe(paidOut, arrivedForCohort, "paid at most what arrived");
    }

    /// @notice The junior leg must not touch the senior leg's accounting. If it
    ///         did, an arrival could unbook a redeemer's floor or free float the
    ///         next proposal is not allowed to deploy.
    function test_arrivalDoesNotDisturbTheReserve() public {
        uint256 id = _settleWithResidue(2_000e6);

        uint256 reservedBefore = vault.reservedQueueAssets();
        _fundStrategy(2_000e6);
        vault.collectResidue(address(resStrat));

        assertEq(vault.reservedQueueAssets(), reservedBefore, "reserve untouched by the junior leg");

        // And the floor is still payable in full afterwards.
        assertGt(queue.claim(id), 0, "senior leg unaffected");
    }

    /// @notice A settlement with NO queued redeems routes the whole arrival to
    ///         the stayers — there is no cohort to pay, and the split must not
    ///         divide by zero.
    function test_noCohort_wholeArrivalGoesToStayers() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        resStrat = new StubResidueStrategy(address(vault), address(usdc));
        resStrat.setResidue(1_000e6);
        governor.set(PID, 1, address(resStrat));
        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        governor.set(0, 0, address(0));

        _fundStrategy(1_000e6);
        uint256 queueBefore = usdc.balanceOf(address(queue));
        uint256 collected = vault.collectResidue(address(resStrat));

        assertEq(collected, 1_000e6, "arrived");
        assertEq(usdc.balanceOf(address(queue)), queueBefore, "nothing earmarked - nobody exited");
        assertEq(queue.cohortAssets(), 0, "no cohort assets booked");
    }

    /// @notice A deposit request can never claim the junior leg — it exists only
    ///         for the party a float-only stamp under-pays.
    function test_depositRequestCannotClaimRemainder() public {
        governor.set(PID, 1, address(strat));
        vm.prank(alice);
        uint256 depositId = vault.requestDeposit(1_000e6, alice);
        governor.set(0, 0, address(0));

        vm.expectRevert(IVaultWithdrawalQueue.NotRedeemRequest.selector);
        queue.claimRemainder(depositId);
    }

    // ── the two asset pools this contract now holds must not bleed ──

    /// @notice The queue custodies escrowed DEPOSITS and redeem-cohort
    ///         ARRIVALS in the same contract balance. They are tracked by
    ///         separate counters and every flow touches exactly one of them, so
    ///         neither pool can be paid out of the other's money.
    ///
    ///         Checked in the direction that would actually lose funds: a
    ///         depositor cancelling must get their full escrow back even though
    ///         cohort assets are sitting alongside it, and the cohort's claim
    ///         must still be payable afterwards.
    function test_depositEscrowAndCohortAssetsDoNotBleed() public {
        uint256 id = _settleWithResidue(2_000e6);
        queue.claim(id);
        _fundStrategy(2_000e6);
        vault.collectResidue(address(resStrat));

        uint256 cohortHeld = queue.cohortAssets();
        assertGt(cohortHeld, 0, "cohort money is sitting in the queue");

        // A depositor escrows into the SAME contract while that money is held.
        governor.set(PID + 1, 1, address(strat));
        vm.prank(bob);
        uint256 depositId = vault.requestDeposit(1_000e6, bob);
        assertEq(queue.cohortAssets(), cohortHeld, "escrow did not disturb the cohort pool");

        // Cancelling returns the full escrow, not a penny of the cohort's.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        queue.cancel(depositId);
        assertEq(usdc.balanceOf(bob) - bobBefore, 1_000e6, "depositor got their escrow back in full");
        assertEq(queue.cohortAssets(), cohortHeld, "and the cohort pool is untouched");

        // The cohort's claim is still payable.
        governor.set(0, 0, address(0));
        assertGt(queue.claimRemainder(id), 0, "cohort still paid");
    }

    /// @notice THE MASTER INVARIANT WITH A REAL COHORT: several redeemers
    ///         against one settlement can never, between them, be paid more
    ///         than arrived for that cohort. Rounding is DOWN, so the sum falls
    ///         short by dust rather than over-running.
    function test_multipleRedeemers_sumOfClaimsNeverExceedsArrived() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(bob);
        vault.deposit(10_000e6, bob);

        resStrat = new StubResidueStrategy(address(vault), address(usdc));
        resStrat.setResidue(3_000e6);
        governor.set(PID, 1, address(resStrat));

        uint256 aliceShares = vault.balanceOf(alice) / 3;
        vm.startPrank(alice);
        vault.approve(address(vault), aliceShares);
        uint256 aliceId = vault.requestRedeem(aliceShares, alice);
        vm.stopPrank();

        uint256 bobShares = vault.balanceOf(bob) / 2;
        vm.startPrank(bob);
        vault.approve(address(vault), bobShares);
        uint256 bobId = vault.requestRedeem(bobShares, bob);
        vm.stopPrank();

        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        governor.set(0, 0, address(0));

        _fundStrategy(3_000e6);
        vault.collectResidue(address(resStrat));

        uint256 arrived = queue.cohortAssets();
        uint256 paidAlice = queue.claimRemainder(aliceId);
        uint256 paidBob = queue.claimRemainder(bobId);

        assertGt(paidAlice, 0, "alice paid");
        assertGt(paidBob, 0, "bob paid");
        assertLe(paidAlice + paidBob, arrived, "never more than arrived");
        // Bob exited a larger stake, so he is owed proportionally more.
        assertGt(paidBob, paidAlice, "split is pro-rata by shares exited");
    }

    /// @notice A strategy that already owes for one proposal keeps that
    ///         proposal's cohort as the payee. Re-pointing it would route the
    ///         first cohort's arrivals to a later one — real money, misallocated
    ///         between two sets of exited LPs.
    /// @dev    Unreachable through the governor today (`BaseStrategy.execute`
    ///         requires `State.Pending`, so a settled clone cannot settle
    ///         twice), which is precisely why the guard is asserted locally
    ///         rather than argued from another contract's state machine.
    function test_residuePidIsNotRepointedWhileTheStrategyStillOwes() public {
        uint256 id = _settleWithResidue(2_000e6);

        // The same clone settles again under a later proposal.
        governor.set(PID + 1, 1, address(resStrat));
        vm.prank(address(governor));
        vault.onProposalSettled(PID + 1);
        governor.set(0, 0, address(0));

        _fundStrategy(2_000e6);
        vault.collectResidue(address(resStrat));

        // The FIRST cohort is still the payee.
        assertGt(queue.claimableRemainder(id), 0, "first cohort keeps its claim");
    }
}
