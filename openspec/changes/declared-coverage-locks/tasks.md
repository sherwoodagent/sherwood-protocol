## 1. Clear the ground

- [x] 1.1 Archive `settle-coverage-self-trigger` WITHOUT merging its delta into the main `syndicate-governor` spec (design D7); record in the archive note that this change deletes the mechanism it wired.
- [ ] 1.2 Pin the reproduction: convert `test/audit-fixes/ExposureLedger_she212PhantomCapacity.t.sol` from a failing exploit into a "cannot happen" test against the new model (asserts a second lock is refused while the first is live, and that a retired lock frees budget). Keep the attack narrative in its natspec.
- [x] 1.3 Inventory every `settleCoverage` call site (36) and every full-reservation assumption in `test/`; list them in the PR description so the rewrite in §6 is auditable.

## 2. ExposureLedger — the lock replaces booking and pledge

- [x] 2.1 Restructure ledger storage for the lock model: the per-(reviewKey, guardian) record holds one WOOD `lock`; `_liveBookedUsd`/`_livePledgedUsd` collapse to one `_liveLockedWood`; drop `_reservedUsd`, `_committedUsd` (USD pledge family) and `_settled`. `ExposureLedger` is a plain constructor-deployed contract (no proxy, no gap, no layout golden), so storage may be restructured freely — there is no layout gate for this contract.
- [x] 2.2 Change `recordApproval(governor, proposalId, guardian)` → `recordApproval(governor, proposalId, guardian, lockWood)`: lock `min(lockWood, kNumerator × slashableStake − openExposure)` in WOOD; drop the `woodPriceX8()` read and its "book nothing on outage" branch; keep idempotence, horizon, zero-coverage and zero-budget no-op paths (spec: "Approval recording books a guardian-declared WOOD lock", "Booking failures never fail the approve vote").
- [x] 2.3 Re-denominate `_buckets` and the bucket scan in WOOD; rename `openExposureUsd` → `openExposure` (or drop the unit suffix) and update every internal caller. Bucket expiry, horizon and the 16-bucket scan bound are unchanged in shape (design D5).
- [x] 2.4 Delete `settleCoverage`, `CoverageSettled`, `_settled`, and `_rebook`'s downward branch; keep `releaseApproval`/`retireApproval`/`_unwindApproval` operating on the single lock figure.
- [x] 2.5 Rewrite `slashBpsFor` to `ceil(lock × 10_000 / liveStake)`, saturating at 10_000 when `lock >= liveStake` or `liveStake == 0`, zero for a zero lock; no price read. Replace the pashov-#13 "binary ceiling" comment with the new rationale and record why the old one no longer applies (spec: "Per-approver slash rates").
- [x] 2.6 Rewrite `liabilityUsd` and `unsharedLiabilityUsd` to `min(needUsd, Σ min(lock_i, liveStake_i) × woodPriceX8())`, reverting on an unpriceable WOOD feed; delete `allocatedUsd` (spec: "Cohort liability is the lock sum capped at need").
- [x] 2.7 Rewrite `requireApproveQuorum` to `Σ min(lock_i, liveStake_i) × woodPriceX8() >= coverageUsd(asset, requiredCoverage)`; keep zero-approvers-always-revert.
- [x] 2.8 Update `setKNumerator` natspec and the `IExposureLedger` interface: state the k = 1 containment property and that k > 1 is deliberate leverage (spec: "Exposure cap multiplier").
- [x] 2.9 Update `IExposureLedger` for the new `recordApproval` signature, removed functions/events, and renamed views.

## 3. GuardianRegistry — carry the declaration

- [x] 3.1 Add a `lockWood` parameter to the approve vote path (`voteOnProposal` or a sibling overload; pick one and delete the other so there is a single entry) and forward it to `recordApproval`.
- [ ] 3.2 Vote-change round trip: `Approve → Block → Approve` must release and re-lock cleanly with the new signature; pin with a test.
- [ ] 3.3 Update `IGuardianRegistry` and every registry stand-in in `test/` that implements the approve path (grep `function voteOnProposal`).

## 4. StakedWood and ChallengeGame — burn the lock

- [ ] 4.1 `StakedWood._slashOne`: confirm the existing bps-of-live-stake leg plus the `[minSlashBps, maxSlashBps]` clamp yields `min(lock, liveStake)` when fed the new rate; adjust natspec on both `slashGuardians` and `slashVerdict` to the lock basis (spec: both slash requirements). No arithmetic change expected — verify with tests rather than assume.
- [x] 4.2 `ChallengeGame._accusedWithRates`: consume the lock-derived rates; confirm zero-lock approvers are still filtered out.
- [x] 4.3 `ChallengeGame.file`: size the bond off the capped `liabilityUsd`; remove the try/catch fallback that substitutes the uncapped sum on failure — a stale feed must make filing wait, never enlarge the bond (spec: "Challenger bond sized to the coverage the filing freezes").
- [ ] 3.4 Review-path slash carries the lock basis (design D3 — BOTH slash paths): in `GuardianRegistry.resolveReview`'s Blocked branch, compute a per-approver rate for the ledger's approver set — `bps_i = ceil( ceil(lock_i × 1e4 / slashableStakeAt(g, openedAt)) × severityBps / 1e4 )`, saturating at 10_000 and 0 for a zero lock — and pass the array to `swood.slashGuardians`. Severity stays the deterministic block-decisiveness ramp, applied as a multiplier on the lock-derived rate (spec: guardian-staking "Review-path slash"). Basis at `openedAt` because a review-path slash lands BEFORE execution, so `executedAt` is zero. State the adversary in natspec.
- [ ] 4.5 `StakedWood.slashGuardians(reviewKey, openedAt, approvers, slashBps)` → per-approver `uint256[] slashBpsPer`, mirroring `slashVerdict`'s existing shape (length check → `SlashBpsLengthMismatch`, per-element envelope clamp, zero rate skipped). ABI change only — StakedWood is layout-pinned and this touches no storage; `script/staked-wood-layout.golden.json` must diff zero. Update `IStakedWood`, the registry call site, and finish 4.1's `slashGuardians` natspec to the lock basis.
- [ ] 4.4 (script DONE; `test/deploy` pin pending §6) `script/DeployPlanB.s.sol`: rewrite the `maxSlashBps == 10_000` pre-flight's message to the lock rationale (a lock may equal the whole stake and must burn in full) and ADD a pre-broadcast `minSlashBps != 0` pre-flight naming it the deterrence floor (spec: deployment-docs "Plan B deployment pre-flights and wiring"). Pin both with `test/deploy/` cases that run the script against a mis-set sWOOD and assert the revert message.

## 5. SyndicateGovernor — remove the trigger

- [x] 5.1 Delete `_settleCoverageBestEffort`, both call sites (`_finishSettlement` tail, `reclaimProposerBond` tail), and the `CoverageSettleFailed` event from `ISyndicateGovernor`.
- [x] 5.2 Confirm `script/syndicate-governor-layout.golden.json` diffs ZERO — this section changes no storage.

## 6. Tests

- [ ] 6.1 Rewrite every fixture from §1.3 to declared locks; delete tests whose only subject was `settleCoverage`, and re-home any assertion they carried about bucket expiry or retirement onto the surviving paths.
- [ ] 6.2 New ledger tests: over-subscribed cohort locks in full; declaration clamped to free budget; unpriceable WOOD still locks; `slashBpsFor` at lock < stake, lock ≥ stake, zero lock, and the 1-wei floor case; `liabilityUsd` capped at need and below need.
- [ ] 6.3 Containment test at k = 1: guardian backs A and B, A convicted, assert B's coverage from that guardian is unchanged. Leverage test at k = 2: assert the documented under-coverage appears — this pins the property the spec now states.
- [ ] 6.4 End-to-end: propose → approve with locks → execute at quorum → challenge → conviction burns exactly the locks (under the envelope) → other proposals unaffected. Extend `CoverageEndToEnd` / `ChallengeEndToEnd` rather than adding a parallel harness.
- [ ] 6.5 Mutation-verify the two load-bearing pins: (a) reintroduce a pro-rata write-down and confirm the over-subscription test fails; (b) make `slashBpsFor` return the whole-bond ceiling and confirm the containment test fails.
- [ ] 6.6 Full non-fork suite green; `forge fmt --check` clean under the CI-pinned forge; contract sizes within the 98,304-byte limit; both layout goldens as expected (ledger regenerated, governor zero-diff).

## 7. Off-chain and docs

- [x] 7.1 SDK: N/A — verified `sherwood/sdk/src` contains no guardian-vote encoder (no `GuardianRegistry`, `GuardianVoteType` or `voteOnProposal` reference; its `vote`/`approve` hits are the LP vote and ERC20 approve). Guardians vote through the CLI and the daemon, covered by 7.2 and 7.3.
- [x] 7.2 CLI: N/A — verified `sherwood/cli/src` has no guardian review-vote command (the `guardian` group is status/stake/prepare-owner-stake/unstake/delegate/undelegate/set-commission/claim-wood) and no `voteOnProposal` reference. The guardian daemon is the sole off-chain voter; see 7.3.
- [ ] 7.3 Guardian daemon (`sherwood-guardian`): (a) `src/signer.ts:54` inline ABI and `:281` `send(deps, "voteOnProposal", [governor, proposalId, support])` gain the `lockWood` argument; (b) the lock is the prospective placement `judge.ts` already computes under the operator's per-proposal ceiling (design D8) — thread it from judge to signer, in WOOD; (c) rewrite the SHE-56 rationale comment in `judge.ts` (~:261-285) to the lock predicate: a zero lock owes 0 bps and is skipped by `slashVerdict`, so the costless zero-lock approve survives — and drop its stale `ExposureLedger.sol:1521,1541` line references; (d) update `src/abis/GuardianRegistry.json` from the rebuilt artifact; (e) tests for the new argument and for the zero-lock path.
- [ ] 7.4 `docs/guardian-network.md` and `openspec/specs/deployment-docs`: describe declared locks, the k = 1 containment property, and `minSlashBps` as the deterrence floor whose launch value is a governance decision; remove every reference to reservation collapse and `settleCoverage`.
- [ ] 7.5 App: `sherwood/app/src/lib/selector-registry.ts` pins the approve-vote selector; the new `voteOnProposal` signature changes it — update the registry entry (and any decoder that renders the vote) so the app does not label the new call as unknown.
- [ ] 7.6 Linear: resolve SHE-212 and SHE-225 by removal (link this change); mark SHE-227 implemented; leave SHE-213 open with a note that it is unaffected.
