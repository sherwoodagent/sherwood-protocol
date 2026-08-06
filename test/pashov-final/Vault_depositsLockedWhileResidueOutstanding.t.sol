// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultInstantLiquidityTest} from "../SyndicateVault.InstantLiquidity.t.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";

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

    /// @notice DEGRADES OPEN, AND THAT IS A STATED DECISION. A strategy that
    ///         cannot answer leaves deposits unlocked — the pre-existing
    ///         behaviour — rather than locked.
    ///
    ///         Failing closed would let one non-conforming clone shut deposits
    ///         for the vault's whole remaining life with no permissionless way
    ///         out, which is a worse and far less reversible failure than the
    ///         mispricing being guarded against. The guard is therefore
    ///         best-effort by construction, not airtight.
    function test_finding3_unanswerableStrategyLeavesDepositsOpen() public {
        _settleWith(makeAddr("strategyWithNoCode"));

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "a codeless strategy must not brick deposits forever");
    }

    /// @notice Same decision for a wrong-shaped answer — the explicit
    ///         `ret.length` check is what keeps this a decision rather than an
    ///         undecodable revert inside a view the deposit path depends on.
    function test_finding3_shortReturnStrategyLeavesDepositsOpen() public {
        _settleWith(address(new StubDeliveryShortReturn()));

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "a malformed answer must not be decoded");
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
}
