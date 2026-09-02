# Archived unfinished, spec delta NOT merged

Archived at 15/18 tasks with `--skip-specs`, deliberately.

This change wired `ExposureLedger.settleCoverage` as a best-effort self-trigger from
`SyndicateGovernor._finishSettlement` and `reclaimProposerBond` (issue #33). The
`declared-coverage-locks` change removes `settleCoverage` and the reservation-collapse
mechanism it belonged to entirely (SHE-227 Variant C + Option B): guardians declare a
WOOD lock, nothing over-reserves, so nothing ever needs collapsing.

Its delta was therefore not merged into the main `syndicate-governor` spec: doing so
would have created a requirement that `declared-coverage-locks` would then have had to
REMOVE in the same release. The 15 completed tasks' code (`_settleCoverageBestEffort`,
`CoverageSettleFailed`, both call sites) is deleted by `declared-coverage-locks` §5.

The 3 remaining tasks were validation only (strict validate, full suite, bytecode size)
— validating code that is about to be removed.

Kept for the record: the design rationale (execute-time trigger, no gas floor, ledger
resolution matching the reclaim gates' pinned-first rule) is sound under the reservation
model and would be the right shape if that model ever returned.
