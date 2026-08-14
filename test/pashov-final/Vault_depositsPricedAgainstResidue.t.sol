// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultInstantLiquidityTest} from "../SyndicateVault.InstantLiquidity.t.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";

/// @dev A settled strategy that answers the delivery probe. `holding` is what a
///      `sweep()` would still return.
contract StubDeliveryStrategy {
    bool public holding;
    bool public unvalued;

    function setHolding(bool v) external {
        holding = v;
    }

    /// @dev Residue this template could not express in vault-asset units — an LP
    ///      leg, a volatile token, a non-asset collateral.
    function setUnvalued(bool v) external {
        unvalued = v;
    }

    function hasUnvaluedResidue() external view returns (bool) {
        return unvalued;
    }

    function hasUndeliveredValue() external view returns (bool) {
        return holding;
    }

    uint256 public residue;

    function setResidue(uint256 v) external {
        residue = v;
    }

    function undeliveredValue() external view returns (uint256) {
        return residue;
    }
}

/// @dev Answers with the WRONG SHAPE — succeeds but returns ZERO bytes, the way
///      a void-returning or non-conforming implementation does. The probe must
///      treat that as unanswerable rather than decoding whatever is on the wire.
///
///      Note a narrower-typed return does NOT reproduce this: a `uint128` return
///      is still ABI-padded to a full 32-byte word, so it passes the length
///      check and decodes as a normal non-zero answer. Reaching the length
///      branch takes a genuinely short return, which is what the bare fallback
///      below produces.
contract StubDeliveryShortReturn {
    fallback() external {
        // returns 0 bytes of returndata with success
    }
}

/// @title SyndicateVault — deposits are PRICED against value a settlement left behind
/// @notice Finding #3. `totalAssets()` counts only `balanceOf(this)`, so value a
///         strategy still holds prices at ZERO. During a live proposal that is
///         covered by `openProposalCount() != 0` — but strategy settlement is
///         DELIVERABLE-MAXIMUM, not all-or-revert: a market at high utilization
///         delivers what it can, emits `SettlementIncomplete`, and leaves the
///         rest for the permissionless `sweep()`. `_finishSettlement` clears the
///         open count regardless.
///
///         In that gap the vault reopens deposits at a price missing the
///         residue. A depositor mints cheap, calls `sweep()` themselves to drag
///         the residue back into the now-larger pool, and redeems: for a deposit
///         `A` against residue `R`, they take `A * R / (float + A)` straight out
///         of the LPs who were already in. Unprivileged, repeatable per
///         proposal, and inducible rather than merely opportunistic —
///         `_deliverableNow` caps at Morpho's idle balance, which a fee-free
///         `flashLoan` removes for one callback frame.
contract PashovFinalDepositResiduePricingTest is VaultInstantLiquidityTest {
    StubDeliveryStrategy internal deliveryStrat;

    function _settleWith(address strategy) internal {
        _settleWithPid(PID, strategy);
    }

    /// @dev Distinct pid per settlement — `stampSettlement` refuses a repeat
    ///      (`AlreadySettled`) and a lower one (`StampOutOfOrder`), so the
    ///      multi-settlement tests below must step the pid forward.
    function _settleWithPid(uint256 pid, address strategy) internal {
        // Live proposal naming `strategy`, then settle it — the governor stamps
        // and clears the open count, which is exactly the transition under test.
        governor.set(pid, 1, strategy);
        vm.prank(address(governor));
        vault.onProposalSettled(pid);
        governor.set(0, 0, address(0));
    }

    /// @notice THE FIX, IN ITS FINAL FORM: a residue is PRICED, not locked.
    ///         The deposit succeeds — but at a price that already charges for
    ///         the value the strategy still owes, so there is nothing left to
    ///         skim by sweeping it in afterwards.
    ///
    ///         Locking was the earlier shape and it was a bet on an
    ///         unanswerable question. If the residue never arrives, the
    ///         residue-free price was right all along and the vault was frozen
    ///         for nothing — potentially forever, since a market that never
    ///         refills never clears. Pricing is safe in BOTH branches.
    function test_finding3_depositIsPricedAgainstTheResidue() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(1_000e6);
        deal(vault.asset(), address(vault), 1_000e6);

        uint256 floatOnly = vault.totalAssets();
        _settleWith(address(deliveryStrat));

        assertEq(vault.depositNav(), floatOnly + 1_000e6, "deposits price against float + residue");
        assertEq(vault.totalAssets(), floatOnly, "totalAssets is untouched - redeems keep reading float");

        // Same assets, fewer shares than the float-only price would have minted.
        uint256 pricedIn = vault.previewDeposit(1_000e6);
        uint256 floatOnlyShares = vault.convertToShares(1_000e6);
        assertLt(pricedIn, floatOnlyShares, "charged for the residue");

        vm.prank(alice);
        assertEq(vault.deposit(1_000e6, alice), pricedIn, "mint matches the quoted, residue-inclusive price");
    }

    /// @notice AND THE SKIM IS GONE. The attacker's sequence — deposit at the
    ///         residue-free price, then sweep the residue into the enlarged pool
    ///         — cannot profit, because the deposit already paid for it. Their
    ///         share of the vault after sweeping is worth no more than they put
    ///         in.
    function test_finding3_depositThenSweepIsNotProfitable() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(1_000e6);
        deal(vault.asset(), address(vault), 1_000e6);
        _settleWith(address(deliveryStrat));

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);

        // The residue comes home; the attacker sweeps it in themselves.
        deal(vault.asset(), address(vault), vault.totalAssets() + 1_000e6);
        deliveryStrat.setHolding(false);
        deliveryStrat.setResidue(0);
        vault.collectResidue(address(deliveryStrat));

        // Their stake is worth no more than they paid — the skim is priced out.
        assertLe(vault.convertToAssets(shares), 1_000e6 + 1, "no value extracted from the incumbents");
    }

    /// @notice A residue never locks anything, so a market that never refills
    ///         cannot freeze the vault. This is the liveness property the lock
    ///         could not offer at any timeout.
    function test_finding3_permanentlyStuckResidueNeverBlocksDeposits() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(5_000e6);
        _settleWith(address(deliveryStrat));

        assertFalse(vault.depositsLocked(), "a residue must never lock the vault");
        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "deposits stay open against a dead market");
    }

    /// @notice THE STAMP STAYS FLOAT-ONLY. Redeems are priced on cash in hand,
    ///         which is what keeps the residue off the side where over-counting
    ///         would pay out assets the vault does not hold.
    function test_finding3_stampRemainsFloatOnly() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(4_000e6);
        deal(vault.asset(), address(vault), 10_000e6);

        uint256 float_ = vault.totalAssets();
        _settleWith(address(deliveryStrat));

        IVaultWithdrawalQueue.SettlePrice memory sp = queue.getSettlePrice(PID);
        assertEq(sp.num, float_ + 1, "the stamp is float-only; the residue lives on the deposit side alone");
    }

    /// @notice Collecting refreshes the figure. Once the value is home it is in
    ///         `totalAssets()` and must stop being added on top, or it would be
    ///         counted twice against every later deposit.
    function test_finding3_collectingStopsDoubleCountingTheResidue() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(1_000e6);
        _settleWith(address(deliveryStrat));
        assertEq(vault.depositNav(), vault.totalAssets() + 1_000e6);

        deliveryStrat.setHolding(false);
        deliveryStrat.setResidue(0);
        vault.collectResidue(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets(), "no residue left to add");
    }

    /// @notice A partial delivery lowers the figure rather than clearing it.
    function test_finding3_partialDeliveryLowersTheDepositPrice() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(1_000e6);
        _settleWith(address(deliveryStrat));

        deliveryStrat.setResidue(400e6);
        vault.collectResidue(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets() + 400e6, "figure tracks what is still owed");
    }

    /// @notice A COMPLETE settlement adds nothing — the ordinary case is
    ///         untouched.
    function test_finding3_completeSettlementPricesAtFloat() public {
        deliveryStrat = new StubDeliveryStrategy(); // holding == false, residue == 0
        _settleWith(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets(), "nothing owed, nothing added");
        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "deposits open");
    }

    /// @notice UNREADABLE KEEPS THE LAST KNOWN FIGURE. Delivery only ever
    ///         shrinks what is owed, so a stale reading is stale-HIGH — the
    ///         direction that over-prices a deposit rather than under-pricing
    ///         it. Silence therefore cannot wedge the vault OR open the skim.
    function test_finding3_unreadableStrategyKeepsTheLastKnownFigure() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(1_000e6);
        _settleWith(address(deliveryStrat));

        // Same address, now a contract that cannot answer.
        vm.etch(address(deliveryStrat), address(new StubDeliveryShortReturn()).code);
        vault.collectResidue(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets() + 1_000e6, "last known figure retained");
        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "still not a lock");
    }

    /// @notice A strategy that never reported anything is never priced in — the
    ///         figure is only ever entered from a definite, readable answer.
    function test_finding3_unreadableAtSettlementIsNeverPricedIn() public {
        _settleWith(address(new StubDeliveryShortReturn()));

        assertEq(vault.depositNav(), vault.totalAssets(), "unreadable is never recorded");
    }

    /// @notice THE BLOCKER AN EARLIER VERSION OF THIS PR SHIPPED.
    ///         `SyndicateGovernor` stores `strategy` unvalidated and explicitly
    ///         skips its own probe for codeless addresses (the
    ///         `strategy.code.length != 0` guard there, pinned by
    ///         `test_propose_eoaStrategySucceedsAtPropose`). Nothing ever calls
    ///         the field — it is a label — so a proposal naming an EOA settles
    ///         normally, and a staticcall to it succeeds with EMPTY returndata.
    ///
    ///         Under the old fail-closed lock that read as "unreadable", marked
    ///         the EOA, and could never be cleared: one proposal from any
    ///         registered agent permanently shut every deposit path. Codeless is
    ///         short-circuited before any call, and there is no lock left to
    ///         brick regardless.
    function test_finding3_eoaStrategyIsNeverPricedIn() public {
        _settleWith(makeAddr("eoaStrategyLabel"));

        assertEq(vault.depositNav(), vault.totalAssets(), "an EOA label owes nothing");
        assertFalse(vault.depositsLocked(), "and cannot lock the vault");
        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "deposits unaffected");
    }

    /// @notice A strategy that owed and has since self-destructed drops out: it
    ///         can hold nothing, so carrying its figure would over-price every
    ///         later deposit against value that provably cannot exist.
    function test_finding3_codelessAfterRecordingIsCleared() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(1_000e6);
        _settleWith(address(deliveryStrat));
        assertEq(vault.depositNav(), vault.totalAssets() + 1_000e6);

        vm.etch(address(deliveryStrat), "");
        vault.collectResidue(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets(), "codeless owes nothing");
    }

    // ── every strategy that owes, not just the newest ──

    /// @notice THE TWO-PROPOSAL SKIM. The figure used to hang off a single
    ///         `_lastSettledStrategy` pin, overwritten at every settlement — so
    ///         a strategy still holding a residue stopped being accounted for
    ///         the moment the next proposal settled, and a deposit priced as if
    ///         it owed nothing.
    function test_finding3_earlierStrategysResidueStillPricedAfterALaterSettlement() public {
        StubDeliveryStrategy dirty = new StubDeliveryStrategy();
        dirty.setHolding(true);
        dirty.setResidue(1_000e6);
        _settleWithPid(PID, address(dirty));

        StubDeliveryStrategy clean = new StubDeliveryStrategy(); // owes nothing
        _settleWithPid(PID + 1, address(clean));

        // Pre-fix the pin named `clean`, which owes nothing, and the earlier
        // strategy's 1,000 vanished from the price.
        assertEq(vault.depositNav(), vault.totalAssets() + 1_000e6, "the earlier strategy still owes");
    }

    /// @notice Two outstanding at once: the figure is a SUM, not a flag.
    function test_finding3_twoOutstandingStrategiesBothPriced() public {
        StubDeliveryStrategy a = new StubDeliveryStrategy();
        a.setHolding(true);
        a.setResidue(600e6);
        _settleWithPid(PID, address(a));

        StubDeliveryStrategy b = new StubDeliveryStrategy();
        b.setHolding(true);
        b.setResidue(400e6);
        _settleWithPid(PID + 1, address(b));

        assertEq(vault.depositNav(), vault.totalAssets() + 1_000e6, "both counted");

        a.setResidue(0);
        a.setHolding(false);
        vault.collectResidue(address(a));
        assertEq(vault.depositNav(), vault.totalAssets() + 400e6, "only b remains");
    }

    /// @notice Collecting a strategy that is not owed anything is inert, so the
    ///         running total cannot be drained by repetition.
    function test_finding3_collectResidueIsInertForAnUnrecordedStrategy() public {
        StubDeliveryStrategy a = new StubDeliveryStrategy();
        a.setHolding(true);
        a.setResidue(500e6);
        _settleWithPid(PID, address(a));

        uint256 navBefore = vault.depositNav();
        vault.collectResidue(makeAddr("neverRecorded"));
        vault.collectResidue(makeAddr("neverRecorded"));
        assertEq(vault.depositNav(), navBefore, "unrecorded strategies cannot move the figure");
    }

    // ── the ASYNC half of the same gate ──

    /// @notice THE ASYNC HALF. The instant path was gated while a residue was
    ///         outstanding; the QUEUED path was not — it claimed against the
    ///         frozen settle stamp, a float-only number blind to the residue by
    ///         construction, so the skim survived the earlier fix by going
    ///         around it.
    ///
    ///         Both paths now price through `previewDeposit`, so the queued
    ///         claim is charged for the residue exactly like an instant deposit.
    function test_finding3_queuedDepositClaimIsPricedAgainstTheResidue() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(1_000e6);

        governor.set(PID, 1, address(deliveryStrat));
        vm.prank(alice);
        uint256 id = vault.requestDeposit(1_000e6, alice);

        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        governor.set(0, 0, address(0));

        // The claim mints at the residue-inclusive price, not the stamp.
        uint256 expected = vault.previewDeposit(1_000e6);
        uint256 floatOnly = vault.convertToShares(1_000e6);
        assertLt(expected, floatOnly, "charged for the residue");

        uint256 minted = queue.claim(id);
        assertEq(minted, expected, "queued claim priced like an instant deposit");
    }

    /// @notice A queued claim placed against a clean settlement is unaffected —
    ///         no residue, no spread, the price is simply the live one.
    function test_finding3_queuedDepositClaimUnaffectedByACleanSettlement() public {
        deliveryStrat = new StubDeliveryStrategy(); // owes nothing

        governor.set(PID, 1, address(deliveryStrat));
        vm.prank(alice);
        uint256 id = vault.requestDeposit(1_000e6, alice);

        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        governor.set(0, 0, address(0));

        assertEq(vault.depositNav(), vault.totalAssets(), "nothing owed");
        uint256 expected = vault.previewDeposit(1_000e6);
        assertEq(queue.claim(id), expected, "priced at the plain live price");
        assertEq(vault.balanceOf(alice), expected, "shares landed with the depositor");
    }

    // ── B1: residue a template cannot value still BLOCKS, it cannot be priced ──

    /// @notice THE SKIM THAT SURVIVED PRICING. `ConcentratedLiquidityStrategy`
    ///         reports `undeliveredValue()` deliberately partial and biased low:
    ///         it excludes a live LP position, the volatile leg, and non-asset
    ///         collateral, because valuing them means reading a price the
    ///         proposal can move — the lever finding #3 was exploited through.
    ///
    ///         Under-reporting was harmless while a BOOLEAN lock covered every
    ///         residue shape. Once the figure sets the price a mint pays,
    ///         "biased low" IS the skim: a depositor mints against a price
    ///         missing the LP leg, sweeps it in, and takes the difference.
    ///         Pricing replaces the lock only where the value is knowable, so
    ///         the lock survives exactly where it is not.
    function test_finding3_unvaluableResidueStillBlocksDeposits() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setUnvalued(true);
        _settleWith(address(deliveryStrat));

        assertTrue(vault.depositsLocked(), "no honest price exists, so no mint");
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice And it lifts once the unvaluable leg is gone. Every such shape is
    ///         unwindable by the permissionless sweep — burning an LP position
    ///         always returns its tokens — so unlike an illiquid Morpho supply
    ///         this cannot wedge the vault.
    function test_finding3_unvaluableResidueClearsOnSweep() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setUnvalued(true);
        _settleWith(address(deliveryStrat));

        deliveryStrat.setUnvalued(false);
        vault.collectResidue(address(deliveryStrat));

        assertFalse(vault.depositsLocked(), "unwound, so priceable again");
        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "deposits reopen");
    }

    /// @notice THE LOCK EXPIRES, because a label that lies never lifts it.
    ///
    /// @dev    `_refreshUnvalued` takes `hasUnvaluedResidue()` at face value from
    ///         the settled strategy label, and `SyndicateGovernor.propose` stores
    ///         that label unvalidated — a contract satisfying `proposer()` and
    ///         `vault()` is enough, and it need never be a batch target or hold a
    ///         cent. A label that simply answers TRUE forever was unliftable
    ///         before this fix:
    ///           - `_refreshUnvalued` only clears on a truthful zero, which a
    ///             hostile contract never returns;
    ///           - `collectResidue` force-clears only for a CODELESS address, so
    ///             against a live liar it re-reads the lie and leaves the mark;
    ///           - `_unvaluedCount` is vault-wide, so unlike the
    ///             `_lastSettledStrategy` slot it replaced, no later settlement
    ///             displaces it;
    ///           - and no owner, governor or guardian path writes it.
    ///         Net: every deposit path, instant and queued, shut permanently by
    ///         any registered agent who can carry one proposal to Settled.
    ///
    ///         That is the failure this contract refuses everywhere else — see
    ///         `_recordResidue`'s own natspec making exactly this argument for a
    ///         codeless label ("a permanent DoS is worse than the suppression it
    ///         guards"). The codeless short-circuit just never covered the case
    ///         that matters. `UNVALUED_MAX_LOCK` bounds the episode.
    function test_lyingUnvaluedLabelCannotLockDepositsForever() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setUnvalued(true); // ...and never stops saying so
        _settleWith(address(deliveryStrat));

        assertTrue(vault.depositsLocked(), "the unvalued mark should hold the gate at first");

        // The permissionless exit does NOT lift it: the liar still has code and
        // still answers true, so both clearing arms decline.
        vault.collectResidue(address(deliveryStrat));
        assertTrue(vault.depositsLocked(), "collectResidue cleared a live liar's mark");

        // Still shut just before the deadline — the window is real, not a no-op.
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        assertTrue(vault.depositsLocked(), "the lock lapsed early");
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);

        // ...and open once it passes, with no privileged action by anyone.
        vm.warp(vm.getBlockTimestamp() + 2);
        assertFalse(vault.depositsLocked(), "the lock never lifted - permanent DoS");
        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "deposits never reopened");
    }

    /// @notice The deadline dates from the FIRST mark, so a second hostile label
    ///         cannot restart the clock and hold the gate indefinitely.
    /// @dev    Per-strategy expiry would leave the vector intact in a slower
    ///         form: mark, wait, mark again, forever. `_bumpUnvalued` stamps only
    ///         on the 0 -> 1 transition for exactly this reason.
    function test_secondUnvaluedLabelDoesNotRestartTheClock() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setUnvalued(true);
        _settleWith(address(deliveryStrat));

        // Halfway through the window, a SECOND lying label settles.
        vm.warp(vm.getBlockTimestamp() + 4 days);
        StubDeliveryStrategy second = new StubDeliveryStrategy();
        second.setHolding(true);
        second.setUnvalued(true);
        _settleWithPid(PID + 1, address(second));
        assertTrue(vault.depositsLocked(), "two marks outstanding, still inside the window");

        // The original deadline governs: 7 days from the FIRST mark, not from
        // the second. A restart here would be an unbounded lock again.
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        assertFalse(vault.depositsLocked(), "a later mark restarted the clock - the lock is unbounded again");
    }

    /// @notice THE GATE ARMS AGAIN AFTER A PRUNE, which is the whole reason the
    ///         prune exists.
    ///
    /// @dev    `UNVALUED_MAX_LOCK` bounds how long a mark SHUTS deposits, not
    ///         how long it SURVIVES. A liar's mark is permanent, so
    ///         `_unvaluedCount` never returns to zero, so the 0 -> 1 transition
    ///         that stamps `_unvaluedSince` never happens again — and the
    ///         deadline stays frozen at the attacker's timestamp forever. Every
    ///         LATER mark, from an honest strategy, is then a 1 -> 2 that
    ///         re-stamps nothing and is measured against a deadline months in
    ///         the past. Deposits stay open against a NAV that structurally
    ///         cannot include the unvaluable leg: the guard is off for the rest
    ///         of the vault's life, bought once, for the price of one settled
    ///         proposal.
    ///
    ///         This is the mutant that proves it: without the prune, the second
    ///         (honest) mark below does not lock.
    function test_pruningALapsedMarkRearmsTheGateForTheNextStrategy() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setUnvalued(true); // ...and never stops saying so
        _settleWith(address(deliveryStrat));
        assertTrue(vault.depositsLocked(), "precondition: the liar shuts the gate");

        // The window lapses. Deposits reopen, and the stale mark is still there.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        assertFalse(vault.depositsLocked(), "the lock did not lapse");

        // Anyone may drop it now that it blocks nothing.
        vm.prank(makeAddr("passerby"));
        vault.pruneUnvaluedMark(address(deliveryStrat));

        // THE POINT: a later, honest mark locks again. Before the prune this
        // was a 1 -> 2 measured against a deadline already 7 days gone.
        StubDeliveryStrategy honest = new StubDeliveryStrategy();
        honest.setHolding(true);
        honest.setUnvalued(true);
        _settleWithPid(PID + 1, address(honest));
        assertTrue(vault.depositsLocked(), "the gate never re-armed - it is off for good");
    }

    /// @notice Pruning INSIDE the window is refused: deposits are genuinely shut
    ///         there, so there is nothing stale to drop.
    /// @dev    A no-op would be worse than a revert — the caller could not tell
    ///         "too early" from "nothing marked", and the two differ by whether
    ///         the vault is currently accepting deposits.
    function test_pruneIsRefusedWhileTheLockIsStillRunning() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setUnvalued(true);
        _settleWith(address(deliveryStrat));

        vm.expectRevert(ISyndicateVault.UnvaluedLockStillActive.selector);
        vault.pruneUnvaluedMark(address(deliveryStrat));

        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(ISyndicateVault.UnvaluedLockStillActive.selector);
        vault.pruneUnvaluedMark(address(deliveryStrat));
    }

    /// @notice A PRUNED LABEL CANNOT MARK AGAIN, or the prune would hand anyone
    ///         a renewable lock.
    ///
    /// @dev    `_refreshUnvalued` re-reads the label on every `collectResidue`,
    ///         and the liar still answers TRUE. Without the burn, that read is a
    ///         fresh 0 -> 1: `_unvaluedSince` re-stamps and the vault shuts for
    ///         another full window — permissionlessly, for free, repeatable
    ///         forever by anyone. That is strictly worse than the DoS the expiry
    ///         was added to bound, so the burn and the prune ship together.
    ///
    ///         THE LABEL MUST CARRY A RECORDED RESIDUE AMOUNT for this to test
    ///         anything. `collectResidue` short-circuits on `!tracked` BEFORE it
    ///         reaches `_refreshUnvalued`, and after a prune the unvalued flag is
    ///         false — so with a zero `undeliveredValue()` the re-read never
    ///         happens and the test passes against a vault with no burn at all.
    ///         Caught by mutation: the first version of this test survived
    ///         deleting the guard it claims to pin.
    function test_prunedLabelCannotReshutTheGate() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setUnvalued(true);
        deliveryStrat.setResidue(1_000e6); // keeps it TRACKED past the prune
        _settleWith(address(deliveryStrat));

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vault.pruneUnvaluedMark(address(deliveryStrat));

        // Reaching `_refreshUnvalued` at all is the point of the line above.
        assertGt(vault.depositNav(), vault.totalAssets(), "precondition: the residue is on the books");

        // The liar has not changed its story, and this re-reads it.
        vault.collectResidue(address(deliveryStrat));
        assertFalse(vault.depositsLocked(), "a pruned label re-shut the gate - the lock is renewable");

        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "deposits did not stay open");
    }

    /// @notice A VALUABLE residue does NOT block — that is the point of pricing.
    ///         Only the unvaluable shape falls back to refusal.
    function test_finding3_valuableResidueDoesNotBlock() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(1_000e6);
        _settleWith(address(deliveryStrat));

        assertFalse(vault.depositsLocked(), "priceable, so not blocked");
        assertEq(vault.depositNav(), vault.totalAssets() + 1_000e6, "priced instead");
    }

    // ── B2: the self-reported figure is bounded ──

    /// @notice AN UNBOUNDED SELF-REPORTED NUMBER IS A DEPOSIT BRICK. The figure
    ///         comes from a proposer-chosen contract that `propose` does not
    ///         validate. Near `type(uint256).max` it would overflow
    ///         `depositNav()` and revert every mint path with no way to clear;
    ///         merely large would floor `previewDeposit` to zero.
    ///
    ///         Capped at the capital the vault held when the batch that funded
    ///         the strategy ran: it cannot owe back more than it was handed.
    function test_finding3_absurdResidueReportIsCappedNotFatal() public {
        governor.setCapitalSnapshot(2_000e6);

        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(type(uint256).max);
        _settleWith(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets() + 2_000e6, "clamped to the capital bound");

        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "mint paths still work");
    }

    /// @notice The cap holds on REFRESH too, so a strategy cannot report small
    ///         at settlement and enormous afterwards.
    function test_finding3_capHoldsOnRefresh() public {
        governor.setCapitalSnapshot(2_000e6);

        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(100e6);
        _settleWith(address(deliveryStrat));

        deliveryStrat.setResidue(type(uint256).max);
        vault.collectResidue(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets() + 2_000e6, "still bounded");
    }

    /// @notice A deposit that would mint zero shares is refused rather than
    ///         swallowing the assets. Independent of the residue work: the
    ///         instant path simply never had the guard the queue path has.
    function test_deposit_refusesWhenItWouldMintZeroShares() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(type(uint128).max);
        _settleWith(address(deliveryStrat));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.ZeroShares.selector);
        vault.deposit(1, alice);
    }

    /// @notice Zero in, zero out stays the harmless ERC-4626 no-op — the guard
    ///         is scoped to assets actually being taken.
    function test_deposit_zeroAssetsIsStillANoOp() public {
        vm.prank(alice);
        assertEq(vault.deposit(0, alice), 0, "zero-asset deposit is not an error");
    }

    /// @notice THE CAP IS THE TIGHTER OF THE TWO BOUNDS. The capital snapshot is
    ///         the vault's ENTIRE float before the batch, so on its own it would
    ///         admit a self-report of up to the whole vault — a permanent entry
    ///         tax a proposer could impose, compounding across settlements. The
    ///         coverage-scaled ceiling is what the batch was actually held to,
    ///         and it is the honest bound.
    function test_finding3_capUsesTheTighterOfSnapshotAndCeiling() public {
        governor.setCapitalSnapshot(50_000e6); // the whole vault
        governor.setEffectiveMaxCapital(2_000e6); // what the batch could move

        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(type(uint256).max);
        _settleWith(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets() + 2_000e6, "bounded by the ceiling, not the float");
    }

    /// @notice And the other way round, so the min is a real min rather than a
    ///         rename of the ceiling.
    function test_finding3_capUsesTheSnapshotWhenItIsTheTighter() public {
        governor.setCapitalSnapshot(800e6);
        governor.setEffectiveMaxCapital(5_000e6);

        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(type(uint256).max);
        _settleWith(address(deliveryStrat));

        assertEq(vault.depositNav(), vault.totalAssets() + 800e6, "bounded by the snapshot");
    }
}
