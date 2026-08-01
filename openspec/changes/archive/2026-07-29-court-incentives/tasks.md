# Tasks — Court Incentives

Baseline at HEAD `57559b1`: full suite 1747 passed / 21 pre-existing fork failures. Process rules: forge always foreground; layout goldens after any `StakedWood` change; a test that does not fail under its mutation does not count.

## 1. slashToEscrow pays a conviction bounty

- [x] 1.1 Write failing tests: bounty paid and escrow case opened NET of it, zero bps pays nothing, zero recipient pays nothing (full proceeds to escrow)
- [x] 1.2 Extend `IStakedWood.slashToEscrow` with `bountyTo`/`bountyBps` calldata params (no new storage — plain UUPS upgrade, not a migration) + `ConvictionBountyPaid` event
- [x] 1.3 Implement in `StakedWood`: bounty comes off the top before `forceApprove`/`openCase`; burn-fallback burns the already-netted total (ordering load-bearing, commented)
- [x] 1.4 Update `MockStakedWood` to the new signature (record bounty, net the total)
- [x] 1.5 Run tests + `./script/check-layout-goldens.sh` (must stay OK), commit

## 2. ChallengeGame pins and passes the bounty rate

- [x] 2.1 Write failing tests: no bounty on the silence path (the design's central decision), bounty paid on the escalated `Guilty` ruling, no bounty on `_fail`/`_refundAll`, pinned at filing (raising the live rate mid-challenge does not move the payout), setter bounds `[0, 2_000]` + owner-only + zero legal
- [x] 2.2 Interface: `convictionBountyBps` getter/setter/event; append `convictionBountyBpsAtFiling` to the `Challenge` struct
- [x] 2.3 Implement: `MAX_CONVICTION_BOUNTY_BPS = 2_000`, default 500; pin in `file`; forward in `_settle` gated on `escalated` (`escalated ? c.convictionBountyBpsAtFiling : 0`)
- [x] 2.4 Add the double-pay guard test: a concurrent second challenge hitting the `_convicted` short-circuit never collects a second bounty
- [x] 2.5 Run + fmt + commit

## 3. Present-holdings gate on voting (defect B4)

- [x] 3.1 Write failing tests: fully exited holder refused, current holder with historic weight accepted at SNAPSHOT weight, present holder with no snapshot weight still refused; add `getVotes`/`setVotes` to `MockStakedWood` with defaults that keep the existing suite green
- [x] 3.2 Implement the one-line gate in `TokenCourt.vote`: `getVotes(msg.sender) == 0` reverts `NoVotingPower` — a gate, never a weight (re-weighting would reintroduce the post-hoc accumulation the snapshot closes)
- [x] 3.3 Mutation-verify (delete the line, watch the exited-holder test fail, restore byte-identical), run, commit

## 4. Re-challenge window extension (finding M3)

- [x] 4.1 Write failing tests: Inconclusive extends the window past `executedAt + challengeWindow` so a re-file succeeds; the deadline only ever lengthens across rounds
- [x] 4.2 Implement `challengeableUntil[reviewKey]`: `file` reads it (fallback `executedAt + challengeWindow`); `_refundAll` extends to `block.timestamp + challengeWindow`, never shortening
- [x] 4.3 Run + commit

## 5. Namespace the case registry by game (defect B1)

- [x] 5.1 Write failing test: after a game migration (`setChallengeGame` to a redeploy whose ids restart at 1), `refer` on a colliding challenge id must not revert `AlreadyReferred`; old mapping intact
- [x] 5.2 Change `caseOfChallenge` to `mapping(address game => mapping(uint256 challengeId => uint256 caseId))`; update `refer`'s guard, the interface, and every call site
- [x] 5.3 Run TokenCourt + E2E suites, commit

## 6. Bubble NotCourt instead of swallowing it (defect B2)

- [x] 6.1 Write failing test: `finalize` under `NotCourt` reverts whole and leaves the case `Voting`; re-wiring the court then lands the verdict for real; delete the old `test_finalize_notCourt_swallowed` that pinned the defect
- [x] 6.2 Implement the selector filter: swallow only `WrongStatus` (genuinely terminal); everything else — `NotCourt` included — re-reverts via memory-safe assembly
- [x] 6.3 Run + commit

## 7. Cross-contract setter guards (defect B3)

- [x] 7.1 Write failing tests: `setDisputeTimeout` and `setAutoSlashDelay` refuse values the court cannot fit in; vacuous with no court wired; `TokenCourt.setVoteWindow` mirror refuses values the game cannot fit
- [x] 7.2 Implement `_requireWindowFits` (`autoSlash + voteWindow + FINALIZE_BUFFER <= disputeTimeout`, `WindowInvariantViolated` in both interfaces) as the last check in all three setters; fix pre-existing setter tests to conforming values without weakening the guard
- [x] 7.3 Run both suites, commit

## 8. REMOVED (decision 2026-07-29) — silence-path bounty bound

No work. This task originally added a pre-flight bounding `convictionBountyBps` below `settleBurnBps * challengerBondBps / 10_000`. Writing the bound revealed the two constraints on a silence-path bounty are contradictory at every rate (making honest unopposed filing profitable needs the bounty above ~100 bps at defaults; keeping false filing unprofitable needs it below — the contract cannot tell the filers apart). The fix was a narrower branch, not a smaller number: pay only on the escalated `Guilty` ruling (design §2), which deleted both the bound and this task. Numbering preserved so the mutation table and external references stay valid.

## 9. Spec and natspec honesty pass

- [x] 9.1 Correct §1 of the 2026-07-28 token-court design: capture-economics claim replaced with the corrected framing from design §6 (optimistic layer is the mechanism; court is a backstop against unsophisticated adversaries), with a pointer to this change's design
- [x] 9.2 Correct `AccusedCannotVote` natspec (A1): the bar covers the approving address, not the party; address splitting defeats it and shrinks the siblings' quorum
- [x] 9.3 Record A2 (last-mover advantage, with §6's trigger) on `finalize` and A5 (mid-case top-up re-anchors `stakedAt` and floors historic weight) on `vote`
- [x] 9.4 fmt + commit

## 10. Gates, mutation battery, PR update

- [x] 10.1 Full gates: suite at 1747 + new tests (same 21 fork failures), CI-matching `forge fmt --check`, layout goldens OK
- [x] 10.2 Mutation battery — each mutation applied, named test observed failing, tree restored byte-identical: bounty not deducted; unconditional bounty rate (silence path); live rate instead of pin; present-holdings check deleted; `challengeableUntil` write removed; single-key `caseOfChallenge`; `NotCourt` re-swallowed; `_requireWindowFits` emptied
- [x] 10.3 Push and update PR #52: B1–B4 fixed; M1 accepted risk documented in design §6 with its trigger
