# Seat maxStrategyDuration; assert delegationEnabled == false (DeployPlanB)

> Merged via PR #80 (originally authored as an independent OpenSpec change proposal, reconciled into the migrated spec tree on 2026-08-01).

## Why

Closes issue #32. Two deploy-time invariants PR #22 introduced/relied on but
never enforced:

1. `ProtocolConfig.maxStrategyDuration` ships 0 = no ceiling. The
   capped-duration ADR says values are deferred but INVARIANTS are not; a
   vault owner can meanwhile seat any duration up to 3,650 days, unbounding
   guardian exposure (finding N4's enabling condition).
2. `delegationEnabled == false` is assumed by the v2-deferral of delegation
   (the delegator-walkout hole stays dormant only while it's off), but no
   pre-flight asserts it.

## What changes

STACKED ON PR #61's branch (`fix/pr56-review-findings`) — that PR owns
`DeployPlanB.s.sol`'s current shape (issue #30's rewrite, beacon pre-flights)
and this change slots two more pre-flights beside them. Base branch of the
PR = `fix/pr56-review-findings`; retarget to main after #61 merges.

1. `DeployPlanB` seats `ProtocolConfig.maxStrategyDuration` inside the
   broadcast (env-parameterized `MAX_STRATEGY_DURATION`, default from the
   ADR/spec — implementer reads `docs/superpowers/specs/2026-07-26-capped-duration-coverage.md`
   and the existing testnet scripts' 7d/30d precedents to pick the default,
   and records the choice in the PR), then post-broadcast asserts it != 0.
2. Post-broadcast assert `delegationEnabled == false` (read from wherever it
   lives — StakedWood/ProtocolConfig; implementer locates the actual getter)
   with a message naming the delegator-walkout hole as the reason.
3. Both asserts follow the script's existing pre-flight message style
   (actionable, names the fix).

## Impact

- `script/DeployPlanB.s.sol` + `test/deploy/DeployPlanBPreflight.t.sol`
  (extend the suite #61 added). Nothing else. No src/ changes.
- Conflicts: deliberately based on #61 to avoid them; disjoint from PR #64's
  escrow hunk. Do not touch #68 scope.
