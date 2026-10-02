# Tasks

## 1. Source

- [x] 1.1 `GovernorEmergency.finalizeEmergencySettle` passes `maxNetOutflow = 0`.
- [x] 1.2 `SyndicateFactory.rotateOwner` applies `ProposalActive` / `ProposalsOpen` only when `newOwner != currentOwner`.

## 2. Tests

- [x] 2.1 `test/audit-fixes/GovernorEmergency_zeroEgressBudget.t.sol`: the inverted V1-02 PoC, the precise bound, the redirect residual, the outside-funded repay.
- [x] 2.2 `test/audit-fixes/SyndicateFactory_rotateOwner_sameOwnerRebond.t.sol`: the inverted V1-03 PoC (full recovery), a stranger still refused, consent required, each blocked round costs a bond.
- [x] 2.3 `test/audit-fixes/PortfolioStrategy_deadFeedRebond.t.sol`: the recovery on the shipped PortfolioStrategy.
- [x] 2.4 Update the two tests that asserted the old emergency budget.

## 3. Docs

- [x] 3.1 `docs/guardian-network.md` and the `StakedWood.requiredOwnerBond` natspec.
