# Design: fix-bond-reclaim-deadline

## Context

See proposal.md — Why. The single fact this design turns on: the only clock
`ChallengeGame.file` actually enforces is
`max(executedAt + challengeWindow, challengeableUntil[key])`
(src/ChallengeGame.sol:602-605), while `reclaimProposerBond` enforces two
different clocks that both read from the ledger (src/SyndicateGovernor.sol:598,
601). The correct reclaim predicate is "is a filing still admissible on the
game" — which the governor can only answer by asking the game.

Wiring facts constraining the approach:

- The governor holds no game reference. Its only path to the game is
  `_exposureLedger` → `IExposureLedger.coverageFreezer()`
  (src/interfaces/IExposureLedger.sol:89) — the same resolution
  `ProposerBondEscrow.forfeitBond` already trusts for the opposite decision
  (src/ProposerBondEscrow.sol:227). Both sides of the bond's fate then key off
  one slot.
- `IChallengeGame` already exposes `challengeWindow()` (interface line 607)
  and `challengeableUntil(bytes32)` (line 697). No interface changes.
- The game's review key is `keccak256(abi.encode(governor, proposalId))`
  (src/ChallengeGame.sol:549-551, "Same derivation as ExposureLedger and
  GuardianRegistry"). From inside the governor that is
  `keccak256(abi.encode(address(this), proposalId))` — the issue's suggested
  derivation is correct as written.
- The game's setters guarantee `game.challengeWindow <= ledger.challengeWindow`
  at construction (src/ChallengeGame.sol:516), on `setChallengeWindow`
  (src/ChallengeGame.sol:1619), and on `setExposureLedger`
  (src/ChallengeGame.sol:1592) — but nothing stops the LEDGER owner lowering
  its own window under the game's afterward (src/ExposureLedger.sol:498 floors
  only against the registry review period). So the gate reads the game's
  window too, not just `challengeableUntil`.

## Goals / Non-Goals

Goals:

- No timestamp at which `ChallengeGame.file` would accept a filing against an
  executed proposal AND `reclaimProposerBond` would release its bond.
- Zero schedule change for unchallenged proposals under a correctly configured
  deployment (game window <= ledger window, which the game enforces).
- No new storage, events, errors, or interface members; no changes outside
  `SyndicateGovernor.sol`.

Non-Goals:

- Fixing the #106 spec drift beyond the one requirement block this delta must
  carry in full (noted in the delta header).
- Bounding how long repeated `Inconclusive` grinds can extend
  `challengeableUntil`. That cost is already priced by the escalating
  inconclusive burn (src/ChallengeGame.sol:1387+ schedule,
  `inconclusiveRounds`); the bond being held for as long as a conviction is
  reachable is the correct behavior, not a DoS to mitigate here.
- Constraining `ExposureLedger.setChallengeWindow` against the game's window
  (the ledger cannot know its freezer is a game). The governor-side max-read
  makes the divergence harmless for the bond; the ledger's own bucket-expiry
  consequences are out of scope.

## Decisions

### D1 — Fix lives in the governor, not the ledger or escrow

The governor is the sole gatekeeper of WHEN release is legal (the escrow
deliberately re-derives nothing, src/ProposerBondEscrow.sol:142-150; the spec
says the same). A ledger-side pin — e.g. having `_refundAll` re-freeze or the
ledger track the extended deadline — would (a) add a write path from game to
ledger that doesn't exist today, (b) overload `isCoverageFrozen`, whose
semantics ("an open, unresolved challenge") other readers rely on, and
(c) still leave the governor reading the wrong clock for the ordinary-window
divergence. A view-only read at the single reclaim entrypoint is the minimal
blast radius. Alternative rejected: gating inside `ProposerBondEscrow.releaseBond`
— the escrow is ownerless and lifecycle-blind by design; teaching it clocks
inverts its whole model.

### D2 — Gate on the game's FULL deadline, not only `challengeableUntil`

The issue's one-liner reads only `challengeableUntil`. That closes the
`Inconclusive` re-arm (the exploited path) but leaves the
ledger-window-lowered-below-game-window divergence open. Mirroring `file`'s
own computation — `max(executedAt + game.challengeWindow(),
challengeableUntil(key))` — makes the reclaim predicate definitionally the
negation of filing admissibility, so the two can never diverge again however
the windows are tuned. Cost: one extra view call. The existing ledger-window
gate (line 598) stays: it is the only time gate when no freezer is wired, and
redundant checks that fail identically are cheap.

### D3 — Strict `>` comparison

`file` admits while `block.timestamp <= deadline` (reverts `WindowClosed` only
when `>`, src/ChallengeGame.sol:605). Reclaim must therefore require
`block.timestamp > deadline` — at `timestamp == deadline` a filing is still
admissible, so reclaim reverts. The issue's suggested `>=` off-by-one would
leave a one-second overlap. (A filing landing at the deadline then blocks
reclaim onward via the coverage freeze, gate 2.)

### D4 — Skip the game gate when `coverageFreezer` is zero; otherwise fail closed

- `coverageFreezer == address(0)`: skip gate 3. Justification is structural,
  not charitable: `freezeCoverage` is `onlyFreezer`
  (src/ExposureLedger.sol:260) so no filing can complete, and
  `forfeitBond` requires the caller to BE the freezer
  (src/ProposerBondEscrow.sol:227) so no conviction can collect. Nothing is
  reachable that reclaim could pre-empt. This is what keeps an unwired
  deployment (and every existing test fixture with a bare mock ledger
  returning zero) working unchanged, and honest bonds un-strandable through
  that misconfiguration.
- `coverageFreezer` non-zero but not answering `challengeableUntil` /
  `challengeWindow` (rotated to a non-game freezer, or a broken address): the
  staticcalls revert and reclaim reverts — fail closed, matching the
  function's existing posture for an unset ledger
  (src/SyndicateGovernor.sol:592-597) and recoverable the same way: the
  ledger owner rotates `coverageFreezer` (legal whenever nothing is frozen,
  src/ExposureLedger.sol:530-534) or the factory re-points the ledger. No
  try/catch: a freezer we cannot read is indistinguishable from one that
  lies, and a lying freezer under fail-open releases early — closed is the
  only safe default, and every existing gate in this function already chose
  it.

### D5 — Key derivation inline, matching `_reviewKey`

`keccak256(abi.encode(address(this), proposalId))` — verified identical to
`ChallengeGame._reviewKey` (src/ChallengeGame.sol:549-551). `abi.encode`
(padded), not `abi.encodePacked`. No helper worth extracting for one use;
a comment cites the game's derivation.

### D6 — Natspec replaces the "Known gap" paragraph

The paragraph at src/SyndicateGovernor.sol:564-567 documents exactly this bug;
shipping the fix while leaving it would be false documentation. House style:
state the adversary (a proposer racing an `Inconclusive` unwind's re-armed
window) and cross-reference `ChallengeGame._refundAll`.

## Risks / Trade-offs

- [Griefer extends the hold indefinitely via repeated Inconclusive rounds]
  → Priced, not prevented: each round burns an escalating slice of a bond
  sized at `challengerBondBps` (5%) of frozen coverage (rounds 2/3 fixed,
  4+ at `inconclusiveBurnBps`), and the hold is exactly coextensive with
  "a conviction is still reachable" — which is the invariant, not a side
  effect.
- [New external calls from reclaim] → All views on contracts the governor
  already trusts transitively (ledger, and the freezer the ledger names);
  reclaim is `nonReentrant` and the calls precede the effects block.
- [A non-game freezer bricks reclaim until rotated] → Accepted, matches the
  existing fail-closed posture; recovery documented in D4. The rotation
  gate (`_frozenKeyCount == 0`) cannot deadlock this: a frozen key means a
  live challenge, which blocks reclaim anyway via gate 2.
- [Mocks in existing suites revert on `coverageFreezer()`] → Suites wiring a
  real `ExposureLedger` get the real freezer; bare-mock suites must add a
  zero-returning `coverageFreezer()`. Task 3 sweeps them.

## Migration Plan

Contract-only change to the governor implementation behind `GovernorBeacon`;
one beacon upgrade rolls it out, no storage migration, no re-wiring. Rollback
is re-pointing the beacon at the previous implementation. Bonds already
reclaimed through the gap are unrecoverable (they went home); the fix is
prospective.

## Open Questions

None.
