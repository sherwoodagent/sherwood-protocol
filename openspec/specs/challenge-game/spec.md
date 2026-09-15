# Challenge Game Specification

## Purpose

The challenge trigger of the guardian economic-security model: anyone may post a bonded challenge against an executed proposal, freezing the coverage its approvers committed and opening a vote of the staked guardians outside the accused cohort. A convict quorum executes the verdict through the slash rails, burning the convicted approvers' bonds; a window that closes short of that quorum fails the challenge and burns a slice of the challenger's bond. Depositors are not compensated. Covers `ChallengeGame` and `ProposerBondEscrow`.
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
The owner SHALL be able to set `filingsPaused` via `setFilingsPaused(bool)`. While true, `file` SHALL revert `FilingsPaused` before any other check. The flag MUST NOT be read by `voteOnChallenge`, `resolve`, or any other path — the owner can stop a NEW challenge from starting but can never freeze or re-price one already in flight.

#### Scenario: Paused filings refuse new challenges only
- **WHEN** `filingsPaused` is true and a caller invokes `file`
- **THEN** the call reverts `FilingsPaused`
- **AND** `voteOnChallenge` and `resolve` on existing challenges proceed unaffected

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
Live-challenge slots SHALL be keyed per `(reviewKey, challenger)`: a challenger with a live (`Filed`) challenge against the proposal SHALL be refused with `AlreadyChallenged`, but a squatting challenge never blocks a different honest filer. Once any settled challenge has collected the proposal's one liability (`_convicted`), ALL further filings against that proposal SHALL revert `AlreadyConvicted` — a filing that cannot convict would only buy another freeze on already-slashed collateral. A FAILED challenge does not set the convicted flag, so a fresh filing after a failure remains legitimate. Liveness views SHALL re-check status rather than trusting stored pointers (`liveChallengeOf`, `liveChallengeOfBy`).

#### Scenario: Same challenger, same proposal, second filing refused
- **WHEN** a challenger with a live challenge against a proposal files again
- **THEN** the call reverts `AlreadyChallenged`, while a different challenger may still file

#### Scenario: Filing against a convicted proposal refused
- **WHEN** an earlier challenge on the proposal has settled to a conviction
- **THEN** any later `file` against it reverts `AlreadyConvicted`

### Requirement: Economic terms and slash basis pinned at filing
Each challenge SHALL pin at filing: `voteWindowAtFiling`, `quorumBpsAtFiling`, `totalStakeAtFiling`, `settleBurnBpsAtFiling`, `forfeitBurnBpsAtFiling`, `prosecutorFeeBpsAtFiling`, plus the proposal's `executedAt`, `vault`, `proposerBondEscrow` and `proposer`. All clock checks and payout rates for that challenge MUST read the pinned values, never the live parameters — the owner can never retroactively shorten a window, extend a freeze, or re-price a challenge already running. The verdict slash basis SHALL be the pinned `executedAt` (with snapshot `executedAt - 1`), never `filedAt`, so an accused approver cannot zero its own stake checkpoint between drain and accusation.

#### Scenario: Owner parameter change does not move a live challenge
- **WHEN** the owner changes `voteWindow`, `challengeQuorumBps`, or any burn or fee rate after a challenge is filed
- **THEN** that challenge's windows and payouts continue to use the values pinned at its filing; only challenges filed after the change use the new values

### Requirement: The challenge vote — the quorum's denominator is the whole staked set
`file` SHALL pin the challenge's denominator in the same call, as `totalStakeAtFiling = stakedWood.getPastTotalVotes(block.timestamp - 1)` — the TOTAL staked WOOD, the accused cohort included. The accused lose their ballot, not their weight in the denominator: subtracting them would make a conviction cheaper the wider the cohort that approved, so a proposal most of the stake approved could be convicted by a small minority of it. The stamp SHALL be one second before the filing, never the filing instant: an sWOOD checkpoint is keyed on the second a stake changes and a same-key push overwrites, so reading the current timestamp would let stake planted in the filing block itself score in the numerator while the denominator missed it. `file` SHALL additionally compute, WITHOUT storing it, that total less `stakedWood.getPastStake(accused_i, block.timestamp - 1)` for every accused approver, saturating at zero, and SHALL revert `NoVotableStake` when `votable * 10_000 < challengeQuorumBps * totalStake` — NO CONVICTION COULD CLEAR THE QUORUM. That stake outside the cohort is the ceiling on either tally, so once the accused hold more than `1 - quorum` of the total, every filing against the proposal is guaranteed to fail as silence: the challenger loses the forfeit burn, the coverage freezes for the whole window and the proposal's one re-arm is spent, for a verdict that was never reachable. The guard SHALL read the same `challengeQuorumBps` the challenge pins, so the door and the bar cannot drift apart. `file` SHALL also pin the proposal's `proposer`, record each accused approver in an O(1) membership map for the vote's own gate, written in the loop it already runs over the cohort, record each of the proposal's `getCoProposers` entries in a second such map, and SHALL revert `ZeroAddress` when `stakedWood` is unwired.

#### Scenario: Electorate measured one second before the filing
- **WHEN** a guardian stakes WOOD in the same block as a filing
- **THEN** that stake is in neither `totalStakeAtFiling` nor any ballot weight — both read `filedAt - 1`

#### Scenario: The accused stay in the denominator
- **WHEN** the accused cohort holds most of the staked WOOD and one outsider holding all of the remainder votes convict
- **THEN** the quorum is measured against the total, so that outsider alone does not reach it even though it is the whole of the stake that may vote

#### Scenario: A filing no conviction could clear is refused
- **WHEN** the accused cohort holds 75% of the total staked WOOD at a 3,000 bps quorum — so the stake outside it cannot reach the bar
- **THEN** `file` reverts `NoVotableStake`, no bond is taken, and no coverage is frozen; at 65% the same filing is admitted

#### Scenario: Whole staked set accused refuses the filing
- **WHEN** every active guardian's stake backs the challenged proposal
- **THEN** `file` reverts `NoVotableStake` — the zero case the quorum guard subsumes

### Requirement: Casting a ballot
`voteOnChallenge(challengeId, convict)` SHALL be callable only on a `Filed` challenge (otherwise `WrongStatus`) and strictly before `filedAt + voteWindowAtFiling` (otherwise `WindowClosed`). It SHALL refuse the challenge's own challenger (`ChallengerCannotVote`), the challenged proposal's pinned proposer AND each of its recorded co-proposers (`ProposerCannotVote`), an accused approver of that challenge (`AccusedCannotVote`) and a second ballot from the same address (`AlreadyVoted`). Co-proposers are named on-chain and take a share of the proposal's performance fee, so they are the same interested-party class as the lead. All three identity bars are checks a second, unlinked address defeats, so they are floors rather than ceilings; what BOUNDS a self-dealing voter is the denominator, which requires a sybil to hold the quorum of the TOTAL staked WOOD and to outweigh the acquit side. Without the bars a filer convicts its own accusation and collects the prosecutor fee for it, and a proposer or co-proposer votes on the challenge that would confiscate the proposer bond. The voter MUST be an active guardian (`isActiveGuardian`) with non-zero `getPastStake(voter, filedAt - 1)`, otherwise `NoVotableStake`. The ballot's weight SHALL be that `getPastStake` value, credited to exactly one of `convictWeight` / `acquitWeight`, and `ChallengeVoteCast(challengeId, voter, convict, weight)` SHALL be emitted. There SHALL be no vote change and no un-vote: the ballot latch is one-shot, which is what lets `resolve` settle on a crossed quorum without waiting for the window. Consequently `convictWeight + acquitWeight <= totalStakeAtFiling` always holds.

#### Scenario: Challenger refused on its own filing
- **WHEN** the address that filed the challenge calls `voteOnChallenge`, holding a guardian seat of its own
- **THEN** the call reverts `ChallengerCannotVote` and neither tally moves

#### Scenario: Proposer refused
- **WHEN** the proposer of the challenged proposal calls `voteOnChallenge`, holding a guardian seat of its own
- **THEN** the call reverts `ProposerCannotVote` and neither tally moves

#### Scenario: Co-proposer refused
- **WHEN** a co-proposer of a collaborative proposal calls `voteOnChallenge`, holding a guardian seat of its own
- **THEN** the call reverts `ProposerCannotVote` and neither tally moves

#### Scenario: Accused approver refused
- **WHEN** an approver whose lock backs the challenged proposal calls `voteOnChallenge`
- **THEN** the call reverts `AccusedCannotVote`, while that approver's stake stays in the denominator

#### Scenario: One ballot per guardian
- **WHEN** a guardian that already voted calls `voteOnChallenge` again, with either value
- **THEN** the call reverts `AlreadyVoted` and neither tally moves

#### Scenario: Ballot after the pinned window refused
- **WHEN** `block.timestamp >= filedAt + voteWindowAtFiling`
- **THEN** `voteOnChallenge` reverts `WindowClosed`, whatever the owner has since done to the live `voteWindow`

### Requirement: Resolution — a quorum with a convict majority settles, a closed window short of it fails
`resolve(challengeId)` SHALL be permissionless and choose nothing; the outcome is fixed by the tallies and the clock. On a `Filed` challenge it SHALL settle immediately when `totalStakeAtFiling != 0`, `convictWeight * 10_000 >= quorumBpsAtFiling * totalStakeAtFiling` AND `convictWeight > acquitWeight` — both tallies are monotone, so a quorum the convict side carries is already final and need not wait out the window. The majority clause is load-bearing on its own: without it a convicting minority settles over a larger acquit side. Otherwise it SHALL revert `DelayNotElapsed` before `filedAt + voteWindowAtFiling`, and at or after it SHALL fail the challenge. From any terminal status it SHALL revert `WrongStatus`. `filedAt + voteWindowAtFiling` is therefore the hard end of the accusation: it is the same value `file` books on the ledger as the freeze deadline, and no ballot can be cast from that instant on, so a filing short of quorum at that moment can only fail. Settling a reached quorum, by contrast, has no deadline of its own: `resolve` is permissionless and the challenger, whose bond returns only on settlement, is the party paid to call it, while the ledger freeze covers only `filedAt + voteWindow` — so a settlement left until after that MAY find the approvers' locks already retired.

#### Scenario: Quorum settles without waiting for the window
- **WHEN** convict weight crosses `quorumBpsAtFiling` of `totalStakeAtFiling` on day two of a seven-day window, ahead of the acquit weight
- **THEN** `resolve` executes the conviction path at once and a later `resolve` reverts `WrongStatus`

#### Scenario: A quorum outweighed by the acquit side convicts nobody
- **WHEN** convict weight is past the quorum but below the acquit weight
- **THEN** `resolve` reverts `DelayNotElapsed` while the window is open and fails the challenge once it closes

#### Scenario: Silent window fails the challenge
- **WHEN** the window closes with no ballot cast either way
- **THEN** `resolve` fails the challenge: nothing is slashed, coverage is unfrozen, `forfeitBurnBpsAtFiling` of the bond is burned and the remainder returns to the challenger

#### Scenario: Resolve before the window, short of quorum
- **WHEN** `resolve` is called with convict weight below the bar and the window still open
- **THEN** it reverts `DelayNotElapsed` — the cohort still has time to convict

### Requirement: An acquittal spends the window only at the quorum; below it the failure is silence and re-arms
On the fail path the game SHALL re-arm the proposal's challenge window — raising `challengeableUntil[reviewKey]` to at least `block.timestamp + challengeWindow` and pinning the ledger's coverage to the same deadline — if and only if `acquitWeight * 10_000 < quorumBpsAtFiling * totalStakeAtFiling`, the proposal is not already convicted, and that proposal's window has not been re-armed before. An acquittal adjudicates only once it clears the same bar a conviction must: below it the cohort did not decide, and one dust ballot MUST NOT spend the proposal's one re-arm. The re-arm latch SHALL be one-shot per proposal, so repeated silent failures let the window lapse rather than letting a filer cycling addresses pin an honest cohort's coverage indefinitely. `challengeableUntil` SHALL be raise-only on every write.

#### Scenario: Acquittal at the quorum does not re-arm
- **WHEN** a challenge fails with `acquitWeight` at or above `quorumBpsAtFiling` of `totalStakeAtFiling`
- **THEN** `challengeableUntil[reviewKey]` is unchanged and the proposal's ordinary window runs out on its original schedule

#### Scenario: A sub-quorum acquittal does not foreclose the re-arm
- **WHEN** a challenge fails with acquit weight below that bar — one wei, or a substantial 25% of the total against 20% convict at a 3,000 bps quorum
- **THEN** the failure counts as silence in both cases: `challengeableUntil[reviewKey]` is raised and the ledger's coverage is pinned to the same deadline

#### Scenario: Silence re-arms exactly once
- **WHEN** a second challenge against the same proposal also fails in silence
- **THEN** no further re-arm occurs — the first silent failure spent the proposal's one re-arm

### Requirement: Settle path — conviction, burn-only slash, prosecutor fee from the proposer's bond
`_settle` (reached only from a crossed convict quorum) SHALL fail closed with `ZeroAddress` if `stakedWood` is unwired (recoverable: wiring the slasher makes every stuck challenge resolvable). It SHALL mark the status `Settled`, release this challenge's freeze hold, and — unless the proposal was already convicted by a concurrent challenge or by an earlier deployment of this game, in which case it SHALL emit `VerdictAlreadyCollected` and slash nothing — set the convicted flag and execute the slash via `IStakedWood.slashVerdict` using the ledger's per-approver rates (`slashBpsFor`, filtered to non-zero entries so released approvers are not named in the conviction) and the pinned `executedAt` as basis. `slashVerdict` takes no recipient: the slash burns inside sWOOD and pays nobody. The pinned `proposerBondEscrow` SHALL then be asked to `forfeitBond(governor, proposalId, challenger, prosecutorFeeBpsAtFiling)`; a revert SHALL be retried at a zero fee and, failing that, surfaced as `ProposerBondForfeitureFailed` rather than losing the conviction. The challenger SHALL receive its bond less `settleBurnBpsAtFiling`, burned to `0x…dEaD` (`ChallengerBondBurned`) — a correct filing is cheap, not free, and the burn is charged by rate rather than by an identity check a second address would defeat. `ChallengeSettled(challengeId, slashedWood)` SHALL be emitted, where `slashedWood` is what was burned.

#### Scenario: Conviction burns the settle slice and pays the prosecutor fee
- **WHEN** a challenge settles on a crossed convict quorum
- **THEN** the accused approvers' locks are burned, the named adapter demotion is attempted, the convicted proposer's bond is forfeited with `prosecutorFeeBpsAtFiling` to the challenger, `settleBurnBpsAtFiling` of the challenger's bond is burned, and the challenger receives the rest

#### Scenario: Concurrent settle against an already-convicted proposal
- **WHEN** a second live challenge settles after another already collected the proposal's liability
- **THEN** no slash is attempted, `VerdictAlreadyCollected` is emitted, and the challenge still terminates normally (settle-path bond handling included)

### Requirement: No transfer in the game reaches an approver or the proposer
Every value-moving path SHALL pay only `BURN_ADDRESS` or the challenger. `_settle` burns `settleBurnBpsAtFiling` of the bond and returns the remainder to the challenger; `_fail` burns `forfeitBurnBpsAtFiling` and returns the remainder to the challenger; `slashVerdict` names no recipient; `forfeitBond` splits into the challenger's bounded prosecutor fee and the burn address. No accused approver and no proposer SHALL be a payee on any path. This is what makes an attacker controlling both sides of a challenge strictly worse off either way: convicting itself forfeits a bond in full to recover at most `MAX_PROSECUTOR_FEE_BPS` of it, and failing against itself destroys `forfeitBurnBpsAtFiling` of the challenger bond for nothing.

#### Scenario: Self-filed challenge has no profitable branch
- **WHEN** one operator controls the challenger, the accused approvers and the proposer
- **THEN** both terminal paths destroy value it holds and neither routes any of it back to the accused side

### Requirement: Slash gas floor
Because `resolve` is permissionless, `_settle` SHALL revert `InsufficientSlashGas` when `gasleft() < approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE`, with `SLASH_GAS_PER_APPROVER = 180_000` and `SLASH_GAS_BASE = 2_000_000` — measured end to end through `resolve`, not against the slash call alone. When the challenge names a non-zero adapter, the floor SHALL additionally require `DEMOTION_GAS = 200_000`: the check becomes `gasleft() >= approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE + DEMOTION_GAS`, so a settle that passes it is GUARANTEED to reach the best-effort `demoteByChallenge` child with enough gas for the demotion to succeed on a willing registry — a caller cannot choose a gas budget on which the conviction lands but the demotion is starved. A filing that accuses no adapter (zero `adapterTarget`) demotes nothing and SHALL owe nothing for it: its floor is the slash terms alone. Without the term, the demotion's gas safety rested on two incidental facts — the slash constants' measured slack reaching the demotion call, and an out-of-gas demotion child consuming its whole 63/64 stipend so the 1/64 remainder could not pay for the settle's own tail (the whole call reverted rather than settling with a silent miss). Both held at the time this term was added, but neither was stated or tested; the explicit term is what survives retuning the slash constants, slimming the settle tail, or reordering the demotion. The full-cap floor including `DEMOTION_GAS` SHALL fit Robinhood's 32M per-transaction limit (`100 * 180_000 + 2_000_000 + 200_000 = 20,200,000` against `32M * (63/64)^3 = 30,523,315`). The check is skipped on the `VerdictAlreadyCollected` branch (nothing is slashed, nothing is demoted) and a failed check changes no challenge state — retry with more gas.

#### Scenario: Under-gassed resolve reverts cleanly
- **WHEN** `resolve` reaches the slash with less than the floor remaining
- **THEN** it reverts `InsufficientSlashGas` and the challenge remains resolvable by a retry with more gas

#### Scenario: A budget that covers the slash but not the demotion is refused up front
- **WHEN** `resolve` reaches `_settle` on an adapter-naming challenge with gas at or above the slash terms but below the demotion-extended floor
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

### Requirement: Fail path — bond returned to the challenger net of the forfeit burn
`_fail` (reached when the pinned window closes short of the convict quorum) SHALL mark the status `Failed`, release the freeze hold, burn `forfeitBurnBpsAtFiling` of the challenger's bond to `0x…dEaD`, and return the remainder to the CHALLENGER. Integer division keeps the burn at most the bond, so the remainder cannot underflow and a zero rate returns the bond whole. The accused SHALL receive nothing: a failed accusation is a cost to the filer, never a transfer to the cohort it accused. `ChallengeFailed(challengeId, bondWood, burnedWood)` SHALL report the gross bond and the burned slice separately, and the burn SHALL additionally emit `ChallengerBondBurned`. The re-arm decision on this path is governed by the acquittal requirement above.

#### Scenario: Failed challenge pays the challenger, not the cohort
- **WHEN** a challenge fails at the window's close
- **THEN** the challenger receives `bond - burn` and every accused approver receives zero

#### Scenario: Forfeit burn prices the self-challenge round trip
- **WHEN** a challenge fails with `forfeitBurnBpsAtFiling` of 2,000
- **THEN** 20% of the bond is destroyed with no reachable beneficiary, so an operator that filed against its own proposal to freeze co-approvers' coverage pays for the freeze

### Requirement: WOOD custody invariant
The game SHALL track `bondedWood` — the sum of the challenger bonds of LIVE (`Filed`) challenges, the only WOOD it custodies — maintaining `wood.balanceOf(game) >= bondedWood` at all times, with "no live challenge implies `bondedWood == 0`". Exactly one path credits it (`file`, paired 1:1 with the bond transfer in) and exactly two debit it (`_settle`, `_fail`), each decrementing precisely that challenge's bond and paying it out across a burn leg and a challenger leg that sum to it. WOOD requires standard ERC20 semantics (no fee-on-transfer, no rebase, no hooks); donated surplus is never spent by any path.

#### Scenario: Terminal accounting balances to the wei
- **WHEN** any challenge reaches a terminal state
- **THEN** `bondedWood` decreases by exactly that challenge's bond, and every wei of it is transferred out across the burn and challenger legs

### Requirement: Parameter governance, bounded and pinned
Owner setters SHALL enforce: `challengeWindow` non-zero and never above the wired ledger's own `challengeWindow` (read live); `challengerBondBps` in (0, 10_000] — zero would make the freeze free; `forfeitBurnBps` in [0, 5_000] (`MAX_FORFEIT_BURN_BPS`); `settleBurnBps` in [0, 5_000] (`MAX_SETTLE_BURN_BPS`; zero is legal and refunds a winning challenger in full); `prosecutorFeeBps` in [0, `MAX_PROSECUTOR_FEE_BPS` = 2_000], with the paying escrow re-checking its own bound as the authority; `voteWindow` in [`MIN_VOTE_WINDOW` = 2 days, `MAX_VOTE_WINDOW` = 60 days] — the floor is load-bearing because a window collapsed to zero would turn a filing into an instant verdict, and the ceiling is the same value as `ExposureLedger.MAX_COVERAGE_HORIZON`, past which the freeze `file` books outlives the horizon the ledger clamps a lock to; `challengeQuorumBps` in [1_000, 10_000], floored well above zero because a bar a single dust guardian could clear would make the vote a formality rather than a decision. There SHALL be no cross-setter ordering between the two burn rates. Every one of these values is copied onto each challenge at filing, so no setter can re-rate or re-time a challenge in flight; `renounceOwnership` SHALL revert.

#### Scenario: Vote window cannot be collapsed
- **WHEN** the owner calls `setVoteWindow` with anything below `MIN_VOTE_WINDOW`
- **THEN** the call reverts `InvalidParameter` and the live window is unchanged

#### Scenario: Vote window cannot outrun the coverage horizon
- **WHEN** the owner calls `setVoteWindow` with 61 days
- **THEN** the call reverts `InvalidParameter`, while 60 days — `MAX_VOTE_WINDOW` itself — is accepted

#### Scenario: Quorum stays inside its band
- **WHEN** the owner calls `setChallengeQuorumBps` with 999 or with 10_001
- **THEN** the call reverts `InvalidParameter` from either end

### Requirement: Cross-contract wiring and roles
The game SHALL be plain `Ownable2Step` (not upgradeable). It requires three externally granted roles: the exposure ledger's `coverageFreezer`, the tier registry's `authorizedDemoter`, and sWOOD's `authorizedSlasher`. `wood`, `exposureLedger`, and `tierRegistry` are constructor-set (zero addresses revert); `stakedWood` SHALL be owner-set AFTER construction via `setStakedWood`, because the slasher role is granted on sWOOD's side and the two contracts are wired in either order at deploy time. Until `stakedWood` is wired, `file` SHALL revert `ZeroAddress` (it cannot measure an electorate) and `_settle` SHALL fail closed with the same error, both recoverable by wiring the slasher. `setExposureLedger` SHALL revalidate `challengeWindow` against the new ledger's window. The ledger the game reads the accused cohort from and the sWOOD it reads the electorate from MUST describe the same book of stake; no on-chain check relates the two pointers, so this is a wire-time and monitoring obligation. The game names no sink: slash proceeds burn inside sWOOD, and the prosecutor fee is paid by the escrow out of the convicted proposer's own bond, so there is nothing for the game to redirect.

#### Scenario: Settling before the slasher is wired fails closed
- **WHEN** `resolve` reaches the settle path while `stakedWood` is unset
- **THEN** the call reverts `ZeroAddress`, and wiring the slasher later makes the same challenge resolvable

#### Scenario: Filing before the slasher is wired is refused
- **WHEN** `file` is called while `stakedWood` is unset
- **THEN** the call reverts `ZeroAddress` — no bond is taken for a challenge whose electorate cannot be measured

### Requirement: Proposer bond lock, release, and forfeiture
`ProposerBondEscrow` SHALL be ownerless with no discretionary exit — exactly two exits exist, release and forfeiture, and both are keyed rather than caller-directed. `lockBond(proposalId, proposer, amount)` SHALL be callable only by a registry-authorized governor (`NotAuthorizedGovernor`), with a non-zero proposer, `amount <= type(uint96).max` (`AmountTooLarge`), and at most one bond per `(governor, proposalId)` key (`BondAlreadyLocked`); the WOOD is pulled from the named proposer. `releaseBond(proposalId)` SHALL key the bond to `msg.sender` (so only the governor that locked it can address it) and deliberately SKIP the live registry check — a later-deauthorized governor can still release open bonds to the recorded proposer rather than stranding them; the payout always goes to the recorded proposer, never a caller-chosen payee. `bondOf(governor, proposalId)` SHALL report the recorded proposer and amount.

`forfeitBond(governor, proposalId, feeTo, feeBps)` SHALL be callable only by the live `coverageFreezer` of the wired exposure ledger — the challenge game and nothing else (`NotAuthorizedConvictor`) — fail-closed when the freezer is unset. It SHALL reject `feeBps > MAX_PROSECUTOR_FEE_BPS` (`FeeBpsTooHigh`, revert not clamp) and SHALL delete the bond record before transferring (so a second forfeit on the same key hits `NoBond` rather than double-burning). The prosecutor's fee — `feeBps` of the bond, paid to `feeTo` — comes off the top; the remainder SHALL burn to `BURN_ADDRESS` with no other payee (every alternative destination is a round trip back to the party that forfeited or to whoever governs). `ChallengeGame._settle` SHALL call `forfeitBond` best-effort (wrapped in try/catch, emitting `ProposerBondForfeited` on success or `ProposerBondForfeitureFailed` on revert) exactly once per proposal, inside the `_convicted` branch, so a proposal with one liability and one bond cannot have it taken twice by concurrent challenges.

The governor gates WHEN release is legal, not the escrow: `SyndicateGovernor.reclaimProposerBond` requires the proposal in a terminal state (`Rejected`/`Expired`/`Cancelled`/`Settled`), and for an EXECUTED proposal additionally requires ALL of the following, reverting `ChallengeWindowOpen` otherwise and `ExposureLedgerUnset` (fail-closed) when no ledger is resolvable:

1. `block.timestamp >= executedAt + ledgerChallengeWindow` (the ledger's window);
2. coverage not currently frozen for that proposal (an open, unresolved challenge);
3. when the ledger's `coverageFreezer` is a non-zero address, the game's LIVE filing deadline has lapsed: `block.timestamp > max(executedAt + gameChallengeWindow, challengeableUntil[reviewKey])`, read from the freezer with the same review-key derivation the game uses (`keccak256(abi.encode(governor, proposalId))`). The comparison MUST be strict (`>`), mirroring `file`'s admissibility bound (`block.timestamp <= deadline`), so there is no instant at which a filing is still admissible and the bond is simultaneously reclaimable.

THE LEDGER THESE GATES READ SHALL BE THE ONE RECORDED ON THE PROPOSAL AT PROPOSE TIME — the ledger that priced and gated the bond — not the governor's live, re-pointable exposure-ledger slot. Adversary: a vault owner (who may be the proposer, or colluding with it) who has the factory re-point the governor's ledger at a permissive one (zero `coverageFreezer`, collapsed window) after the proposal settles — the open-proposal guard on re-pointing no longer holds then, and under live reads one re-point would detach all three gates from a still-convictable challenge for as long as the configured windows allow. Re-pointing the governor's live ledger slot MUST NOT alter the reclaim gates of any proposal whose bond is already locked. A proposal recorded before ledger pinning existed (zero recorded ledger, non-zero bond) SHALL fall back to the live slot, preserving its pre-pin behavior including the `ExposureLedgerUnset` fail-closed path.

A FORFEITED BOND SHALL BE A DISTINGUISHABLE, TERMINAL OUTCOME AT RECLAIM, not a permanent indistinguishable revert. When the governor still records a non-zero bond but the escrow recorded on the proposal reports none for `(governor, proposalId)`, the bond was forfeited by a conviction (forfeiture and reclaim-release are the only record-deleting exits, and reclaim-release zeroes the governor's record in the same transaction) — `reclaimProposerBond` SHALL zero the recorded bond amount, emit `ProposerBondForfeitureAcknowledged(proposalId, amount)`, and return without transferring, before evaluating the challenge-window gates (a nonexistent bond has no window to wait out). A subsequent call SHALL revert `NoBondToReclaim`, the same terminal answer as after an ordinary release.

Gate 3 SHALL be skipped entirely when `coverageFreezer` is the zero address: with no freezer wired, no challenge can freeze coverage and no convictor can reach `forfeitBond`, so no conviction is reachable and gates 1-2 remain a sufficient hold — an unwired or rotated-away freezer MUST NOT strand honest proposers' bonds. For an unchallenged proposal `challengeableUntil[reviewKey]` is zero (an untouched key), so gate 3 reduces to the game's ordinary window and reclaim proceeds on the same schedule as before whenever the game's window does not exceed the ledger's (which the game's own setters enforce). A non-zero freezer whose views revert or cannot be decoded fails closed; a freezer that ANSWERS zero passes (a genuine `ChallengeGame` never answers zero for `challengeWindow` — its setter rejects it — so a zero answer can only come from a non-genuine freezer; whether that asymmetry should also fail closed is tracked as an open decision in this change's design.md and is NOT changed here). A bond therefore cannot be reclaimed while it could still be forfeited: the filing deadline — including any `challengeableUntil` extension re-armed by a silent failure — and any live freeze both block reclaim, and no owner-side re-point can lift that hold.

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
- **WHEN** the challenge window has elapsed but the proposal's coverage is still frozen (an unresolved challenge)
- **THEN** `reclaimProposerBond` reverts `ChallengeWindowOpen`

#### Scenario: Reclaim refused while a silent-failure re-arm keeps filing admissible
- **WHEN** a challenge against an executed proposal fails in silence after `executedAt + challengeWindow` (releasing the freeze and re-arming `challengeableUntil[reviewKey]` to `block.timestamp + challengeWindow`), and the proposer calls `reclaimProposerBond` while `block.timestamp <= challengeableUntil[reviewKey]`
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

