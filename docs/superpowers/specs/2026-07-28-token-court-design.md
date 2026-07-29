# Token Court — single-layer WOOD-vote adjudication (v1c revision)

**Date:** 2026-07-28
**Status:** Approved design, replaces the two-layer Court of PR #26
**Supersedes:** the §3.5 court of `2026-07-22-guardian-economic-security-design.md` (panel + appeal + bad-faith track) and `2026-07-25-guardian-econ-security-E-court.md`
**Depends on:** Plan D challenge game (merged, `552dbef`), PR #50 pull-payment counter-bond (must merge into `e` before this builds)

## 1. Decision and rationale

The two-layer court (5-person bonded panel, token-vote appeal, bad-faith track) is
replaced by a **single WOOD-token vote** per disputed challenge.

Why:

- **The token layer was already sovereign.** In the two-layer design the appeal
  and the bad-faith track — the checks on the panel — were both token votes. The
  panel was a fast path, not an authority. Deleting it removes ~40% of Court.sol
  (roster, panel bonds, bad-faith machinery, rewards) and the panel-election
  operational burden, without changing who ultimately decides.
- **Scale and decentralization.** A fixed panel of 5 humans is a liveness single
  point of failure (an inactive panel acquits by default), an election ops burden
  on the governance multisig (D1), and a centralization optic that undercuts the
  protocol's story. The optimistic layer (silence = verdict, bonds price
  filings/disputes) is what actually scales; adjudication only sees the residue.
- **Industry alignment (researched 2026-07-28).** UMA (token vote), Nexus Mutual
  (staked assessors), and Symbiotic (pluggable resolver, token-vote default) all
  run token-side adjudication; EigenLayer's expert committee is the outlier and
  is shrinking in scope; Aragon Court (bespoke drafted-juror court) is dead from
  low case volume. Kleros-style sortition scales but is a heavier machine and
  does not exist on Robinhood Chain.
- **Capture economics are better than UMA's, not worse.** The §3.5 fear ("token
  vote capturable at ~$15M mcap") is blunted by three properties UMA lacks:
  the electorate snapshots at `executedAt - 1` (**before the crime** — capture
  must be pre-positioned before the prize is known), voters hold no position in
  the outcome (a conviction pays the compensation escrow, never voters), and
  aged voting weight makes rented stake weak. The residual vector — the accused
  bribing a pre-positioned whale for acquittal — is bounded by the accused's own
  slashable stake.

Decisions locked during brainstorm (2026-07-28):

| Question | Decision |
|---|---|
| Human backstop | **Pause only, on `ChallengeGame.file`** — stops new cases entering; no human ever touches a live case or a verdict |
| Vote privacy | **Open voting** (single tx per voter; commit-reveal explicitly deferred — revisit only on observed tally-watching) |
| Floor miss | **Inconclusive: refund both sides** (acquit, no forfeit, no conviction mark; proposal re-challengeable) |
| Voter incentives | **Bare vote on-chain.** Electorate = permissionless `stakeAsGuardian` sWOOD stakers with aged weight; incentives, if any, are off-chain |
| Migration | **Rebuild on `e` before merge** — PR #26 closes unmerged; token court cut from its reviewed parts |

## 2. Architecture

```
ChallengeGame (all custody, unchanged invariants)   TokenCourt (ZERO custody)
─────────────────────────────────────────────────   ─────────────────────────
file  → [silence] → _settle                         refer(challengeId)
      → dispute pool completes ──try/catch────────→   snapshot = executedAt - 1
        (auto-refer; manual refer is the fallback)    record accused set + raw weight
                                                      ── one vote window ──
rule(id, Verdict) ←───────────────────────────────  finalize(caseId)
  Guilty       → _settle   (slash, demote,            tally vs participation floor
                            challenger paid)          → Guilty | NotGuilty | Inconclusive
  NotGuilty    → _fail     (forfeit split to
                            defence contributors)
  Inconclusive → _refundAll  (NEW: unwind, no verdict)
```

Two contracts change; nothing else does.

- **`TokenCourt`** (new, ~450 lines, plain `Ownable2Step`, non-upgradeable —
  house shape). Holds **no WOOD, ever**: no bonds, no custody bookkeeping, no
  `SafeERC20`. Replaces `Court.sol`.
- **`ChallengeGame`** (+~150 lines): three-valued `rule`, `_refundAll`,
  auto-refer call, `pauseFilings`.
- **`StakedWood`, `ExposureLedger`, `TierRegistry`, escrow: untouched.** The
  electorate machinery (aged `getPastVotes`, raw `getPastTotalVotes`, same-basis
  `getPastStake` — review F17) is reused as-is.

### Kept verbatim from the reviewed #26 court

- Snapshot discipline: `snapshotTs = executedAt - 1`, computed once in `refer`,
  stored, never re-derived (D2). Fail-closed on `executedAt == 0`.
- `_recordAccused`: ledger read **from the game** (`IChallengeGameLedger`),
  never from the challenger-supplied governor; released commitments excluded;
  dedup guard; accused raw-stake sum via `getPastStake`.
- `_participationFloor`: `participationFloorBps × (total − accusedWeight)` with
  the `>` strict-inequality fallback guard. The stale delegation-era natspec
  (review finding E3) is rewritten to the post-#29 argument: same-basis
  subtraction makes the fallback belt-and-braces defence-in-depth, not
  load-bearing.
- The voting core of `voteAppeal`: one vote per address, accused barred
  (`AccusedCannotVote`), zero weight reverts (`NoVotingPower`), weight =
  `getPastVotes(voter, snapshotTs)`, no re-weighting (D3).
- CEI posture throughout; `refer` claims state before any external read
  (hostile-governor STATICCALL reasoning unchanged).

### Deleted relative to #26

Panel roster + `setPanel` + seats/bonds/locks, `panelRule`/`finalizePanel`,
appeal bond + `appeal`/`finalizeAppeal`/`finalizeUnappealed` as separate phases,
the entire bad-faith track, panel rewards + reservation, `bondedWood` /
`forfeitedWood` / `reservedRewards` / `burnForfeited`, `MAX_PANEL_*` constants,
the §4 court custody invariant (now vacuous: balance is 0 save donations).

## 3. TokenCourt mechanism

### State (per case)

```solidity
enum Phase { None, Voting, Resolved }
struct Case {
    uint256 challengeId;
    address game;            // pinned IChallengeGame this case rules on, written once in refer
    uint256 snapshotTs;      // executedAt - 1, written once
    uint256 referredAt;
    uint256 voteWindowAtReferral; // pinned (F5 lesson): owner cannot move a live case's clock
    uint256 accusedWeight;   // raw getPastStake sum at snapshotTs
    uint256 guiltyVotes;     // aged weight
    uint256 notGuiltyVotes;  // aged weight
    Phase phase;
    Verdict verdict;
    uint256 finalizedAt;
}
```

Plus: `caseCount`, `caseOfChallenge`, `isAccused[caseId][addr]`,
`_accused[caseId]` array, `voteOf[caseId][voter]` (Ruling).

### refer(challengeId) — permissionless, free

Requires, in order:

1. `challengeGame` and `stakedWood` wired (hard revert — closes review finding
   E4: a case can no longer exist before its electorate does).
2. Not already referred (`caseOfChallenge == 0` guard; `caseId` starts at 1).
3. Challenge status is `Disputed` (read from the game).
4. `executedAt != 0` (fail closed).
5. **The clock check:** `filedAt + disputeTimeoutAtFiling − block.timestamp
   ≥ voteWindow + FINALIZE_BUFFER`. A vote that could not finish before the
   challenge's own timeout never opens. `FINALIZE_BUFFER = 1 days` (constant):
   the grace period for someone to call `finalize` after the window closes.

Effects: create case (`Phase.Voting`), pin the referring `game` address, store
snapshot, pin `voteWindow`, record accused set + weight. Emits `CaseReferred`.

**Auto-referral:** `ChallengeGame.dispute`'s pool-completing branch calls
`court.refer(challengeId)` in a try/catch after its own state writes (CEI
preserved; a reverting court cannot brick the dispute). On catch, emit
`AutoReferFailed` and leave manual `refer` as the fallback. This removes the
unbounded referral slack that produced review finding E1's main feeding path.
`court == address(0)` skips the call (D5 world: unwired court, timeout
fail-safe governs).

### vote(caseId, guilty) — the one vote

- Phase `Voting`, `block.timestamp < referredAt + voteWindowAtReferral`.
- One vote per address; no vote changes; accused barred; zero weight reverts.
- Weight `getPastVotes(voter, snapshotTs)` — aged, snapshot-fixed.

### finalize(caseId) — permissionless

- Phase `Voting`, window elapsed (no early close: with an open electorate there
  is no "every seat has voted" condition).
- Tally: `turnout = guilty + notGuilty`; `floor = _participationFloor(...)`.
  - `turnout == 0 || turnout < floor` → **Inconclusive**.
  - else `guilty > notGuilty` → **Guilty**; otherwise (tie) → **NotGuilty**.
    Fail-safe direction throughout: no slash without established ground truth.
- Write verdict + `Phase.Resolved` **before** the external call, then
  `try IChallengeGame(case.game).rule(challengeId, verdict)` — against the
  case's **pinned** `game`, never the live `challengeGame` (a re-wire between
  `refer` and `finalize` must not redirect an in-flight case's verdict to a
  different game instance).
- The catch is **selector-filtered, not bare**. Only two reverts mean "nothing
  left to rule" and are swallowed, emitting `ChallengeAlreadyTerminal(caseId,
  challengeId)`: `WrongStatus` (the challenge went terminal on its own clock
  during the finalize buffer — the E1 race) and `NotCourt` (the game's `court`
  was re-pointed away before the call landed). **Every other revert bubbles**
  out of `finalize` whole, reverting the state writes above and leaving the
  case `Voting` for an honest retry. This is load-bearing, not cosmetic: a bare
  catch turns `rule`'s own callee-side `InsufficientSlashGas` gas floor — the
  check `ChallengeGame._settle` runs on behalf of sWOOD's burn-vs-bubble
  classifier (pinning the gas `slashToEscrow`'s child call needs, per N-4)
  before it ever calls `slashToEscrow` — into a verdict-burning primitive —
  anyone (profitably, the accused) could call `finalize` under-gassed so the
  `rule`→`_settle` call starves and reverts while the parent still has gas to
  spare, writing
  `Resolved` and dropping a `Guilty` verdict permanently, with the challenge
  later timing out to acquit the accused and pay them the challenger's bond.
  Filtering by selector closes that: an under-gassed or otherwise transient
  failure never resolves the case, only `WrongStatus`/`NotCourt` do. The case
  is closed either way it legitimately can be, and because the court holds no
  WOOD, a swallowed `WrongStatus`/`NotCourt` is bookkeeping, not stranded
  funds (review finding E1's fix, made structural).

### Owner surface (all `onlyOwner`, all bounded)

- `setChallengeGame(addr != 0)`, `setStakedWood(addr != 0)` — wiring.
  `setChallengeGame` governs future referrals only: a case already `Voting` or
  `Resolved` keeps the `game` it was referred under (`Case.game`), so
  re-wiring never redirects a live case's `finalize` to a different game.
- `setVoteWindow(0 < w ≤ MAX_VOTE_WINDOW = 14 days)` — governs future
  referrals only (pinned per case).
- `setParticipationFloorBps(0 < bps ≤ 10_000)`.
- **No pause on the court.** The pause lives on `ChallengeGame.file` (§4).
  Rationale: pausing referrals would let an already-disputed challenge drift
  into `disputeTimeout → _fail`, forfeiting an honest challenger's bond by
  owner action. Pausing filings stops new cases without touching any live
  challenge's rights.

## 4. ChallengeGame changes

### Verdict enum and rule

```solidity
enum Verdict { Inconclusive, NotGuilty, Guilty }  // zero value is the harmless full unwind, never the max-slash conviction
function rule(uint256 challengeId, Verdict verdict) external; // onlyCourt, requires Disputed
```

`Guilty → _settle` (unchanged: slash at ledger rates from the pinned
`executedAt` basis, demote, challenger repaid + pool forfeited to it).
`NotGuilty → _fail` (unchanged: pool + burn-sliced forfeit to defence
contributors via #50's pull machinery). `Inconclusive → _refundAll` (new).

### _refundAll — the third terminal path

- Status → `Status.Inconclusive` (enum **appended**; existing members keep
  their values — indexers unaffected).
- `bondedWood -= bond + pool`; freeze released via `_releaseFreeze`.
- Challenger bond returned **whole** — no `settleBurnBps` slice. Nothing was
  adjudicated; this is an unwind, not a verdict, and burning an unwound bond
  would price electorate apathy onto the challenger (the exact harm the
  Inconclusive outcome exists to avoid).
- Contributions booked into **#50's pull machinery** (`unclaimedWood` +
  `claimContribution`), never a push loop: open standing makes the contributor
  list unbounded.
- **No `_convicted` mark, no demotion, no compensation case.** The proposal is
  re-challengeable by a fresh filing with fresh bonds; `_liveCount` handles
  concurrency exactly as today.
- Emits `ChallengeInconclusive(challengeId, bond, pool)`.

### pauseFilings

`setFilingsPaused(bool)` (`onlyOwner`): gates **`file` only**. `dispute`,
`resolve`, `rule`, claims all run regardless — in-flight challenges retain
every right under their pinned parameters. This is the entire human backstop.

### Unchanged on purpose

`resolve`'s permissionless timeout (`Disputed` past `disputeTimeoutAtFiling` →
`_fail`) is **not** gated on an open court case: the court must never be able to
pin a guardian's frozen coverage past the challenge's own clock. The clock check
in `refer` + the finalize buffer make the timeout firing mid-case a
narrow-window race instead of a design hole, and the court-side try/catch makes
the residue harmless.

## 5. Parameters and launch math (E5)

Defaults: `voteWindow = 5 days`, `FINALIZE_BUFFER = 1 days`,
`participationFloorBps = 1_000`, `MAX_VOTE_WINDOW = 14 days`.

Preflight pins `voteWindow + FINALIZE_BUFFER ≤ disputeTimeout − autoSlashDelay`
(the worst-case dispute completes at the end of `autoSlashDelay`; a vote must
still fit). At defaults: `5 + 1 ≤ 30 − 7` ✓ with 17 days of referral slack.

**Floor reachability at launch:** turnout is aged, the floor base is raw. With
all stake young, max turnout ≈ `ageFloorBps`-fraction of raw total. Deploy
config MUST satisfy `participationFloorBps < ageFloorBps` with real margin —
at `ageFloorBps = 2_500`, `participationFloorBps = 1_000` needs ≥40% of raw
stake voting. The deploy script logs this arithmetic; an Inconclusive outcome
is survivable (refund + re-challenge), so a missed floor is degraded liveness,
not a fund event.

Electorate note: `stakeAsGuardian` is already permissionless — any WOOD holder
above `minGuardianStake` is a voter with aged weight. `minGuardianStake` is
therefore also the voter-entry floor; deploy config should set it low enough
for meaningful voter breadth (it bounds checkpoint churn, not security).

## 6. Testing

Ported (light edits): refer/snapshot/accused-set/floor suites; voting-core
suite (from the appeal-layer tests); hostile-governor re-entry; F17 same-basis
floor tests.

New:

- Inconclusive end-to-end: bonds whole, freeze released, no conviction mark,
  re-challenge of the same proposal succeeds.
- Clock-check boundary: referral at exactly `remaining == voteWindow + buffer`
  passes; one second less refuses.
- Auto-refer: fires on pool completion; court revert does not brick `dispute`
  (`AutoReferFailed` emitted); manual refer succeeds after.
- `rule(Verdict)` mapping ×3 verdicts.
- **Both orderings of the timeout race** (the E1 lesson): court finalizes then
  `resolve` reverts `WrongStatus`; `resolve` fires during the buffer then
  `finalize` closes the case via catch with `ChallengeAlreadyTerminal`.
- **`NotCourt` is swallowed identically to `WrongStatus`** (the game's `court`
  re-pointed away before `rule` landed) — case closes, `ChallengeAlreadyTerminal`.
- **The selector filter is not a bare catch**: an under-gassed `finalize` call
  that trips `rule`'s own `InsufficientSlashGas` floor must revert the whole
  `finalize` and leave the case `Voting` (regression test for the
  verdict-burning PoC), and a plain transient revert (any selector other than
  `WrongStatus`/`NotCourt`) must do the same — both then succeed on a retry
  once the condition clears.
- Pause: `file` refused while paused; `dispute`/`resolve`/`rule`/claims run on
  a pre-pause challenge.
- Custody: court WOOD balance is 0 across every arc (donation-only tolerance).

Rewritten: `CourtEndToEnd` arcs (single layer), `DeployPlanE` script +
preflight (panel checks deleted; window-fit check per §5; sWOOD identity on
both contracts; wiring order).

Gates: full `forge test`, `forge fmt --check` (CI-matching forge),
`script/check-layout-goldens.sh` (expected no-op: nothing upgradeable changes).

## 7. Migration

1. Merge **PR #50** into `e` (pull machinery is a dependency of `_refundAll`).
2. Branch **`feat/token-court`** off `e`.
3. Replace `Court.sol` → `TokenCourt.sol`; `ICourt.sol` → `ITokenCourt.sol`;
   game changes per §4; tests per §6; scripts.
4. Close **PR #26** unmerged with a pointer to this spec; keep branch `e`.
5. Open PR `feat/token-court` → `integration/lifecycle-planb`.

Estimated diff: `Court.sol` 1,409 → ~450; `Court.t.sol` 3,530 → ~1,400;
`ChallengeGame.sol` +~150; net roughly −3,500 lines against #26.

## 8. Explicitly deferred (with triggers)

- **Commit-reveal voting** — trigger: observed tally-watching/last-block
  swinging in real disputes.
- **On-chain voter rewards** (funding source: game's forfeit-burn slice) —
  trigger: repeated Inconclusive outcomes from apathy despite off-chain
  incentives.
- **Voter-tier staking below `minGuardianStake`** — trigger: evidence the
  entry floor materially narrows the electorate.
- **Sortition/drafted jurors (Kleros-shape)** — trigger: dispute volume high
  enough that per-case full-electorate votes exhaust voters; not before.
