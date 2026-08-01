# Tasks

- [ ] 1. Recon: read `script/DeployPlanB.s.sol` AS IT IS ON THIS BRANCH
  (#61's rewrite), `test/deploy/DeployPlanBPreflight.t.sol`, the
  capped-duration spec doc, and locate the real `maxStrategyDuration` setter
  + `delegationEnabled` getter (grep src/).
- [ ] 2. Implement the seat + both asserts per the spec delta, matching the
  script's existing pre-flight style; keep away from PR #64's escrow
  constructor region.
- [ ] 3. Extend the preflight test suite (4 cases per spec). Repo gotchas:
  vm.getBlockTimestamp over cached block.timestamp across warps; hoist
  argument-position calls before vm.prank; forward-only warps.
- [ ] 4. Gate (solc-serialized: `while pgrep -x solc >/dev/null; do sleep 30; done`
  first): forge build; forge test --no-match-path
  "{test/integration/**,test/WstETHMoonwellStrategy.t.sol}"; forge fmt
  --check src test script.
- [ ] 5. Commit on `chore/deployplanb-seat-invariants`, push, open PR with
  BASE `fix/pr56-review-findings`:
  `chore(deploy): seat maxStrategyDuration + assert delegation off (#32)` —
  body "Closes #32", stacked-on-#61 note + retarget instruction, chosen
  default + its source, test evidence. Do NOT merge.
