# Proposal: fix-bond-reclaim-deadline

GitHub issue: #94 — "Proposer bond is reclaimable while the proposal is still convictable"

## Why

`SyndicateGovernor.reclaimProposerBond` (src/SyndicateGovernor.sol:573) gates a
Settled-after-execution reclaim on exactly two clocks: the **ledger's**
`challengeWindow` elapsed since `executedAt` (line 598) and the ledger's
per-proposal coverage freeze being clear (line 601). But `ChallengeGame.file`
admits a challenge until `max(executedAt + challengeWindow,
challengeableUntil[reviewKey])` (src/ChallengeGame.sol:602-605), and
`_refundAll` — the `Inconclusive` unwind — **releases the freeze and re-arms**
`challengeableUntil[rk] = block.timestamp + challengeWindow` in the same call
(src/ChallengeGame.sol:1338, 1355-1356). The two clocks are independent, so
between an `Inconclusive` unwind and the re-armed deadline the bond is
reclaimable while a conviction is still reachable. The governor's own natspec
concedes this as a "Known gap" (src/SyndicateGovernor.sol:564-567).

Concrete timeline at shipped defaults (ledger `challengeWindow` 14d,
ExposureLedger.sol:122; game `challengeWindow` 14d, ChallengeGame.sol:292;
`autoSlashDelay` 7d, ChallengeGame.sol:325; court `voteWindow` 5d,
TokenCourt.sol:101; `FINALIZE_BUFFER` 1d, TokenCourt.sol:77): execute day 0,
sock-puppet files day 13, self-disputes, pool completes and refers day 19,
vote closes day 24, turnout misses the floor → `Inconclusive` →
`challengeableUntil` = day 38 with the freeze released. Days 24→38 the bond
walks home; an honest challenge filed day 30 still convicts, slashes the
approvers 100%, and its `forfeitBond` call lands in `_settle`'s try/catch as
`ProposerBondForfeitureFailed` (src/ChallengeGame.sol:1107-1114). Since #106
the prosecutor's fee is paid **out of that bond** (ProposerBondEscrow.sol:246+),
so the reclaim also silently zeroes the prosecutor's compensation. The party
the threat model names "the actual attacker" (src/ChallengeGame.sol:1079-1081)
keeps its bond; the approvers who merely underwrote lose everything and the
prosecutor works for gas.

A second, smaller divergence exists through the same seam: the ledger owner
may lower `ExposureLedger.challengeWindow` (ExposureLedger.sol:498 checks only
a floor against the registry's review period) below the game's own
`challengeWindow`, after which the governor's gate opens before the game's
ordinary filing deadline even with no `Inconclusive` involved. Gating on the
game's real deadline closes both.

## What Changes

- `SyndicateGovernor.reclaimProposerBond` additionally requires, for executed
  proposals, that the challenge game's **actual filing deadline** has lapsed:
  `block.timestamp > max(executedAt + game.challengeWindow(),
  game.challengeableUntil(keccak256(abi.encode(address(this), proposalId))))`,
  where `game = IExposureLedger(ledger).coverageFreezer()`. Reverts
  `ChallengeWindowOpen` otherwise (same error as the two existing gates).
- The gate is applied only when `coverageFreezer() != address(0)`. With no
  freezer wired, no game can freeze (`ExposureLedger.freezeCoverage` is
  `onlyFreezer`, ExposureLedger.sol:260) and no game can forfeit
  (`ProposerBondEscrow.forfeitBond` requires
  `msg.sender == exposureLedger.coverageFreezer()`, ProposerBondEscrow.sol:227),
  so no conviction is reachable and the existing ledger-window + freeze gates
  remain the only (sufficient) hold — reclaim cannot be stranded by an unwired
  or rotated-away freezer.
- The "Known gap" natspec paragraph on `reclaimProposerBond` is replaced by the
  new gate's rationale.
- No changes to `ChallengeGame`, `ProposerBondEscrow`, or `ExposureLedger`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `challenge-game`: the "Proposer bond lock, release, and forfeiture"
  requirement's reclaim-gating paragraph changes — the governor's release gate
  must track the game's live filing deadline (`challengeableUntil` and the
  game's own `challengeWindow`), not only the ledger's window and freeze, so
  the stated invariant "a bond cannot be reclaimed while it could still be
  forfeited" actually holds. Adds scenarios for the reclaim-then-convict
  window, the unchallenged-proposal schedule, and the unset-freezer fallback.

## Impact

- `src/SyndicateGovernor.sol` — `reclaimProposerBond` gains one gate (reads
  `coverageFreezer()` from the already-required ledger, then two views on the
  game). Interfaces already expose everything needed:
  `IExposureLedger.coverageFreezer()` (src/interfaces/IExposureLedger.sol:89),
  `IChallengeGame.challengeWindow()` (src/interfaces/IChallengeGame.sol:607),
  `IChallengeGame.challengeableUntil(bytes32)`
  (src/interfaces/IChallengeGame.sol:697). The governor gains an
  `IChallengeGame` import.
- Contract size: the governor sits well inside the Robinhood 98,304-byte
  ceiling; the legacy Base deployment is not receiving this stack.
- Tests: `test/` suites covering `reclaimProposerBond` (reclaim timing,
  challenge end-to-end) gain the reproduction and regression cases listed in
  tasks.md. Mocks that stand in for the ledger must answer `coverageFreezer()`
  (returning `address(0)` preserves old behavior for suites without a game).
- No storage layout changes, no new events, no new errors.
