// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultInstantLiquidityTest} from "../SyndicateVault.InstantLiquidity.t.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";

/// @dev A settled strategy that answers the delivery probe. `holding` is what a
///      `sweep()` would still return.
contract StubDeliveryStrategy {
    bool public holding;

    function setHolding(bool v) external {
        holding = v;
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

/// @title SyndicateVault — deposits stay shut while a settlement is still in flight
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
contract PashovFinalDepositLockTest is VaultInstantLiquidityTest {
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

    /// @notice THE PIN. A residue still on the clone keeps deposits shut.
    ///         Pre-fix this deposit succeeded at the under-reported price.
    function test_finding3_depositsLockedWhileResidueOutstanding() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        _settleWith(address(deliveryStrat));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice THE STAMP STAYS FLOAT-ONLY, and this pins that deliberately.
    ///         Adding the residue to `num` was tried and reverted: the queue
    ///         reserve is `mulDiv(redeemShares, num, den)`, so raising `num`
    ///         reserves assets the vault does not hold and floors instant exits
    ///         for every LP. Capping `num` does not help — the reserve scales
    ///         with a ratio this call does not control.
    ///
    ///         So the queued-deposit mispricing remains OPEN, and this test
    ///         exists so nobody re-adds the residue here without also solving
    ///         the reserve coupling (skip-stamp plus a permissionless
    ///         `restamp`, most likely).
    function test_finding3_stampRemainsFloatOnly() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        deliveryStrat.setResidue(4_000e6);
        deal(vault.asset(), address(vault), 10_000e6);

        uint256 float_ = vault.totalAssets();
        _settleWith(address(deliveryStrat));

        IVaultWithdrawalQueue.SettlePrice memory sp = queue.getSettlePrice(PID);
        assertEq(sp.num, float_ + 1, "stamp must stay payable; residue correction needs a non-reserving mechanism");
    }

    /// @notice NOBODY IS WEDGED — the property that makes locking safe here.
    ///         `sweep()` is permissionless, so the very depositor this refuses
    ///         can trigger the recovery and then deposit at the correct price.
    ///         Blocking SETTLEMENT would not have this property, which is why
    ///         the guard is on deposits only.
    function test_finding3_depositsReopenOnceTheResidueIsSwept() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        _settleWith(address(deliveryStrat));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);

        // The residue comes back and the strategy goes quiet — but the gate
        // reads a COUNTER, not a live probe, so it takes an explicit
        // `collectResidue` to stop counting this strategy. That call is
        // permissionless and untaxed precisely so the refused depositor can
        // make it themselves.
        deliveryStrat.setHolding(false);
        assertTrue(vault.depositsLocked(), "still counted until collected");

        vm.prank(alice);
        vault.collectResidue(address(deliveryStrat));

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "deposits reopen once the residue is collected");
    }

    /// @notice A COMPLETE settlement is unaffected. Without this the fix could be
    ///         "lock deposits after every settlement", which would shut the
    ///         vault permanently in the ordinary case.
    function test_finding3_completeSettlementLeavesDepositsOpen() public {
        deliveryStrat = new StubDeliveryStrategy(); // holding == false
        _settleWith(address(deliveryStrat));

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "nothing outstanding, nothing to wait for");
    }

    /// @notice DEGRADES OPEN, AND THAT IS FORCED RATHER THAN PREFERRED. A
    ///         strategy that cannot answer is never marked, so deposits stay
    ///         open.
    ///
    ///         Failing closed was tried in this PR and reverted: the mark would
    ///         be unremovable, because `collectResidue` can only clear on a
    ///         definite readable zero. An address that can never answer would be
    ///         marked once and never cleared, shutting every deposit path —
    ///         instant and queued — for the rest of the vault's life, with no
    ///         permissionless exit. See the EOA test below for why that is
    ///         reachable by any registered agent rather than theoretical.
    ///
    ///         A permanent DoS is worse than the suppression it guards, which is
    ///         the trade `_PROBE_GAS` already documents and the doctrine both
    ///         templates state.
    function test_finding3_unanswerableStrategyLeavesDepositsOpen() public {
        _settleWith(address(new StubDeliveryShortReturn()));

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "a malformed answer must not brick deposits");
        assertFalse(vault.depositsLocked(), "unreadable is never marked");
    }

    /// @notice THE BLOCKER THIS PR SHIPPED AND THEN FIXED. `SyndicateGovernor`
    ///         stores `strategy` unvalidated and explicitly skips its own probe
    ///         for codeless addresses (`strategy.code.length != 0` there,
    ///         pinned by `test_propose_eoaStrategySucceedsAtPropose`). Nothing
    ///         ever calls the field — it is a label — so a proposal naming an
    ///         EOA executes and settles normally.
    ///
    ///         A staticcall to a codeless address succeeds with EMPTY
    ///         returndata. Under a fail-closed mark that is "unreadable", so the
    ///         EOA was marked and could never be cleared: one proposal from any
    ///         registered agent permanently shut every deposit path on the
    ///         vault. Codeless is now short-circuited before any call — the same
    ///         treatment `address(0)` gets, and the same rule `propose` applies.
    function test_finding3_eoaStrategyCannotBrickDeposits() public {
        _settleWith(makeAddr("eoaStrategyLabel"));

        assertFalse(vault.depositsLocked(), "an EOA label must never lock the vault");
        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "deposits unaffected by a codeless strategy");
    }

    /// @notice A strategy that DID owe and has since self-destructed is
    ///         clearable: it can hold nothing and answer nothing, so counting it
    ///         forever would be a wedge with no upside.
    function test_finding3_codelessAfterMarkingIsClearable() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        _settleWith(address(deliveryStrat));
        assertTrue(vault.depositsLocked(), "marked on a definite yes");

        // The clone's code goes away underneath the mark.
        vm.etch(address(deliveryStrat), "");
        vault.collectResidue(address(deliveryStrat));
        assertFalse(vault.depositsLocked(), "codeless clears rather than wedging");
    }

    /// @notice A LIVE contract that stops answering stays counted — deposits
    ///         shut. That state is only ever entered from a definite readable
    ///         "yes", so it means a strategy that DID owe went quiet, not that
    ///         an arbitrary address was marked.
    function test_finding3_liveStrategyThatStopsAnsweringStaysCounted() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        _settleWith(address(deliveryStrat));

        // Same address, now a contract that cannot answer the probe.
        vm.etch(address(deliveryStrat), address(new StubDeliveryShortReturn()).code);
        vault.collectResidue(address(deliveryStrat));
        assertTrue(vault.depositsLocked(), "a live strategy that went quiet stays counted");
    }

    /// @notice The original lock is untouched: an OPEN proposal still shuts
    ///         deposits regardless of what any strategy reports. The new probe
    ///         is an additional condition, not a replacement.
    function test_finding3_openProposalStillLocksIndependently() public {
        deliveryStrat = new StubDeliveryStrategy(); // reports nothing outstanding
        governor.set(PID, 1, address(deliveryStrat));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice A vault that never settled anything has no pin, so the probe is
    ///         skipped entirely — the zero address reads as nothing outstanding
    ///         rather than as an unanswerable strategy.
    function test_finding3_noSettlementYetLeavesDepositsOpen() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "fresh vault, nothing pinned, deposits open");
    }

    // ── the MULTI-STRATEGY half of the same gate ──

    /// @notice THE TWO-PROPOSAL SKIM. The gate used to hang off a single
    ///         `_lastSettledStrategy` pin, overwritten at every settlement — so
    ///         a strategy that was still holding a residue simply stopped being
    ///         watched the moment the next proposal settled.
    ///
    ///         Settle N dirty (deposits locked, correctly). Settle N+1 clean.
    ///         The pin moves to N+1, which reports nothing, and deposits reopen
    ///         — while N's clone still holds `R` and `sweep()` is permissionless.
    ///         Deposit cheap, sweep N, skim: the same finding-#3 theft, reached
    ///         one proposal later and around the fix.
    ///
    ///         The gate now counts EVERY strategy that still owes.
    function test_finding3_earlierStrategysResidueStillLocksAfterALaterCleanSettlement() public {
        StubDeliveryStrategy dirty = new StubDeliveryStrategy();
        dirty.setHolding(true);
        _settleWithPid(PID, address(dirty));
        assertTrue(vault.depositsLocked(), "N settled dirty");

        // A later proposal settles CLEAN with a different strategy.
        StubDeliveryStrategy clean = new StubDeliveryStrategy(); // holding == false
        _settleWithPid(PID + 1, address(clean));

        // Pre-fix the pin now named `clean`, which reports nothing, and this
        // deposit succeeded while `dirty` was still holding the residue.
        assertTrue(vault.depositsLocked(), "the earlier strategy still owes");
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);

        // Collecting the CLEAN one is not enough — it was never the problem.
        vault.collectResidue(address(clean));
        assertTrue(vault.depositsLocked(), "clearing the wrong strategy changes nothing");

        // Collecting the one that actually owes is what opens the gate.
        dirty.setHolding(false);
        vault.collectResidue(address(dirty));
        assertFalse(vault.depositsLocked(), "both accounted for");

        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0, "deposits reopen");
    }

    /// @notice Two dirty settlements outstanding at once: the count is a count,
    ///         not a flag. Clearing one leaves the gate shut for the other.
    function test_finding3_twoOutstandingStrategiesEachHoldTheGate() public {
        StubDeliveryStrategy a = new StubDeliveryStrategy();
        a.setHolding(true);
        _settleWithPid(PID, address(a));

        StubDeliveryStrategy b = new StubDeliveryStrategy();
        b.setHolding(true);
        _settleWithPid(PID + 1, address(b));

        a.setHolding(false);
        vault.collectResidue(address(a));
        assertTrue(vault.depositsLocked(), "b still owes");

        b.setHolding(false);
        vault.collectResidue(address(b));
        assertFalse(vault.depositsLocked(), "both cleared");
    }

    /// @notice `collectResidue` never clears a strategy that still owes, however
    ///         many times it is called — the counter cannot be drained by
    ///         repetition.
    function test_finding3_collectResidueIsNoOpWhileTheStrategyStillOwes() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);
        _settleWith(address(deliveryStrat));

        vault.collectResidue(address(deliveryStrat));
        vault.collectResidue(address(deliveryStrat));
        assertTrue(vault.depositsLocked(), "still owing, still counted");
    }

    /// @notice And it cannot be double-cleared: once a strategy has left the
    ///         set, further calls are inert rather than decrementing the count
    ///         again (which would open the gate while another strategy owes).
    function test_finding3_collectResidueCannotDoubleClear() public {
        StubDeliveryStrategy a = new StubDeliveryStrategy();
        a.setHolding(true);
        _settleWithPid(PID, address(a));

        StubDeliveryStrategy b = new StubDeliveryStrategy();
        b.setHolding(true);
        _settleWithPid(PID + 1, address(b));

        a.setHolding(false);
        vault.collectResidue(address(a));
        vault.collectResidue(address(a)); // second call must not decrement again
        vault.collectResidue(address(a));

        assertTrue(vault.depositsLocked(), "b still owes; a cannot be cleared twice");
    }

    // ── the ASYNC half of the same gate ──

    /// @notice THE HOLE THIS PR CLOSES. The instant path was already shut while
    ///         a residue was outstanding; the QUEUED path was not. A deposit
    ///         requested during the proposal claimed afterwards against the
    ///         frozen settle stamp — a number computed from float alone, blind
    ///         to the residue by construction — so the skim survived the earlier
    ///         fix entirely by going around it.
    ///
    ///         Now the claim gates on the same predicate as the instant path.
    function test_finding3_queuedDepositClaimRefusedWhileResidueOutstanding() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);

        // Queue a deposit while the proposal is live, then settle it dirty.
        governor.set(PID, 1, address(deliveryStrat));
        vm.prank(alice);
        uint256 id = vault.requestDeposit(1_000e6, alice);

        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        governor.set(0, 0, address(0));

        // The open count is clear, so the OLD gate would have let this mint at
        // the residue-blind stamp. The residue probe holds it shut.
        assertTrue(vault.depositsLocked(), "residue outstanding");
        vm.expectRevert(IVaultWithdrawalQueue.VaultLocked.selector);
        queue.claim(id);
    }

    /// @notice And it opens again once the residue is in — at the corrected
    ///         price, which is the half that makes the gate meaningful rather
    ///         than merely obstructive. `sweep()` is permissionless and untaxed,
    ///         so the very depositor being refused can clear it themselves.
    function test_finding3_queuedDepositClaimOpensOnceResidueIsCleared() public {
        deliveryStrat = new StubDeliveryStrategy();
        deliveryStrat.setHolding(true);

        governor.set(PID, 1, address(deliveryStrat));
        vm.prank(alice);
        uint256 id = vault.requestDeposit(1_000e6, alice);

        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        governor.set(0, 0, address(0));

        // The residue is delivered and collected — only then does the strategy
        // stop counting against the gate.
        deliveryStrat.setHolding(false);
        vault.collectResidue(address(deliveryStrat));
        assertFalse(vault.depositsLocked(), "residue cleared");

        uint256 expected = vault.convertToShares(1_000e6);
        uint256 minted = queue.claim(id);
        assertEq(minted, expected, "mints at the live, residue-inclusive price");
        assertEq(vault.balanceOf(alice), minted, "shares landed with the depositor");
    }
}
