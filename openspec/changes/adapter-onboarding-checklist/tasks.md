# Tasks

- [x] 1. Recon: read `src/TierRegistry.sol` (certify, setAdapterAllowed,
  isAdapterAllowed, tierOf, demote paths) and the vault selector guard
  (`src/SyndicateVault.sol` ~:505-540) so every function name, owner, and
  failure direction in the doc is verified against current main. Check
  whether PR #74 merged (gh pr view 74) to decide the runbook cross-ref.
- [x] 2. Write `docs/adapter-onboarding-checklist.md` per the spec delta.
- [x] 3. Verify docs-only diff; `git diff --name-only origin/main...HEAD`
  shows no compiler inputs.
- [x] 4. Commit on `docs/adapter-onboarding-checklist`, push, open PR
  `docs: adapter onboarding checklist — the dual-gate is explicit (#17)` —
  body "Closes #17". Do NOT merge.
