# Tasks — Plan F Epoch NAV Checkpointing

## 1. CoverageEpochs — cover open and baseline NAV

- [x] 1.1 Write failing tests: baseline from `valueStrategy` (not `totalAssets`), revert on unpriceable router, revert before execution, idempotent refusal, ledger epoch-schedule copy
- [x] 1.2 Create `src/interfaces/ICoverageEpochs.sol` + `src/CoverageEpochs.sol` with `openCover` (permissionless, `Executed`-only, D1/D2/D3), `Cover` struct, `_coverKey` mirroring `ChallengeGame._reviewKey`
- [x] 1.3 Run `forge test --match-contract CoverageEpochs`, fmt, commit

## 2. Boundary checkpointing

- [x] 2.1 Write failing tests: revert before boundary, NAV recorded at boundary, once per epoch, revert on unpriceable router, missed boundary still measures from baseline (D4)
- [x] 2.2 Implement `checkpoint` (permissionless, once per epoch at/after the boundary) and `cumulativeLossBps` (cumulative from baseline, never epoch-over-epoch)
- [x] 2.3 Run suite, fmt, commit

## 3. Drawdown evaluation and the passive-mandate skip

- [x] 3.1 Write failing tests: breach sets flag + emits `DrawdownBreached`, loss inside envelope no breach, loss exactly at envelope no breach (strictly greater), passive mandate checkpoints but never breaches (D5)
- [x] 3.2 Implement breach evaluation in `checkpoint` with an explicit early-return branch for `maxDrawdownBps >= 10_000`
- [x] 3.3 Run suite, fmt, commit

## 4. Renewal and the sequencing that closes the exit run

- [x] 4.1 Write failing tests: renewal accepted before deadline, refused after deadline even one second before the boundary (the sequencing test), checkpoint cannot precede the renewal deadline, renewal consumes exposure capacity, double-commit reverts, `renewalLeadTime` bounded `(0, epochLength/2]` and owner-only
- [x] 4.2 Implement `renewalDeadline` (`boundary(epoch) - renewalLeadTime`, default 3 days) and `commitRenewal` (books exposure via `exposureLedger.recordApproval`; epoch 0 refused)
- [x] 4.3 Run suite, fmt, commit

## 5. Claims-made attribution

- [x] 5.1 Write failing tests: epoch-0 coverers are the original approvers, later-epoch coverers are the renewers, original approver not liable for a later epoch, released (zero-`committedUsd`) approver is not a coverer, breach epoch recorded
- [x] 5.2 Implement `coverersOf`: epoch 0 filters `approversOf` by non-zero `committedUsd` exactly as `ChallengeGame._accused`; epoch N > 0 returns the renewal committers
- [x] 5.3 Run suite, fmt, commit

## 6. No renewal → forced wind-down

- [x] 6.1 Write failing tests: flagged when nobody renewed, refused while coverage exists, flagged when NAV stays unavailable past `checkpointGrace` (D6), `settleProposal` permissionless once wound down, still gated without wind-down
- [x] 6.2 Implement `flagWindDown` (permissionless; uncovered epoch or stale checkpoint past grace; D7 — seizes nothing) and the `SyndicateGovernor.settleProposal` wind-down bypass; `_coverageEpochs` appended from `__gap`
- [x] 6.3 Run tests + `./script/check-layout-goldens.sh`, update pinned layout JSON in the same commit

## 7. ChallengeGame accuses the epoch's coverers

- [x] 7.1 Write failing tests: drawdown challenge with `epoch > 0` accuses the epoch coverers, epoch 0 keeps ledger behaviour, non-drawdown predicates ignore the epoch, cited epoch with no coverers reverts `NoCoverage`
- [x] 7.2 Thread `epoch` through `file` and the `Challenge` struct; branch inside `_accused` for `Predicate.Drawdown && epoch != 0` (after re-deriving `_accused`'s invariants across slashing, forfeit split, and coverage freeze)
- [x] 7.3 Run full challenge and court suites unregressed, fmt, commit

## 8. End-to-end, deploy wiring, goldens, PR

- [x] 8.1 Three E2E arcs on the real stack: renewed breach slashes the later epoch's coverers (epoch-0 approvers untouched); no renewal → wind-down → permissionless settle before `strategyDuration`; router outage past grace → wind-down with no breach recorded
- [x] 8.2 `script/DeployPlanF.s.sol` with pre-flights (unclaimed governor role, router priceability, ledger identity, lead-time and grace bounds), each deliberately broken to prove it bites
- [x] 8.3 Layout goldens (SyndicateGovernor changed; `CoverageEpochs` non-upgradeable, no golden), full suite at baseline, fmt
- [x] 8.4 Mark §3.4a complete in the design spec; note Plan G (§3.10) remains and mid-epoch exit is deferred to v2
- [x] 8.5 PR against `feat/guardian-econ-security-e` naming the five known gaps (drift vs jump, unforced `openCover`, unpaid checkpoints, late-open baseline drift, wind-down does not force liquidation)
