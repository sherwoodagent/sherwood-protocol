# Document ExposureLedger fixture hazards + shared multi-approver helper

## Why

Closes issue #71. Two correct early exits — `requireApproveQuorum`'s
quorum-reached break and `recordApproval`'s no-free-budget return — silently
shrink the approver set a fixture believes it is testing. Four tests have
already shipped passing-for-the-wrong-reason (repaired in #61), two adjacent
to exactly this shape. Not a contract change: the early exits are correct
gas behaviour and stay.

## What changes

Test tree only (`test/ExposureLedger.t.sol`, possibly a shared helper):

1. A prominent comment block in `ExposureLedger.t.sol` naming both early
   exits as fixture hazards, with the sizing rule: give each approver a
   budget strictly smaller than the requirement so every approver books a
   real non-zero share and is genuinely read.
2. A shared fixture helper that constructs a multi-approver set applying the
   sizing rule by construction (model: the existing
   `_wireUnderCoveredEpochZeroApprovers`), plus an assertion helper that the
   constructed set's `approversOf` length equals the intended count.
3. Migrate the suite's existing multi-approver fixtures to the helper where
   they qualify; any fixture that deliberately wants the early exit gets an
   explicit `// EARLY-EXIT INTENDED:` comment instead.

## Impact

- `test/` only; zero `src/` changes. No overlap with protected #68 (fee
  tests) — do not touch `test/fees/**`, `test/invariants/**`, or the other
  in-flight branches' files (`test/ExposureLedger.t.sol` is not touched by
  any open PR or in-flight worktree).
- Suite must remain green; the migration must not reduce assertion strength.
