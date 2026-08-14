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

    /// @dev When set, `sweep()` returns the strategy's WHOLE balance rather
    ///      than capping at what it reported owing — a strategy that recovered
    ///      more than its own probe could see (accrued yield, a market that
    ///      refilled past the snapshot). Models `collected > known`.
    bool public overDeliver;

    function setOverDeliver(bool v) external {
        overDeliver = v;
    }

    /// @dev Pays whatever it has been funded with, up to what it owes — the
    ///      deliverable-maximum shape the real templates have.
    error NotVault();

    /// @dev Mirrors the real templates: `sweep()` is VAULT-ONLY. A stub that
    ///      stayed permissionless would confirm the old assumption back to us
    ///      and hide the very bypass this suite now pins.
    function sweep() external returns (uint256 sent) {
        if (msg.sender != vaultAddr) revert NotVault();
        return _deliver();
    }

    /// @dev The last-resort hatch, modelled on `ConcentratedLiquidityStrategy`:
    ///      it CONVERTS before it releases, so it too can push vault asset home
    ///      — which is why it needs the same gate. A stub whose hatch stayed
    ///      permissionless would hide the second door exactly as a permissionless
    ///      `sweep()` stub hid the first.
    function releaseUnconvertible() external returns (uint256 sent) {
        if (msg.sender != vaultAddr) revert NotVault();
        return _deliver();
    }

    function _deliver() private returns (uint256 sent) {
        uint256 bal = IERC20Like(assetAddr).balanceOf(address(this));
        sent = (overDeliver || bal < residue) ? bal : residue;
        if (sent != 0) {
            residue = sent >= residue ? 0 : residue - sent;
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

    /// @notice THE JUNIOR LEG HAS EXACTLY ONE DOOR, and this is what forces it.
    ///
    /// @dev    `_payCohortShare` splits a MEASURED BALANCE DELTA taken across
    ///         the `sweep()` call inside `collectResidue`. A delta is a complete
    ///         measurement only while that is the only way value can arrive —
    ///         so while `sweep()` was itself permissionless, anyone could push
    ///         the residue home outside the measurement and the cohort was
    ///         credited NOTHING. Verified before the fix: cohort owed 0 after a
    ///         direct sweep, and 0 again after `collectResidue`, which sees a
    ///         zero delta and cannot repair it. The arrival silently lifted the
    ///         STAYERS' price — the precise misallocation this whole leg exists
    ///         to correct, reachable by an honest keeper calling a function the
    ///         natspec advertised as permissionless.
    ///
    ///         Closing it by removing the second door, not by documenting around
    ///         it: `sweep()` is vault-only and `collectResidue` stays open to
    ///         anyone, so the permissionless property is preserved where it
    ///         matters (the exit from the deposit lock) without letting the
    ///         accounting be stepped over.
    function test_directSweepIsRefusedSoTheCohortCannotBeBypassed() public {
        uint256 id = _settleWithResidue(2_000e6);
        queue.claim(id);
        _fundStrategy(2_000e6);

        // The bypass is now closed at the source.
        vm.expectRevert(StubResidueStrategy.NotVault.selector);
        resStrat.sweep();

        // ...and the only remaining route pays the cohort, as it always should.
        assertEq(vault.collectResidue(address(resStrat)), 2_000e6, "the residue came home");
        assertGt(queue.claimableRemainder(id), 0, "the exited cohort was starved of its share");
    }

    /// @notice THE HATCH IS THE SAME DOOR, and it was left open by the first fix.
    ///
    /// @dev    `sweep()` was not the only way vault asset could leave a settled
    ///         clone: `ConcentratedLiquidityStrategy.releaseUnconvertible()`
    ///         attempts the conversion BEFORE releasing and pushes whatever it
    ///         produced (`_trySwapToAsset` then `_pushAllToVault(asset)`), and it
    ///         was permissionless. Gating `sweep()` alone therefore closed one
    ///         door and left its twin standing — the cohort still credited
    ///         nothing, the arrival still lifting the stayers' price, still
    ///         unrepairable because the delta is spent.
    ///
    ///         Both are vault-only now, each with its own permissionless vault
    ///         entry point. They stay SEPARATE rather than folded together
    ///         because the hatch forecloses a conversion the routine sweep would
    ///         retry.
    function test_directReleaseUnconvertibleIsRefusedSoTheCohortCannotBeBypassed() public {
        uint256 id = _settleWithResidue(2_000e6);
        queue.claim(id);
        _fundStrategy(2_000e6);

        vm.expectRevert(StubResidueStrategy.NotVault.selector);
        resStrat.releaseUnconvertible();

        // The vault-side hatch is permissionless and measures what arrives.
        vm.prank(makeAddr("passerby"));
        assertEq(vault.releaseUnconvertible(address(resStrat)), 2_000e6, "the residue came home");
        assertGt(queue.claimableRemainder(id), 0, "the exited cohort was starved of its share");
    }

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

    // ── the depositor priced in the settle-to-arrival window ──

    /// @notice THE MIRROR OF THE BUG BEING FIXED. A valued residue does NOT lock
    ///         deposits (that was the deliberate #243 design — only unvaluable
    ///         residue blocks), so the whole settle-to-arrival window is open in
    ///         normal operation. `depositNav()` therefore has to price what will
    ///         actually reach the pool.
    ///
    ///         Once a cohort is owed part of a residue, only the REST ever
    ///         arrives. Pricing the gross figure would charge a window depositor
    ///         for value routed to somebody else — finding #3's shape flipped:
    ///         an over-charged depositor instead of an under-paid redeemer.
    function test_windowDepositorIsNotChargedForTheCohortsShare() public {
        _settleWithResidue(2_000e6);

        (uint256 shares, uint256 den) = queue.cohortOf(PID);
        uint256 cohortSlice = (2_000e6 * shares) / den;
        assertGt(cohortSlice, 0, "a cohort is owed part of this residue");

        // The pool is priced on what will actually reach it, not the gross.
        assertEq(
            vault.depositNav(),
            vault.totalAssets() + 2_000e6 - cohortSlice,
            "the cohort's slice is excluded from the mint price"
        );
    }

    /// @notice And end to end: what a window depositor pays matches what the
    ///         pool is worth once the residue has actually landed and been
    ///         split. Their entry price must not be an over-charge that the
    ///         arrival then fails to justify.
    function test_windowDepositorEntryPriceSurvivesTheArrival() public {
        _settleWithResidue(2_000e6);

        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6, bob);
        uint256 valueAtEntry = vault.convertToAssets(minted);

        _fundStrategy(2_000e6);
        vault.collectResidue(address(resStrat));

        // After the split lands, their stake is worth at least what the entry
        // price implied — the residue they were charged for did arrive for the
        // pool, because they were only ever charged for the pool's part of it.
        assertGe(vault.convertToAssets(minted) + 1, valueAtEntry, "no silent over-charge at entry");
    }

    /// @notice With no cohort the whole residue belongs to the pool, so the
    ///         netting must not quietly under-price the mint either.
    function test_noCohort_depositNavCountsTheWholeResidue() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        resStrat = new StubResidueStrategy(address(vault), address(usdc));
        resStrat.setResidue(1_000e6);
        governor.set(PID, 1, address(resStrat));
        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        governor.set(0, 0, address(0));

        assertEq(vault.depositNav(), vault.totalAssets() + 1_000e6, "nobody exited, so the pool owns all of it");
    }

    // ── the queue's solvency, and arrivals across pids ──

    /// @notice The queue's balance must always cover BOTH pools it custodies.
    ///         Monotonically slack, because floor-rounding dust and any
    ///         never-claimed slice stay here with no sweep path — stated rather
    ///         than left implicit.
    function test_queueBalanceCoversBothPools() public {
        uint256 id = _settleWithResidue(2_000e6);
        _fundStrategy(2_000e6);
        vault.collectResidue(address(resStrat));

        governor.set(PID + 1, 1, address(strat));
        vm.prank(bob);
        vault.requestDeposit(1_000e6, bob);
        governor.set(0, 0, address(0));

        assertGe(
            usdc.balanceOf(address(queue)),
            queue.cohortAssets() + queue.pendingDepositAssets(),
            "queue covers both pools"
        );

        queue.claim(id);
        queue.claimRemainder(id);
        assertGe(
            usdc.balanceOf(address(queue)),
            queue.cohortAssets() + queue.pendingDepositAssets(),
            "and still covers them after payouts"
        );
    }

    /// @notice A sweep that OVER-DELIVERS: the strategy hands back more than it
    ///         ever reported owing. The cohort takes its fraction of the whole
    ///         arrival, which is the same rule as every other arrival — the
    ///         excess is not treated as a windfall belonging solely to whoever
    ///         stayed. What matters is that it cannot break the accounting:
    ///         nothing is valued, so a bigger arrival is just a bigger split.
    function test_overDeliveryIsSplitOnTheSameRuleAndStaysSolvent() public {
        uint256 id = _settleWithResidue(1_000e6);
        queue.claim(id);

        resStrat.setOverDeliver(true);
        _fundStrategy(1_500e6); // 500e6 more than it said it owed

        uint256 floatBefore = usdc.balanceOf(address(vault));
        uint256 collected = vault.collectResidue(address(resStrat));
        assertEq(collected, 1_500e6, "the whole balance came home");

        uint256 cohortSlice = queue.cohortAssets();
        assertGt(cohortSlice, 0, "the cohort took its fraction of the excess too");
        assertEq(
            usdc.balanceOf(address(vault)) - floatBefore, collected - cohortSlice, "and the rest stayed with the pool"
        );

        assertGe(
            usdc.balanceOf(address(queue)),
            queue.cohortAssets() + queue.pendingDepositAssets(),
            "solvent after an over-delivery"
        );

        // A claim never pays more than the queue is holding for that cohort.
        assertLe(queue.claimableRemainder(id), queue.cohortAssets(), "entitlement bounded by what arrived");
        queue.claimRemainder(id);
        assertEq(queue.claimableRemainder(id), 0, "and the claim is idempotent");
    }

    /// @notice TWO COHORTS, TWO STRATEGIES, ARRIVALS INTERLEAVED. `_pidArrived`
    ///         is per-pid for a reason: a later proposal's residue coming home
    ///         must not enlarge an earlier cohort's entitlement, and vice versa.
    ///         A single shared arrivals counter would silently pay each cohort a
    ///         fraction of the other's money.
    function test_arrivalsForDifferentPidsDoNotCrossCredit() public {
        uint256 idA = _settleWithResidue(1_000e6);
        StubResidueStrategy stratA = resStrat;

        // A second round: Bob exits into the queue against PID + 1, which
        // settles leaving its own residue on a different strategy.
        StubResidueStrategy stratB = new StubResidueStrategy(address(vault), address(usdc));
        stratB.setResidue(1_000e6);
        governor.set(PID + 1, 1, address(stratB));

        uint256 exiting = vault.balanceOf(bob) / 2;
        vm.startPrank(bob);
        vault.approve(address(vault), exiting);
        uint256 idB = vault.requestRedeem(exiting, bob);
        vm.stopPrank();

        vm.prank(address(governor));
        vault.onProposalSettled(PID + 1);
        governor.set(0, 0, address(0));

        // Only A's residue comes home.
        usdc.mint(address(stratA), 1_000e6);
        vault.collectResidue(address(stratA));

        assertGt(queue.claimableRemainder(idA), 0, "A's cohort is owed its slice");
        assertEq(queue.claimableRemainder(idB), 0, "B's cohort is owed nothing yet");

        // Now B's. A's entitlement must not move.
        uint256 owedABefore = queue.claimableRemainder(idA);
        usdc.mint(address(stratB), 1_000e6);
        vault.collectResidue(address(stratB));

        assertEq(queue.claimableRemainder(idA), owedABefore, "A unchanged by B's arrival");
        assertGt(queue.claimableRemainder(idB), 0, "and B is now owed its own slice");

        assertGe(
            usdc.balanceOf(address(queue)),
            queue.cohortAssets() + queue.pendingDepositAssets(),
            "solvent across both cohorts"
        );
    }
}
