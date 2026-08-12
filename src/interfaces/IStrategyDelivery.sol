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
    ///         Read by `SyndicateVault` through a length-checked
    ///         staticcall that degrades OPEN: a strategy which cannot answer
    ///         leaves deposits unlocked rather than bricking them, since failing
    ///         closed would let one non-conforming clone shut deposits for the
    ///         vault's whole remaining life with no permissionless way out.
    function hasUndeliveredValue() external view returns (bool);

    /// @notice The vault-asset value this strategy still holds and has not
    ///         delivered — the AMOUNT behind `hasUndeliveredValue`'s bool.
    ///
    /// @dev    LIVE, AND LOAD-BEARING: this is the number every MINT is priced
    ///         against. The vault adds it to `totalAssets()` in `depositNav()`,
    ///         which `previewDeposit` / `previewMint` read, so a report that is
    ///         too LOW is the finding-#3 skim (a depositor mints against a price
    ///         missing value they can then sweep in) and one that is too HIGH
    ///         only over-charges that depositor. Bias low is therefore NOT safe
    ///         here in the way it was when a boolean lock guarded the mint —
    ///         anything this cannot value must be declared through
    ///         `hasUnvaluedResidue()` so the vault refuses to mint instead of
    ///         charging a number it knows is incomplete.
    ///
    ///         The stamp correction that would once have consumed this was
    ///         attempted twice and reverted — raising the settle price reserves
    ///         float the vault does not hold. That is why the figure lives on
    ///         the DEPOSIT side only: redemptions still read `totalAssets()`,
    ///         so nothing is ever paid out against value that has not arrived.
    ///
    ///         BOUNDED BY THE CALLER. The vault clamps each strategy's
    ///         contribution to the capital it was handed
    ///         (`SyndicateVault._residueCap`), because this member is
    ///         self-reported by a proposer-chosen contract and an unbounded
    ///         figure would overflow or zero out every mint path.
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

    /// @notice Whether this strategy holds undelivered value it CANNOT express
    ///         in vault-asset units — an open LP position, a volatile leg, a
    ///         collateral token that is not the vault asset.
    /// @dev    THE COMPANION `undeliveredValue()` NEEDS TO BE HONEST ABOUT ITS
    ///         OWN BLIND SPOTS. That figure is deliberately partial and biased
    ///         low, because valuing the excluded legs would mean consulting a
    ///         price an attacker can move inside the settlement transaction —
    ///         exactly what finding #3 exploited. Under-reporting was harmless
    ///         while a boolean lock covered every residue shape; it is NOT
    ///         harmless now that the figure sets the price a mint pays, because
    ///         "biased low" is then precisely the skim.
    ///
    ///         So a template that cannot value something must SAY so here. The
    ///         vault prices what is valued and refuses to mint at all while
    ///         anything is unvalued — the one place a lock still beats a price,
    ///         since there is no honest number to charge.
    ///
    ///         MUST NOT REVERT and must not depend on a movable price; an
    ///         unreadable answer is treated as the last known one.
    function hasUnvaluedResidue() external view returns (bool);
}
