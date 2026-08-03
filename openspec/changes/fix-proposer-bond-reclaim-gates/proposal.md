# Fix proposer-bond reclaim gates: pin the ledger, acknowledge forfeiture (issues #116, #117)

## Why

Two Pashov-panel findings on merged PR #112 (issue #94), both in
`SyndicateGovernor.reclaimProposerBond`:

- **#116 (medium)**: the reclaim gates for executed proposals reach the
  challenge game THROUGH `_exposureLedger` (`src/SyndicateGovernor.sol:624`),
  a factory-mutable pointer. The `_openProposalCount > 0` guard on
  `setExposureLedger` (`src/SyndicateGovernor.sol:1632`) only counts
  NON-TERMINAL proposals — a Settled proposal holding a bond through its
  challenge window has already decremented it, so the pointer can be re-pointed
  at a permissive ledger (zero `coverageFreezer`, short window) exactly during
  the window the gates exist to hold, detaching them from a still-convictable
  challenge. The escrow pointer is pinned per proposal
  (`proposerBondEscrow`, `src/SyndicateGovernor.sol:1019`); the ledger is not.
  The exposure window is bounded by the CONFIGURED `disputeTimeout` — up to
  `MAX_DISPUTE_TIMEOUT = 60 days` (`src/ChallengeGame.sol:90`), not the
  shipped 30-day default.
- **#117 L1 (low)**: after `ProposerBondEscrow.forfeitBond` deletes the bond
  record on conviction, `reclaimProposerBond` reverts permanently (the escrow's
  `NoBond`), indistinguishable from "still locked" for a retrying integration,
  and `proposal.proposerBondWood` stays non-zero forever — stale state for any
  reader.
- **#117 L2 (low)**: the natspec's "fails closed" claim covered a freezer
  that REVERTS, but a freezer that ANSWERS zero for `challengeWindow()`
  passed the gate silently (`src/SyndicateGovernor.sol:639-649`). PR #119
  corrected the comment to state this honestly; Ana approved changing the
  BEHAVIOR on 2026-08-03, so it is fixed here.

One change for both issues: they edit the same ~40-line region of the same
function, and separate PRs would conflict.

## What Changes

- **Pin the exposure ledger per proposal** (#116): record the ledger address
  on the proposal at propose time, next to `proposerBondWood` /
  `proposerBondEscrow` (`_snapshotTierAndGate`), and make all three reclaim
  gates read the pinned address rather than the live `_exposureLedger` slot.
  A zero pinned value fails closed (`ExposureLedgerUnset`) with no fallback
  to the live slot — unreachable for a bond-carrying proposal, since the
  pin is written in the same transaction that locks the bond.
- **Acknowledge forfeiture at reclaim** (#117 L1): when the governor still
  records a bond but the pinned escrow's `bondOf` reports none, the bond was
  forfeited — zero `proposal.proposerBondWood`, emit a distinguishable event,
  and return without transferring, instead of reverting forever.
- **Zero-answer freezer semantics** (#117 L2): a wired freezer answering
  `challengeWindow() == 0` now fails closed (a genuine `ChallengeGame` can
  never answer zero — `setChallengeWindow` rejects it). Scoped to that view
  alone; `challengeableUntil == 0` still passes. Approved by Ana 2026-08-03,
  see design.md D7.
- Natspec updates at `src/SyndicateGovernor.sol:575` and `:588-598` closing
  the loops PR #119 left referencing issues #116/#117 by number.
- Storage: one appended member on `StrategyProposal` (mapping-held struct —
  append-only-safe); regenerate `script/syndicate-governor-layout.golden.json`
  in the same PR.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `challenge-game`: the "Proposer bond lock, release, and forfeiture"
  requirement — reclaim gates read the propose-time-pinned ledger, and a
  forfeited bond's reclaim becomes a distinguishable acknowledged no-op.
  NOTE: this delta stacks on the unarchived `fix-bond-reclaim-deadline`
  change's delta for the same requirement (issue #94 / PR #112, merged to
  main but not yet synced into `openspec/specs/challenge-game/spec.md`); the
  full requirement block here carries that text plus these changes.
- `syndicate-governor`: the "Risk tiering and proposer bond at propose"
  requirement — propose records the ledger address alongside the bond amount
  and escrow, and the reclaim scenarios gain the forfeited-bond outcome.

## Impact

- `src/SyndicateGovernor.sol` — `reclaimProposerBond` gates + natspec,
  `_snapshotTierAndGate` pin write.
- `src/interfaces/ISyndicateGovernor.sol` — `StrategyProposal` appended
  member, new event, (possibly) new error.
- `script/syndicate-governor-layout.golden.json` — regenerated (`types`
  section changes; top-level slots do not).
- ABI: `getProposal` returns the struct — the tuple grows one member.
  `ChallengeGame` decodes it (`src/ChallengeGame.sol:603`), so a beacon
  upgrade of the governor requires a matching `ChallengeGame` (re)deploy.
  No mainnet lineage exists (chains/4663.json records no protocol
  addresses), so this is a deploy-ordering note, not a live-chain break.
- Tests: `test/GovernorCoverageGates.t.sol`, `test/ChallengeEndToEnd.t.sol`
  (one existing assertion changes under L1), `test/CoverageEndToEnd.t.sol`
  unaffected on the happy path; new tests per tasks.md.
