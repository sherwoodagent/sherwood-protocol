// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IStrategyDelivery
 * @notice The one question the vault asks a SETTLED strategy: is any of this
 *         proposal's value still in flight?
 *
 *         Kept as its own file, and as a single scalar, for the same reason
 *         `IProposalStatus` is narrow — it makes "what can the vault learn from
 *         a strategy" answerable from one place, and a test fake satisfies it in
 *         one line.
 *
 * @dev    WHY THE VAULT NEEDS TO ASK. `totalAssets()` counts only
 *         `balanceOf(this)`, so any value a strategy still holds is priced at
 *         zero. During a live proposal that is covered by `openProposalCount()
 *         != 0`, but strategy settlement is DELIVERABLE-MAXIMUM rather than
 *         all-or-revert — a market at high utilization delivers what it can,
 *         emits `SettlementIncomplete`, and leaves the rest claimable by the
 *         permissionless `sweep()`. `_finishSettlement` clears the open count
 *         regardless, so between settlement and the sweep the vault reopens
 *         deposits at a price missing the residue.
 *
 *         Implementations must answer for the SETTLED state specifically. A
 *         strategy that is still executing is already covered by the open
 *         count, and a strategy that has delivered everything must answer false
 *         or deposits stay shut until someone calls a sweep that would move
 *         nothing.
 */
interface IStrategyDelivery {
    /// @notice True while this strategy still holds value belonging to the
    ///         vault that a `sweep()` (or equivalent release) would return.
    ///
    ///         Read by `SyndicateVault._depositsLocked` through a length-checked
    ///         staticcall that degrades OPEN: a strategy which cannot answer
    ///         leaves deposits unlocked rather than bricking them, since failing
    ///         closed would let one non-conforming clone shut deposits for the
    ///         vault's whole remaining life with no permissionless way out.
    function hasUndeliveredValue() external view returns (bool);
}
