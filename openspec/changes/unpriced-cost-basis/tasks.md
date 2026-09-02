# Tasks — unpriced-cost-basis

Ships inside the LaunchpadStrategy PR (SHE-153, PR #277): the governor seam and
both affected templates already live on this branch, and fixing them apart would
leave `ConcentratedLiquidityStrategy` reporting the same false loss.

Order matters. The clamp (2.2) is the safety property the rest of the change
rests on and SHOULD land with its adversarial test (5.1) in the same commit as
the credit it bounds — a credit merged without its clamp is an extraction path.

## 1. Interface and base

- [ ] 1.1 Declare `unpricedCostBasis()` on `IStrategyDelivery`: the vault-asset amount the strategy spent acquiring inventory it declines to price. Natspec MUST state the coupling — a template overriding `hasUnvaluedResidue()` to true owes a basis — and MUST state that the figure is recorded at deployment time, not derived from live balances, so moving inventory between holders that both decline to price it changes nothing.
- [ ] 1.2 Add the `virtual` default returning `0` to `BaseStrategy`, alongside the existing `hasUnvaluedResidue`/`undeliveredValue` defaults and documented from the same rationale.

## 2. Governor

- [ ] 2.1 Add the bounded-gas probe, mirroring `SyndicateVault._readUndeliveredValue`: `staticcall{gas: _PROBE_GAS}`, `ok == false` or `ret.length != 32` yields zero. Do NOT distinguish unknown from zero here — unlike the vault's residue probe, the two mean the same thing for a credit that defaults to no credit.
- [ ] 2.2 **The clamp.** `basis = min(probe, apparentLoss)` where `apparentLoss = snapshot > balanceNow ? snapshot - balanceNow : 0`. Natspec MUST record why it exists: a conversion may erase a reported loss and may never manufacture a gain, which is what makes a strategy-supplied number safe to trust at all.
- [ ] 2.3 Credit the clamped basis in `_finishSettlement`, alongside the existing interim-LP-flow term.
- [ ] 2.4 Credit the clamped basis in the CAPITAL floor: compare `realized + basis` against `floor` before reverting `SettlementBelowDrawdownFloor`. Beware the local name collision — that block already binds `basis` to the capital snapshot, so name the new term distinctly (`convertedBasis`) rather than shadowing it.
- [ ] 2.5 Credit the same clamped basis in `_requireSettlePriceAboveFloorHook`, converted to price-per-share units and rounded DOWN. Leave the rescue path's `MAX_STAMP_DRAWDOWN_BPS` backstop and the ungated `_finishSettlementHook` paths untouched.
- [ ] 2.6 Add `bool expectsUnpricedResidue` to `StrategyProposal`, packed into the existing `maxDrawdownBps`/`envelopeTier` slot. Confirm with `forge inspect SyndicateGovernor storage` that no later member's offset moved.
- [ ] 2.7 Add the matching field to `RiskEnvelope` — the struct that already carries `maxDrawdownBps` into `propose` — and persist it at `SyndicateGovernor.sol:665` alongside it. Validate nothing: any combination is legal at propose; the mismatch is caught at settle.
- [ ] 2.8 Revert at settle when `basis > 0 && !expectsUnpricedResidue`. New named error.
- [ ] 2.9 Emit `UnpricedConversion(proposalId, vault, costBasis)` when the credited basis is nonzero. `ProposalSettled` keeps its exact signature.

## 3. Templates

- [ ] 3.1 `LaunchpadStrategy`: record at execute the vault asset consumed acquiring the reserve — the amount swapped into the quote plus the native launch fee per `nativeFeeSource()` — and report it less any quote `_convertQuote` returned at settle.
- [ ] 3.2 `ConcentratedLiquidityStrategy`: record the vault asset contributed to the position, report it less what unwinding has returned, zero once the position is closed and its proceeds delivered.
- [ ] 3.3 Confirm `MorphoSupplyStrategy` and `PortfolioStrategy` need no change (neither overrides the residue predicates) and add the coupling assertion for them rather than an override.

## 4. Consumers

- [ ] 4.1 CLI/app: render `UnpricedConversion` as deployed-into-position rather than loss. Coordinate with the sherwood-app work — this is the surface Ana read as malicious.
- [ ] 4.2 Deploy script / proposal builders: set `expectsUnpricedResidue` for launchpad and CL proposals.

## 5. Tests

- [ ] 5.1 **Hostile template.** A mock returning `type(uint256).max` settles at exactly zero P&L, charges no performance fee, and does not ratchet the high-water mark. This is the test that says the new trusted number cannot extract value; it MUST land with 2.2.
- [ ] 5.2 Capital-floor relief: a launch settles with a modest declared envelope where it previously required `maxDrawdownBps = 10_000` to skip the gate.
- [ ] 5.3 Price-floor relief: a launch deploying more than `MAX_STAMP_DRAWDOWN_BPS` of NAV settles by the ordinary permissionless path — impossible before this change.
- [ ] 5.4 Both floors still bind: a converting strategy that also loses beyond its envelope is still refused by each gate independently.
- [ ] 5.5 Undeclared conversion reverts; declared-but-zero settles normally with no event.
- [ ] 5.6 CL settling with a live LP position reports honest P&L.
- [ ] 5.7 Unreadable probe: a template without the view settles byte-for-byte as before.
- [ ] 5.8 Sweep independence: sweeping inventory to the vault does not change the reported basis.
- [ ] 5.9 Bool/basis coupling across all four templates.
- [ ] 5.10 Re-run the launchpad fork e2e (`script/fork/launchpad-e2e.sh`) and confirm the reported P&L on a live launch is no longer the full deployment as loss.

## 6. Follow-through

- [ ] 6.1 Update `openspec/changes/launchpad-strategy/design.md` where it documents settlement leaving P&L understated, pointing at this change.
- [ ] 6.2 Note in the PR description that this fixes a `ConcentratedLiquidityStrategy` defect that predates the launchpad work, so reviewers do not read the CL diff as scope creep.
