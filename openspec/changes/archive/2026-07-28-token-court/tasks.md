# Tasks — Token Court

## 0. Branch setup

- [x] 0.1 Merge PR #50 (pull-payment counter-bond) into `feat/guardian-econ-security-e` — dependency of `_refundAll`
- [x] 0.2 Create `feat/token-court` branch + worktree off `e`; verify build and test baseline

## 1. Delete the panel court

- [x] 1.1 `git rm` `src/Court.sol`, `src/interfaces/ICourt.sol`, `test/Court.t.sol`, `test/CourtEndToEnd.t.sol`, `test/deploy/DeployPlanEPreflight.t.sol`, `script/DeployPlanE.s.sol`
- [x] 1.2 Sweep dangling `ICourt`/`Court` references (only `ChallengeGame`'s `court` address var / `setCourt` / `NotCourt` remain; E2E court stub replaced with a pranked EOA `rule` call)
- [x] 1.3 Build + test green (pass count drops by exactly the deleted suites), commit

## 2. Three-valued verdict in the game

- [x] 2.1 Write failing tests: Inconclusive refunds both sides whole (challenger bond back with no burn slice, pool booked as pull-claims, `bondedWood` released, freeze released), contributors claim exactly their stake, Guilty→Settled / NotGuilty→Failed mapping, Inconclusive allows refiling the same proposal
- [x] 2.2 Interface: append `Status.Inconclusive`, add `Verdict {Guilty, NotGuilty, Inconclusive}`, `rule(uint256, Verdict)`, `ChallengeRuled(id, verdict)` + `ChallengeInconclusive` events
- [x] 2.3 Game: three-way `rule` dispatch; new `_refundAll` (unwind not verdict; pull machinery because open standing makes the contributor list unbounded; no `_convicted`, no demotion); widen `claimableContribution`/`claimContribution` terminal gates
- [x] 2.4 Migrate all `rule(bool)` call sites to `Verdict` via sed sweep + visual spot-check
- [x] 2.5 Run new tests + full suite at baseline, commit

## 3. Filings pause

- [x] 3.1 Write failing tests: pause gates `file` only (in-flight rule/claims still run), owner-only
- [x] 3.2 Implement `filingsPaused` + `setFilingsPaused` (guard as `file`'s first check) — the only human backstop in the adjudication stack
- [x] 3.3 Run + commit

## 4. ITokenCourt + contract skeleton

- [x] 4.1 Write `src/interfaces/ITokenCourt.sol` complete: `Phase`/`Ruling`/`Case`, errors, events, views, `refer`/`vote`/`finalize`, bounded setters
- [x] 4.2 Write failing tests with local mocks (game with `rule` recorder + revert toggle, governor `getProposal` shape recovered from the deleted Court.t.sol, ledger, MockStakedWood): constructor defaults, setter bounds, owner gating
- [x] 4.3 Implement the skeleton (`Ownable2Step`, zero custody, local event/error copies until Task 7 wires the interface): wiring setters, `voteWindow = 5 days`, `participationFloorBps = 1_000`, `FINALIZE_BUFFER = 1 days`, `MAX_VOTE_WINDOW = 14 days`
- [x] 4.4 Run + commit

## 5. refer — clock check + accused recording

- [x] 5.1 Write failing tests: snapshot `executedAt - 1` + window pinned + raw `getPastStake` accused weight + released approver excluded; guards (unwired court, not disputed, unexecuted proposal fails closed, double referral); exact clock-check boundary (`remaining == voteWindow + FINALIZE_BUFFER` passes, one second less refuses)
- [x] 5.2 Implement `refer` + `_recordAccused` (state claimed before external reads — hostile-governor ordering; ledger read from the game; dedup guard) with the clock check making the E1 race structural
- [x] 5.3 Run + commit

## 6. vote

- [x] 6.1 Write failing tests: aged-weight tallies, guards (double vote, accused barred, zero weight, window closed)
- [x] 6.2 Implement `vote` (one vote per address, `getPastVotes` at the pinned snapshot, no re-weighting)
- [x] 6.3 Run + commit

## 7. finalize — floor, verdict, terminal-race catch; wire the interface

- [x] 7.1 Write failing tests: guilty majority above floor, tie acquits, below-floor and zero-turnout → Inconclusive, accused weight lowers the floor base, terminal race closes the case via catch (`ChallengeAlreadyTerminal`), window-open and double-finalize guards
- [x] 7.2 Implement `finalize` (verdict + `Resolved` written before the external `rule` call; try/catch) and `_participationFloor` (same-basis subtraction, `>` fallback as defence-in-depth); add `ITokenCourt` to the inheritance line and delete the local event/error copies
- [x] 7.3 Run TokenCourt suite + full suite, commit

## 8. Auto-referral from dispute

- [x] 8.1 Write failing tests: auto-refers on pool completion, reverting court does not brick `dispute` (`AutoReferFailed`), `court == address(0)` skips
- [x] 8.2 Implement best-effort `try court.refer` as the last statements of `dispute`'s completing branch (CEI preserved; same doctrine as `AdapterDemotionFailed`)
- [x] 8.3 Run + full suite + commit

## 9. End-to-end arcs

- [x] 9.1 `test/TokenCourtEndToEnd.t.sol` on the real stack: guilty verdict slashes and pays the challenger; not-guilty forfeits to defenders via pull-claims; inconclusive unwinds and allows refiling; both orderings of the timeout race — each arc asserting court WOOD custody is zero
- [x] 9.2 Run until green, commit

## 10. Deploy script + preflight

- [x] 10.1 `DeployTokenCourt` (deploy + wire + `transferOwnership`) and `WireTokenCourt` with pre-flights: court wiring, sWOOD identity on both contracts, `voteWindow + FINALIZE_BUFFER <= disputeTimeout - autoSlashDelay`, `participationFloorBps < ageFloorBps` (launch math logged), Plan D wiring intact
- [x] 10.2 Preflight tests proving each check bites, plus a boundary-accept test for the window-fit check
- [x] 10.3 Run + commit

## 11. Gates, PR, close #26

- [x] 11.1 Full suite (only fork tests failing), CI-matching `forge fmt --check`, layout goldens no-op
- [x] 11.2 Reference sweep: zero hits for `ICourt`/`panelBond`/`badFaith`/`panelRule`/`finalizeAppeal`/`finalizeUnappealed` in src/script/test
- [x] 11.3 Push and open PR against `integration/lifecycle-planb`
- [x] 11.4 Close PR #26 unmerged with a pointer to the design (branch `e` kept — base ancestry)
