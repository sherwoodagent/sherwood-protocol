# Sherwood Protocol — working rules

Orientation lives elsewhere; read it, do not duplicate it here:
- `CONTEXT.md` — domain language (use these terms, avoid the listed synonyms).
- `docs/` — architecture and lifecycle docs. `openspec/specs/` — normative requirements.
- `PROPERTIES.md` — invariants the fizz/echidna harness enforces.

## Branching

- Two bases during launch: `audit-fixes-integration` is audit remediation only and must not inherit `post-audit` code; it lands on `main` first, then `post-audit` merges `main` and takes the conflict resolution. See the Linear "Launch merge plan" doc.
- Merge commits, not squash — every merge on `main` is a merge commit.
- CI runs on any PR whose merge ref can be built, including stacked PRs off a non-`main` base. A **conflicting** PR shows *no* checks, which looks like green and is not.

## Before pushing

```
forge fmt
forge test --no-match-path "test/integration/**"   # CI's exact invocation
script/check-layout-goldens.sh
openspec validate --specs
```

- A goldens diff has to be read, not regenerated: the gate compares labels, so a pure rename shows as drift and a regenerated golden looks identical to a real slot move.

## Coding style

- Simplicity first: minimal change, minimal code, smallest blast radius. Find root causes; no temporary fixes.
- **Comments are short.** A comment block in `src/` is at most 3 lines: the non-obvious rule, and one line of why if the code does not make it obvious. No essays, no adversary narratives, no list of alternatives considered, no quoting other files. That reasoning goes in the PR body or the OpenSpec `design.md`. Carve-out: a comment guarding an invariant or a fail-closed choice cites the design doc or ticket in one line, so the next reader finds the argument instead of re-deriving or reverting it. A test gets one `@notice` sentence.
- Adding a new external call to `src/` breaks every test mock lacking the selector — `grep -rn "function <name>" test/` and patch them in the same commit.
- Time in tests: use `vm.getBlockTimestamp()`, never a cached `block.timestamp` across `vm.warp`. Hoist any call out of argument position when a `vm.prank` / `vm.expectRevert` is armed.
- Every new test must fail under a mutation of the code it pins. Say which mutation in the PR body.
