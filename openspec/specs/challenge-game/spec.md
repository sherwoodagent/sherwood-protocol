# Challenge Game Specification

## Purpose

The challenge trigger of the guardian economic-security model: anyone may post a bonded challenge against an executed proposal, freezing the coverage its approvers committed; silence convicts, a dispute escalates to the token court, and verdicts execute through the slash rails, burning the convicted approvers' bonds. Depositors are not compensated. Covers `ChallengeGame` and `ProposerBondEscrow`.
## Requirements
### Requirement: Filing a bonded challenge
`ChallengeGame.file(governor, proposalId, predicate, adapterTarget, adapterSelector, evidenceURI)` SHALL be permissionless and SHALL accept a filing only against an EXECUTED proposal (`executedAt != 0`, read from the governor; otherwise revert `NotExecuted`), and only while `block.timestamp <= max(executedAt + challengeWindow, challengeableUntil[reviewKey])` (otherwise revert `WindowClosed`). The deadline MUST be recomputed as a max against the live `executedAt + challengeWindow` baseline on every call, never read as a stored absolute, so the window can only ever extend, never shorten. The cited predicate (one of `OutOfAdapterOutflow`, `OraclePriceDeviation`, `ProposerLinkedOutflow`, `RogueAllowance`, `DrawdownBreach`) SHALL be a classification label only — recorded and emitted in `ChallengeFiled` but branching no logic; there is no on-chain predicate verification. `evidenceURI` SHALL be carried unindexed in `ChallengeFiled` as the off-chain evidence anchor. The review key SHALL be `keccak256(abi.encode(governor, proposalId))`, matching the ledger and registry derivation.

#### Scenario: Filing against an executed proposal inside the window
- **WHEN** a caller files against a proposal with non-zero `executedAt`, within the window, with a valid bond
- **THEN** a new challenge is created in status `Filed` with `filedAt = block.timestamp`, the bond is pulled via `safeTransferFrom`, and `ChallengeFiled` is emitted with the challenger, predicate, bond, and evidence URI

#### Scenario: Unexecuted proposal refused
- **WHEN** `file` is called for a proposal whose `executedAt` is zero
- **THEN** the call reverts `NotExecuted`

#### Scenario: Window closed
- **WHEN** `block.timestamp` exceeds both `executedAt + challengeWindow` and the proposal's `challengeableUntil` extension
- **THEN** the call reverts `WindowClosed`

### Requirement: Filings pause is the owner's only lever, and gates `file` alone
The owner SHALL be able to set `filingsPaused` via `setFilingsPaused(bool)`. While true, `file` SHALL revert `FilingsPaused` before any other check. The flag MUST NOT be read by `dispute`, `resolve`, `rule`, `claimContribution`, or any other path — the owner can stop a NEW challenge from starting but can never freeze or re-price one already in flight.

#### Scenario: Paused filings refuse new challenges only
- **WHEN** `filingsPaused` is true and a caller invokes `file`
- **THEN** the call reverts `FilingsPaused`
- **AND** `dispute`, `resolve`, `rule`, and both claim paths on existing challenges proceed unaffected

### Requirement: Challenger bond sized to the coverage the filing freezes
The bond SHALL be `coverageUsd * challengerBondBps / 10_000`, converted to WOOD at the ledger's composed haircut price `woodPriceX8()` (never the raw owner scalar). `coverageUsd` SHALL be the sum of the ledger's committed approver shares for the proposal, capped (not replaced) by `exposureLedger.liabilityUsd` when that call succeeds and returns a non-zero value below the sum — reservations over-state liability, and the liability read is wrapped in `try/catch` so a stale feed cannot make filing impossible. Filing SHALL fail closed: revert `NothingToFreeze` when the committed sum is zero, `WoodPriceUnset` when the composed price is zero (transient, protocol-wide), and `BondTooSmall` when the bond floors to zero (permanent, proposal-specific) — the two price failures MUST be distinct errors.

#### Scenario: Bond computed from capped coverage at the composed price
- **WHEN** the ledger reports committed shares summing above `liabilityUsd`
- **THEN** the bond is priced against `liabilityUsd` (the allocation basis the slash itself uses), at `challengerBondBps` (default 500) of that value, converted at `woodPriceX8()`

#### Scenario: Unpriced WOOD blocks filing
- **WHEN** `exposureLedger.woodPriceX8()` returns zero
- **THEN** `file` reverts `WoodPriceUnset`

#### Scenario: Zero-coverage proposal cannot be challenged
- **WHEN** every approver commitment for the proposal has been released (sums to zero)
- **THEN** `file` reverts `NothingToFreeze`

### Requirement: Filing freezes coverage, refcounted across concurrent challenges
Filing SHALL freeze the proposal's committed coverage on the exposure ledger (per-proposal, never the guardian's whole stake). The freeze MUST be refcounted per proposal: only the first live challenge calls `freezeCoverage`, and only the termination of the LAST live challenge calls `unfreezeCoverage`, so a terminating challenge never unfreezes coverage that concurrent filings still pin. The refcount decrement SHALL be defensive against underflow (a rewired ledger must not produce a permanent freeze). `liveChallengeCountOf` SHALL report the live count; non-zero is exactly the condition under which coverage stays frozen.

#### Scenario: First filing freezes, second does not double-freeze
- **WHEN** two challengers file against the same proposal
- **THEN** `freezeCoverage` is called once, on the first filing, and the live count is 2

#### Scenario: Last termination unfreezes
- **WHEN** one of two live challenges reaches a terminal state
- **THEN** coverage remains frozen until the second also terminates, at which point `unfreezeCoverage` is called once

### Requirement: The challenger names the accused adapter, checked for membership
The filer SHALL name the adapter it accuses (`adapterTarget`, `adapterSelector`); the chain MUST NOT derive it. The zero address SHALL mean the filing accuses no adapter (and demotes nothing). A non-zero `adapterTarget` MUST appear, with its selector, among the challenged proposal's own stored execute calls (calls with fewer than 4 bytes of data are skipped, never treated as wildcards); otherwise `file` SHALL revert `AdapterNotInProposal`. This is a membership test over data the governor holds, not a second calldata parser.

#### Scenario: Adapter outside the proposal refused
- **WHEN** a filing names a certified adapter `(target, selector)` that does not appear in the proposal's execute calls
- **THEN** `file` reverts `AdapterNotInProposal`

#### Scenario: No-adapter filing
- **WHEN** a filing passes the zero address as `adapterTarget`
- **THEN** the filing is accepted and no demotion occurs on any outcome

### Requirement: One live challenge per challenger; convicted proposals unchallengeable
Live-challenge slots SHALL be keyed per `(reviewKey, challenger)`: a challenger with a live (`Filed`/`Disputed`) challenge against the proposal SHALL be refused with `AlreadyChallenged`, but a squatting challenge never blocks a different honest filer. Once any settled challenge has collected the proposal's one liability (`_convicted`), ALL further filings against that proposal SHALL revert `AlreadyConvicted` — a filing that cannot convict would only buy another freeze on already-slashed collateral. A FAILED challenge does not set the convicted flag, so a fresh filing after a failure remains legitimate. Liveness views SHALL re-check status rather than trusting stored pointers (`liveChallengeOf`, `liveChallengeOfBy`).

#### Scenario: Same challenger, same proposal, second filing refused
- **WHEN** a challenger with a live challenge against a proposal files again
- **THEN** the call reverts `AlreadyChallenged`, while a different challenger may still file

#### Scenario: Filing against a convicted proposal refused
- **WHEN** an earlier challenge on the proposal has settled to a conviction
- **THEN** any later `file` against it reverts `AlreadyConvicted`

### Requirement: Economic terms and slash basis pinned at filing
Each challenge SHALL pin at filing: `autoSlashDelayAtFiling`, `disputeTimeoutAtFiling`, `settleBurnBpsAtFiling`, `forfeitBurnBpsAtFiling`, `convictionBountyBpsAtFiling`, `inconclusiveBurnBpsAtFiling` (the escalating-schedule value for the proposal's current round), plus the proposal's `executedAt` and `vault`. All clock checks and payout rates for that challenge MUST read the pinned values, never the live parameters — the owner can never retroactively shorten a window, extend a freeze, or re-price a challenge already running. The verdict slash basis SHALL be the pinned `executedAt` (with snapshot `executedAt - 1`), never `filedAt`, so an accused approver cannot zero its own stake checkpoint between drain and accusation.

#### Scenario: Owner parameter change does not move a live challenge
- **WHEN** the owner changes `autoSlashDelay`, `disputeTimeout`, or any burn/bounty rate after a challenge is filed
- **THEN** that challenge's windows and payouts continue to use the values pinned at its filing; only challenges filed after the change use the new values

### Requirement: Counter-bond pool with open standing
`dispute(challengeId, amountWood)` SHALL accept contributions to a `Filed` challenge's counter-bond pool from ANY address (open standing — skin in the game is enforced economically: a guilty ruling forfeits the pool), strictly before `filedAt + autoSlashDelayAtFiling` (otherwise `WindowClosed`; non-`Filed` status reverts `WrongStatus`). The pool's target SHALL be exactly the challenger's bond and MUST NOT scale with the payer's own share — pinning the TOTAL is what makes an identity split cost the same as staying whole. Contributions SHALL be clamped to the remaining shortfall (no refund-of-excess path; a clamped-to-zero amount reverts `NothingToContribute`), recorded per contributor without list duplicates, and emitted per contribution (`CounterBondContributed`).

#### Scenario: Contribution clamped to the shortfall
- **WHEN** a contributor sends `type(uint256).max` against a pool 10 WOOD short
- **THEN** exactly 10 WOOD is pulled, the pool completes, and no excess is ever held

#### Scenario: Contribution after the silence window refused
- **WHEN** `block.timestamp >= filedAt + autoSlashDelayAtFiling`
- **THEN** `dispute` reverts `WindowClosed` — at that instant the silence verdict is already final

### Requirement: Pool completion flips to Disputed and best-effort refers to the court
The contribution that brings the pool to exactly the bond SHALL flip the status to `Disputed` in the same call and emit `ChallengeDisputed` once. `Filed` therefore always implies pool < bond and `Disputed` implies pool == bond. When a court is wired, the completing call SHALL then attempt `TokenCourt.refer(challengeId)` inside a deliberately BROAD `try/catch` with no gas floor — a revert here would deny the accused their defence, which is unrecoverable, while a skipped referral is recoverable because `refer` is permissionless. A swallowed referral failure SHALL emit `AutoReferFailed`. With no court wired, no referral is attempted and the dispute timeout remains the only exit from `Disputed`.

#### Scenario: Completing contribution escalates
- **WHEN** a contribution completes the pool
- **THEN** the status becomes `Disputed`, the auto-slash clock stops mattering, `ChallengeDisputed` is emitted, and (with a court wired) `refer` is attempted on the same transaction

#### Scenario: Failed auto-referral does not fail the dispute
- **WHEN** the wired court's `refer` reverts during the completing `dispute` call
- **THEN** the dispute itself still lands (status `Disputed`, transfer cleared) and `AutoReferFailed` is emitted; anyone may retry `refer` directly

### Requirement: Silence is the verdict — permissionless timeout resolution
`resolve(challengeId)` SHALL be permissionless and choose nothing: from `Filed` at or after `filedAt + autoSlashDelayAtFiling` and before `filedAt + disputeTimeoutAtFiling` it SHALL settle the challenge (the silence IS the adjudication); from `Filed` at or after `filedAt + disputeTimeoutAtFiling` (a STALE filing nobody settled inside its window) it SHALL unwind the challenge through the `Inconclusive` path — nothing slashed, the freeze released, the bond returned net of the round's inconclusive burn, any part-funded pool released to its funders; from `Disputed` at or after `filedAt + disputeTimeoutAtFiling` it SHALL fail the challenge in favour of the accused (the fail-safe when no ruling arrived). Before the respective clock it SHALL revert `DelayNotElapsed`; from any terminal status, `WrongStatus`. `filedAt + disputeTimeoutAtFiling` is therefore the HARD END OF SLASHABILITY for a filing: it is the same value `file` books on the ledger as `liveUntil`, and no path may convict on that filing from that instant on. THIS IS A CHANGE TO THE CHALLENGER'S LIVENESS BURDEN: a valid, undisputed filing that nobody `resolve`s inside `[filedAt + autoSlashDelayAtFiling, filedAt + disputeTimeoutAtFiling)` (23 days at defaults) no longer convicts - it unwinds as `Inconclusive` and the challenger's bond is burned at the round's escalating rate. `resolve` is permissionless, so the challenger (or any keeper acting for it) SHALL settle inside that window or eat the round burn; the escalation schedule itself is SHE-247's subject.

#### Scenario: Undisputed challenge auto-settles
- **WHEN** a challenge is still `Filed` and `autoSlashDelayAtFiling` has elapsed since filing, and `disputeTimeoutAtFiling` has not
- **THEN** any caller's `resolve` executes the conviction path (slash, demotion, bond handling) and the challenge becomes `Settled`

#### Scenario: Stale undisputed challenge unwinds instead of settling
- **WHEN** a challenge is still `Filed` and `disputeTimeoutAtFiling` has elapsed since filing with nobody having settled it
- **THEN** any caller's `resolve` makes the challenge `Inconclusive`: no slash, coverage unfrozen, bond returned net of the inconclusive burn, the re-challenge window re-armed and pinned

#### Scenario: Slashability ends exactly at the ledger's liveUntil
- **WHEN** the latest live filing on a key has reached `filedAt + disputeTimeoutAtFiling` and nobody has resolved it
- **THEN** the key MAY still read as frozen (`hasFrozenCoverage`) until someone resolves, but neither `resolve` nor `rule` can slash it, so the ledger is correct to stop counting the lock in `openExposure` any time from that instant on (it keeps counting at least until then - the bucket containing `liveUntil` ages out no earlier than its end plus the ledger's `challengeWindow` - and MUST never stop earlier); with two concurrent filings the key stays slashable until the LATER filing's deadline and the earlier one going stale neither unfreezes it nor shortens that window

#### Scenario: Unruled dispute times out to the accused
- **WHEN** a challenge is `Disputed` and `disputeTimeoutAtFiling` has elapsed since filing with no ruling
- **THEN** any caller's `resolve` fails the challenge: the accused side wins, the challenger's bond forfeits

### Requirement: Court ruling — three verdicts, ruling beats timeout
`rule(challengeId, verdict)` SHALL be callable only by the wired `court` (otherwise `NotCourt`; the zero-address court makes `rule` unreachable by construction) and only on a `Disputed` challenge (otherwise `WrongStatus`). The court supplies ONLY the verdict enum — there is no severity argument. `Guilty` SHALL take the identical settle path an undisputed challenge takes; `NotGuilty` SHALL take the identical fail path the timeout takes; `Inconclusive` (deliberately the enum's zero value, so a defaulted verdict lands on the harmless unwind) SHALL unwind both sides. `ChallengeRuled` SHALL be emitted before the consequent accounting. All three outcomes are terminal, and `resolve` acts only on `Filed`/`Disputed`, so a ruling can never be overwritten by the clock — a guilty approver cannot dispute and run out `disputeTimeout` once a court is wired. The clock in turn beats a LATE ruling: at or after `filedAt + disputeTimeoutAtFiling`, `rule` SHALL revert `WindowClosed` for every verdict, checked after the status and court gates so a terminal challenge still reports `WrongStatus`. `TokenCourt.refer` already refuses a case whose vote plus `FINALIZE_BUFFER` would not fit inside that deadline, so an honest `finalize` always lands before it; a late `finalize` bubbles `WindowClosed` (the court swallows only `WrongStatus`), leaves the case in `Voting`, and closes through `WrongStatus` once `resolve` has timed the challenge out.

#### Scenario: Non-court caller refused
- **WHEN** any address other than `court` calls `rule`
- **THEN** the call reverts `NotCourt`, including every caller while `court` is the zero address

#### Scenario: Ruling pre-empts the timeout
- **WHEN** the court rules `Guilty` before `disputeTimeoutAtFiling` elapses
- **THEN** the conviction executes and a later `resolve` reverts `WrongStatus`

#### Scenario: Late ruling refused
- **WHEN** the court calls `rule` with any verdict at or after `filedAt + disputeTimeoutAtFiling` on a still-live `Disputed` challenge
- **THEN** the call reverts `WindowClosed`, nothing is slashed, and `resolve` remains the only exit (failing the challenge to the accused, or unwinding it when no court was pinned)

### Requirement: Settle path — conviction, slash into escrow, per-path bond handling
`_settle` (reached from the silence timeout or a `Guilty` ruling) SHALL fail closed with `ZeroAddress` if `stakedWood` is unwired (recoverable: wiring the slasher makes every stuck challenge resolvable). It SHALL mark the status `Settled`, release this challenge's freeze hold, and — unless the proposal was already convicted by a concurrent challenge, in which case it SHALL emit `VerdictAlreadyCollected` and slash nothing — set the convicted flag and execute the slash via `IStakedWood.slashVerdict` using the ledger's per-approver rates (`slashBpsFor`, filtered to non-zero entries so released approvers are not named in the conviction) and the pinned `executedAt` as basis. It SHALL also pass a `contestors` array, positionally aligned with the approvers, flagging every approver that funded the counter-bond — sWOOD caps the conviction bounty at their summed slash, so the scan MUST be complete rather than stopping at the first match. Bond handling SHALL differ by entry: on the ESCALATED entry (`Guilty` ruling) the challenger receives its bond whole plus the entire forfeited pool, with no burn; on the SILENCE entry, `settleBurnBpsAtFiling` of the bond is burned to `0x…dEaD` (`ChallengerBondBurned`), the remainder returns to the challenger, and any part-funded pool is booked for pull-refund to its contributors. `ChallengeSettled(challengeId, slashedWood)` SHALL be emitted, where `slashedWood` is what was actually BURNED (net of any conviction bounty).

#### Scenario: Silence conviction burns the settle slice
- **WHEN** an undisputed challenge settles by timeout
- **THEN** the accused approvers are slashed and their bonds burned, the named adapter demotion is attempted, `settleBurnBpsAtFiling` (default 2,000 bps) of the bond is burned, and the challenger receives the rest

#### Scenario: Escalated conviction pays the challenger the pool
- **WHEN** the court rules `Guilty` on a disputed challenge
- **THEN** the challenger receives its full bond plus the complete counter-bond pool, and nothing is burned — the filing was tested on the merits and won

#### Scenario: Concurrent settle against an already-convicted proposal
- **WHEN** a second live challenge settles after another already collected the proposal's liability
- **THEN** no slash is attempted, `VerdictAlreadyCollected` is emitted, and the challenge still terminates normally (settle-path bond handling included)

### Requirement: Conviction bounty only on a genuinely contested escalated conviction
The pinned `convictionBountyBpsAtFiling` SHALL be forwarded to `slashVerdict` (with the challenger as recipient) ONLY when the conviction is escalated (`Guilty` ruling) AND at least one member of the ACCUSED approver set contributed to the counter-bond pool. On the silence path, and on an escalated conviction whose pool no accused approver funded (a challenger-staged contest), the game SHALL pass `(address(0), 0)` — no bounty. The bounty ceiling is sWOOD's own `MAX_CONVICTION_BOUNTY_BPS`, read live, never restated in this contract.

#### Scenario: Sybil-staged contest earns no bounty
- **WHEN** a `Guilty` ruling lands on a dispute whose pool was funded only by non-accused addresses
- **THEN** the slash executes with zero bounty; the challenger still receives bond plus pool but collects no slice of the slash

### Requirement: Slash gas floor
Because `resolve` is permissionless, `_settle` SHALL revert `InsufficientSlashGas` when `gasleft() < approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE`, with `SLASH_GAS_PER_APPROVER = 180_000` and `SLASH_GAS_BASE = 2_000_000` — measured end to end through court `finalize`, not against the slash call alone. When the challenge names a non-zero adapter, the floor SHALL additionally require `DEMOTION_GAS = 200_000`: the check becomes `gasleft() >= approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE + DEMOTION_GAS`, so a settle that passes it is GUARANTEED to reach the best-effort `demoteByChallenge` child with enough gas for the demotion to succeed on a willing registry — a caller cannot choose a gas budget on which the conviction lands but the demotion is starved. A filing that accuses no adapter (zero `adapterTarget`) demotes nothing and SHALL owe nothing for it: its floor is the slash terms alone. Without the term, the demotion's gas safety rested on two incidental facts — the slash constants' measured slack reaching the demotion call, and an out-of-gas demotion child consuming its whole 63/64 stipend so the 1/64 remainder could not pay for the settle's own tail (the whole call reverted rather than settling with a silent miss). Both held at the time this term was added, but neither was stated or tested; the explicit term is what survives retuning the slash constants, slimming the settle tail, or reordering the demotion. The full-cap floor including `DEMOTION_GAS` SHALL fit Robinhood's 32M per-transaction limit (`100 * 180_000 + 2_000_000 + 200_000 = 20,200,000` against `32M * (63/64)^3 = 30,523,315`). The check is skipped on the `VerdictAlreadyCollected` branch (nothing is slashed, nothing is demoted) and a failed check changes no challenge state — retry with more gas.

#### Scenario: Under-gassed resolve reverts cleanly
- **WHEN** `resolve` reaches the slash with less than the floor remaining
- **THEN** it reverts `InsufficientSlashGas` and the challenge remains resolvable by a retry with more gas

#### Scenario: A budget that covers the slash but not the demotion is refused up front
- **WHEN** `resolve` or `rule` reaches `_settle` on an adapter-naming challenge with gas at or above the slash terms but below the demotion-extended floor
- **THEN** it reverts `InsufficientSlashGas` before any state moves — the conviction cannot land on a budget that cannot also afford the demotion

#### Scenario: A settle that clears the extended floor lands the demotion
- **WHEN** an adapter-naming challenge settles with the demoter role intact and gas exactly at the extended floor
- **THEN** the demotion succeeds — no `AdapterDemotionFailed` is emitted and the adapter's certification is revoked

#### Scenario: No-adapter filings pay no demotion term
- **WHEN** a challenge naming the zero adapter settles with gas at or above the slash-only floor
- **THEN** the floor passes and the settle completes, demoting nothing

### Requirement: Adapter demotion is best-effort on a passed challenge only
A passed challenge naming a non-zero adapter SHALL attempt `tierRegistry.demoteByChallenge(target, selector)` inside a `try/catch`: a registry refusal (e.g. the game's demoter role was rotated away mid-challenge) MUST NOT revert the verdict — the slash, bond refund, and freeze release proceed, and the miss is surfaced as `AdapterDemotionFailed`. The catch exists for REGISTRY-SIDE refusals, which no caller selects at call time; the caller-selectable failure axis — the gas budget — is refused up front by the demotion-extended slash gas floor, so `AdapterDemotionFailed` can no longer be induced by dialling gas. The catch SHALL remain bare (no selector filter): every reachable failure behind the floor is registry-side, and bubbling any of them would re-open the permanent wedge the best-effort design exists to prevent (a revoked role stranding the bond, the freeze, and the accused's unstake path forever). The game's registry surface SHALL be demote-only (`ITierRegistryDemoterMinimal`): it can revoke a certification on a passed challenge and never grant one. No demotion occurs on any non-settled outcome.

#### Scenario: Rotated demoter role does not strand the verdict
- **WHEN** `demoteByChallenge` reverts during settle
- **THEN** `AdapterDemotionFailed` is emitted and the settlement completes; the registry owner's own `demote` is the remedy

### Requirement: Fail path — forfeit split pro-rata to contribution, net of the forfeit burn
`_fail` (reached from the dispute timeout or a `NotGuilty` ruling — the two settle identically, since both say the defence was right) SHALL mark the status `Failed`, release the freeze hold, burn `forfeitBurnBpsAtFiling` of the challenger's bond to `0x…dEaD` (taken off the top, before the split), and book the remainder plus the whole pool as pull-claimable: each contributor is owed its stake back plus a slice of the net forfeit pro-rata to its CONTRIBUTION (never to coverage share — a non-contributing accused approver collects nothing). `ChallengeFailed(challengeId, forfeitedWood, burnedWood)` SHALL report gross forfeit and burned slice separately. On the defensive empty-pool branch (unreachable from `Disputed` in the current reachable set) the bond SHALL return to the challenger intact with no burn and `ChallengeFailed(id, 0, 0)`.

#### Scenario: Failed challenge pays the funders, not the cohort
- **WHEN** a disputed challenge fails (timeout or `NotGuilty`) with contributors A (75%) and B (25%) having funded the pool
- **THEN** A can claim its stake plus 75% of `bond - burn` and B its stake plus 25%; accused approvers that contributed nothing collect nothing

#### Scenario: Forfeit burn prices the self-challenge round trip
- **WHEN** a challenge fails with `forfeitBurnBpsAtFiling` of 2,000
- **THEN** 20% of the forfeited bond is destroyed before the pro-rata split, so an operator that filed against itself and funded its own pool loses that slice with no reachable beneficiary

### Requirement: Inconclusive unwind — non-verdict, escalating burn, re-armed window
An `Inconclusive` ruling (the court's vote missed its participation floor) SHALL unwind both sides: status `Inconclusive`, freeze hold released, NO slash, NO adapter demotion, NO convicted flag — the proposal is immediately re-challengeable. The pool SHALL be booked for pull-refund untouched. The challenger's bond SHALL be returned minus a burn at the PINNED `inconclusiveBurnBpsAtFiling`, computed at filing from the proposal's prior `Inconclusive` round count: round 1 free (0 bps), round 2 = 500 bps, round 3 = 1,000 bps, round 4+ = the live `inconclusiveBurnBps` (default 2,000) — every tier additionally clamped to the live `settleBurnBps` at computation time, so a non-verdict never costs more than a verdict that recovered value. On each unwind of a not-yet-convicted proposal the game SHALL raise `challengeableUntil[reviewKey]` to at least `block.timestamp + challengeWindow` (extend, never shorten — a stall buys delay, never a permanent acquittal) and increment `inconclusiveRounds[reviewKey]`. `file` SHALL reset the round counter to zero when the re-armed window has lapsed with nobody refiling inside it. The counter is keyed per proposal, not per challenger, so a sybil cannot reset the escalation. `ChallengeInconclusive(id, bondWood, poolWood)` reports the GROSS bond; the burned slice is reported separately via `ChallengerBondBurned`.

#### Scenario: First inconclusive round is free
- **WHEN** a proposal's first-ever challenge is ruled `Inconclusive`
- **THEN** the challenger's bond returns whole (pinned rate 0), the pool is refundable to its contributors, and the proposal's challenge window is re-armed to `block.timestamp + challengeWindow`

#### Scenario: Repeated grinding escalates the burn
- **WHEN** a fourth consecutive challenge against the same proposal (three prior `Inconclusive` rounds, streak unbroken) is filed and later unwinds `Inconclusive`
- **THEN** its pinned burn rate was the round-4+ `inconclusiveBurnBps` (clamped to live `settleBurnBps`), and that slice of the bond is burned

#### Scenario: Lapsed streak resets the schedule
- **WHEN** the re-armed window lapses with no refiling and a legitimate filing later becomes possible again
- **THEN** `inconclusiveRounds` is reset to zero and the new filing is priced as round 1

### Requirement: Counter-bond payouts are pull, not push
Contributor payouts SHALL be pull-based via `claimContribution(challengeId)`: resolution stores totals (`forfeitPayoutWood` on the fail path) and each claimant computes its own O(1) share on the way out, so list length is irrelevant and one reverting recipient can never brick a resolution. Claims SHALL revert `ChallengeNotTerminal` before the challenge is terminal and `NothingToClaim` when nothing is owed. `claimableContribution` SHALL return: on `Failed`, stake plus the pro-rata forfeit slice; on `Settled` with a COMPLETE pool (the guilty-ruling case), zero — the pool forfeited to the challenger; on `Settled` with a partial pool, stake back; on `Inconclusive`, stake back; zero while live. The entitlement SHALL be zeroed before transfer (single-shot, re-entrancy-safe). Floor-division dust (up to `contributors - 1` wei per failed challenge) remains in the contract, covered by `unclaimedWood`.

#### Scenario: Guilty ruling leaves funders nothing to claim
- **WHEN** a contributor calls `claimContribution` on a challenge the court ruled `Guilty`
- **THEN** the call reverts `NothingToClaim` — the complete pool forfeited to the challenger

#### Scenario: Double claim refused
- **WHEN** a contributor claims a second time on the same terminal challenge
- **THEN** the call reverts `NothingToClaim`

### Requirement: WOOD custody invariant
The game SHALL track `bondedWood` (bonds plus pool contributions of LIVE challenges; every terminal path decrements exactly `bond + pool`) and `unclaimedWood` (booked but uncollected contributor entitlements of TERMINAL challenges) separately, maintaining `wood.balanceOf(game) >= bondedWood + unclaimedWood` at all times, with "no live challenge implies `bondedWood == 0`". WOOD requires standard ERC20 semantics (no fee-on-transfer, no rebase, no hooks); donated surplus is never spent by any path.

#### Scenario: Terminal accounting balances to the wei
- **WHEN** any challenge reaches a terminal state
- **THEN** `bondedWood` decreases by exactly that challenge's `bond + pool`, and every wei of it is either transferred out (challenger payout, burn) or moved into `unclaimedWood`

### Requirement: Parameter governance with enforced orderings
Owner setters SHALL enforce: `challengeWindow` non-zero and never above the wired ledger's own `challengeWindow` (read live); `challengerBondBps` in (0, 10_000] — zero would make the freeze free; `forfeitBurnBps` in [0, 5_000] (`MAX_FORFEIT_BURN_BPS`; zero is the off-switch); `autoSlashDelay` in [`MIN_AUTO_SLASH_DELAY` = 2 days, `disputeTimeout - MIN_SETTLE_WINDOW`]; `disputeTimeout` in [`autoSlashDelay + MIN_SETTLE_WINDOW`, `MAX_DISPUTE_TIMEOUT` = 60 days] - `MIN_SETTLE_WINDOW` = 1 day floors the settle window `[autoSlashDelay, disputeTimeout)` in BOTH setters regardless of court wiring, because the dispute timeout is now the hard end of slashability and an owner could otherwise make every later un-backed filing effectively unconvictable with no court wired (`_requireWindowFits` is vacuous then); `settleBurnBps` in [0, 5_000] AND not below the live `inconclusiveBurnBps`; `inconclusiveBurnBps` in [0, 5_000] AND not above the live `settleBurnBps` (the two setters cross-check each other's LIVE value — a shared ceiling alone does not preserve the ordering); `convictionBountyBps` requires `stakedWood` wired first and not above the slasher's live `MAX_CONVICTION_BOUNTY_BPS`. `setAutoSlashDelay`, `setDisputeTimeout`, and `setCourt` (for a non-zero court) SHALL additionally enforce the cross-contract window invariant `autoSlashDelay + court.voteWindow() + court.FINALIZE_BUFFER() <= disputeTimeout` (revert `WindowInvariantViolated`), with `setCourt` validating the NEW address about to become live; the check is vacuous with no court wired. Rounds 2/3 of the inconclusive schedule are fixed constants (500/1,000 bps) outside the setter pair, guarded only by the live clamp at rate computation.

#### Scenario: Burn ordering cannot be inverted
- **WHEN** the owner tries `setSettleBurnBps` below the live `inconclusiveBurnBps`, or `setInconclusiveBurnBps` above the live `settleBurnBps`
- **THEN** the call reverts `InvalidParameter` from either side

#### Scenario: Re-wiring a court cannot bypass the window invariant
- **WHEN** the owner unwires the court, sets clocks that only pass vacuously, then calls `setCourt` with a real court those clocks violate
- **THEN** `setCourt` reverts `WindowInvariantViolated` against the new court's own `voteWindow`/`FINALIZE_BUFFER`

### Requirement: Cross-contract wiring and roles
The game SHALL be plain `Ownable2Step` (not upgradeable). It requires three externally granted roles: the exposure ledger's `coverageFreezer`, the tier registry's `authorizedDemoter`, and sWOOD's `authorizedSlasher`. `wood`, `exposureLedger`, and `tierRegistry` are constructor-set (zero addresses revert); `stakedWood` SHALL be owner-set AFTER construction via `setStakedWood`, because the slasher role is granted on sWOOD's side and the two contracts are wired in either order at deploy time — until wired, `_settle` fail-closes with `ZeroAddress` and no challenge can settle. `setStakedWood` SHALL revalidate the live `convictionBountyBps` against the new slasher's `MAX_CONVICTION_BOUNTY_BPS`; `setExposureLedger` SHALL revalidate `challengeWindow` against the new ledger's window. `setCourt(address(0))` SHALL be permitted — it is the governance off-switch that returns disputes to the fail-safe timeout — and `rule` reads the LIVE `court` deliberately, so a replaced court can still rule pending disputes. The game names no sink: slash proceeds burn inside sWOOD, so there is nothing for the game to redirect.

#### Scenario: Settling before the slasher is wired fails closed
- **WHEN** `resolve` reaches the settle path while `stakedWood` is unset
- **THEN** the call reverts `ZeroAddress`, and wiring the slasher later makes the same challenge resolvable

#### Scenario: Unwiring the court restores the fail-safe
- **WHEN** governance calls `setCourt(address(0))` with disputes open
- **THEN** `rule` becomes unreachable and every open dispute can only terminate via the timeout acquittal

### Requirement: Proposer bond lock, release, and forfeiture
`ProposerBondEscrow` SHALL be ownerless with no discretionary exit — exactly two exits exist, release and forfeiture, and both are keyed rather than caller-directed. `lockBond(proposalId, proposer, amount)` SHALL be callable only by a registry-authorized governor (`NotAuthorizedGovernor`), with a non-zero proposer, `amount <= type(uint96).max` (`AmountTooLarge`), and at most one bond per `(governor, proposalId)` key (`BondAlreadyLocked`); the WOOD is pulled from the named proposer. `releaseBond(proposalId)` SHALL key the bond to `msg.sender` (so only the governor that locked it can address it) and deliberately SKIP the live registry check — a later-deauthorized governor can still release open bonds to the recorded proposer rather than stranding them; the payout always goes to the recorded proposer, never a caller-chosen payee. `bondOf(governor, proposalId)` SHALL report the recorded proposer and amount.

`forfeitBond(governor, proposalId, feeTo, feeBps)` SHALL be callable only by the live `coverageFreezer` of the wired exposure ledger — the challenge game and nothing else (`NotAuthorizedConvictor`) — fail-closed when the freezer is unset. It SHALL reject `feeBps > MAX_PROSECUTOR_FEE_BPS` (`FeeBpsTooHigh`, revert not clamp) and SHALL delete the bond record before transferring (so a second forfeit on the same key hits `NoBond` rather than double-burning). The prosecutor's fee — `feeBps` of the bond, paid to `feeTo` — comes off the top; the remainder SHALL burn to `BURN_ADDRESS` with no other payee (every alternative destination is a round trip back to the party that forfeited or to whoever governs). `ChallengeGame._settle` SHALL call `forfeitBond` best-effort (wrapped in try/catch, emitting `ProposerBondForfeited` on success or `ProposerBondForfeitureFailed` on revert) exactly once per proposal, inside the `_convicted` branch, so a proposal with one liability and one bond cannot have it taken twice by concurrent challenges.

The governor gates WHEN release is legal, not the escrow: `SyndicateGovernor.reclaimProposerBond` requires the proposal in a terminal state (`Rejected`/`Expired`/`Cancelled`/`Settled`), and for an EXECUTED proposal additionally requires ALL of the following, reverting `ChallengeWindowOpen` otherwise and `ExposureLedgerUnset` (fail-closed) when no ledger is resolvable:

1. `block.timestamp >= executedAt + ledgerChallengeWindow` (the ledger's window);
2. coverage not currently frozen for that proposal (an open, unresolved challenge);
3. when the ledger's `coverageFreezer` is a non-zero address, the game's LIVE filing deadline has lapsed: `block.timestamp > max(executedAt + gameChallengeWindow, challengeableUntil[reviewKey])`, read from the freezer with the same review-key derivation the game uses (`keccak256(abi.encode(governor, proposalId))`). The comparison MUST be strict (`>`), mirroring `file`'s admissibility bound (`block.timestamp <= deadline`), so there is no instant at which a filing is still admissible and the bond is simultaneously reclaimable.

THE LEDGER THESE GATES READ SHALL BE THE ONE RECORDED ON THE PROPOSAL AT PROPOSE TIME — the ledger that priced and gated the bond — not the governor's live, re-pointable exposure-ledger slot. Adversary: a vault owner (who may be the proposer, or colluding with it) who has the factory re-point the governor's ledger at a permissive one (zero `coverageFreezer`, collapsed window) after the proposal settles — the open-proposal guard on re-pointing no longer holds then, and under live reads one re-point would detach all three gates from a still-convictable challenge for as long as the configured `disputeTimeout` allows (up to 60 days). Re-pointing the governor's live ledger slot MUST NOT alter the reclaim gates of any proposal whose bond is already locked. A proposal recorded before ledger pinning existed (zero recorded ledger, non-zero bond) SHALL fall back to the live slot, preserving its pre-pin behavior including the `ExposureLedgerUnset` fail-closed path.

A FORFEITED BOND SHALL BE A DISTINGUISHABLE, TERMINAL OUTCOME AT RECLAIM, not a permanent indistinguishable revert. When the governor still records a non-zero bond but the escrow recorded on the proposal reports none for `(governor, proposalId)`, the bond was forfeited by a conviction (forfeiture and reclaim-release are the only record-deleting exits, and reclaim-release zeroes the governor's record in the same transaction) — `reclaimProposerBond` SHALL zero the recorded bond amount, emit `ProposerBondForfeitureAcknowledged(proposalId, amount)`, and return without transferring, before evaluating the challenge-window gates (a nonexistent bond has no window to wait out). A subsequent call SHALL revert `NoBondToReclaim`, the same terminal answer as after an ordinary release.

Gate 3 SHALL be skipped entirely when `coverageFreezer` is the zero address: with no freezer wired, no challenge can freeze coverage and no convictor can reach `forfeitBond`, so no conviction is reachable and gates 1-2 remain a sufficient hold — an unwired or rotated-away freezer MUST NOT strand honest proposers' bonds. For an unchallenged proposal `challengeableUntil[reviewKey]` is zero (an untouched key), so gate 3 reduces to the game's ordinary window and reclaim proceeds on the same schedule as before whenever the game's window does not exceed the ledger's (which the game's own setters enforce). A non-zero freezer whose views revert or cannot be decoded fails closed; a freezer that ANSWERS zero passes (a genuine `ChallengeGame` never answers zero for `challengeWindow` — its setter rejects it — so a zero answer can only come from a non-genuine freezer; whether that asymmetry should also fail closed is tracked as an open decision in this change's design.md and is NOT changed here). A bond therefore cannot be reclaimed while it could still be forfeited: the filing deadline — including any `challengeableUntil` extension re-armed by an `Inconclusive` unwind — and any live freeze both block reclaim, and no owner-side re-point can lift that hold.

#### Scenario: Double lock refused
- **WHEN** a governor locks a bond for a proposal that already has one
- **THEN** the call reverts `BondAlreadyLocked`

#### Scenario: Deauthorized governor can still release
- **WHEN** a governor that locked a bond is later removed from the registry and calls `releaseBond`
- **THEN** the bond is deleted and paid to the recorded proposer; a random caller for the same proposalId hits `NoBond` (its key differs)

#### Scenario: Convicted proposal forfeits its bond
- **WHEN** `ChallengeGame._settle` reaches a `_convicted` verdict for a proposal with a non-zero locked bond
- **THEN** the escrow pays the pinned prosecutor fee to the challenger, burns the remainder to `BURN_ADDRESS`, deletes the record, and `ProposerBondForfeited` is emitted; the proposer can never reclaim it

#### Scenario: Forfeiture failure does not block settlement
- **WHEN** `forfeitBond` reverts during `_settle` (e.g. the bond was already reclaimed, or the escrow is re-pointed)
- **THEN** settlement continues — the slash, challenger payout, and coverage unfreeze all still complete — and `ProposerBondForfeitureFailed` is emitted instead

#### Scenario: Reclaim refused while the challenge window is open
- **WHEN** an executed proposal's proposer calls `reclaimProposerBond` before `executedAt + challengeWindow` has elapsed
- **THEN** the call reverts `ChallengeWindowOpen`

#### Scenario: Reclaim refused while coverage is still frozen
- **WHEN** the challenge window has elapsed but the proposal's coverage is still frozen (an unresolved dispute)
- **THEN** `reclaimProposerBond` reverts `ChallengeWindowOpen`

#### Scenario: Reclaim refused while an Inconclusive re-arm keeps filing admissible
- **WHEN** a challenge against an executed proposal unwinds `Inconclusive` after `executedAt + challengeWindow` (releasing the freeze and re-arming `challengeableUntil[reviewKey]` to `block.timestamp + challengeWindow`), and the proposer calls `reclaimProposerBond` while `block.timestamp <= challengeableUntil[reviewKey]`
- **THEN** the call reverts `ChallengeWindowOpen`, and a challenge filed inside the re-armed window that reaches a conviction finds the bond still in escrow — `forfeitBond` succeeds, paying the prosecutor fee and burning the remainder

#### Scenario: Reclaim opens the instant the re-armed deadline lapses
- **WHEN** the re-armed `challengeableUntil[reviewKey]` passes with no live challenge and no further filing
- **THEN** `reclaimProposerBond` succeeds at the first timestamp strictly greater than the deadline (where `file` would revert `WindowClosed`)

#### Scenario: Unchallenged proposal reclaims on the ordinary schedule
- **WHEN** an executed proposal is never challenged (its `challengeableUntil[reviewKey]` is zero) and both windows have elapsed since `executedAt`
- **THEN** `reclaimProposerBond` succeeds — the new gate never delays a reclaim beyond `executedAt + max(ledger window, game window)` for an unchallenged proposal

#### Scenario: Unset coverage freezer does not strand the bond
- **WHEN** the exposure ledger's `coverageFreezer` is the zero address (unwired, or rotated away after live freezes drained) and an executed proposal's ledger window has elapsed with no freeze
- **THEN** `reclaimProposerBond` succeeds without consulting any game — no conviction is reachable without a freezer, so nothing is being given up

#### Scenario: Unauthorized forfeiture attempt refused
- **WHEN** an address other than the wired ledger's live `coverageFreezer` calls `forfeitBond`
- **THEN** the call reverts `NotAuthorizedConvictor` and the bond is untouched

#### Scenario: Re-pointing the governor's ledger cannot detach the reclaim gates
- **WHEN** a proposal with a locked bond settles, a challenge against it is still live or still admissible, and the factory re-points the governor's exposure ledger at a permissive ledger with no `coverageFreezer` and a collapsed window
- **THEN** `reclaimProposerBond` still evaluates every gate against the ledger recorded on the proposal at propose time and reverts `ChallengeWindowOpen` — the re-point changes nothing for the locked bond, and a conviction reached inside the window still finds the bond in escrow

#### Scenario: Forfeited bond reclaim acknowledges instead of reverting forever
- **WHEN** a conviction has forfeited a proposal's bond and any caller later invokes `reclaimProposerBond` for it
- **THEN** the call succeeds without transferring: the governor zeroes its recorded bond amount, emits `ProposerBondForfeitureAcknowledged(proposalId, amount)`, and a retrying integration observes a terminal success rather than an indefinite `ChallengeWindowOpen`/`NoBond` revert; a second call reverts `NoBondToReclaim`, and readers of the recorded bond amount see zero

#### Scenario: Pre-pin proposal falls back to the live ledger
- **WHEN** a proposal recorded before ledger pinning existed (zero recorded ledger, non-zero bond) reaches `reclaimProposerBond` in a terminal state after execution
- **THEN** the gates read the governor's live exposure-ledger slot exactly as before this change, including reverting `ExposureLedgerUnset` when that slot is zero

