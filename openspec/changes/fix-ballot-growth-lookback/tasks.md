# Tasks — fix-ballot-growth-lookback (option 2)

Sequencing gate before any code: rebase this branch on main AFTER issue #84
(`enforce-floor-invariant-in-setters`) merges — it edits `TokenCourt.sol`
setters and `test/mocks/MockStakedWood.sol`. If PR #144 (issue #83) has merged
too, rebase over it and re-verify this file's line references.

## 1. StakedWood — anchor checkpointing (design §2.3)

- [ ] 1.1 Declare `mapping(address => Checkpoints.Trace224) internal
      _anchorCheckpoints;` immediately below `__gap` and shrink the gap
      `uint256[4]` → `uint256[3]` (src/StakedWood.sol:387), extending the
      gap's doc comment with this change's entry, per the
      `_liabilityCheckpoints` precedent.
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
      doc (src/interfaces/IStakedWood.sol:101-111). Note the live-parameter
      qualification (design §2.3): historical evaluations use current
      `ageFloorBps`/`maturationPeriod`, unchanged from today.
- [ ] 1.5 Regenerate `script/staked-wood-layout.golden.json` and confirm
      `./script/check-layout-goldens.sh` passes.

## 2. TokenCourt — the weight min (design §1)

- [ ] 2.1 In `vote` (:421-441), replace the single weight read (:428-429)
      with: read `weightNow = getPastVotes(msg.sender, c.snapshotTs)`; compute
      `lookbackTs` (clamped at 0); when
      `getPastTotalVotes(lookbackTs) != 0`, read
      `weightThen = getPastVotes(msg.sender, lookbackTs)` and take
      `weight = min(weightNow, weightThen)`. Keep the
      `weight == 0 → NoVotingPower` check AFTER the min and BEFORE the
      present-holdings gate (:429/:431 ordering preserved — pinned by the
      :739 test). No new imports; no `mulDiv`. Hoist reads before any
      prank-sensitive call sites in tests (error-guardrails:
      argument-position calls eat one-shot cheatcodes).
- [ ] 2.2 Natspec on `vote` (:328-420): extend the flash-loan block (:334-341)
      — the snapshot bars post-drain stake; the min now also prices stake and
      age acquired inside `FLOOR_LOOKBACK` before it. Add a @dev block
      stating the exact rule (`min(weightNow, weightThen)`, each side on its
      own instant's anchor and raw), the bootstrap fallback and its
      total-not-caller keying, the top-up bound (design §3.2 — a top-up
      changes the ballot by exactly zero), the young-steady-cohort discount
      as an ACCEPTED COST verbatim from design §3.4, and the residuals from
      design §6 (dormant capital now needing ~60d for par; touch-stake
      unchanged). State the adversary for every guard (house style).
- [ ] 2.3 Natspec: present-holdings block (:394-420) — the re-stake residual's
      figure now also passes through the lookback min; one sentence on
      `FLOOR_LOOKBACK` (:80-91): it bounds the ballot as well as the floor's
      base. `ITokenCourt` natspec (:152 `NoVotingPower`, :196 `VoteCast`,
      :319 vote weight doc) updated to the min — natspec only, no ABI change.

## 3. Tests

- [ ] 3.1 `_caseWithElectorate` (test/TokenCourt.t.sol:1017): when
      `totalAtLookback != 0`, also set
      `swood.setPastVotes(voterA, snap - court.FLOOR_LOOKBACK(), 300e18)` and
      `swood.setPastVotes(voterB, snap - court.FLOOR_LOOKBACK(), 200e18)`
      (mature-steady modelling — equal aged weight at both instants). This
      un-breaks the five B2 tests at :1078, :1102, :1124, :1151, :1258. No
      `MockStakedWood` change (design §8).
- [ ] 3.2 Doc-comment touch-ups (no assertion changes) on :620
      `test_vote_tallies_agedWeight` and :703
      `test_vote_acceptsACurrentHolderWithHistoricWeight` noting they exercise
      the bootstrap-fallback (unclamped) branch.
- [ ] 3.3 New TokenCourt unit tests (vote section; lookback total non-zero so
      the min is live unless stated):
      (a) steady-mature regression — equal aged weight both instants → tally
      and `VoteCast` equal `getPastVotes(snap)` bit-exactly;
      (b) young-cohort discount — `weightThen < weightNow`, both non-zero →
      tally equals `weightThen` (pins design §3.4; mutation-kills dropping
      the min or gating it on raw growth);
      (c) cannot-exceed-now — `weightThen > weightNow` → tally equals the
      unclamped `weightNow`;
      (d) fresh-address attack regression (#82) — non-zero snap weight, zero
      lookback weight, non-zero lookback total → `NoVotingPower`, tally
      untouched (mutation-kills reverting to the bare single read);
      (e) bootstrap — lookback total 0 → weight unclamped.
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
      comment, which currently derives the 7_499e18 drift arithmetic.
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
- [ ] 4.2 `./script/check-layout-goldens.sh` (StakedWood golden), `forge fmt`
      with a CI-matching forge, and
      `openspec validate fix-ballot-growth-lookback --strict`.
- [ ] 4.3 Before opening the PR: confirm #84 merged and this branch is rebased
      on it; check PR #144's state and re-run the court suite after any
      rebase over it. PR targets `main` (stacked PRs get no CI).
