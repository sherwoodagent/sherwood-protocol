## ADDED Requirements

### Requirement: The challenge vote — the quorum's denominator and what the admission guard checks
`file` SHALL pin the challenge's denominator in the same call, as `totalStakeAtFiling = stakedWood.getPastTotalVotes(block.timestamp - 1)` less, for every accused approver, `max(0, getPastStake(accused_i, block.timestamp - 1) - min(getPastStake(accused_i, executedAt - 1), getPastStake(accused_i, p.snapshotTimestamp)))` — the TOTAL staked WOOD, the accused cohort included, but each accused counted at no more than its stake at the approve snapshot (`p.snapshotTimestamp`, the instant its approve weight was read) and at execution. The accused lose their ballot, not their weight in the denominator: subtracting them would make a conviction cheaper the wider the cohort that approved. A top-up after approving SHALL NOT count: the verdict slash is sized by the booked lock, so stake added after the approve snapshot risks nothing, and counting it would let an accused approver stake past `1 - quorum` of the total and have every filing refused. The stamp SHALL be one second before the filing, never the filing instant: an sWOOD checkpoint is keyed on the second a stake changes and a same-key push overwrites. `file` SHALL additionally compute `votable`, that total less `stakedWood.getPastStake(accused_i, block.timestamp - 1)` for every accused approver, saturating at zero, pin it as `votableAtFiling`, and SHALL revert `NoVotableStake` when `votable * 10_000 < challengeQuorumBps * totalStake`, reading the same `challengeQuorumBps` the challenge pins.

What that guard checks is that the stake NOT held by the accused at `filedAt - 1` is at least `challengeQuorumBps` of the pinned total. It does NOT check that the stake able to vote can reach the quorum. Both `votable` and `totalStakeAtFiling` include stake that carries no ballot on this challenge: stake added after the proposal's `snapshotAt` (a ballot is capped at the voter's stake at `snapshotAt`, see "Casting a ballot"), and the stake of the challenger, the proposer and each co-proposer, which `voteOnChallenge` refuses. Such stake raises the bar the eligible electorate must clear and can never help clear it, so a filing MAY be admitted that no set of ballots can win; it then fails at the window's close and the challenger pays the forfeit burn. The guard refuses only filings where the accused cohort alone leaves the rest of the stake below the quorum. The same inflated `votableAtFiling` is the early-settle bar in `resolve`. `file` SHALL also pin the proposal's `proposer` and `snapshotAt`, record each accused approver in an O(1) membership map for the vote's own gate, written in the loop it already runs over the cohort, record each of the proposal's `getCoProposers` entries in a second such map, and SHALL revert `ZeroAddress` when `stakedWood` is unwired.

#### Scenario: Electorate measured one second before the filing
- **WHEN** a guardian stakes WOOD in the same block as a filing
- **THEN** that stake is in neither `totalStakeAtFiling` nor any ballot weight — both read `filedAt - 1`

#### Scenario: The accused stay in the denominator
- **WHEN** the accused cohort holds most of the staked WOOD and one outsider holding all of the remainder votes convict
- **THEN** the quorum is measured against the total, so that outsider alone does not reach it even though it is the whole of the stake that may vote

#### Scenario: An accused top-up after execution does not raise the bar
- **WHEN** an accused approver more than triples its stake after the proposal executes, enough that its filing-time stake would put the rest of the network below the quorum
- **THEN** `file` succeeds, `totalStakeAtFiling` counts that approver at its approve-snapshot stake (a top-up before execution is capped the same way), and the rest of the network can convict

#### Scenario: An accused cohort above `1 - quorum` refuses the filing
- **WHEN** the accused cohort holds 75% of the total staked WOOD at a 3,000 bps quorum
- **THEN** `file` reverts `NoVotableStake`, no bond is taken, and no coverage is frozen; at 65% the same filing is admitted

#### Scenario: Whole staked set accused refuses the filing
- **WHEN** every active guardian's stake backs the challenged proposal
- **THEN** `file` reverts `NoVotableStake` — the zero case the quorum guard subsumes

#### Scenario: Stake staked after the snapshot is admitted into the base and cannot vote
- **WHEN** a non-approving address with no stake at `snapshotAt` stakes, before the filing, more than `honest × 10_000 / challengeQuorumBps − (honest + accused)`, and every honest guardian staked before `snapshotAt` votes convict
- **THEN** `file` succeeds, that stake counts in `totalStakeAtFiling` and `votableAtFiling`, its own ballot reverts `NoVotableStake`, the unanimous honest conviction misses the quorum, and the challenge fails at the window's close

#### Scenario: Barred-party stake can make a filing unwinnable
- **WHEN** the proposer holds, from before `snapshotAt`, enough staked WOOD that the stake able to vote is below `challengeQuorumBps` of `totalStakeAtFiling`
- **THEN** `file` is admitted, the proposer's ballot reverts `ProposerCannotVote`, and no set of eligible ballots can reach the quorum

## MODIFIED Requirements

### Requirement: Filing a bonded challenge
`ChallengeGame.file(governor, proposalId, predicate, adapterTarget, adapterSelector, evidenceURI)` SHALL be permissionless and SHALL accept a filing only against an EXECUTED proposal (`executedAt != 0`, read from the governor; otherwise revert `NotExecuted`), and only while `block.timestamp <= max(executedAt + strategyDuration + challengeWindow, challengeableUntil[reviewKey])` (otherwise revert `WindowClosed`), where `executedAt` and `strategyDuration` come from the same `getProposal` read and `challengeWindow` is the game's live value. The deadline MUST be recomputed as a max against that live baseline on every call, never read as a stored absolute, so the extension can only ever raise it. The cited predicate (one of `OutOfAdapterOutflow`, `OraclePriceDeviation`, `ProposerLinkedOutflow`, `RogueAllowance`, `DrawdownBreach`) SHALL be a classification label only — recorded and emitted in `ChallengeFiled` but branching no logic; there is no on-chain predicate verification. `evidenceURI` SHALL be carried unindexed in `ChallengeFiled` as the off-chain evidence anchor. The review key SHALL be `keccak256(abi.encode(governor, proposalId))`, matching the ledger and registry derivation.

#### Scenario: Filing against an executed proposal inside the window
- **WHEN** a caller files against a proposal with non-zero `executedAt`, within the window, with a valid bond
- **THEN** a new challenge is created in status `Filed` with `filedAt = block.timestamp`, the bond is pulled via `safeTransferFrom`, and `ChallengeFiled` is emitted with the challenger, predicate, bond, and evidence URI

#### Scenario: Unexecuted proposal refused
- **WHEN** `file` is called for a proposal whose `executedAt` is zero
- **THEN** the call reverts `NotExecuted`

#### Scenario: The window counts from the end of the strategy duration
- **WHEN** a proposal executed with a 7-day `strategyDuration` and a 14-day `challengeWindow` is challenged 20 days after `executedAt`
- **THEN** the filing is inside the window and is accepted

#### Scenario: Window closed
- **WHEN** `block.timestamp` exceeds both `executedAt + strategyDuration + challengeWindow` and the proposal's `challengeableUntil` extension
- **THEN** the call reverts `WindowClosed`

### Requirement: Challenger bond sized to the coverage the filing freezes
The bond SHALL be `coverageUsd * challengerBondBps / 10_000` (default 150, i.e. 1.5%), converted to WOOD at the ledger's composed haircut price `woodPriceX8()` (never the raw owner scalar). `coverageUsd` SHALL be `exposureLedger.unsharedLiabilityUsd(governor, proposalId)`: the approvers' recoverable WOOD, `Σ min(lock_i, slash basis_i at executedAt)`, valued at `woodPriceX8()` and capped at the proposal's need priced through the vault asset's feed (`coverageUsd(asset, requiredCoverage)`). A cohort that over-subscribed the proposal therefore cannot inflate the bond past what a conviction can recover. `file` SHALL call that view inside `try/catch` and SHALL revert `WoodPriceUnset` on ANY failure of it: no WOOD price (`NoWoodPrice`: zero cap, unwired or failing feed) and a stale or unconfigured vault-asset feed (`StalePrice`, `FeedNotConfigured`) are not told apart. There SHALL be no fallback bond: a filing during a price outage waits, and the filing deadline keeps running while it does. Filing SHALL fail closed: revert `NothingToFreeze` when the approvers' lock sum is zero (checked before any price is read), `WoodPriceUnset` when the liability read fails or `woodPriceX8()` is zero (transient, protocol-wide), and `BondTooSmall` when the bond floors to zero (proposal-specific) — which includes a cohort whose slash basis at `executedAt` is zero, since the liability view then returns zero without reading the asset feed.

#### Scenario: Bond computed from capped coverage at the composed price
- **WHEN** the approvers' recoverable locks at live value exceed the proposal's need
- **THEN** the bond is priced against the need, at `challengerBondBps` of that value, converted at `woodPriceX8()`

#### Scenario: Under-subscribed proposal prices the bond off what is recoverable
- **WHEN** the approvers' recoverable locks at live value are below the proposal's need
- **THEN** the bond is priced against the lock value, not the need

#### Scenario: Unpriced WOOD blocks filing
- **WHEN** `exposureLedger.woodPriceX8()` reverts `NoWoodPrice`
- **THEN** `file` reverts `WoodPriceUnset`, and the filing deadline is not extended

#### Scenario: A stale vault-asset feed blocks filing
- **WHEN** WOOD is priced but the vault asset's feed is older than its `maxDelay`
- **THEN** `file` reverts `WoodPriceUnset`

#### Scenario: Zero-coverage proposal cannot be challenged
- **WHEN** every approver lock for the proposal has been released (sums to zero)
- **THEN** `file` reverts `NothingToFreeze`

### Requirement: Filing freezes coverage, refcounted across concurrent challenges
Every filing SHALL call `exposureLedger.freezeCoverage(governor, proposalId, block.timestamp + voteWindow)`, freezing the proposal's committed coverage (per-proposal, never the guardian's whole stake). The ledger's freeze is idempotent per proposal and per approver and moves each lock's bucket only later, so a later filing extends the hold to its own vote window and never shortens an earlier one. The release MUST be refcounted per proposal: only the termination of the LAST live challenge calls `unfreezeCoverage`, so a terminating challenge never unfreezes coverage that concurrent filings still pin. The refcount decrement SHALL be defensive against underflow (a rewired ledger must not produce a permanent freeze). `liveChallengeCountOf` SHALL report the live count; non-zero is exactly the condition under which the game holds the coverage frozen.

#### Scenario: First filing freezes, second does not double-freeze
- **WHEN** two challengers file against the same proposal
- **THEN** `freezeCoverage` is called on each filing with that filing's own `filedAt + voteWindow`, the ledger counts the proposal and each approver's frozen commitment once, and the live count is 2

#### Scenario: Last termination unfreezes
- **WHEN** one of two live challenges reaches a terminal state
- **THEN** coverage remains frozen until the second also terminates, at which point `unfreezeCoverage` is called once

### Requirement: The challenger names the accused adapter, checked for membership
The filer SHALL name the adapter it accuses (`adapterTarget`, `adapterSelector`); the chain MUST NOT derive it. The zero address SHALL mean the filing accuses no adapter (and demotes nothing). A non-zero `adapterTarget` MUST appear, with its selector, among the challenged proposal's own stored execute calls OR its stored settlement calls (calls with fewer than 4 bytes of data are skipped, never treated as wildcards); otherwise `file` SHALL revert `AdapterNotInProposal`. This is a membership test over data the governor holds, not a second calldata parser.

#### Scenario: Adapter outside the proposal refused
- **WHEN** a filing names a certified adapter `(target, selector)` that appears in neither the proposal's execute calls nor its settlement calls
- **THEN** `file` reverts `AdapterNotInProposal`

#### Scenario: Adapter named only in the settlement calls
- **WHEN** a filing names a `(target, selector)` that appears only among the proposal's settlement calls
- **THEN** the membership test passes

#### Scenario: No-adapter filing
- **WHEN** a filing passes the zero address as `adapterTarget`
- **THEN** the filing is accepted and no demotion occurs on any outcome

### Requirement: Cross-contract wiring and roles
The game SHALL be plain `Ownable2Step` (not upgradeable). It requires three externally granted roles: the exposure ledger's `coverageFreezer`, the tier registry's `authorizedDemoter`, and sWOOD's `authorizedSlasher`. `wood`, `exposureLedger`, and `tierRegistry` are constructor-set (zero addresses revert); `stakedWood` SHALL be owner-set AFTER construction via `setStakedWood`, because the slasher role is granted on sWOOD's side and the two contracts are wired in either order at deploy time. `setStakedWood` SHALL revert `RoleNotGranted` unless the new sWOOD already names this game as its `authorizedSlasher`, and `setExposureLedger` SHALL revert `RoleNotGranted` unless the new ledger already names this game as its `coverageFreezer`, so a re-point never sends terminal paths into the counterpart's caller gate. Until `stakedWood` is wired, `file` SHALL revert `ZeroAddress` (it cannot measure an electorate) and `_settle` SHALL fail closed with the same error, both recoverable by wiring the slasher. `setExposureLedger` SHALL revalidate `challengeWindow` against the new ledger's window. The ledger the game reads the accused cohort from and the sWOOD it reads the electorate from MUST describe the same book of stake; no on-chain check relates the two pointers, so this is a wire-time and monitoring obligation. The game names no sink: slash proceeds burn inside sWOOD, and the prosecutor fee is paid by the escrow out of the convicted proposer's own bond, so there is nothing for the game to redirect.

#### Scenario: Settling before the slasher is wired fails closed
- **WHEN** `resolve` reaches the settle path while `stakedWood` is unset
- **THEN** the call reverts `ZeroAddress`, and wiring the slasher later makes the same challenge resolvable

#### Scenario: Filing before the slasher is wired is refused
- **WHEN** `file` is called while `stakedWood` is unset
- **THEN** the call reverts `ZeroAddress` — no bond is taken for a challenge whose electorate cannot be measured

#### Scenario: Re-pointing at a counterpart that has not granted the role is refused
- **WHEN** the owner calls `setStakedWood` with an sWOOD whose `authorizedSlasher` is another address, or `setExposureLedger` with a ledger whose `coverageFreezer` is another address
- **THEN** the call reverts `RoleNotGranted` and the pointer is unchanged

### Requirement: Proposer bond lock, release, and forfeiture
`ProposerBondEscrow` SHALL be ownerless with no discretionary exit — exactly two exits exist, release and forfeiture, and both are keyed rather than caller-directed. `lockBond(proposalId, proposer, amount)` SHALL be callable only by a registry-authorized governor (`NotAuthorizedGovernor`), with a non-zero proposer, `amount <= type(uint96).max` (`AmountTooLarge`), and at most one bond per `(governor, proposalId)` key (`BondAlreadyLocked`); the WOOD is pulled from the named proposer. `releaseBond(proposalId)` SHALL key the bond to `msg.sender` (so only the governor that locked it can address it) and deliberately SKIP the live registry check — a later-deauthorized governor can still release open bonds to the recorded proposer rather than stranding them; the payout always goes to the recorded proposer, never a caller-chosen payee. `bondOf(governor, proposalId)` SHALL report the recorded proposer and amount.

`forfeitBond(governor, proposalId, feeTo, feeBps)` SHALL be callable only by the live `coverageFreezer` of the wired exposure ledger — the challenge game and nothing else (`NotAuthorizedConvictor`) — fail-closed when the freezer is unset. It SHALL reject `feeBps > MAX_PROSECUTOR_FEE_BPS` (`FeeBpsTooHigh`, revert not clamp) and SHALL delete the bond record before transferring (so a second forfeit on the same key hits `NoBond` rather than double-burning). The prosecutor's fee — `feeBps` of the bond, paid to `feeTo` — comes off the top; the remainder SHALL burn to `BURN_ADDRESS` with no other payee (every alternative destination is a round trip back to the party that forfeited or to whoever governs). `ChallengeGame._settle` SHALL call `forfeitBond` best-effort (wrapped in try/catch, emitting `ProposerBondForfeited` on success or `ProposerBondForfeitureFailed` on revert) exactly once per proposal, inside the `_convicted` branch, so a proposal with one liability and one bond cannot have it taken twice by concurrent challenges.

The governor gates WHEN release is legal, not the escrow: `SyndicateGovernor.reclaimProposerBond` requires the proposal in a terminal state (`Rejected`/`Expired`/`Cancelled`/`Settled`), and for an EXECUTED proposal additionally requires ALL of the following, reverting `ChallengeWindowOpen` otherwise and `ExposureLedgerUnset` (fail-closed) when no ledger is resolvable:

1. `block.timestamp >= executedAt + strategyDuration + ledgerChallengeWindow` (the ledger's window, counted from the end of the strategy duration as the game's is);
2. coverage not currently frozen for that proposal (an open, unresolved challenge);
3. when the ledger's `coverageFreezer` is a non-zero address, the game's LIVE filing deadline has lapsed: `block.timestamp > max(executedAt + strategyDuration + gameChallengeWindow, challengeableUntil[reviewKey])`, read from the freezer with the same review-key derivation the game uses (`keccak256(abi.encode(governor, proposalId))`). The comparison MUST be strict (`>`), mirroring `file`'s admissibility bound (`block.timestamp <= deadline`), so there is no instant at which a filing is still admissible and the bond is simultaneously reclaimable.

THE LEDGER THESE GATES READ SHALL BE THE ONE RECORDED ON THE PROPOSAL AT PROPOSE TIME — the ledger that priced and gated the bond — not the governor's live, re-pointable exposure-ledger slot. Adversary: a vault owner (who may be the proposer, or colluding with it) who has the factory re-point the governor's ledger at a permissive one (zero `coverageFreezer`, collapsed window) after the proposal settles — the open-proposal guard on re-pointing no longer holds then, and under live reads one re-point would detach all three gates from a still-convictable challenge for as long as the configured windows allow. Re-pointing the governor's live ledger slot MUST NOT alter the reclaim gates of any proposal whose bond is already locked. A proposal recorded before ledger pinning existed (zero recorded ledger, non-zero bond) SHALL fall back to the live slot, preserving its pre-pin behavior including the `ExposureLedgerUnset` fail-closed path.

A FORFEITED BOND SHALL BE A DISTINGUISHABLE, TERMINAL OUTCOME AT RECLAIM, not a permanent indistinguishable revert. When the governor still records a non-zero bond but the escrow recorded on the proposal reports none for `(governor, proposalId)`, the bond was forfeited by a conviction (forfeiture and reclaim-release are the only record-deleting exits, and reclaim-release zeroes the governor's record in the same transaction) — `reclaimProposerBond` SHALL zero the recorded bond amount, emit `ProposerBondForfeitureAcknowledged(proposalId, amount)`, and return without transferring, before evaluating the challenge-window gates (a nonexistent bond has no window to wait out). A subsequent call SHALL revert `NoBondToReclaim`, the same terminal answer as after an ordinary release.

Gate 3 SHALL be skipped entirely when `coverageFreezer` is the zero address: with no freezer wired, no challenge can freeze coverage and no convictor can reach `forfeitBond`, so no conviction is reachable and gates 1-2 remain a sufficient hold — an unwired or rotated-away freezer MUST NOT strand honest proposers' bonds. For an unchallenged proposal `challengeableUntil[reviewKey]` is zero (an untouched key), so gate 3 reduces to the game's ordinary window (`executedAt + strategyDuration + gameChallengeWindow`) and reclaim proceeds on the same schedule as before whenever the game's window does not exceed the ledger's (which the game's own setters enforce). A non-zero freezer whose views revert or cannot be decoded fails closed; a freezer that ANSWERS zero passes (a genuine `ChallengeGame` never answers zero for `challengeWindow` — its setter rejects it — so a zero answer can only come from a non-genuine freezer; whether that asymmetry should also fail closed is tracked as an open decision in this change's design.md and is NOT changed here). A bond therefore cannot be reclaimed while it could still be forfeited: the filing deadline — including any `challengeableUntil` extension re-armed by a silent failure — and any live freeze both block reclaim, and no owner-side re-point can lift that hold.

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
- **WHEN** an executed proposal's proposer calls `reclaimProposerBond` before `executedAt + strategyDuration + challengeWindow` has elapsed
- **THEN** the call reverts `ChallengeWindowOpen`

#### Scenario: Reclaim refused while coverage is still frozen
- **WHEN** the challenge window has elapsed but the proposal's coverage is still frozen (an unresolved challenge)
- **THEN** `reclaimProposerBond` reverts `ChallengeWindowOpen`

#### Scenario: Reclaim refused while a silent-failure re-arm keeps filing admissible
- **WHEN** a challenge against an executed proposal fails in silence after `executedAt + strategyDuration + challengeWindow` (releasing the freeze and re-arming `challengeableUntil[reviewKey]` to `block.timestamp + challengeWindow`), and the proposer calls `reclaimProposerBond` while `block.timestamp <= challengeableUntil[reviewKey]`
- **THEN** the call reverts `ChallengeWindowOpen`, and a challenge filed inside the re-armed window that reaches a conviction finds the bond still in escrow — `forfeitBond` succeeds, paying the prosecutor fee and burning the remainder

#### Scenario: Reclaim opens the instant the re-armed deadline lapses
- **WHEN** the re-armed `challengeableUntil[reviewKey]` passes with no live challenge and no further filing
- **THEN** `reclaimProposerBond` succeeds at the first timestamp strictly greater than the deadline (where `file` would revert `WindowClosed`)

#### Scenario: Unchallenged proposal reclaims on the ordinary schedule
- **WHEN** an executed proposal is never challenged (its `challengeableUntil[reviewKey]` is zero) and both windows have elapsed since `executedAt + strategyDuration`
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

## REMOVED Requirements

### Requirement: The challenge vote — the quorum's denominator is the whole staked set
**Reason**: It said the `NoVotableStake` guard refuses any filing no conviction could clear. The guard checks only the stake outside the accused cohort; stake added after `snapshotAt` and the stake of the challenger, proposer and co-proposers sit in the base and cannot vote.
**Migration**: Replaced by "The challenge vote — the quorum's denominator and what the admission guard checks".
