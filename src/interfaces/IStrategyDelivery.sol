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

    /// @notice The vault-asset amount this strategy SPENT acquiring inventory it
    ///         declines to price — the cost basis of whatever made
    ///         `hasUnvaluedResidue()` true.
    ///
    /// @dev    THE COMPANION TO THE PREDICATE ABOVE, and the two MUST NOT
    ///         DIVERGE: a template that refuses to price something owes the
    ///         figure it paid for it, exactly as `hasUndeliveredValue()` owes
    ///         `undeliveredValue()`. Default `0` on `BaseStrategy`, so only a
    ///         template that overrides the predicate implements this.
    ///
    ///         WHAT IT IS FOR. Settlement measures performance as the vault's
    ///         ASSET-balance delta, which silently asserts that every strategy
    ///         round-trips into the vault asset. A template that deliberately
    ///         does not — a launch holding its launch token, a CL clone holding
    ///         a live position — would otherwise have its entire deployment
    ///         reported as a LOSS, and would trip the settlement drawdown gates
    ///         that exist to catch value which genuinely vanished. This figure
    ///         is what lets the governor tell CONVERTED from LOST.
    ///
    ///         IT IS A COST, NOT A VALUATION. Reporting what was paid keeps this
    ///         view free of the movable price that `hasUnvaluedResidue()` exists
    ///         to avoid consulting. It is emphatically NOT a mark-to-market of
    ///         the inventory, and a caller MUST NOT read it as one — the fund
    ///         still holds something it cannot price, and this says only what it
    ///         cost to get.
    ///
    ///         RECORDED, NOT MEASURED LIVE. Derive this from a figure recorded
    ///         when the capital was deployed, never from a live balance read.
    ///         Inventory can move — `sweep()` hands it to the vault, which does
    ///         not price it either — and a balance-derived answer would collapse
    ///         to zero the moment it did, resurrecting the false loss. Moving
    ///         inventory between two holders that both decline to price it
    ///         realizes nothing. Report zero only once the capital is genuinely
    ///         REALIZED: converted back into the vault asset, where the ordinary
    ///         balance-delta measure sees it again.
    ///
    ///         The governor CLAMPS whatever this returns to the settling
    ///         proposal's own apparent loss, so an over-report can erase a
    ///         reported loss and can never manufacture a gain. That bound is the
    ///         reason a strategy-supplied number is safe to consume here at all;
    ///         it is not licence to return a figure that is not the true cost.
    ///
    ///         MUST NOT REVERT. Read through a bounded-gas staticcall whose
    ///         failure is treated as zero, which is what lets a strategy
    ///         predating this view settle unchanged.
    function unpricedCostBasis() external view returns (uint256);

    /// @notice Whether this template is EXPECTED to settle holding inventory it
    ///         declines to price — true for a launch that keeps its launch
    ///         token, false for a template that round-trips into the vault
    ///         asset.
    ///
    /// @dev    READ AT PROPOSE TIME and snapshotted onto the proposal, so a
    ///         guardian reviewing it sees the intent BEFORE execution rather
    ///         than discovering the conversion at settlement. Settlement then
    ///         refuses a strategy that reports a basis without this having been
    ///         recorded.
    ///
    ///         DECLARED BY THE TEMPLATE, NOT BY THE PROPOSER, and that is the
    ///         point. The proposer cannot set it, so it cannot be used to buy
    ///         drawdown relief for a strategy that has not earned it; it comes
    ///         from code the TierRegistry certified, exactly like the cost basis
    ///         itself. A CONSTANT of the template's design rather than of one
    ///         proposal's parameters — every launch converts, no Morpho supply
    ///         does — so it is answerable before the clone has run.
    ///
    ///         MUST NOT REVERT. Read through a bounded-gas staticcall whose
    ///         failure is treated as `false`, so a strategy predating this view
    ///         proposes and settles exactly as it always did.
    function expectsUnpricedResidue() external view returns (bool);
}
