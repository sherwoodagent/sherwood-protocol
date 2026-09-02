# Sherwood Protocol — working rules

Orientation lives elsewhere; read it, do not duplicate it here:
- `CONTEXT.md` — domain language (use these terms, avoid the listed synonyms).
- `docs/` — architecture and lifecycle docs. `openspec/specs/` — normative requirements.
- `PROPERTIES.md` — invariants the fizz/echidna harness enforces.

## Branching

- CI only runs on PRs targeting `main`; verify stacked PRs locally.

## Before pushing

```
forge fmt
forge test --no-match-path 'test/fork/**'
script/check-layout-goldens.sh
openspec validate --specs
```

## Coding style

- Simplicity first: minimal change, minimal code, smallest blast radius. Find root causes; no temporary fixes.
- **Comments are short.** A comment block in `src/` is at most 3 lines: the non-obvious rule, and one line of why if the code does not make it obvious. No essays, no adversary narratives, no list of alternatives considered, no quoting other files. That reasoning goes in the PR body or the OpenSpec `design.md`. A test gets one `@notice` sentence.
- Adding a new external call to `src/` breaks every test mock lacking the selector — `grep -rn "function <name>" test/` and patch them in the same commit.
- Time in tests: use `vm.getBlockTimestamp()`, never a cached `block.timestamp` across `vm.warp`. Hoist any call out of argument position when a `vm.prank` / `vm.expectRevert` is armed.
- Every new test must fail under a mutation of the code it pins. Say which mutation in the PR body.
