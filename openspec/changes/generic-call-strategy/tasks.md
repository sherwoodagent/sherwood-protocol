# Tasks

> Scope: a new template, its tests, its deploy phase and its docs. NO edits to `SyndicateVault`,
> `SyndicateGovernor`, `StrategyFactory`, `TierRegistry`, `BaseStrategy`, the layout goldens or
> `chains/*.json`. Nothing is deployed, approved or registered on chain.

## 1. Template

- [x] 1.1 `src/strategies/GenericCallStrategy.sol` extending `BaseStrategy`: init decode, caps, `configHash` (design D1)
- [x] 1.2 Target rules at init: value, denylist via fail-closed walk, code presence, asset selector rule, codehash pin (D2, D3, D4)
- [x] 1.3 Grant recording at init and best-effort revocation after each leg (D7)
- [x] 1.4 `_execute`: codehash re-check over both legs, pull (skip at zero), run leg with `CallFailed`, revoke (D5)
- [x] 1.5 `_settle`: run leg, revoke, push asset and sweep tokens; no codehash check, no minimum-return floor (D6)
- [x] 1.6 `_updateParams` reverts `NoTunableParams`; `rescueERC721To`; `onERC721Received`; no `receive`/`fallback`, no ERC-1155 hooks (D1, D9)
- [x] 1.7 Getters: `name`, `asset`, `pullAmount`, `executeCalls`, `settleCalls`, `settlePatches`, `sweepTokens`, `grants`, `pinnedCodehash`, `configHash` (D10)
- [x] 1.9 Settle-leg balance patches: init validation and live-balance write before each patched call (D13)
- [x] 1.10 Denylist adds the GuardianRegistry and sWOOD (fail-closed) and the withdrawal queue and ExposureLedger (when set); WOOD not denied (D2)
- [x] 1.11 Sweep tokens checked at init (`InvalidSweepToken`) and pushed best-effort at settle (`SweepFailed`); the asset push stays strict (D6)
- [x] 1.12 Patch token must be in the plan; address words of the approve and transfer selectors refused (D13)
- [x] 1.13 ChallengeGame denied when set (D2); revoke reads and writes under `HYGIENE_GAS` (D7)
- [x] 1.8 `script/check-template-destinations.sh` passes, now also matching `trySafeTransfer`/`trySafeTransferFrom`; runtime size within the Robinhood limit

## 2. Tests (`test/strategies/`, mocks only, no fork)

- [x] 2.1 Happy path through a real `SyndicateVault` + `SyndicateGovernor` + `GuardianRegistry`: propose, vote, review, execute, settle, P&L in the asset
- [x] 2.2 Every forbidden target in both legs; codeless target; non-zero value; each forbidden asset selector; short asset calldata; unresolved protocol hop
- [x] 2.3 Re-initialization of a clone and of the template; non-vault callers of `execute`/`settle`/`rescueTo`/`rescueERC721To`; `updateParams` by the proposer and by a stranger
- [x] 2.4 Caps: calls per leg, calldata bytes per leg, sweep tokens
- [x] 2.5 Failed inner call reverts `CallFailed` with the callee's data; `TargetCodeChanged` at execute; no check at settle
- [x] 2.6 Approvals and operator approvals revoked after each leg; ERC-721 `approve` collision skipped
- [x] 2.7 Sweep tokens and asset returned at settle; NFT rescued by an emergency batch
- [x] 2.10 Patches: market-price buy sold whole; unpatched call keeps its init amount; every `InvalidPatch` branch
- [x] 2.8 A reentering venue mock (into the clone, the vault and the governor) and a fuzz test bounding the vault's loss by `pullAmount`
- [x] 2.11 Sweep failure and unreadable sweep do not block the asset; gas-burning revoke; patch address words and token membership; ChallengeGame; venue-held position lost through `settleProposal`, `unstick` and the emergency batch; per-attempt reentry reasons
- [x] 2.9 Each new test names the mutation that breaks it in the PR body

## 3. Deploy (source only, not run)

- [x] 3.1 `DeploySalts.GENERIC_CALL_TEMPLATE`, `Stack.genericCallTemplate`, `DeployGenericCallStrategy` mixin with a public `deployGenericCallTemplate()` and the standalone `DeployGenericCallTemplate` live-chain entry
- [x] 3.2 Wire the phase into `DeployAll` (predict, stage, checks, persist) and add `GENERIC_CALL_TEMPLATE` to `DeployStrategyFactory._templateKeys()`
- [x] 3.3 Update the deploy tests that pin the template set and the ceremony's addresses, and pin the template's class tier at `(2, 10_000)`
- [x] 3.4 `verify-robinhood.sh` checks `GENERIC_CALL_TEMPLATE` once the book carries it; `verify-blockscout.py` reads `DeployGenericCallStrategy.s.sol` broadcasts

## 4. Docs

- [x] 4.1 `docs/generic-call-strategy.md`: what it does, what an agent supplies, how a guardian reads it, tier-2 posture, risks
- [x] 4.2 README template table and `docs/audit-scope-and-accepted-risks.md` out-of-scope list and open-changes paragraph
- [x] 4.3 Runbook: the 4663 live steps (mint, `setTemplateApproval` by the `StrategyFactory` owner, book key, Blockscout)

## 5. Follow-ups (record in the PR body; not this change)

- [ ] 5.1 `sherwood`: CLI/SDK encoder for the template, a guardian `TEMPLATE_ABIS` entry so the walk reads `executeCalls()`/`settleCalls()`, skill docs
- [ ] 5.2 `sherwood-arena`: catalog entry for the template
- [ ] 5.3 Owner GO: deploy the template on 4663, `setTemplateApproval(template, true)` from the `StrategyFactory` owner (the deployer today), `GENERIC_CALL_TEMPLATE` in `chains/4663.json`, `verify-blockscout.py 4663`
