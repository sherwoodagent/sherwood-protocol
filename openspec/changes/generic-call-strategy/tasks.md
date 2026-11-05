# Tasks

> Scope: a new template, its tests, its deploy phase and its docs. NO edits to `SyndicateVault`,
> `SyndicateGovernor`, `StrategyFactory`, `TierRegistry`, `BaseStrategy`, the layout goldens or
> `chains/*.json`. Nothing is deployed, approved or registered on chain.

## 1. Template

- [ ] 1.1 `src/strategies/GenericCallStrategy.sol` extending `BaseStrategy`: init decode, caps, `configHash` (design D1)
- [ ] 1.2 Target rules at init: value, denylist via fail-closed walk, code presence, asset selector rule, codehash pin (D2, D3, D4)
- [ ] 1.3 Grant recording at init and best-effort revocation after each leg (D7)
- [ ] 1.4 `_execute`: codehash re-check over both legs, pull (skip at zero), run leg with `CallFailed`, revoke (D5)
- [ ] 1.5 `_settle`: run leg, revoke, push asset and sweep tokens; no codehash check, no minimum-return floor (D6)
- [ ] 1.6 `_updateParams` reverts `NoTunableParams`; `rescueERC721To`; `onERC721Received`; no `receive`/`fallback`, no ERC-1155 hooks (D1, D9)
- [ ] 1.7 Getters: `name`, `asset`, `pullAmount`, `executeCalls`, `settleCalls`, `sweepTokens`, `grants`, `pinnedCodehash`, `configHash` (D10)
- [ ] 1.8 `script/check-template-destinations.sh` passes; runtime size within the Robinhood limit

## 2. Tests (`test/strategies/`, mocks only, no fork)

- [ ] 2.1 Happy path through a real `SyndicateVault` + `SyndicateGovernor` + `GuardianRegistry`: propose, vote, review, execute, settle, P&L in the asset
- [ ] 2.2 Every forbidden target in both legs; codeless target; non-zero value; each forbidden asset selector; short asset calldata; unresolved protocol hop
- [ ] 2.3 Re-initialization of a clone and of the template; non-vault callers of `execute`/`settle`/`rescueTo`/`rescueERC721To`; `updateParams` by the proposer and by a stranger
- [ ] 2.4 Caps: calls per leg, calldata bytes per leg, sweep tokens
- [ ] 2.5 Failed inner call reverts `CallFailed` with the callee's data; `TargetCodeChanged` at execute; no check at settle
- [ ] 2.6 Approvals and operator approvals revoked after each leg; ERC-721 `approve` collision skipped
- [ ] 2.7 Sweep tokens and asset returned at settle; NFT rescued by an emergency batch
- [ ] 2.8 A reentering venue mock (into the clone, the vault and the governor) and a fuzz test bounding the vault's loss by `pullAmount`
- [ ] 2.9 Each new test names the mutation that breaks it in the PR body

## 3. Deploy (source only, not run)

- [ ] 3.1 `DeploySalts.GENERIC_CALL_TEMPLATE`, `Stack.genericCallTemplate`, `DeployGenericCallStrategy` mixin with a public `deploy()`
- [ ] 3.2 Wire the phase into `DeployAll` (predict, stage, checks, persist) and add `GENERIC_CALL_TEMPLATE` to `DeployStrategyFactory._templateKeys()`
- [ ] 3.3 Update the deploy tests that pin the template set and the ceremony's addresses

## 4. Docs

- [ ] 4.1 `docs/generic-call-strategy.md`: what it does, what an agent supplies, how a guardian reads it, tier-2 posture, risks
- [ ] 4.2 README template table and `docs/audit-scope-and-accepted-risks.md` out-of-scope list

## 5. Follow-ups (record in the PR body; not this change)

- [ ] 5.1 `sherwood`: CLI/SDK encoder for the template, a guardian `TEMPLATE_ABIS` entry so the walk reads `executeCalls()`/`settleCalls()`, skill docs
- [ ] 5.2 `sherwood-arena`: catalog entry for the template
- [ ] 5.3 Owner GO: deploy the template on 4663, Safe `setTemplateApproval(template, true)`, `GENERIC_CALL_TEMPLATE` in `chains/4663.json`
- [ ] 5.4 Live-balance calldata substitution, if Arena agents need exits sized at settle time
