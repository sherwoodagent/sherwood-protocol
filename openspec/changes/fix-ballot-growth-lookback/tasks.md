# Tasks — fix-ballot-growth-lookback

## 1. Contract change (src/TokenCourt.sol)

- [ ] 1.1 Add `import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";`
      alongside the existing OZ import (:4).
- [ ] 1.2 In `vote` (:413-433), replace the single weight read (:420) with the
      growth clamp per design §1: compute `lookbackTs` (clamped at 0),
      `rawNow = getPastStake(msg.sender, snapshotTs)`,
      `rawThen = getPastStake(msg.sender, lookbackTs)`,
      `weight = getPastVotes(msg.sender, snapshotTs)`; when
      `getPastTotalVotes(lookbackTs) != 0 && rawNow > rawThen`, set
      `weight = Math.mulDiv(weight, rawThen, rawNow)`. Keep the
      `weight == 0 → NoVotingPower` check AFTER the clamp and BEFORE the
      present-holdings gate (:421-423 ordering preserved). Hoist all reads
      before any prank-sensitive call sites in tests (error-guardrails:
      argument-position calls eat one-shot cheatcodes).
- [ ] 1.3 Natspec: extend the flash-loan @dev block (:333-340) — the snapshot
      bars post-drain stake, the clamp now also silences stake GROWTH inside
      `FLOOR_LOOKBACK` before it; add a new @dev block stating the exact rule
      (`f(snapshotTs) * min(rawNow, rawThen) / 1e4`), why narrow-not-blanket
      (steady/shrinking guardians keep full weight; blanket would silence the
      < ~60-day honest cohort), the bootstrap fallback and its total-not-caller
      keying, and the residuals verbatim from design §3 (dormant capital,
      touch-stake/endpoint sampling, honest top-up under-shoot from the
      stakedAt re-anchor). State the adversary for every guard (house style).
- [ ] 1.4 Natspec: update the present-holdings block (:386-412) — the re-stake
      residual now additionally requires raw history at both sampled instants —
      and add one sentence to `FLOOR_LOOKBACK`'s doc (:80-91): it bounds the
      ballot's raw basis as well as the floor's base.

## 2. Test updates (test/TokenCourt.t.sol)

- [ ] 2.1 `_caseWithElectorate` (:1016): when `totalAtLookback != 0`, also set
      `swood.setPastVotes(voterA, snap - court.FLOOR_LOOKBACK(), 300e18)` and
      `swood.setPastVotes(voterB, snap - court.FLOOR_LOOKBACK(), 200e18)`
      (steady-staker modelling; mock `getPastStake` defaults to these). This
      un-breaks the five B2 tests at :1077, :1101, :1123, :1150, :1257.
- [ ] 2.2 Doc-comment touch-ups (no assertion changes) on :619
      `test_vote_tallies_agedWeight` and :702
      `test_vote_acceptsACurrentHolderWithHistoricWeight` noting they exercise
      the bootstrap-fallback (unclamped) branch.

## 3. New tests (test/TokenCourt.t.sol, vote section; lookback total non-zero unless stated)

- [ ] 3.1 Steady-staker regression: identical raw at both instants → recorded
      weight and `VoteCast` equal `getPastVotes(snap)` bit-exactly.
- [ ] 3.2 Growth clamp: `setPastStake` rawNow > rawThen with an aged snap
      figure via `setPastVotes` → weight equals
      `Math.mulDiv(aged, rawThen, rawNow)`.
- [ ] 3.3 Shrunk position: rawNow < rawThen → weight equals the unclamped
      `getPastVotes(snap)`, NOT the historical figure.
- [ ] 3.4 Fresh-address attack regression (#82): non-zero snap weight,
      `rawThen = 0`, lookback total non-zero → `NoVotingPower`; assert the
      tally is untouched. Mutation check: reverting the clamp to the bare :420
      read must fail this test.
- [ ] 3.5 Bootstrap fallback: lookback total 0 → weight unclamped (existing
      behaviour), mirroring the floor's `earlier == 0` branch.

## 4. Verification

- [ ] 4.1 `forge build` then `forge test --match-contract TokenCourt` in the
      FOREGROUND (serialize on solc: `while pgrep -x solc >/dev/null; do sleep
      30; done` first — 16 GB machine OOM rule). Confirm
      `TokenCourtEndToEnd` stays green unmodified (design §7 predicts the
      bootstrap fallback covers it).
- [ ] 4.2 `forge fmt` with a CI-matching forge; `openspec validate --strict
      --change fix-ballot-growth-lookback`.
- [ ] 4.3 Before opening the PR: check whether
      `fix/issue-96-participation-floor` merged; if so rebase and re-verify the
      ballot fallback still mirrors `_participationFloor`'s `earlier == 0`
      branch (design §8). PR targets `main` (stacked PRs get no CI).
