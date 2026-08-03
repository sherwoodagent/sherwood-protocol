# Token Court Specification

## Purpose

Single-layer WOOD-vote adjudication of disputed `ChallengeGame` challenges. One referral opens one vote window; one tally against a participation floor produces a three-valued verdict (`Guilty` / `NotGuilty` / `Inconclusive`) delivered to the game via `rule`. The court holds no WOOD, ever — every value-moving consequence of a verdict lives on `ChallengeGame` and `StakedWood` (see `openspec/specs/challenge-game/spec.md`).
## Requirements
### Requirement: Zero custody

The court SHALL hold no WOOD at any point in any case lifecycle: no bonds, no counter-bonds, no reward pools, no custody bookkeeping. Its only output SHALL be a verdict handed to the pinned game's `rule` function. A verdict that fails to land on the game (terminal race) is bookkeeping, never stranded funds.

#### Scenario: Court balance across a full case arc

- **WHEN** a case is referred, voted, and finalized to any of the three verdicts
- **THEN** the court's WOOD balance remains zero throughout (donation-only tolerance), with all slash, refund, forfeit, and burn effects executed by `ChallengeGame` and `StakedWood`

### Requirement: Case referral

`refer(challengeId)` SHALL be permissionless and free, and SHALL open a case only when all of the following hold:

- `challengeGame` and `stakedWood` are both wired (else revert `ZeroAddress`) — a case cannot exist before its electorate does;
- no case already exists for this challenge on the currently-wired game — `caseOfChallenge` is keyed by `(game, challengeId)`, not by id alone, so a redeployed game's restarting challenge ids never collide with the old game's cases (else revert `AlreadyReferred`);
- the challenge's status on the game is `Disputed` (else revert `ChallengeNotDisputed`) — a `Filed` challenge is still inside its own auto-slash clock and a terminal one has nothing left to decide;
- the clock check passes: `block.timestamp + voteWindow + FINALIZE_BUFFER <= filedAt + disputeTimeoutAtFiling` (else revert `InsufficientClock`) — a vote that could not finish before the challenge's own timeout never opens;
- the challenge's pinned `executedAt` is non-zero (else revert `InvalidParameter`, fail-closed against an underflowed snapshot).

On success the court SHALL create a 1-indexed case in phase `Voting`, pin into it the referring `game` address, `snapshotTs`, `referredAt = block.timestamp`, `voteWindowAtReferral` (the live `voteWindow` at referral), and `Case.ledger` (the exposure ledger read from `IChallengeGameLedger(game).exposureLedger()` — resolved exactly once, at `refer`), record the accused set using that same resolved `Case.ledger` (single read, no second live resolution within the call), and emit `CaseReferred` carrying `snapshotTs`. The court SHALL claim `caseOfChallenge` before any external read of challenge state.

Because `Case.ledger` is a snapshot taken at `refer` and not at `file`, an owner re-point of the game's exposure ledger strictly between `file` and `refer` still produces an empty accused set — this residual gap is owner-only, recoverable by re-pointing back before `refer`, and is documented in natspec on `refer`/`_recordAccused` as an accepted follow-up (closing it fully would require an at-`file` pin inside `ChallengeGame` or a live-challenge guard on `setExposureLedger`, out of scope here).

#### Scenario: Ledger pinned at refer

- **GIVEN** a disputed challenge on the wired `ChallengeGame`
- **WHEN** `refer(challengeId)` executes
- **THEN** the ledger address read from `IChallengeGameLedger(game).exposureLedger()` is stored in `Case.ledger`, and `_recordAccused` consumes that same resolved address

#### Scenario: Owner re-point after refer does not disturb the case

- **GIVEN** a referred case with a non-empty accused set and `accusedWeight > 0`
- **WHEN** the game owner calls `ChallengeGame.setExposureLedger(newLedger)` where `newLedger.approversOf(...)` returns an empty set
- **THEN** `Case.ledger`, the `isAccused` set, and `Case.accusedWeight` are unchanged, and `finalize`'s participation floor uses the pinned `accusedWeight`

#### Scenario: Referral of a disputed challenge

- **WHEN** anyone calls `refer` on a `Disputed` challenge with both dependencies wired, no prior case on this (game, challenge), and at least `voteWindow + FINALIZE_BUFFER` remaining before the challenge's dispute timeout
- **THEN** a new case opens in phase `Voting` with `game`, `snapshotTs`, `referredAt`, and `voteWindowAtReferral` pinned, the accused set recorded, and `CaseReferred` emitted

#### Scenario: Referral refused when the vote cannot finish in time

- **WHEN** `refer` is called with less than `voteWindow + FINALIZE_BUFFER` remaining before `filedAt + disputeTimeoutAtFiling`
- **THEN** the call reverts `InsufficientClock` and no case opens

#### Scenario: Second referral for the same challenge

- **WHEN** `refer` is called for a challenge that already has a case on the currently-wired game
- **THEN** the call reverts `AlreadyReferred`

#### Scenario: Referral against a redeployed game

- **WHEN** the owner re-wires `challengeGame` to a fresh deployment whose challenge ids restart at zero, and `refer` is called for a challenge id the old game also used
- **THEN** the referral succeeds — case existence is keyed by `(game, challengeId)`, so the old game's cases do not block the new game's challenges

### Requirement: Pre-crime snapshot electorate

The electorate for a case SHALL be fixed at `snapshotTs = executedAt - 1` — the instant before the challenged proposal executed — computed once in `refer` from the game's own pinned `executedAt` record (never a live governor read) and stored on the case, never re-derived. All vote weights, the accused-weight sum, and the participation floor's total SHALL be read at this stored instant, so WOOD acquired or staked after the drain carries no weight and the electorate cannot change while the case is live.

#### Scenario: Post-execution stake has no weight

- **WHEN** an address stakes WOOD after the challenged proposal executed and attempts to vote
- **THEN** its `getPastVotes` at `snapshotTs` is zero and the vote reverts `NoVotingPower`

#### Scenario: Snapshot is immune to later record movement

- **WHEN** any state reachable through the governor or the game changes after `refer`
- **THEN** the case's `snapshotTs` and the weight readings against it are unchanged — the snapshot was stored at referral and is never re-derived

### Requirement: Accused set recording

At referral the court SHALL record the accused set as `Case.ledger`'s covering approvers for the challenged `(governor, proposalId)`, using the single resolution of `Case.ledger` made at `refer` (never a second live read, and never the challenger-supplied governor). Approvers whose committed share is zero (released before the filing) SHALL be excluded — they backed nothing on this proposal, so they are neither slashed for it nor barred from voting on it. Duplicate entries SHALL NOT be double-counted. The case's `accusedWeight` SHALL be the sum of raw `getPastStake` (not aged `getPastVotes`) over the recorded set at `snapshotTs`, computed over the approvers of `Case.ledger` (never a different ledger than the one pinned), and `AccusedSetRecorded(caseId, count, accusedWeight)` SHALL be emitted. The bar covers the specific approving addresses the ledger named — not any broader notion of the party behind them.

#### Scenario: Released approver excluded

- **WHEN** an approver released its commitment on the challenged proposal before the filing
- **THEN** it is not recorded in the accused set, contributes nothing to `accusedWeight`, and is free to vote on the case

#### Scenario: Accused weight uses the raw-stake basis

- **WHEN** the accused set is recorded
- **THEN** each member's contribution is `getPastStake(approver, snapshotTs)` — the same raw basis `getPastTotalVotes` sums — so the participation floor's subtraction never compares two different measures of the same WOOD, and a pending unstake request cannot shrink an accused member's contribution to raise the floor

#### Scenario: Ledger and accused weight are pinned together

- **GIVEN** any referred case
- **THEN** `Case.accusedWeight` equals the `getPastStake` sum computed over the approvers of `Case.ledger` at `Case.snapshotTs` — the derived weight can never come from a different ledger than the one pinned on the case

### Requirement: Voting

`vote(caseId, guilty)` SHALL accept a ballot only when all of the following hold, reverting otherwise:

- the case is in phase `Voting` (else `WrongPhase`);
- `block.timestamp < referredAt + voteWindowAtReferral` (else `WindowClosed`);
- the caller has not already voted on this case (else `AlreadyVoted`) — one vote per address, no vote changes;
- the caller is not in the case's accused set (else `AccusedCannotVote`);
- the caller's aged weight `getPastVotes(caller, snapshotTs)` is non-zero (else `NoVotingPower`);
- the caller's present voting power `getVotes(caller)` is non-zero (else `NoPresentHoldings`) — the present-holdings gate.

The ballot's weight SHALL be the aged `getPastVotes` amount at `snapshotTs`, accumulated into `guiltyVotes` or `notGuiltyVotes`, with `VoteCast(caseId, voter, guilty, weight)` emitted. Voting SHALL be open: ballots and running tallies are public on-chain the instant they land; there is no commit-reveal.

#### Scenario: Valid vote inside the window

- **WHEN** an unaccused address with non-zero aged snapshot weight and non-zero present holdings votes during the open window
- **THEN** its aged weight is added to the chosen tally, its ruling is recorded, and `VoteCast` is emitted

#### Scenario: Accused address barred

- **WHEN** an address in the case's accused set calls `vote`
- **THEN** the call reverts `AccusedCannotVote`

#### Scenario: Second vote refused

- **WHEN** an address that already voted on the case calls `vote` again, with either value
- **THEN** the call reverts `AlreadyVoted` — there is no path to change a cast vote

#### Scenario: Vote after the window closes

- **WHEN** `vote` is called at or after `referredAt + voteWindowAtReferral`
- **THEN** the call reverts `WindowClosed`

### Requirement: Present-holdings gate

Present holdings SHALL be a binary gate, never a weight: they decide only WHETHER the caller may vote at the instant the ballot is cast; the ballot's weight remains the historic aged snapshot value. An address whose current `getVotes` is zero — including a guardian with a pending unstake request, which zeroes present voting power from the request instant — SHALL be refused with `NoPresentHoldings`, distinct from `NoVotingPower` because the remedy differs: re-staking at least `minGuardianStake` restores votability, at the historic raw checkpoint discounted to the age floor (the re-stake re-anchors `stakedAt`), not at the original historic weight.

#### Scenario: Fully exited holder refused

- **WHEN** an address that held aged weight at `snapshotTs` but has since exited (or has a pending unstake request, so `getVotes` reads zero) calls `vote`
- **THEN** the call reverts `NoPresentHoldings`

#### Scenario: Gate does not lock voting capital

- **WHEN** a guardian votes, then requests unstake, then claims after the cooldown, all before `finalize`
- **THEN** every step succeeds — the gate is evaluated only at vote time

### Requirement: Verdict determination

`finalize(caseId)` SHALL be permissionless, SHALL require the case in phase `Voting` (else `WrongPhase`) and the window elapsed — `block.timestamp >= referredAt + voteWindowAtReferral` (else `WindowOpen`; there is no early close, even if every conceivable voter has voted). The verdict SHALL be computed from the tally and the participation floor as:

- `turnout == 0` or `turnout < floor` → `Inconclusive` — a thin or absent vote answers nothing and must not be read as an answer in either direction;
- otherwise `guiltyVotes > notGuiltyVotes` (strict majority) → `Guilty`;
- otherwise, a tie included → `NotGuilty` — a tie fails safe away from the verdict that destroys stake.

The court SHALL write `verdict`, `finalizedAt`, and phase `Resolved`, and emit `CaseFinalized(caseId, verdict, guiltyVotes, notGuiltyVotes, floor)` — the floor is logged so an `Inconclusive` outcome is explainable from the log alone — BEFORE the external `rule` call.

#### Scenario: Strict majority convicts

- **WHEN** the window has elapsed, turnout meets the floor, and `guiltyVotes > notGuiltyVotes`
- **THEN** the verdict is `Guilty`

#### Scenario: Tie acquits

- **WHEN** the window has elapsed, turnout meets the floor, and `guiltyVotes == notGuiltyVotes`
- **THEN** the verdict is `NotGuilty`

#### Scenario: Turnout below the floor

- **WHEN** the window has elapsed and `turnout` is zero or below the participation floor
- **THEN** the verdict is `Inconclusive`, regardless of which side leads the tally

#### Scenario: Finalize before the window elapses

- **WHEN** `finalize` is called while `block.timestamp < referredAt + voteWindowAtReferral`
- **THEN** the call reverts `WindowOpen`

### Requirement: Participation floor

The participation floor SHALL be `participationFloorBps × base / 10_000` where the base is computed in two steps, both at `finalize` time:

1. **Same-instant accused reduction, clamped at zero**: `reduced = total(snapshotTs) > accusedWeight ? total(snapshotTs) - accusedWeight : 0`. `accusedWeight` sums the same raw-stake basis as `total(snapshotTs)` over a subset of the same addresses (the accused set), read at the same instant, so `accusedWeight <= total(snapshotTs)` holds structurally under one consistently-wired electorate source and the clamp exists only as defence-in-depth for an out-of-band `setStakedWood` re-point. Because the subtraction is same-instant, staking more by an accused address raises `total(snapshotTs)` and `accusedWeight` together and leaves `reduced` unchanged — there is no lever by which the accused can buy a higher floor by staking. The floor SHALL be monotone non-increasing as a function of WHICH addresses are named accused: naming one more address can only remove that address's stake from `reduced`, never add to it.
2. **Lookback min**: `base = (getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK) != 0 && getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK) < reduced) ? getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK) : reduced`, i.e. `base = min(earlier, reduced)` with a fallback to `reduced` when the lookback read is zero (no electorate existed a lookback ago, including a `snapshotTs` inside the chain's first `FLOOR_LOOKBACK`, where the lookback instant clamps to 0) — a zero base there would disable the anti-capture floor for the protocol's whole bootstrap window. `accusedWeight` is never subtracted from the earlier read; only `reduced` (step 1's output) is compared against it. The min defeats the pre-drain stake-surge denial lever: an attacker inflating the electorate immediately before their own drain (the attacker is exactly the party who knows when `executedAt` will be) must have the inflating stake present at BOTH instants, i.e. visibly parked on-chain for a month before the drain it exists to protect. A zero floor is safe because `finalize`'s `turnout == 0` guard still forces `Inconclusive` on an empty vote — a zero floor never lets a zero-turnout case resolve on the merits.

Turnout is summed in aged weight while the base is raw, so aging only ever makes the floor harder to reach, never easier — the floor stays conservative. The floor SHALL read the LIVE `participationFloorBps` and the LIVE `stakedWood` at `finalize` time, deliberately not pinned per case: the floor is consumed exactly once, after voting has closed, so a change cannot retroactively alter any cast ballot, and a floor change applies to every case finalizing after it takes effect.

#### Scenario: Floor base excludes accused stake

- **WHEN** `finalize` computes the floor and `accusedWeight` is below the electorate base
- **THEN** the base is the electorate base minus the case's recorded `accusedWeight`, so the accused's own stake never inflates the turnout bar its jury must clear

#### Scenario: Floor is monotone across the accused-weight boundary

- **GIVEN** two otherwise identical cases whose recorded `accusedWeight` differ only in that one is just below the electorate base and the other is at or above it
- **WHEN** `finalize` computes each floor
- **THEN** the floor of the larger-`accusedWeight` case is less than or equal to the floor of the smaller — the floor never jumps up when `accusedWeight` crosses the base

#### Scenario: Accused outweighing the electorate cannot deny a verdict

- **GIVEN** a case whose recorded `accusedWeight` is at or above the electorate base
- **WHEN** a single unaccused voter with any non-zero aged snapshot weight votes and the window elapses
- **THEN** the floor is zero, turnout meets it, and `finalize` resolves the case on the merits rather than `Inconclusive` — the accused cannot buy a denial by staking past the base

#### Scenario: Zero floor never resolves an empty vote

- **GIVEN** a case whose recorded `accusedWeight` is at or above the electorate base, so the floor is zero
- **WHEN** the window elapses with no votes cast
- **THEN** `finalize` still returns `Inconclusive` via the `turnout == 0` guard — the clamp delegates the empty-vote case to that guard, never to the floor

#### Scenario: Floor change applies to a live case

- **WHEN** the owner changes `participationFloorBps` while a case is in `Voting`
- **THEN** that case's `finalize` uses the new value — the floor is read live at finalization, unlike the case's pinned snapshot and window

### Requirement: Verdict delivery and the selector-filtered catch

After closing the case, `finalize` SHALL call `rule(challengeId, verdict)` on the case's PINNED `game` — never the live `challengeGame` — and SHALL tolerate exactly one revert from it: `WrongStatus`, meaning the challenge went terminal on its own clock (the terminal race) and there is genuinely nothing left to rule; that revert is swallowed and `ChallengeAlreadyTerminal(caseId, challengeId)` is emitted, with the case remaining closed. Every other revert — an under-gassed slash (`InsufficientSlashGas`), `NotCourt` from the game's court being re-pointed while the challenge is still rulable, an unwired downstream, a token failure — SHALL bubble out of `finalize` whole, reverting the case's state writes too, so the case stays `Voting` with its tally intact for an honest retry once the condition clears. A bare catch is forbidden: it would let anyone burn a `Guilty` verdict permanently by choosing a gas limit.

#### Scenario: Challenge went terminal during the finalize buffer

- **WHEN** the underlying challenge resolved on its own dispute timeout before `finalize`'s `rule` call lands, so `rule` reverts `WrongStatus`
- **THEN** `finalize` succeeds anyway: the case is `Resolved` with its verdict recorded, and `ChallengeAlreadyTerminal` is emitted

#### Scenario: Under-gassed finalize cannot burn a verdict

- **WHEN** `finalize` is called with a gas limit that starves the `rule` call into `InsufficientSlashGas` while the caller retains enough gas to complete
- **THEN** the entire `finalize` reverts, the case remains `Voting` with tally intact, and a properly gassed retry delivers the verdict

#### Scenario: Re-pointed court does not close the case

- **WHEN** the game's `court` was re-pointed away so `rule` reverts `NotCourt` while the challenge is still `Disputed`
- **THEN** the entire `finalize` reverts and the case remains `Voting` — the condition is transient and retryable, and swallowing it would record a verdict that could never be delivered

### Requirement: Inconclusive consequence — unwind with escalating challenger burn

An `Inconclusive` verdict SHALL be a non-event that unwinds both sides on the game, never an acquittal-with-forfeit: no conviction mark, no demotion, the accused's counter-bond pool refunded whole (via pull payments), the coverage freeze released, and the proposal re-challengeable. The challenger's bond SHALL be refunded minus an escalating per-round burn enforced by `ChallengeGame`: the rate is pinned at filing (`inconclusiveBurnBpsAtFiling`) from the proposal's prior `Inconclusive` round count — round 1 (first-ever attempt against the proposal) burns 0 bps, round 2 burns 500 bps, round 3 burns 1,000 bps, round 4 and beyond burns the live `inconclusiveBurnBps` (default 2,000) — with every tier clamped to the live `settleBurnBps` ceiling at filing (the clamp never reverts a filing), so a non-verdict never costs more than a verdict that recovered real value. A lapsed re-challenge window resets the round counter. Full mechanics live in `openspec/specs/challenge-game/spec.md`.

#### Scenario: First Inconclusive round is free

- **WHEN** the first-ever challenge against a proposal ends `Inconclusive`
- **THEN** the challenger's bond is refunded whole (0 bps burned) and the counter-bond pool returns whole — a genuine one-shot filer whose vote merely missed quorum pays nothing

#### Scenario: Repeated grinding is priced

- **WHEN** successive challenges against the same proposal each end `Inconclusive`
- **THEN** each round's filing pins the escalated rate — 500 bps, then 1,000 bps, then `inconclusiveBurnBps` — clamped to the live `settleBurnBps` at filing, burned from the challenger's bond on the unwind

### Requirement: Owner surface

All configuration setters SHALL be `onlyOwner` under plain `Ownable2Step` (two-step transfer; non-upgradeable), bounded, and event-emitting:

- `setChallengeGame(newGame)`: rejects the zero address, and validates the cross-contract window invariant against the NEW game unconditionally (see the window-invariant requirement). Emits `ChallengeGameSet`.
- `setStakedWood(newStakedWood)`: rejects the zero address. Emits `StakedWoodSet`.
- `setVoteWindow(newWindow)`: requires `0 < newWindow <= MAX_VOTE_WINDOW` (14 days), and validates the window invariant against the live game when one is wired. Emits `VoteWindowSet`.
- `setParticipationFloorBps(newBps)`: requires `0 < newBps <= 10_000`. Emits `ParticipationFloorBpsSet`.

Re-wiring and window changes SHALL govern future referrals only: a case already `Voting` or `Resolved` keeps its pinned `game`, `snapshotTs`, and `voteWindowAtReferral`, so no owner action redirects a live case's `finalize` to a different game or moves a live case's clock or electorate.

#### Scenario: Live case immune to re-wiring

- **WHEN** the owner calls `setChallengeGame` or `setVoteWindow` while a case is in `Voting`
- **THEN** that case keeps the `game` and `voteWindowAtReferral` pinned at its referral; only cases referred afterward see the new values

#### Scenario: Non-owner refused

- **WHEN** any address other than the owner calls a setter
- **THEN** the call reverts with the `Ownable` unauthorized error

#### Scenario: Bounded parameters

- **WHEN** `setVoteWindow` is called with 0 or a value above 14 days, or `setParticipationFloorBps` with 0 or a value above 10,000
- **THEN** the call reverts `InvalidParameter`

### Requirement: Cross-contract window invariant

The court SHALL enforce `autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout` (with `FINALIZE_BUFFER = 1 day`) against the game's LIVE clock values on both setters that can break it: `setVoteWindow` (when a game is wired; vacuous while unwired) and `setChallengeGame` (always, against the new game — closing the compose-bypass where a window raised while unwired is then wired to a game that cannot fit it). Violations revert `WindowInvariantViolated`. `FINALIZE_BUFFER` is the grace margin `refer`'s clock check reserves for `finalize`; it is not itself a gate on the game's timeout.

#### Scenario: Vote window that cannot fit the game's clocks

- **WHEN** the owner calls `setVoteWindow` with a value such that `autoSlashDelay + newWindow + 1 day` exceeds the wired game's `disputeTimeout`
- **THEN** the call reverts `WindowInvariantViolated`

#### Scenario: Wiring a game that cannot fit the current window

- **WHEN** the owner calls `setChallengeGame` with a game whose `autoSlashDelay + voteWindow + 1 day` exceeds that game's `disputeTimeout`
- **THEN** the call reverts `WindowInvariantViolated` — the invariant is checked on every wiring call, with no vacuous branch

### Requirement: No pause on the court

The court SHALL expose no pause. The human backstop for the system is `ChallengeGame`'s filings pause, which gates new filings only; pausing referral or voting on the court would let an already-disputed challenge drift into its own dispute timeout while frozen, forfeiting an honest challenger's bond by owner inaction.

#### Scenario: Live case proceeds regardless of any owner action

- **WHEN** a case is in `Voting`
- **THEN** no owner-callable function on the court can halt its voting or block its `finalize` — only the clock and the tally decide it

### Requirement: Case observability

The court SHALL expose full case state for indexers and callers: `caseOf(caseId)` (the complete case struct), `accusedOf(caseId)` (the recorded accused set in order), `caseOfChallenge(game, challengeId)` (zero meaning no case), `voteOf(caseId, voter)` (the three-valued ruling, `None` if unvoted), `isAccused(caseId, account)`, and `caseCount`. Events SHALL make outcomes auditable from logs alone: `CaseReferred` carries the pinned `snapshotTs`; `CaseFinalized` carries both tallies and the floor the verdict was measured against.

#### Scenario: Inconclusive verdict explainable from logs

- **WHEN** a case finalizes `Inconclusive`
- **THEN** the `CaseFinalized` event carries `guiltyVotes`, `notGuiltyVotes`, and `floor`, so `turnout < floor` is verifiable off-chain without re-deriving the floor

