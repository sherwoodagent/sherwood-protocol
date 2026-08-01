# Tasks — Plan E: Two-Layer Court (completed; work merged — Court later superseded by the 2026-07-28 token court)

## 1. ChallengeGame — court-only ruling entrypoint

- [x] 1.1 Write failing tests: `rule` is court-only (`NotCourt`); guilty settles through the same path as an undisputed challenge (D7); not-guilty fails exactly as a timeout would; `rule` only from `Disputed` (`WrongStatus`); a ruling beats the timeout (`resolve` cannot re-resolve); with no court wired, Plan D's timeout-to-accused behaviour is unchanged (additive, not breaking)
- [x] 1.2 Add `court` (owner-set via `setCourt`), `rule(uint256,bool)` routing guilty → `_settle` / not-guilty → `_fail`, plus `NotCourt`, `CourtSet`, `ChallengeRuled` in `IChallengeGame`; verify `_fail`'s counter-bond handling makes no timeout-specific assumption
- [x] 1.3 Run green and commit

## 2. Court — panel roster and bonds

- [x] 2.1 Write failing tests: `setPanel` owner-only seats N members (D1); a seated panelist must post `panelBondWood` before ruling; an unbonded panelist cannot rule; `setPanel` cannot unseat a panelist with an open ruling (its bond must not escape the bad-faith track); `withdrawPanelBond` only after unseated AND no bad-faith window open; the §4 invariant view (`bondedWood`) tracks posted bonds exactly
- [x] 2.2 Create `ICourt` (errors, `Ruling {None, Guilty, NotGuilty}`, events, function set) and implement the roster half of `Court`
- [x] 2.3 Run green and commit

## 3. Layer 1 — the panel rules

- [x] 3.1 Implement `refer(challengeId)` — anyone, once a challenge is `Disputed`; opens a case and computes the snapshot ONCE as `executedAt - 1` (D2), stored so no two votes can disagree about the electorate
- [x] 3.2 Implement `panelRule(caseId, guilty)` (bonded panelists only) and `finalizePanel(caseId)` (after `panelWindow` or all seated members voted); no ruling within the window → `NotGuilty` by default (fail-safe, documented)
- [x] 3.3 Tests: non-panelist/unbonded/double-vote reverts; majority resolves; tie → `NotGuilty`; silence → `NotGuilty`; early finalize with votes outstanding reverts; no double referral; referring a non-`Disputed` challenge reverts
- [x] 3.4 Commit

## 4. Layer 2 — the token-vote appeal

- [x] 4.1 Implement `appeal(caseId)` (anyone, within `appealWindow`, posting `appealBondWood`), `voteAppeal(caseId, guilty)` (weight = `getPastVotes(msg.sender, snapshotTs)`; zero weight → `NoVotingPower`; one vote per address; no re-weighting — age math lives in `getPastVotes`, D3), `finalizeAppeal` (below floor → panel ruling STANDS with its own branch and event, appellant bond forfeits, D6; at/above floor → cast-vote majority overrides), and `finalizeUnappealed`; every branch ends by calling `ChallengeGame.rule` with the right bit
- [x] 4.2 Tests: late appeal reverts; a voter with no pre-exploit stake reverts `NoVotingPower` (the flash-loan / post-drain-buyer defense — asserted with an address that staked only AFTER `snapshotTs`); double-vote reverts; below-floor turnout leaves the panel ruling standing even when cast votes went the other way (the D6 test); above-floor overturns; unappealed finalizes; `rule` called correctly in every branch
- [x] 4.3 Commit

## 5. The bad-faith track (F6)

- [x] 5.1 Implement `openBadFaith(caseId, panelist)` (within `badFaithWindow`, posting `badFaithBondWood`), `voteBadFaith` (same electorate, same stored `snapshotTs`, same floor), `finalizeBadFaith` (floor met + majority bad faith → slash that panelist's bond to the protocol backstop — not the escrow's per-case claims, since a corrupt panelist's bond is not the drained value; otherwise return the posting)
- [x] 5.2 Tests proving D4 independence in BOTH directions: a merits overturn does NOT slash the panelist; an upheld merits appeal does NOT immunize against a bad-faith slash; below-floor bad-faith vote does not slash; no bond withdrawal while a bad-faith window is open; flat reward regardless of ruling direction (D5)
- [x] 5.3 Commit

## 6. End-to-end — a disputed challenge actually resolves

- [x] 6.1 Extend the real-stack end-to-end fixture with a real `Court` wired via `game.setCourt`
- [x] 6.2 Arc 1 — guilty, unappealed: file → dispute → refer → panel guilty → appeal lapses → `finalizeUnappealed` → guardian slashed into the compensation escrow, pre-drain LPs redeem; asserts Plan D's hole is closed (the guilty approver could NOT escape by disputing)
- [x] 6.3 Arc 2 — acquitted on appeal: quorate appeal overturns → challenge `Failed`, challenger's bond forfeits to the accused, panelist's bond untouched (D4)
- [x] 6.4 Arc 3 — below-floor appeal: turnout misses the floor → panel ruling stands, guardian slashed (D6, the anti-capture arc)
- [x] 6.5 Commit

## 7. Deploy wiring, goldens, full suite, PR

- [x] 7.1 Add `script/DeployPlanE.s.sol` with load-bearing pre-flights (a half-wired court is worse than none): `game.court() == address(0)`; panel seated AND every member bonded; `participationFloorBps != 0` (a zero floor silently removes D6); `badFaithWindow != 0` (a zero window leaves a bribable panel); Plan D wiring intact so the ruling path does not dead-end — verified by simulation, with the state deliberately broken to prove each pre-flight bites; never `--broadcast`
- [x] 7.2 Run `./script/check-layout-goldens.sh` (four pinned contracts untouched); note explicitly that `ChallengeGame`'s new `court` slot has no golden (not upgradeable) rather than implying it was checked
- [x] 7.3 Full `forge test` (no new failures beyond the 22-known baseline, exact counts reported) and `forge fmt --check`
- [x] 7.4 Update the spec status header (v1c complete — the court adjudicates disputed challenges, closing the Plan D hole; Plans F and G remain) and open the PR against `feat/guardian-econ-security-d`
