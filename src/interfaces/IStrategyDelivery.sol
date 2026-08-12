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
    ///         Read by `SyndicateVault.depositsLocked` through a length-checked
    ///         staticcall that degrades OPEN: a strategy which cannot answer
    ///         leaves deposits unlocked rather than bricking them, since failing
    ///         closed would let one non-conforming clone shut deposits for the
    ///         vault's whole remaining life with no permissionless way out.
    function hasUndeliveredValue() external view returns (bool);

    /// @notice The vault-asset value this strategy still holds and has not
    ///         delivered — the AMOUNT behind `hasUndeliveredValue`'s bool.
    ///
    /// @dev    CURRENTLY UNREAD BY THE VAULT, and deliberately so. The stamp
    ///         correction that would have consumed it was attempted twice and
    ///         reverted — raising the settle price reserves float the vault does
    ///         not hold, and no cap on the price bounds that (see the note at
    ///         `SyndicateVault.onProposalSettled` and issue #233). This member
    ///         is retained as the hook the replacement mechanism will use;
    ///         treat it as reserved, not as live behaviour.
    ///
    ///         UNREAD AND THEREFORE UNCOVERED. With no caller, the vault-side
    ///         degrade path is unreachable from a test, and a test asserting
    ///         otherwise would be theatre — one was written and removed for
    ///         exactly that reason. Whoever wires the consumer in #233 owns
    ///         covering it then.
    ///
    ///         READ ONLY AT SETTLEMENT once a caller exists, and that scoping is
    ///         the whole safety argument. `VaultWithdrawalQueue`'s header commits the vault to
    ///         stamping ONE frozen REALIZED price per proposal precisely "so the
    ///         vault never mints or burns against an unrealized,
    ///         strategy-influenced NAV". Counting strategy-held value in the
    ///         LIVE `totalAssets()` would reintroduce exactly that, and hand a
    ///         proposer the pricing lever back. By settlement the position is
    ///         already unwound, so what remains is realized-but-undelivered
    ///         value — a receivable, not a mark to market.
    ///
    ///         MUST NOT REVERT and must not depend on a price an attacker can
    ///         move within the settlement transaction. Callers read it through a
    ///         length-checked staticcall that treats any failure as 0, which
    ///         degrades to the pre-fix stamp rather than to a wrong one.
    function undeliveredValue() external view returns (uint256);
}
