# challenge-game (delta)

<!-- Change: fix-bond-reclaim-deadline (issue #94). The reclaim-gate paragraph
     is the substantive change. The forfeitBond paragraph is additionally
     reconciled to shipped behavior from #106 (prosecutor fee carved from the
     bond, `forfeitBond(governor, proposalId, feeTo, feeBps)`), which merged
     without a spec sync — a MODIFIED delta must carry the full requirement
     block, and carrying the stale text would re-assert behavior the code no
     longer has. -->

## MODIFIED Requirements

### Requirement: Proposer bond lock, release, and forfeiture
`ProposerBondEscrow` SHALL be ownerless with no discretionary exit — exactly two exits exist, release and forfeiture, and both are keyed rather than caller-directed. `lockBond(proposalId, proposer, amount)` SHALL be callable only by a registry-authorized governor (`NotAuthorizedGovernor`), with a non-zero proposer, `amount <= type(uint96).max` (`AmountTooLarge`), and at most one bond per `(governor, proposalId)` key (`BondAlreadyLocked`); the WOOD is pulled from the named proposer. `releaseBond(proposalId)` SHALL key the bond to `msg.sender` (so only the governor that locked it can address it) and deliberately SKIP the live registry check — a later-deauthorized governor can still release open bonds to the recorded proposer rather than stranding them; the payout always goes to the recorded proposer, never a caller-chosen payee. `bondOf(governor, proposalId)` SHALL report the recorded proposer and amount.

`forfeitBond(governor, proposalId, feeTo, feeBps)` SHALL be callable only by the live `coverageFreezer` of the wired exposure ledger — the challenge game and nothing else (`NotAuthorizedConvictor`) — fail-closed when the freezer is unset. It SHALL reject `feeBps > MAX_PROSECUTOR_FEE_BPS` (`FeeBpsTooHigh`, revert not clamp) and SHALL delete the bond record before transferring (so a second forfeit on the same key hits `NoBond` rather than double-burning). The prosecutor's fee — `feeBps` of the bond, paid to `feeTo` — comes off the top; the remainder SHALL burn to `BURN_ADDRESS` with no other payee (every alternative destination is a round trip back to the party that forfeited or to whoever governs). `ChallengeGame._settle` SHALL call `forfeitBond` best-effort (wrapped in try/catch, emitting `ProposerBondForfeited` on success or `ProposerBondForfeitureFailed` on revert) exactly once per proposal, inside the `_convicted` branch, so a proposal with one liability and one bond cannot have it taken twice by concurrent challenges.

The governor gates WHEN release is legal, not the escrow: `SyndicateGovernor.reclaimProposerBond` requires the proposal in a terminal state (`Rejected`/`Expired`/`Cancelled`/`Settled`), and for an EXECUTED proposal additionally requires ALL of the following, reverting `ChallengeWindowOpen` otherwise and `ExposureLedgerUnset` (fail-closed) when the exposure ledger is unset:

1. `block.timestamp >= executedAt + ledgerChallengeWindow` (the ledger's window);
2. coverage not currently frozen for that proposal (an open, unresolved challenge);
3. when the ledger's `coverageFreezer` is a non-zero address, the game's LIVE filing deadline has lapsed: `block.timestamp > max(executedAt + gameChallengeWindow, challengeableUntil[reviewKey])`, read from the freezer with the same review-key derivation the game uses (`keccak256(abi.encode(governor, proposalId))`). The comparison MUST be strict (`>`), mirroring `file`'s admissibility bound (`block.timestamp <= deadline`), so there is no instant at which a filing is still admissible and the bond is simultaneously reclaimable.

Gate 3 SHALL be skipped entirely when `coverageFreezer` is the zero address: with no freezer wired, no challenge can freeze coverage and no convictor can reach `forfeitBond`, so no conviction is reachable and gates 1-2 remain a sufficient hold — an unwired or rotated-away freezer MUST NOT strand honest proposers' bonds. For an unchallenged proposal `challengeableUntil[reviewKey]` is zero (an untouched key), so gate 3 reduces to the game's ordinary window and reclaim proceeds on the same schedule as before whenever the game's window does not exceed the ledger's (which the game's own setters enforce). A bond therefore cannot be reclaimed while it could still be forfeited: the filing deadline — including any `challengeableUntil` extension re-armed by an `Inconclusive` unwind — and any live freeze both block reclaim.

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
