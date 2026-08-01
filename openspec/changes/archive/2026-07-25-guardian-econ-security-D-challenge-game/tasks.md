# Tasks — Plan D: Challenge Game (completed; work merged as PR #25)

## 1. ExposureLedger — approver getter + per-proposal coverage freeze

- [x] 1.1 Write failing tests: `approversOf` lists committed approvers with shares and reports released commitments as zero; freeze is freezer-only; freeze blocks `releaseApproval` (`CoverageFrozen`); unfreeze restores release; freeze does not touch the guardian's other open approvals (§3.4 freeze scope)
- [x] 1.2 Add `coverageFreezer` (owner-set), `_frozen` mapping, `onlyFreezer` modifier, `approversOf`/`freezeCoverage`/`unfreezeCoverage`/`isCoverageFrozen` and the `CoverageFrozen` guard in `releaseApproval`; extend `IExposureLedger` (errors, events, functions)
- [x] 1.3 Run ledger + coverage suites green (pre-existing suites never freeze, so unaffected) and commit

## 2. TierRegistry — authorized demoter

- [x] 2.1 Write failing tests: `setAuthorizedDemoter` owner-only; `demoteByChallenge` demoter-only; a passed challenge demotes back to the tier-2 default (bound 10_000); the demoter cannot certify (revoke-only role, not ownership)
- [x] 2.2 Add `authorizedDemoter`, `NotAuthorizedDemoter`, `AuthorizedDemoterSet`, `setAuthorizedDemoter`, and `demoteByChallenge` reusing the owner `_demote` path (§3.6 slash-first timelock starts identically)
- [x] 2.3 Run tier suites green and commit

## 3. ChallengeGame — filing, bonding, freeze

- [x] 3.1 Write failing tests on a mock fixture (governor, ledger, tier registry mocks + real ERC20 WOOD): `file` pulls the bond and freezes coverage into `Filed`; bond scales with frozen exposure (coverage × `challengerBondBps`, WOOD at the haircut price); reverts `NotExecuted`, `WindowClosed` (past `executedAt + challengeWindow`), `AlreadyChallenged`, `NothingToFreeze`
- [x] 3.2 Create `IChallengeGame` (`Predicate` enum — event-only classification per D1; `Status {None, Filed, Disputed, Failed, Settled}`; errors; events incl. `evidenceURI` in `ChallengeFiled`) and implement the filing half of `ChallengeGame`
- [x] 3.3 Run green and commit

## 4. Dispute, timeout, resolve, slash, demote

- [x] 4.1 Implement `dispute(challengeId)` — only an accused approver (ledger list), only from `Filed`, only before `filedAt + autoSlashDelay`; pulls a counter-bond equal to the challenger's, moves to `Disputed`, stops the auto-slash clock
- [x] 4.2 Implement permissionless `resolve(challengeId)`: `Filed` past `autoSlashDelay` → slash via `slashToEscrow(..., executedAt - 1)`, demote via `demoteByChallenge`, return the challenger's bond, unfreeze, `Settled`; `Disputed` past `disputeTimeout` → fail (D5): challenger's bond forfeits to the accused pro-rata, counter-bond returns, unfreeze, `Failed`; neither deadline → `DelayNotElapsed`
- [x] 4.3 Add owner setters (`challengeWindow`, `autoSlashDelay` with a sane floor, `disputeTimeout`, `challengerBondBps`, wired addresses) — deliberately no `detectorBountyWood` and no escrow pointer
- [x] 4.4 Tests: undisputed slash lands in the escrow pinned to `executedAt - 1` with the adapter demoted; early resolve/dispute-window/non-approver reverts; disputed timeout forfeits to the accused and returns the counter-bond; coverage unfrozen on both terminal paths with `releaseApproval` working again; §4 fuzz invariant (game WOOD balance == bonds held for live challenges, across fuzzed sizes and resolution orders)
- [x] 4.5 Commit

## 5. End-to-end — real drain, real slash, real compensation

- [x] 5.1 Build `test/ChallengeEndToEnd.t.sol` on the real stack (sWOOD, registry, vault, governor, escrow + real ledger, tier registry, game), fully role-wired; no `prove()` step exists in either arc (D1)
- [x] 5.2 Happy arc — silence is the verdict: propose → approve (coverage committed) → execute → file predicate-1 (bond pulled, coverage frozen and genuinely unreleasable) → silence → resolve → guardian slashed into a case pinned to the pre-drain block, adapter demoted, challenger bond returned → pre-drain LPs redeem, post-drain buyer gets nothing
- [x] 5.3 Bad-faith arc — disputed challenge times out to the accused (D5): clean proposal challenged, accused counter-bonds, no court rules, timeout forfeits the challenger's bond pro-rata, returns the counter-bond, unfreezes; assert the negative space (nothing slashed, no case, certification kept — a failed challenge leaves no mark)
- [x] 5.4 Commit

## 6. Deploy wiring, goldens, full suite, PR

- [x] 6.1 Add `script/DeployPlanD.s.sol` (env-var address book, pre-flight asserts each role unset before wiring, manual follow-ups printed, no `--broadcast`): deploy the game, wire `setCoverageFreezer`/`setAuthorizedDemoter`/`setAuthorizedSlasher`, confirm `escrow.authorizedFunder == swood`
- [x] 6.2 Run `./script/check-layout-goldens.sh`; confirm the four pinned contracts untouched and no pre-existing slot moved
- [x] 6.3 Full `forge test` (no new failures beyond the 22-known baseline) and `forge fmt --check`
- [x] 6.4 Update the spec status header (v1b part 2 complete; `authorizedSlasher` is now the ChallengeGame — undisputed verdicts mechanism-driven; disputed ones time out to the accused until Plan E) and §4's phasing (court moved ahead of epoch machinery and premium)
- [x] 6.5 Open the PR against `feat/guardian-econ-security-c`, naming the carried-forward gaps
