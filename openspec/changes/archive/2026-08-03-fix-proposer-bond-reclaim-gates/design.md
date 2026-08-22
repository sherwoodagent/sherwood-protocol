# Design — fix-proposer-bond-reclaim-gates (issues #116, #117)

## Context

See proposal.md for motivation. Verified facts the design rests on (current
main, post-#112/#119):

- The reclaim gates read the live pointer: `address ledger = _exposureLedger;`
  at `src/SyndicateGovernor.sol:624`, then `challengeWindow()` (`:631`),
  `isCoverageFrozen` (`:634`), `coverageFreezer()` (`:639`) and the game's
  window/`challengeableUntil` (`:640-648`) all through it.
- The escrow, by contrast, is pinned: written at `:1018-1019`
  (`_snapshotTierAndGate`), released against `proposal.proposerBondEscrow`
  at `:651-656`.
- `setExposureLedger` (`:1622-1635`) is `onlyFactory`; its guard
  `_openProposalCount > 0` (`:1632`) counts only NON-terminal proposals
  (`src/ProposalLifecycle.sol:28,260-261`; Settled decrements via `_decOpen`
  at `src/SyndicateGovernor.sol:672` etc.), so the guard is open exactly
  during the post-settlement bond-hold window. The factory path is
  `SyndicateFactory.setExposureLedger` (owner, `src/SyndicateFactory.sol:630`)
  + `pushWiring` — two owner txs. `setExposureLedger(0)` is exempt from the
  guard, but reclaim fails closed on a zero ledger (`:630`,
  `ExposureLedgerUnset`), so the zero re-point cannot open the gates; the
  permissive-ledger re-point can.
- Exposure window: a `Disputed` challenge runs to `disputeTimeout`, owner-set
  up to `MAX_DISPUTE_TIMEOUT = 60 days` (`src/ChallengeGame.sol:90,1748-1752`);
  shipped default 30 days (`:336`).
- Post-forfeiture behavior: `_settle` releases the freeze
  (`src/ChallengeGame.sol:1035`) before best-effort `forfeitBond`
  (`:1117-1132`), which deletes the escrow record
  (`src/ProposerBondEscrow.sol:243-248`). The governor's
  `proposal.proposerBondWood` is never touched, so reclaim passes its gates
  once windows lapse and dies in `releaseBond`'s `NoBond`
  (`src/ProposerBondEscrow.sol:151-159`) — permanently, and
  `proposerBondWood` stays stale (issue #117 L1 confirmed).
- Zero-answer freezer: gate 3 (`:639-649`) computes
  `deadline = executedAt + game.challengeWindow()`; a freezer answering 0
  makes the deadline `executedAt`, already past — passes. A reverting freezer
  bubbles (no try/catch) — fails closed. Natspec `:594-598` states this
  honestly (PR #119), tagging issue #117.
- The escrow exposes `bondOf(governor, proposalId)`
  (`src/interfaces/IProposerBondEscrow.sol:58`,
  `src/ProposerBondEscrow.sol:279`) — the forfeiture-detection view already
  exists.
- `SyndicateGovernor` layout is pinned by `script/check-layout-goldens.sh`
  (golden `script/syndicate-governor-layout.golden.json`, `types` section
  covers structs reachable through mappings) and by raw-slot pins in
  `test/governor/GovernorLayoutPins.t.sol` (top-level slots only).
- A genuine game can never answer zero for `challengeWindow`:
  `setChallengeWindow` rejects 0 (`src/ChallengeGame.sol:1622`), default
  14 days (`:292`); the ledger's window is likewise bounded well above zero
  (`src/ExposureLedger.sol:698`, default 14 days at `:183`).

## Goals / Non-Goals

**Goals:**

- Reclaim gates that no owner/factory re-point can detach from the challenge
  they guard, for any bond already locked (#116).
- A terminal, distinguishable, state-cleaning outcome for reclaiming a
  forfeited bond (#117 L1).
- Natspec that stops citing #116/#117 as open caveats.

**Non-Goals:**

- Changing zero-answer freezer semantics (#117 L2) — recommendation recorded
  below, implementation blocked on Ana's decision.
- The interim guard alternative from issue #116 (refusing `setExposureLedger`
  while bonds are outstanding) — superseded by pinning; see D1 alternatives.
- Issue #35 (the other booking-vs-enforcement divergence, in
  `_slashableBondUsd`) — same family, different site, separate change.
- Re-pointing hazards internal to `ChallengeGame`/`ExposureLedger` (the
  game's own `setExposureLedger` already guards its side,
  `src/ChallengeGame.sol:1607-1613`).

## Decisions

### D1 — Pin the ledger as an appended `StrategyProposal` member

Append `address proposerBondLedger;` at the tail of `StrategyProposal`
(`src/interfaces/ISyndicateGovernor.sol:73-160`, after `snapshotPerfSplit`,
in the "APPENDED FIELDS ONLY BELOW" region). Write it in
`_snapshotTierAndGate` next to the two existing bond writes (`:1018-1019`),
before the external `lockBond` call (CEI, same invariant comment that
already governs that block). `reclaimProposerBond` resolves:

```
ledger = proposal.proposerBondLedger; if zero → _exposureLedger (fallback)
```

and runs all three gates against it.

*Why this over a parallel mapping* (`mapping(uint256 => address)` carved
from `__gap`): the pin is the third leg of one propose-time record —
`proposerBondWood` (amount), `proposerBondEscrow` (custodian),
`proposerBondLedger` (policy) — written together, read together, and the
struct is where the other two live; a mapping would scatter the record and
still churn the golden. Struct-member appends into a mapping-held struct are
layout-safe and have precedent (the entire appended region; `Review` 3→4
slots per the golden script's own commentary).

*Why not pin the freezer (game) address instead*: the gates need the
ledger's window and freeze state too; the ledger is the hub all three gates
hang off, and the freezer is deliberately read live THROUGH it so a
legitimate freezer rotation on the pinned ledger still works (recovery, D4).

*Why not only the interim guard* (refuse re-pointing while bonds
outstanding): it trades an owner lever for the invariant, needs a new
outstanding-bond counter (none exists; `_openProposalCount` provably does
not cover it), and still leaves the gate semantically attached to a mutable
slot. Pinning is the same design the escrow already proved.

### D2 — Zero pinned value falls back to the live slot

Bond-carrying proposals created before the upgrade have
`proposerBondLedger == 0`; they keep today's exact semantics (live read,
`ExposureLedgerUnset` fail-closed on zero). Post-upgrade, any proposal that
locks a bond necessarily has a non-zero ledger (the bond is only priced and
locked when a ledger is wired, `:985-1041`), so the fallback is dead code
for new records — purely a migration seam. No initializer/reinitializer
needed.

### D3 — Forfeiture acknowledge: success-no-op, detected via `bondOf`

In `reclaimProposerBond`, after the `bond == 0` check (`:616-617`) and
terminal-state check, and BEFORE the executed-proposal window gates: read
`(, uint256 held) = IProposerBondEscrow(proposal.proposerBondEscrow)
.bondOf(address(this), proposalId)`. If `held == 0` while the governor
records `bond != 0`, the bond was forfeited — zero
`proposal.proposerBondWood`, emit new event
`ProposerBondForfeitureAcknowledged(proposalId, bond)`, return.

*Why detection via `bondOf`*: the predicate `governor-records-bond ∧
escrow-holds-none ⟺ forfeited` is exact — the escrow record has exactly two
deleting exits, and the release exit zeroes the governor's record in the
same nonReentrant transaction (`:655-656`), so the half-state is never
observable. No new escrow surface, no game→governor callback on the verdict
path (which would add a best-effort external call to `_settle` and a trust
edge the verdict path deliberately keeps thin).

*Why success-no-op over a distinct revert* (`BondAlreadyForfeited()`): a
revert rolls back the zeroing, so it fixes distinguishability but leaves
`proposerBondWood` stale forever — half of L1. The no-op fixes both with one
mechanism, terminates retry-on-revert integrations definitively (success),
and converges to the same terminal answer (`NoBondToReclaim`) on the next
call. The cost — a caller expecting WOOD gets success without payment — is
mitigated by the dedicated event (and no `BondReleased` from the escrow, so
off-chain accounting cannot mistake it for a payout).

*Ordering*: before the window gates, not after — a forfeited bond has no
window to wait out, and gate 3 can otherwise return `ChallengeWindowOpen`
for a bond that no longer exists (the filing deadline outlives a conviction
whenever the verdict lands before `challengeableUntil`).

### D4 — Recovery story under pinning (what changes, what doesn't)

Today's natspec (`:594-595`) offers two recoveries from a wedged gate-3
freezer: rotate `coverageFreezer` or re-point the ledger. Pinning removes
the second FOR EXISTING BONDS — deliberately, since it is exactly the attack
vector. Recovery remains on the pinned ledger's own owner surface:
`ExposureLedger.setCoverageFreezer` (`src/ExposureLedger.sol:742`) rotates
the freezer the gate reads (to a working game, or to zero which skips gate 3
entirely once no freeze is live). The freezer is read LIVE through the
pinned ledger for exactly this reason. Natspec at `:588-598` must be
rewritten to state the new recovery surface and drop the "(issue #116)" /
"(issue #117)" caveats that PR #119 left as forward references. Residual:
a pinned ledger that is itself irrecoverably broken (not merely its freezer)
strands the bond — accepted; the gates read only simple public getters on
it, the same ones `propose` already depended on when pricing the bond, and
the same trust the game itself places in its constructor-wired ledger.

### D5 — One change, one PR, for #116 + #117

Both fixes edit `reclaimProposerBond`'s ~40-line gate block and its natspec;
two PRs would conflict textually and semantically (the forfeiture check's
ordering interacts with the gate block D3 reorders). L2, if approved later,
is a two-line follow-up inside gate 3.

### D6 — Storage/ABI mechanics

- Golden: top-level slots unchanged (struct lives inside the `_proposals`
  mapping at slot 1); the golden's `types` section changes → regenerate via
  `./script/check-layout-goldens.sh --update-golden` and commit in the same
  PR. `GovernorLayoutPins.t.sol` pins only top-level slots — unaffected, no
  pin edits (its own header forbids editing pins; nothing moves).
- ABI: `getProposal` (`:781`) returns the struct; the tuple grows one
  member. In-repo consumers recompile (`ChallengeGame` at
  `src/ChallengeGame.sol:603` decodes it via the shared interface). A
  DEPLOYED game binary cannot decode the new tuple — deploy note: a governor
  beacon upgrade carrying this change requires a matching game deploy on any
  chain with a live pairing. No mainnet lineage exists (chains/4663.json);
  testnet 46630's syndicates are already slated for fresh deploys per the
  golden script's own commentary.

## Risks / Trade-offs

- [Stale-policy pin: the pinned ledger's parameters (window) can be tuned
  after propose and the gates follow them] → intended — the pin fixes WHICH
  ledger, not a snapshot of its numbers; gate 3 already deliberately reads
  the game's LIVE deadline, and the ledger's own setters bound its window.
- [Governor and game can end up gating through different ledgers if the
  game's ledger is rotated mid-flight] → the game's own `setExposureLedger`
  demands the new ledger's freezer grant (`src/ChallengeGame.sol:1607-1613`)
  and the freeze refcount is defensive (`:1196-1204`); the governor-side pin
  never worsens this — it removes one of the two moving pointers.
- [Success-no-op reclaim surprises a caller expecting WOOD] → dedicated
  event, no transfer, next call reverts `NoBondToReclaim`; strictly more
  informative than today's undifferentiated revert.
- [`bondOf` read adds an external view call per executed-proposal reclaim]
  → one staticcall to an ownerless contract already trusted for the release
  itself; negligible.
- [Golden regeneration masks an accidental non-append] → the golden diff in
  the PR shows exactly the one appended member; CI re-runs the script.
- [Test breakage: `test/ChallengeEndToEnd.t.sol`
  `test_conviction_forfeitsTheProposerBond` asserts `vm.expectRevert()` on
  post-forfeiture reclaim (~`:880-884`)] → assertion flips to the
  acknowledged no-op (event + zeroed record + unchanged balances); called
  out in tasks.md.

## Migration Plan

1. Land contract change + regenerated golden + tests in one PR to `main`.
2. Fresh deploys pick it up automatically. For any chain with a live
   governor beacon AND a paired game: upgrade the beacon and deploy a
   recompiled game in the same operation (ABI note, D6); pre-existing
   bond-carrying proposals ride the D2 fallback until drained.
3. Rollback: revert the beacon to the prior implementation — the appended
   member is at the struct tail, so old code simply never reads it; no state
   migration in either direction.

## Open Questions

### #117 L2 — should a freezer that ANSWERS zero fail closed? [BLOCKED ON ANA — do not implement either way without her explicit confirmation]

The audit flagged it and deliberately did not resolve it; one panel agent
proposed the hard-block and the lead rejected it. Both sides:

**For treating `game.challengeWindow() == 0` as failure (recommended):**
a genuine `ChallengeGame` can never answer 0 — `setChallengeWindow` rejects
it (`src/ChallengeGame.sol:1622`) and the default is 14 days — so a zero
answer can only come from a stub, a proxy gone wrong, or a hostile
lookalike, and waving it through is exactly the #116 detachment executed at
the freezer layer instead of the ledger layer (a hazard pinning shrinks but
does not close: the pinned ledger's owner can still rotate `coverageFreezer`
to a zero-answering stub). Failing closed strands nothing wired correctly:
the legitimate "no window, reclaim freely" configuration is already
expressible as `coverageFreezer == 0`, which skips gate 3 by design.

**For keeping the current pass-through:** the gate's fail-closed posture
exists to stop UNREADABLE freezers, not unhelpful ones; a future legitimate
freezer implementation reporting 0 ("nothing challengeable") would brick
every executed-proposal reclaim on that ledger until its owner rotates the
slot — the exact honest-bond-stranding the lead auditor rejected the
hard-block over. `challengeableUntil == 0` is a NORMAL answer (untouched
key) and must keep passing under either outcome; a zero-check that
overreaches by one view turns every unchallenged proposal into a wedge.

**Recommendation:** fail closed on `challengeWindow() == 0` only, keep
`challengeableUntil` zero-pass, reuse `ChallengeWindowOpen` (semantics: the
window cannot be proven shut). Scope if approved: ~2 lines inside gate 3 +
one test with a zero-answering mock freezer; no spec-structure change beyond
flipping one sentence in the challenge-game delta. NOT settled — Ana
decides.
