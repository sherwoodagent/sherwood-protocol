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
        // Live proposal naming `strategy`, then settle it — the governor stamps
        // and clears the open count, which is exactly the transition under test.
        governor.set(PID, 1, strategy);
        vm.prank(address(governor));
        vault.onProposalSettled(PID);
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

        // Anyone calls sweep(); the residue returns and the probe goes quiet.
        deliveryStrat.setHolding(false);

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "deposits must reopen the moment the residue is back");
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

    /// @notice DEGRADES CLOSED, AND THAT IS THE INVERSION OF AN EARLIER STATED
    ///         DECISION. A pinned strategy that cannot answer now LOCKS
    ///         deposits.
    ///
    ///         The earlier posture — degrade open, because one non-conforming
    ///         clone shutting deposits is worse than the mispricing — was
    ///         defensible while this probe was defence-in-depth on the instant
    ///         path alone. It is not defensible now: the queued-deposit claim
    ///         gates on this same predicate, so a probe that degrades OPEN
    ///         degrades the entire finding-#3 gate open, in precisely the window
    ///         an attacker can force (the flash loan that empties the market's
    ///         idle balance to induce the residue can also, on a gas-burning
    ///         IRM, push the probe past `_PROBE_GAS`). A false lock costs a
    ///         wait; a false open is the skim.
    ///
    ///         Bounded, not unbounded: the pin only names a clone of a
    ///         factory-allowlisted, TierRegistry-certified template, and the
    ///         permissionless untaxed `sweep()` plus the next settlement's
    ///         re-pin are the exits.
    function test_finding3_unanswerableStrategyLocksDeposits() public {
        _settleWith(makeAddr("strategyWithNoCode"));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice Same inversion for a wrong-shaped answer — the explicit
    ///         `ret.length` check is still what keeps this a DECISION rather
    ///         than an undecodable revert inside a view the deposit path
    ///         depends on; only the decision's direction changed.
    function test_finding3_shortReturnStrategyLocksDeposits() public {
        _settleWith(address(new StubDeliveryShortReturn()));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
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

        // The residue is delivered — the strategy no longer holds anything.
        deliveryStrat.setHolding(false);
        assertFalse(vault.depositsLocked(), "residue cleared");

        uint256 expected = vault.convertToShares(1_000e6);
        uint256 minted = queue.claim(id);
        assertEq(minted, expected, "mints at the live, residue-inclusive price");
        assertEq(vault.balanceOf(alice), minted, "shares landed with the depositor");
    }
}
