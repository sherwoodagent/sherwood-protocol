# Tasks — fix-ballot-growth-lookback (option 2b: growth-gated min)

Sequencing gate before any code: rebase this branch on main AFTER issue #84
(`enforce-floor-invariant-in-setters`, d81d02a) merges — it edits
`TokenCourt.sol` setters, `ITokenCourt`, `test/mocks/MockStakedWood.sol`
(adds `ageFloorBps`), and rewrites large parts of `test/TokenCourt.t.sol`,
so RE-VERIFY every test line reference in this file at that rebase. PR #152
(issue #35, off-limits) shares `src/StakedWood.sol` /
`src/interfaces/IStakedWood.sol` / `test/mocks/MockStakedWood.sol`: if it
merges first, rebase over it and re-verify (it adds no StakedWood storage
and touches no golden — design §9); whichever of the two StakedWood-touching
changes lands second regenerates the layout golden and re-reviews its diff.
This branch adjusts; theirs never does.

## 1. StakedWood — anchor checkpointing (design §2.3)

**This is a storage append against the highest-consequence layout in the
repo** (golden-pinned, UUPS, live on testnets, custodies every WOOD bond —
script/check-layout-goldens.sh:223-229). Treat the golden diff in 1.5 as a
review artifact, not a chore.

- [ ] 1.1 Declare `mapping(address => Checkpoints.Trace224) internal
      _anchorCheckpoints;` IMMEDIATELY BELOW `__gap` and shrink the gap
      `uint256[4]` → `uint256[3]` (src/StakedWood.sol:387) — the END-of-gap
      carve the gap's own doc (:367-386) mandates pre-mainnet: the new
      mapping takes freed slot 20, and every field from `approvedBindVault`
      (slot 21) on keeps its slot. Extend the gap's doc comment with this
      change's entry, per the `_liabilityCheckpoints`/`approvedBindVault`
      precedent.
- [ ] 1.2 Push the anchor at all three write sites, same transaction as the
      existing raw pushes: after `g.stakedAt = uint64(block.timestamp)` in the
      first-stake branch (:604), after the re-anchor write in the top-up
      branch (:623), and after the request-time re-anchor in
      `requestUnstakeGuardian` (:843):
      `_anchorCheckpoints[msg.sender].push(uint32(block.timestamp), uint224(g.stakedAt));`
      Deliberately NO push in `cancelUnstakeGuardian` (does not write the
      anchor), `claimUnstakeGuardian` (raw already 0 from the request; a
      re-stake pushes a fresh anchor), or the slash paths (never write the
      anchor) — document each non-site in the trace's doc comment.
- [ ] 1.3 `getPastVotes` (:666-669): replace `_guardians[guardian].stakedAt`
      with `uint64(_anchorCheckpoints[guardian].upperLookupRecent(uint32(timestamp)))`.
- [ ] 1.4 Natspec: rewrite `_ageFactorBps`'s saturation sentence (:648-649)
      and `getPastVotes`'s @dev — historical reads are now anchor-exact; the
      "deflation-only drift" text is deleted WITH the behaviour, and the
      GuardianRegistry consequence (a post-open top-up no longer deflates a
      frozen review ballot) is stated. Mirror in `IStakedWood.getPastVotes`'s
      doc (src/interfaces/IStakedWood.sol:101-110). Note the live-parameter
      qualification (design §2.3): historical evaluations use current
      `ageFloorBps`/`maturationPeriod`, unchanged from today.
- [ ] 1.5 Regenerate `script/staked-wood-layout.golden.json` with
      `UPDATE_GOLDEN=1 ./script/check-layout-goldens.sh`, then REVIEW the
      golden diff before committing: expected is exactly the gap entry
      changing `t_array(t_uint256)4_storage` → `3_storage` at slot 17 plus
      one added `_anchorCheckpoints` entry at slot 20 — ANY other movement
      means the append was done wrong. Confirm the script passes clean
      afterwards.

## 2. TokenCourt — the growth-gated weight min (design §1)

- [ ] 2.1 In `vote` (:421-441), replace the single weight read (:428-429)
      with the gated clamp: read
      `weight = getPastVotes(msg.sender, c.snapshotTs)`; compute `lookbackTs`
      (clamped at 0); when
      `getPastStake(msg.sender, c.snapshotTs) > getPastStake(msg.sender, lookbackTs)`
      (STRICT — the shrink case rides on it, design §3.3) AND
      `getPastTotalVotes(lookbackTs) != 0`, read
      `weightThen = getPastVotes(msg.sender, lookbackTs)` and take
      `weight = min(weight, weightThen)`. Gate FIRST in the `&&` so the
      total read short-circuits away for non-growth voters (design §7).
      Keep the `weight == 0 → NoVotingPower` check AFTER the clamp and
      BEFORE the present-holdings gate (:429/:431 ordering preserved —
      pinned by test/TokenCourt.t.sol:887). No new imports; no `mulDiv`;
      `getPastStake` is already on `IStakedWood`. Hoist reads before any
      prank-sensitive call sites in tests (error-guardrails:
      argument-position calls eat one-shot cheatcodes).
- [ ] 2.2 Natspec on `vote` (:328-420): extend the flash-loan block (:334-341)
      — the snapshot bars post-drain stake; the gated min now also prices
      stake acquired inside `FLOOR_LOOKBACK` before it at its month-ago
      worth. Add a @dev block stating: the exact rule (gate on RAW growth,
      strict `>`, clamp on WEIGHTS, each side on its own instant's anchor
      and raw — and WHY raw not weight: age growth is legitimate, capital
      growth is the vector, design §1.1); the bootstrap fallback and its
      total-not-caller keying; the top-up bound (design §3.2 — never below
      the base's month-ago worth, AND the honest print that a top-up
      forfeits the window's aging on a still-maturing base relative to not
      topping up, zero forfeit for mature bases); and the residuals from
      design §6 — dormant capital parked a lookback early votes at PAR
      (this rule surrenders 2a's 60-day hardening, recorded as the price of
      un-taxing the steady cohort), the lookback boundary cliff, and the
      unchanged touch-stake. State the adversary for every guard (house
      style).
- [ ] 2.3 Natspec: present-holdings block (:394-420) — the re-stake
      residual's figure now also rides the gate (a full unstake/re-stake of
      the same amount reads `rawNow == rawThen`, gate false, and the
      re-anchored `weightNow` is what discounts it — design §6 residual 2);
      one sentence on `FLOOR_LOOKBACK` (:80-91): it now bounds the ballot as
      well as the floor's base. `ITokenCourt` natspec (:157 `NoVotingPower`,
      :199 `VoteCast`, :319-327 vote doc) updated to the gated min — natspec
      only, no ABI change.

## 3. Tests

Line references below are pre-#84-rebase (e34526c) — re-verify after the
rebase (sequencing gate above).

- [ ] 3.1 `_caseWithElectorate` (test/TokenCourt.t.sol:1165): when
      `totalAtLookback != 0`, also set
      `swood.setPastVotes(voterA, snap - court.FLOOR_LOOKBACK(), 300e18)` and
      `swood.setPastVotes(voterB, snap - court.FLOOR_LOOKBACK(), 200e18)`.
      Under the gate this works through the mock's raw-defaults-to-aged
      inference (`getPastStake` falls back to the `getPastVotes` fixture
      value): equal aged fixtures at both instants → equal defaulted raw →
      gate FALSE → clamp never evaluates — mature-steady modelling,
      bit-identical weights (design §8). This un-breaks the five B2 tests at
      :1226, :1250, :1272, :1299, :1406 (all five DO break under the gate —
      the unset lookback reads as raw growth; design §8 records the
      mechanism). No `MockStakedWood` change — the file is contended by #84
      and PR #152 and this change deliberately adds nothing to it.
- [ ] 3.2 Doc-comment touch-ups (no assertion changes) on :768
      `test_vote_tallies_agedWeight` and :851
      `test_vote_acceptsACurrentHolderWithHistoricWeight` noting they exercise
      the bootstrap-fallback (unclamped) branch.
- [ ] 3.3 New TokenCourt unit tests (vote section; use explicit
      `setPastStake` wherever the gate must be steered independently of aged
      weight — the mock's default couples them):
      (a) steady-mature regression — equal raw and aged weight both instants
      → tally and `VoteCast` equal `getPastVotes(snap)` bit-exactly;
      (b) YOUNG steady staker at par (the 2b headline — kills 2a's
      unconditional min and any weight-gated variant): equal raw both
      instants, `weightThen < weightNow` → tally equals the UNCLAMPED
      `weightNow`;
      (c) top-up bound — `rawNow > rawThen > 0`, `weightThen` non-zero →
      tally equals `weightThen` exactly, not reduced by any snapshot-side
      factor (kills a live-anchor-style implementation);
      (d) gate-true-weight-fell coherence (design §1.1) — `rawNow > rawThen`
      with `weightNow < weightThen` → tally equals `weightNow`;
      (e) shrink — `rawNow < rawThen`, `weightThen > weightNow` → tally
      equals `weightNow` (kills `>=` gating and any rule handing a shrinker
      the historical figure);
      (f) fresh-address attack regression (#82) — `rawThen = 0`, non-zero
      snap weight, non-zero lookback total → `NoVotingPower`, tally
      untouched (mutation-kills reverting to the bare single read);
      (g) partial-position attacker (design §3.1) — `rawThen = P > 0`,
      drain-time top-up of any size → tally is exactly the base's month-ago
      worth, unmoved by the increment;
      (h) bootstrap — lookback total 0, gate true → weight unclamped.
- [ ] 3.4 New StakedWoodAgeWeight tests (REAL contract — the anchor-exactness
      the mock cannot witness):
      (a) top-up after `ts` does not change `getPastVotes(g, ts)` (read
      before and after the top-up, assert equal — kills the live-anchor
      read);
      (b) unstake request after `ts` does not change `getPastVotes(g, ts)`;
      (c) read at a timestamp before the first stake returns 0;
      (d) live `getVotes` before/after the change in behaviour is
      bit-identical for a fresh fixture (guards the delegation at `now`).
- [ ] 3.5 test/GuardianRegistry.t.sol:254
      `test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates`: expected
      weight becomes 10_000e18 (par — anchor at `openedAt` pre-dates the
      top-up); rename to state what it now proves (a post-open top-up neither
      inflates nor deflates the frozen review ballot) and update its doc
      comment, which currently derives the 7_499e18 drift arithmetic (:262-273).
      This breakage is from the StakedWood change, independent of the gate.
- [ ] 3.6 Confirm `TokenCourtEndToEnd` stays green UNMODIFIED (design §8
      predicts every e2e vote lands in the bootstrap fallback) and that
      `StakedWood.t.sol` / `StakedWoodSlashing.t.sol` are unaffected.

## 4. Verification

- [ ] 4.1 `forge build` then `forge test --match-contract
      "TokenCourt|StakedWood|GuardianRegistry"` in the FOREGROUND with a
      generous timeout (serialize on the compiler:
      `while pgrep -x forge >/dev/null; do sleep 30; done` before every forge
      command — `pgrep -x solc` is inert, the binary is `solc-0.8.28`; 16 GB
      OOM rule). Never judge a build through a pipe.
- [ ] 4.2 `./script/check-layout-goldens.sh` (StakedWood golden — after the
      1.5 diff review), `forge fmt` with a CI-matching forge, and
      `openspec validate fix-ballot-growth-lookback --strict`.
- [ ] 4.3 Before opening the PR: confirm #84 merged and this branch is
      rebased on it with test line refs re-verified; check PR #152's state —
      if it merged, rebase over it, re-run the StakedWood suites, and
      re-review the layout golden diff on top of its (storage-free) changes.
      PR targets `main` (stacked PRs get no CI).
