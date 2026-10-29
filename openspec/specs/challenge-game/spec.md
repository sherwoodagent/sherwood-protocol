# Challenge Game Specification

## Purpose

The challenge trigger of the guardian economic-security model: anyone may post a bonded challenge against an executed proposal, freezing the coverage its approvers committed; silence convicts once anyone calls `resolve` before the dispute timeout, a counter-bond pool completed in time escalates the challenge to the token court, and convictions execute through the slash rails, burning each convicted approver's lock (never less than sWOOD's `minSlashBps` of its stake), the completed counter-bond pool, and the proposer's bond less the prosecutor fee. Depositors are not compensated. Covers `ChallengeGame` and `ProposerBondEscrow`.
## Requirements
### Requirement: Filing a bonded challenge
`ChallengeGame.file(governor, proposalId, predicate, adapterTarget, adapterSelector, evidenceURI)` SHALL be permissionless and SHALL accept a filing only against an EXECUTED proposal (`executedAt != 0`, read from the governor; otherwise revert `NotExecuted`), and only while `block.timestamp <= max(executedAt + strategyDuration + challengeWindow, challengeableUntil[reviewKey])` (otherwise revert `WindowClosed`), with `strategyDuration` read from the same `getProposal` call. The deadline MUST be recomputed as a max against the live `executedAt + strategyDuration + challengeWindow` baseline on every call, never read as a stored absolute, so the window can only ever extend, never shorten. The cited predicate (one of `OutOfAdapterOutflow`, `OraclePriceDeviation`, `ProposerLinkedOutflow`, `RogueAllowance`, `DrawdownBreach`) SHALL be a classification label only — recorded and emitted in `ChallengeFiled` but branching no logic; there is no on-chain predicate verification. `evidenceURI` SHALL be carried unindexed in `ChallengeFiled` as the off-chain evidence anchor. The review key SHALL be `keccak256(abi.encode(governor, proposalId))`, matching the ledger and registry derivation.

#### Scenario: Filing against an executed proposal inside the window
- **WHEN** a caller files against a proposal with non-zero `executedAt`, within the window, with a valid bond
- **THEN** a new challenge is created in status `Filed` with `filedAt = block.timestamp`, the bond is pulled via `safeTransferFrom`, and `ChallengeFiled` is emitted with the challenger, predicate, bond, and evidence URI

#### Scenario: Unexecuted proposal refused
- **WHEN** `file` is called for a proposal whose `executedAt` is zero
- **THEN** the call reverts `NotExecuted`

#### Scenario: Window closed
- **WHEN** `block.timestamp` exceeds both `executedAt + strategyDuration + challengeWindow` and the proposal's `challengeableUntil` extension
- **THEN** the call reverts `WindowClosed`

### Requirement: Filings pause is the owner's only lever, and gates `file` alone
The owner SHALL be able to set `filingsPaused` via `setFilingsPaused(bool)`. While true, `file` SHALL revert `FilingsPaused` before any other check. The flag MUST NOT be read by `dispute`, `resolve`, `rule`, `claimContribution`, or any other path — the owner can stop a NEW challenge from starting but can never freeze or re-price one already in flight.

#### Scenario: Paused filings refuse new challenges only
- **WHEN** `filingsPaused` is true and a caller invokes `file`
- **THEN** the call reverts `FilingsPaused`
- **AND** `dispute`, `resolve`, `rule`, and both claim paths on existing challenges proceed unaffected

### Requirement: Challenger bond sized to the coverage the filing freezes
The bond SHALL be `coverageUsd * challengerBondBps / 10_000`, converted to WOOD at the ledger's composed haircut price `woodPriceX8()` (the market feed capped by the owner's `woodUsdPriceX8`, then haircut; the owner scalar is never served as the price). `coverageUsd` SHALL be the ledger's `unsharedLiabilityUsd` for the proposal (the same figure as `liabilityUsd`): the approvers' WOOD locks, each capped at its slashable stake at the proposal's `executedAt` and priced at `woodPriceX8()`, summed and then capped at the proposal's priced need, so a cohort that over-subscribes a proposal cannot inflate the bond a challenger must post. The liability read SHALL NOT be wrapped so as to fall back to an uncapped sum: when it reverts (the ledger cannot price WOOD or the vault asset) the filing waits. Filing SHALL fail closed: revert `NothingToFreeze` when the approvers' WOOD locks (`pledgedOf`) sum to zero, `WoodPriceUnset` when the liability read reverts or the composed price is zero (transient, protocol-wide), and `BondTooSmall` when the bond floors to zero (permanent, proposal-specific) — the two price failures MUST be distinct errors.

#### Scenario: Bond computed from capped coverage at the composed price
- **WHEN** the approvers' locks, priced at `woodPriceX8()`, sum above the proposal's priced need
- **THEN** the bond is priced against the need (the cap binds bond sizing only; a conviction still burns every full lock), at `challengerBondBps` (default 150, i.e. 1.5%) of that value, converted at `woodPriceX8()`

#### Scenario: Unpriced WOOD blocks filing
- **WHEN** the ledger cannot price WOOD (`woodPriceX8()` reverts `NoWoodPrice`, so the `unsharedLiabilityUsd` read reverts)
- **THEN** `file` reverts `WoodPriceUnset`

#### Scenario: Zero-coverage proposal cannot be challenged
- **WHEN** every approver lock for the proposal has been released (the `pledgedOf` WOOD sum is zero)
- **THEN** `file` reverts `NothingToFreeze`

### Requirement: Filing freezes coverage, refcounted across concurrent challenges
Filing SHALL freeze the proposal's committed coverage on the exposure ledger (per-proposal, never the guardian's whole stake). EVERY filing SHALL call `freezeCoverage(governor, proposalId, block.timestamp + disputeTimeout)`: the ledger's frozen flag flips only once (the call is idempotent), but each call carries that filing's own worst-case end as `liveUntil`, so the approvers' locks keep counting until the latest one. The UNFREEZE MUST be refcounted per proposal: only the termination of the LAST live challenge calls `unfreezeCoverage`, so a terminating challenge never unfreezes coverage that concurrent filings still pin. The refcount decrement SHALL be defensive against underflow (a rewired ledger must not produce a permanent freeze). `liveChallengeCountOf` SHALL report the live count; non-zero is exactly the condition under which coverage stays frozen.

#### Scenario: Second filing re-pins, does not double-freeze
- **WHEN** two challengers file against the same proposal
- **THEN** `freezeCoverage` is called on both filings, the frozen flag is set once, each call carries its own `liveUntil`, and the live count is 2

#### Scenario: Last termination unfreezes
- **WHEN** one of two live challenges reaches a terminal state
- **THEN** coverage remains frozen until the second also terminates, at which point `unfreezeCoverage` is called once

### Requirement: The challenger names the accused adapter, checked for membership
The filer SHALL name the adapter it accuses (`adapterTarget`, `adapterSelector`); the chain MUST NOT derive it. The zero address SHALL mean the filing accuses no adapter (and demotes nothing). A non-zero `adapterTarget` MUST appear, with its selector, among the challenged proposal's own stored execute calls or settlement calls (coverage prices both legs; calls with fewer than 4 bytes of data are skipped, never treated as wildcards); otherwise `file` SHALL revert `AdapterNotInProposal`. This is a membership test over data the governor holds, not a second calldata parser.

#### Scenario: Adapter outside the proposal refused
- **WHEN** a filing names a certified adapter `(target, selector)` that does not appear in the proposal's execute or settlement calls
- **THEN** `file` reverts `AdapterNotInProposal`

#### Scenario: No-adapter filing
- **WHEN** a filing passes the zero address as `adapterTarget`
- **THEN** the filing is accepted and no demotion occurs on any outcome

### Requirement: One live challenge per challenger; convicted proposals unchallengeable
Live-challenge slots SHALL be keyed per `(reviewKey, challenger)`: a challenger with a live (`Filed`/`Disputed`) challenge against the proposal SHALL be refused with `AlreadyChallenged`, but a squatting challenge never blocks a different honest filer. Once any settled challenge has collected the proposal's one liability (`_convicted`, or sWOOD's `verdictSlashed` for any accused approver, which survives a redeploy of the game), ALL further filings against that proposal SHALL revert `AlreadyConvicted` — a filing that cannot convict would only buy another freeze on already-slashed collateral. A FAILED challenge does not set the convicted flag, so a fresh filing after a failure remains legitimate. Liveness views SHALL re-check status rather than trusting stored pointers (`liveChallengeOf`, `liveChallengeOfBy`).

#### Scenario: Same challenger, same proposal, second filing refused
- **WHEN** a challenger with a live challenge against a proposal files again
- **THEN** the call reverts `AlreadyChallenged`, while a different challenger may still file

#### Scenario: Filing against a convicted proposal refused
- **WHEN** an earlier challenge on the proposal has settled to a conviction
- **THEN** any later `file` against it reverts `AlreadyConvicted`

### Requirement: Economic terms and slash basis pinned at filing
Each challenge SHALL pin at filing: `autoSlashDelayAtFiling`, `disputeTimeoutAtFiling`, `settleBurnBpsAtFiling`, `forfeitBurnBpsAtFiling`, `prosecutorFeeBpsAtFiling`, `inconclusiveBurnBpsAtFiling` (the ladder value for the proposal's prior `Inconclusive` rounds plus its other live filings), `courtAtFiling` (the court wired at filing), plus the proposal's `executedAt`, `vault` and `proposerBondEscrow`. There is no conviction-bounty term: the bounty was replaced by the prosecutor fee. All clock checks and payout rates for that challenge MUST read the pinned values, never the live parameters — the owner can never retroactively shorten a window, extend a freeze, or re-price a challenge already running. The verdict slash basis SHALL be the pinned `executedAt` (with snapshot `executedAt - 1`), never `filedAt`, so an accused approver cannot zero its own stake checkpoint between drain and accusation.

#### Scenario: Owner parameter change does not move a live challenge
- **WHEN** the owner changes `autoSlashDelay`, `disputeTimeout`, any burn rate, or `prosecutorFeeBps` after a challenge is filed
- **THEN** that challenge's windows and payouts continue to use the values pinned at its filing; only challenges filed after the change use the new values

### Requirement: Counter-bond pool with open standing
`dispute(challengeId, amountWood)` SHALL accept contributions toward a `Filed` challenge's defence from ANY address (open standing — skin in the game is enforced economically: a `Guilty` ruling burns the whole pool), strictly before `filedAt + autoSlashDelayAtFiling` (otherwise `WindowClosed`; a terminal challenge, one its pool already backs, or a pool already burned or released reverts `WrongStatus`). The counter-bond pool SHALL be ONE PER PROPOSAL PER ROUND, keyed `(reviewKey, round)` and never per challenge, so N concurrent filings against one proposal are answered by one pool. Its target SHALL be the LARGEST live challenger bond on the proposal while the pool is incomplete, frozen once it completes, and MUST NOT scale with the payer's own share — pinning the TOTAL is what makes an identity split cost the same as staying whole, on both sides. A challenge filed after the pool completed buys its OWN defence at the same target (`defenceWeight`), paid into the same pool. Contributions SHALL be clamped to the remaining shortfall (no refund-of-excess path; a clamped-to-zero amount reverts `NothingToContribute`), recorded per contributor per pool without list duplicates, and emitted per contribution (`CounterBondContributed`).

#### Scenario: Contribution clamped to the shortfall
- **WHEN** a contributor sends `type(uint256).max` against a pool 10 WOOD short
- **THEN** exactly 10 WOOD is pulled, the pool completes, and no excess is ever held

#### Scenario: Contribution after the silence window refused
- **WHEN** `block.timestamp >= filedAt + autoSlashDelayAtFiling`
- **THEN** `dispute` reverts `WindowClosed` — at that instant the silence verdict is already final

### Requirement: Pool completion disputes by derivation and best-effort refers to the court
The contribution that brings the pool to its target SHALL record the completion on the POOL (`completedAt`, and `completedThroughId` = the challenge count at that instant) and emit `ChallengeDisputed` once. `Disputed` is derived, never stored: a live challenge reads as `Disputed` (in `challengeOf`, and to `resolve` and `rule`) when the pool completed inside that challenge's own silence window and the challenge had been filed by then, or when its own defence completed — so one contribution disputes every such live challenge on the proposal without a loop. `Filed` therefore implies an incomplete defence and `Disputed` a complete one. When the challenge paid through pinned a court at filing and a court is still wired, the completing call SHALL then attempt `refer(challengeId)` on the pinned court inside a deliberately BROAD `try/catch` with no gas floor — a revert here would deny the accused their defence, which is unrecoverable, while a skipped referral is recoverable because `refer` is permissionless (and is how the other challenges the same completion disputed reach the court). A swallowed referral failure SHALL emit `AutoReferFailed`. With no court pinned at filing, no referral is attempted, `TokenCourt.refer` refuses the challenge (`ChallengeNotRulable`), and the dispute timeout is the only exit from `Disputed`.

#### Scenario: Completing contribution escalates
- **WHEN** a contribution completes the pool
- **THEN** every live challenge on the proposal whose silence window contains that instant reads `Disputed`, the auto-slash clock stops mattering for them, `ChallengeDisputed` is emitted, and (with a court pinned at filing and still wired) `refer` is attempted for the challenge paid through, in the same transaction

#### Scenario: Failed auto-referral does not fail the dispute
- **WHEN** the wired court's `refer` reverts during the completing `dispute` call
- **THEN** the dispute itself still lands (status `Disputed`, transfer cleared) and `AutoReferFailed` is emitted; anyone may retry `refer` directly

### Requirement: Silence is the verdict — permissionless timeout resolution
`resolve(challengeId)` SHALL be permissionless and choose nothing: from `Filed` at or after `filedAt + autoSlashDelayAtFiling` and before `filedAt + disputeTimeoutAtFiling` it SHALL settle the challenge (the silence IS the adjudication); from `Filed` at or after `filedAt + disputeTimeoutAtFiling` (a STALE filing nobody settled inside its window) it SHALL unwind the challenge through the `Inconclusive` path — nothing slashed, the freeze released, the bond returned net of the round's inconclusive burn, any part-funded pool released to its funders once no other challenge on the proposal is live; from `Disputed` at or after `filedAt + disputeTimeoutAtFiling` it SHALL fail the challenge (`_fail`: the bond forfeits to the pool's funders and the re-challenge window re-arms) when a court was pinned at filing, and unwind it as `Inconclusive` when none was (no ruling was ever possible, so the timeout says nothing about the accused). Before the respective clock it SHALL revert `DelayNotElapsed`; from any terminal status, `WrongStatus`. `filedAt + disputeTimeoutAtFiling` is therefore the HARD END OF SLASHABILITY for a filing: it is the same value `file` books on the ledger as `liveUntil`, and no path may convict on that filing from that instant on. THIS IS A CHANGE TO THE CHALLENGER'S LIVENESS BURDEN: a valid, undisputed filing that nobody `resolve`s inside `[filedAt + autoSlashDelayAtFiling, filedAt + disputeTimeoutAtFiling)` (23 days at defaults) no longer convicts - it unwinds as `Inconclusive` and the challenger's bond is burned at the round's escalating rate. `resolve` is permissionless, so the challenger (or any keeper acting for it) SHALL settle inside that window or eat the round burn; the escalation schedule itself is SHE-247's subject.

#### Scenario: Undisputed challenge auto-settles
- **WHEN** a challenge is still `Filed` and `autoSlashDelayAtFiling` has elapsed since filing, and `disputeTimeoutAtFiling` has not
- **THEN** any caller's `resolve` executes the conviction path (slash, demotion, bond handling) and the challenge becomes `Settled`

#### Scenario: Stale undisputed challenge unwinds instead of settling
- **WHEN** a challenge is still `Filed` and `disputeTimeoutAtFiling` has elapsed since filing with nobody having settled it
- **THEN** any caller's `resolve` makes the challenge `Inconclusive`: no slash, coverage unfrozen, bond returned net of the inconclusive burn, the re-challenge window re-armed and pinned

#### Scenario: Slashability ends exactly at the ledger's liveUntil
- **WHEN** the latest live filing on a key has reached `filedAt + disputeTimeoutAtFiling` and nobody has resolved it
- **THEN** the key MAY still read as frozen (`hasFrozenCoverage`) until someone resolves, but neither `resolve` nor `rule` can slash it, so the ledger is correct to stop counting the lock in `openExposure` any time from that instant on (it keeps counting at least until then - the bucket containing `liveUntil` ages out no earlier than its end plus the ledger's `challengeWindow` - and MUST never stop earlier); with two concurrent filings the key stays slashable until the LATER filing's deadline and the earlier one going stale neither unfreezes it nor shortens that window

#### Scenario: Unruled dispute times out by its pinned court
- **WHEN** a challenge is `Disputed` and `disputeTimeoutAtFiling` has elapsed since filing with no ruling
- **THEN** any caller's `resolve` fails the challenge when a court was pinned at filing (the challenger's bond forfeits to the pool's funders net of the forfeit burn, and the re-challenge window re-arms), and unwinds it as `Inconclusive` when no court was pinned

### Requirement: Court ruling — three verdicts, ruling beats timeout
`rule(challengeId, verdict)` SHALL be callable only by the wired `court` (otherwise `NotCourt`; the zero-address court makes `rule` unreachable by construction), only on a `Disputed` challenge (otherwise `WrongStatus`), and only on a challenge that pinned a non-zero court at filing (otherwise `NotCourt`, whatever is wired later). The court supplies ONLY the verdict enum — there is no severity argument. `Guilty` SHALL take the identical settle path an undisputed challenge takes; `NotGuilty` SHALL take the timeout's fail payout but NOT its re-arm of the re-challenge window, because a court looked at the merits and cleared the accused; `Inconclusive` (deliberately the enum's zero value, so a defaulted verdict lands on the harmless unwind) SHALL unwind both sides. `ChallengeRuled` SHALL be emitted before the consequent accounting. All three outcomes are terminal, and `resolve` acts only on `Filed`/`Disputed`, so a ruling can never be overwritten by the clock — a guilty approver cannot dispute and run out `disputeTimeout` once a court is wired. The clock in turn beats a LATE ruling: at or after `filedAt + disputeTimeoutAtFiling`, `rule` SHALL revert `WindowClosed` for every verdict, checked after the status and court gates so a terminal challenge still reports `WrongStatus`. `TokenCourt.refer` already refuses a case whose vote plus `FINALIZE_BUFFER` would not fit inside that deadline, so an honest `finalize` always lands before it; a late `finalize` bubbles `WindowClosed` (the court swallows only `WrongStatus`), leaves the case in `Voting`, and closes through `WrongStatus` once `resolve` has timed the challenge out.

#### Scenario: Non-court caller refused
- **WHEN** any address other than `court` calls `rule`
- **THEN** the call reverts `NotCourt`, including every caller while `court` is the zero address, and the wired court itself on a challenge filed with no court pinned

#### Scenario: Ruling pre-empts the timeout
- **WHEN** the court rules `Guilty` before `disputeTimeoutAtFiling` elapses
- **THEN** the conviction executes and a later `resolve` reverts `WrongStatus`

#### Scenario: Late ruling refused
- **WHEN** the court calls `rule` with any verdict at or after `filedAt + disputeTimeoutAtFiling` on a still-live `Disputed` challenge
- **THEN** the call reverts `WindowClosed`, nothing is slashed, and `resolve` remains the only exit (failing the challenge: the forfeit goes to the pool's funders and the re-challenge window re-arms)

### Requirement: Settle path — conviction, slash burned in sWOOD, pool burned
`_settle` (reached from the silence path of `resolve` or a `Guilty` ruling) SHALL fail closed with `ZeroAddress` if `stakedWood` is unwired (recoverable: wiring the slasher makes every stuck challenge resolvable). It SHALL mark the status `Settled`, release this challenge's freeze hold, and — unless the proposal's liability was already collected (`_convicted`, or sWOOD's `verdictSlashed` for any accused approver), in which case it SHALL emit `VerdictAlreadyCollected` and slash, forfeit and demote nothing — set the convicted flag and execute the slash via `IStakedWood.slashVerdict(reviewKey, executedAt, approvers, slashBpsPer)` using the ledger's per-approver rates (`slashBpsFor`, filtered to non-zero entries so released approvers are not named in the conviction) and the pinned `executedAt` as basis; sWOOD clamps each rate into `[minSlashBps, maxSlashBps]`. There is no `contestors` array and no conviction bounty: `slashVerdict` takes no recipient and the slash burns inside sWOOD. Bond handling SHALL be identical on both entries: `settleBurnBpsAtFiling` of the challenger's bond is burned to `0x…dEaD` (`ChallengerBondBurned`), the remainder returns to the challenger, and the challenger is also paid the prosecutor fee out of the proposer's forfeited bond. The counter-bond pool SHALL be BURNED whole (`CounterBondPoolBurned`) when it backs this challenge — paying it to the challenger made the counter-bond a refundable deposit for a guilty cohort that self-files from a fresh address and adopts the honest challenge — and otherwise released to its funders once no other challenge on the proposal is live. `ChallengeSettled(challengeId, slashedWood)` SHALL be emitted, where `slashedWood` is what sWOOD burned.

#### Scenario: Silence conviction burns the settle slice
- **WHEN** an undisputed challenge settles by timeout
- **THEN** the accused approvers' locks are burned (each at least `minSlashBps` of its stake), the proposer's bond is forfeited, the named adapter demotion is attempted, `settleBurnBpsAtFiling` (default 500 bps) of the challenger's bond is burned, and the challenger receives the rest plus the prosecutor fee

#### Scenario: Escalated conviction burns the pool
- **WHEN** the court rules `Guilty` on a disputed challenge
- **THEN** the challenger receives the same payout as on the silence path (its bond less `settleBurnBpsAtFiling`, plus the prosecutor fee), and the complete counter-bond pool is burned (`CounterBondPoolBurned`), so its funders can claim nothing back

#### Scenario: Concurrent settle against an already-convicted proposal
- **WHEN** a second live challenge settles after another already collected the proposal's liability
- **THEN** no slash, proposer-bond forfeit or demotion is attempted, `VerdictAlreadyCollected` is emitted, and the challenge still terminates normally (settle-path bond and pool handling included)

### Requirement: No conviction bounty; the prosecutor fee is paid out of the proposer bond
v1 has no conviction bounty: `slashVerdict` takes no recipient and no bounty rate, and the slash pays no one. The prosecutor fee replaced it. On EVERY conviction, silence path included, `_settle` SHALL ask the escrow pinned at filing (`proposerBondEscrow`) to forfeit the proposer's bond with the challenger as fee recipient at the pinned `prosecutorFeeBpsAtFiling` (default 2,000 bps, owner-settable up to `MAX_PROSECUTOR_FEE_BPS` = 2,000, a ceiling the escrow enforces again), burning the rest. A reward funded from the slash is a pot the prosecutor could fill for itself by staking and approving the proposal it accuses; the proposer's bond cannot be self-funded, so a self-dealing filer recovers at most 20% of a bond it paid in full. If the escrow rejects the pinned rate, `_settle` SHALL retry at zero fee rather than lose the conviction.

#### Scenario: Self-staged contest earns no slice of the slash
- **WHEN** a `Guilty` ruling lands on a dispute whose pool was funded only by the challenger's own addresses
- **THEN** the slash pays no one, the pool is burned, and the challenger collects only its bond less `settleBurnBpsAtFiling` plus the prosecutor fee out of the proposer's bond

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
`_fail` (reached from a `NotGuilty` ruling, or from `resolve` on a `Disputed` challenge whose `disputeTimeoutAtFiling` elapsed with a court pinned at filing and no ruling) SHALL mark the status `Failed`, release the freeze hold, burn `forfeitBurnBpsAtFiling` of the challenger's bond to `0x…dEaD` (taken off the top, before the split), and book the remainder (`forfeitPayoutWood`) as pull-claimable by the pool's funders pro-rata to their CONTRIBUTION (never to coverage share — a non-contributing accused approver collects nothing), counting only contributions made before the failure. Several challenges can fail into one shared pool, each forfeiting its own bond into the same split. The funders' stake comes back when the pool is released, once no challenge on the proposal is live; a sibling conviction the same pool backs burns it instead. The timeout entry SHALL also re-arm the re-challenge window (a court was pinned but nothing adjudicated the merits); the `NotGuilty` entry SHALL NOT. `ChallengeFailed(challengeId, forfeitedWood, burnedWood)` SHALL report gross forfeit and burned slice separately. On the defensive empty-pool branch (unreachable, since a challenge only fails once its pool completed) the bond SHALL return to the challenger intact with no burn and `ChallengeFailed(id, 0, 0)`.

#### Scenario: Failed challenge pays the funders, not the cohort
- **WHEN** a disputed challenge fails (timeout or `NotGuilty`) with contributors A (75%) and B (25%) having funded the pool
- **THEN** A can claim 75% of `bond - burn` and B 25%, each plus its stake once the pool is released; accused approvers that contributed nothing collect nothing

#### Scenario: Forfeit burn prices the self-challenge round trip
- **WHEN** a challenge fails with `forfeitBurnBpsAtFiling` of 2,000
- **THEN** 20% of the forfeited bond is destroyed before the pro-rata split, so an operator that filed against itself and funded its own pool loses that slice with no reachable beneficiary

### Requirement: Inconclusive unwind — non-verdict, escalating burn, re-armed window
An `Inconclusive` unwind (a court verdict whose vote missed its participation floor; `resolve` on a `Filed` challenge nobody settled before `disputeTimeoutAtFiling`; or `resolve` on a timed-out `Disputed` challenge filed with no court pinned) SHALL unwind both sides: status `Inconclusive`, freeze hold released, NO slash, NO adapter demotion, NO convicted flag — the proposal is immediately re-challengeable. The pool SHALL be released whole to its funders for pull-refund once no other challenge on the proposal is live. The challenger's bond SHALL be returned minus a burn at the PINNED `inconclusiveBurnBpsAtFiling`, computed at filing from the proposal's prior `Inconclusive` rounds plus its other live filings: round 1 = 250 bps, round 2 = 500 bps, round 3 = 1,000 bps, round 4+ = the live `inconclusiveBurnBps` (default 1,000). No round is free: a free first round let a filer fund its own pool, miss quorum and freeze coverage for the cost of gas. Rounds 1–3 SHALL be clamped to the live `settleBurnBps` at computation time, so a few-attempt filer never pays more for a non-verdict than for a verdict; round 4+ SHALL NOT be clamped. At the deployed `settleBurnBps` of 500 the realised ladder is 2.5% / 5% / 5% / 10%. On each unwind of a not-yet-convicted proposal the game SHALL raise `challengeableUntil[reviewKey]` to at least `block.timestamp + challengeWindow` (extend, never shorten — a stall buys delay, never a permanent acquittal), pin the approvers' locks on the ledger until that deadline (`pinCoverageUntil`), and increment `inconclusiveRounds[reviewKey]`. `file` SHALL reset the round counter to zero when the re-armed `challengeableUntil[reviewKey]` has lapsed with nobody refiling inside it. The counter is keyed per proposal, not per challenger, so a sybil cannot reset the escalation. `ChallengeInconclusive(id, bondWood, poolWood)` reports the GROSS bond; the burned slice is reported separately via `ChallengerBondBurned`.

#### Scenario: First inconclusive round burns 2.5%
- **WHEN** a proposal's first-ever challenge, filed with no other live filing, is ruled `Inconclusive`
- **THEN** the challenger's bond returns less 250 bps (the pinned round-1 rate, below the live `settleBurnBps`), the pool is refundable to its contributors, and the proposal's challenge window is re-armed to `block.timestamp + challengeWindow`

#### Scenario: Repeated grinding escalates the burn
- **WHEN** a fourth consecutive challenge against the same proposal (three prior `Inconclusive` rounds, streak unbroken) is filed and later unwinds `Inconclusive`
- **THEN** its pinned burn rate was the round-4+ `inconclusiveBurnBps` (1,000 bps by default, not clamped to `settleBurnBps`), and that slice of the bond is burned

#### Scenario: Lapsed streak resets the schedule
- **WHEN** the re-armed window lapses with no refiling and a legitimate filing later becomes possible again
- **THEN** `inconclusiveRounds` is reset to zero and the new filing is priced as round 1

### Requirement: Counter-bond payouts are pull, not push
Contributor payouts SHALL be pull-based via `claimContribution(challengeId)`: resolution stores totals (`forfeitPayoutWood` on the fail path) and each claimant computes its own O(1) share on the way out, so list length is irrelevant and one reverting recipient can never brick a resolution. Claims SHALL revert `ChallengeNotTerminal` before the challenge is terminal and `NothingToClaim` when nothing is owed. `claimableContribution` SHALL return zero while the challenge is live and, once it is terminal, the sum of two independent entitlements: the contributor's STAKE, owed once per pool and only once the pool was released (no live challenge left on the proposal and no conviction backed by it); and, on `Failed`, its pro-rata slice of that challenge's forfeit, owed once per failed challenge and only for contributions made before the failure. A pool burned by a conviction returns no stake. Each entitlement SHALL be single-shot on its own flag (stake per pool, forfeit share per challenge), set before the transfer; the per-contributor weight is never cleared, because it is the pro-rata basis for every other challenge on the same pool. A later payment into the same pool by a funder already owed forfeit shares SHALL pay those shares out first. Floor-division dust (up to `contributors - 1` wei per failed challenge) remains in the contract, covered by `unclaimedWood`.

#### Scenario: Guilty ruling leaves funders nothing to claim
- **WHEN** a contributor calls `claimContribution` on a challenge the court ruled `Guilty`
- **THEN** the call reverts `NothingToClaim` — the complete pool was burned

#### Scenario: Double claim refused
- **WHEN** a contributor claims a second time on the same terminal challenge
- **THEN** the call reverts `NothingToClaim`

### Requirement: WOOD custody invariant
The game SHALL track `bondedWood` (bonds of LIVE challenges plus their OPEN pools; each terminal path decrements its own bond, and a pool's whole weight leaves exactly once, when a conviction burns it or the last live challenge releases it) and `unclaimedWood` (booked but uncollected contributor entitlements of TERMINAL challenges) separately, maintaining `wood.balanceOf(game) >= bondedWood + unclaimedWood` at all times, with "no live challenge implies `bondedWood == 0`". WOOD requires standard ERC20 semantics (no fee-on-transfer, no rebase, no hooks); donated surplus is never spent by any path.

#### Scenario: Terminal accounting balances to the wei
- **WHEN** any challenge reaches a terminal state
- **THEN** `bondedWood` decreases by exactly that challenge's bond, plus the pool's weight when that termination closes the pool, and every wei of it is either transferred out (challenger payout, burn) or moved into `unclaimedWood`

### Requirement: Parameter governance with enforced orderings
Owner setters SHALL enforce: `challengeWindow` non-zero and never above the wired ledger's own `challengeWindow` (read live); `challengerBondBps` in (0, 10_000] — zero would make the freeze free; `forfeitBurnBps` in [0, 5_000] (`MAX_FORFEIT_BURN_BPS`; zero is the off-switch); `autoSlashDelay` in [`MIN_AUTO_SLASH_DELAY` = 2 days, `disputeTimeout - MIN_SETTLE_WINDOW`]; `disputeTimeout` in [`autoSlashDelay + MIN_SETTLE_WINDOW`, `MAX_DISPUTE_TIMEOUT` = 60 days] - `MIN_SETTLE_WINDOW` = 1 day floors the settle window `[autoSlashDelay, disputeTimeout)` in BOTH setters regardless of court wiring, because the dispute timeout is now the hard end of slashability and an owner could otherwise make every later un-backed filing effectively unconvictable with no court wired (`_requireWindowFits` is vacuous then); `settleBurnBps` in [0, 5_000]; `inconclusiveBurnBps` in [0, 5_000] (`MAX_INCONCLUSIVE_BURN_BPS`, equal to the settle ceiling so a non-verdict can never be configured to cost more than the worst-case verdict) — the two setters do NOT cross-check each other's live values, because that coupling made the ladder's round-4+ tier collapse onto round 3's rate; `prosecutorFeeBps` in [0, `MAX_PROSECUTOR_FEE_BPS` = 2_000], a mirror of the escrow's own ceiling, which the escrow re-enforces when it pays (there is no `convictionBountyBps`). `setAutoSlashDelay`, `setDisputeTimeout`, and `setCourt` (for a non-zero court) SHALL additionally enforce the cross-contract window invariant `autoSlashDelay + court.voteWindow() + court.FINALIZE_BUFFER() + MIN_REFERRAL_SLACK <= disputeTimeout` (`MIN_REFERRAL_SLACK` = 1 hour; revert `WindowInvariantViolated`), with `setCourt` validating the NEW address about to become live; the check is vacuous with no court wired. Rounds 1–3 of the inconclusive schedule are fixed constants (250/500/1,000 bps) outside the setters, held at or below `settleBurnBps` only by the live clamp at rate computation.

#### Scenario: Burn ceilings are independent
- **WHEN** the owner sets `inconclusiveBurnBps` above the live `settleBurnBps`, or `settleBurnBps` below the live `inconclusiveBurnBps`, within the 5,000 bps ceiling
- **THEN** the call succeeds — only rounds 1–3 of the ladder are held at or below `settleBurnBps`, by the clamp at rate computation — and a value above 5,000 reverts `InvalidParameter`

#### Scenario: Re-wiring a court cannot bypass the window invariant
- **WHEN** the owner unwires the court, sets clocks that only pass vacuously, then calls `setCourt` with a real court those clocks violate
- **THEN** `setCourt` reverts `WindowInvariantViolated` against the new court's own `voteWindow`/`FINALIZE_BUFFER`

### Requirement: Cross-contract wiring and roles
The game SHALL be plain `Ownable2Step` (not upgradeable). It requires three externally granted roles: the exposure ledger's `coverageFreezer`, the tier registry's `authorizedDemoter`, and sWOOD's `authorizedSlasher`. `wood`, `exposureLedger`, and `tierRegistry` are constructor-set (zero addresses revert); `stakedWood` SHALL be owner-set AFTER construction via `setStakedWood`, because the slasher role is granted on sWOOD's side — until wired, `_settle` fail-closes with `ZeroAddress` and no challenge can settle. `setStakedWood` SHALL refuse a sWOOD that has not already named this game its `authorizedSlasher` (`RoleNotGranted`), which fixes the deploy order: sWOOD grants first, the game points at it last; it revalidates no fee, since the prosecutor fee is paid by the escrow. `setExposureLedger` SHALL revalidate `challengeWindow` against the new ledger's window and SHALL refuse a ledger whose `coverageFreezer` is not this game (`RoleNotGranted`). `setCourt(address(0))` SHALL be permitted — it is the governance off-switch for a captured court, leaving open disputes to the timeout — and `rule` reads the LIVE `court` deliberately, so a replaced court can still rule pending disputes that pinned a court at filing. `renounceOwnership` SHALL revert (`RenounceDisabled`), because several recovery levers are owner-only. The game names no sink for the slash: slash proceeds burn inside sWOOD, and the game's own burns go to the constant `BURN_ADDRESS`.

#### Scenario: Settling before the slasher is wired fails closed
- **WHEN** `resolve` reaches the settle path while `stakedWood` is unset
- **THEN** the call reverts `ZeroAddress`, and wiring the slasher later makes the same challenge resolvable

#### Scenario: Unwiring the court restores the fail-safe
- **WHEN** governance calls `setCourt(address(0))` with disputes open
- **THEN** `rule` becomes unreachable and every open dispute can only terminate via the timeout: one that pinned a court at filing fails (forfeit to the pool's funders, window re-armed), one that pinned none unwinds as `Inconclusive`

### Requirement: Proposer bond lock, release, and forfeiture
`ProposerBondEscrow` SHALL be ownerless with no discretionary exit — exactly two exits exist, release and forfeiture, and both are keyed rather than caller-directed. `lockBond(proposalId, proposer, amount)` SHALL be callable only by a registry-authorized governor (`NotAuthorizedGovernor`), with a non-zero proposer, `amount <= type(uint96).max` (`AmountTooLarge`), and at most one bond per `(governor, proposalId)` key (`BondAlreadyLocked`); the WOOD is pulled from the named proposer. `releaseBond(proposalId)` SHALL key the bond to `msg.sender` (so only the governor that locked it can address it) and deliberately SKIP the live registry check — a later-deauthorized governor can still release open bonds to the recorded proposer rather than stranding them; the payout always goes to the recorded proposer, never a caller-chosen payee. `bondOf(governor, proposalId)` SHALL report the recorded proposer and amount.

`forfeitBond(governor, proposalId, feeTo, feeBps)` SHALL be callable only by the live `coverageFreezer` of the wired exposure ledger — the challenge game and nothing else (`NotAuthorizedConvictor`) — fail-closed when the freezer is unset. It SHALL reject `feeBps > MAX_PROSECUTOR_FEE_BPS` (`FeeBpsTooHigh`, revert not clamp) and SHALL delete the bond record before transferring (so a second forfeit on the same key hits `NoBond` rather than double-burning). The prosecutor's fee — `feeBps` of the bond, paid to `feeTo` — comes off the top; the remainder SHALL burn to `BURN_ADDRESS` with no other payee (every alternative destination is a round trip back to the party that forfeited or to whoever governs). `ChallengeGame._settle` SHALL call `forfeitBond` on the escrow pinned at filing, best-effort: at the pinned `prosecutorFeeBpsAtFiling` first and retried at zero fee if that reverts, emitting `ProposerBondForfeited` on success or `ProposerBondForfeitureFailed` if both revert, exactly once per proposal, inside the branch that executes the conviction, so a proposal with one liability and one bond cannot have it taken twice by concurrent challenges.

The governor gates WHEN release is legal, not the escrow: `SyndicateGovernor.reclaimProposerBond` requires the proposal in a terminal state (`Rejected`/`Expired`/`Cancelled`/`Settled`), and for an EXECUTED proposal additionally requires ALL of the following, reverting `ChallengeWindowOpen` otherwise and `ExposureLedgerUnset` (fail-closed) when no ledger is resolvable:

1. `block.timestamp >= executedAt + strategyDuration + ledgerChallengeWindow` (the ledger's window);
2. coverage not currently frozen for that proposal (an open, unresolved challenge);
3. when the ledger's `coverageFreezer` is a non-zero address, the game's LIVE filing deadline has lapsed: `block.timestamp > max(executedAt + strategyDuration + gameChallengeWindow, challengeableUntil[reviewKey])`, read from the freezer with the same review-key derivation the game uses (`keccak256(abi.encode(governor, proposalId))`). The comparison MUST be strict (`>`), mirroring `file`'s admissibility bound (`block.timestamp <= deadline`), so there is no instant at which a filing is still admissible and the bond is simultaneously reclaimable.

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
- **WHEN** `forfeitBond` reverts during `_settle` at the pinned fee and again at zero fee (e.g. the bond was already reclaimed, or the ledger's `coverageFreezer` was rotated away from this game)
- **THEN** settlement continues — the slash, challenger payout, and coverage unfreeze all still complete — and `ProposerBondForfeitureFailed` is emitted instead

#### Scenario: Reclaim refused while the challenge window is open
- **WHEN** an executed proposal's proposer calls `reclaimProposerBond` before `executedAt + strategyDuration + challengeWindow` has elapsed
- **THEN** the call reverts `ChallengeWindowOpen`

#### Scenario: Reclaim refused while coverage is still frozen
- **WHEN** the challenge window has elapsed but the proposal's coverage is still frozen (an unresolved dispute)
- **THEN** `reclaimProposerBond` reverts `ChallengeWindowOpen`

#### Scenario: Reclaim refused while an Inconclusive re-arm keeps filing admissible
- **WHEN** a challenge against an executed proposal unwinds `Inconclusive` after `executedAt + strategyDuration + challengeWindow` (releasing the freeze and re-arming `challengeableUntil[reviewKey]` to `block.timestamp + challengeWindow`), and the proposer calls `reclaimProposerBond` while `block.timestamp <= challengeableUntil[reviewKey]`
- **THEN** the call reverts `ChallengeWindowOpen`, and a challenge filed inside the re-armed window that reaches a conviction finds the bond still in escrow — `forfeitBond` succeeds, paying the prosecutor fee and burning the remainder

#### Scenario: Reclaim opens the instant the re-armed deadline lapses
- **WHEN** the re-armed `challengeableUntil[reviewKey]` passes with no live challenge and no further filing
- **THEN** `reclaimProposerBond` succeeds at the first timestamp strictly greater than the deadline (where `file` would revert `WindowClosed`)

#### Scenario: Unchallenged proposal reclaims on the ordinary schedule
- **WHEN** an executed proposal is never challenged (its `challengeableUntil[reviewKey]` is zero) and both windows have elapsed since `executedAt`
- **THEN** `reclaimProposerBond` succeeds — the new gate never delays a reclaim beyond `executedAt + strategyDuration + max(ledger window, game window)` for an unchallenged proposal

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

