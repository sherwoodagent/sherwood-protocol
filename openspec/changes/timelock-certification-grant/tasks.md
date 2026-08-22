# Tasks: timelock-certification-grant

## 1. TierRegistry implementation (src/TierRegistry.sol only)

- [ ] 1.1 Add `PendingCertification` struct (design D8 packing: tier / bound /
      submitter / readyAt in one slot; bondAmount; codehash), the
      `_pending` mapping, and `certifyDelay = 3 days` — appended after
      `authorizedDemoter`. Add constants `MIN_CERTIFY_DELAY = 1 days`,
      `MAX_CERTIFY_DELAY = 30 days`. Add errors `NoPendingCertification`,
      `CertifyDelayNotElapsed`, `CodehashChanged`; events
      `CertificationProposed`, `CertificationCancelled`, `CertifyDelaySet`.
- [ ] 1.2 Implement `proposeCertification(target, selector, tier,
      extractableBoundBps, submitter)` — `onlyOwner`; all input guards moved
      from the current `certify` (InvalidTier, BoundRequired, NotAContract,
      and ZeroAddressSubmitter against the CURRENT `submitterBondWood`);
      snapshot codehash + pin bond amount + `readyAt = block.timestamp +
      certifyDelay`; overwrite semantics on re-proposal; emit
      `CertificationProposed`. Natspec states the adversary (compromised
      certification key) per house style.
- [ ] 1.3 Replace `certify` with the two-argument execution step:
      permissionless; revert `NoPendingCertification` (readyAt == 0),
      `CertifyDelayNotElapsed`, `CodehashChanged` (live codehash vs pinned
      snapshot); keep the BondActive/BondPendingRelease conflict guards here;
      pull the PINNED bond amount from the recorded submitter (skip when
      pinned amount is zero); write `TierConfig` with the SNAPSHOTTED
      codehash; delete `_pending[k]`; emit `TierCertified`. Natspec explains
      why permissionless is safe (content fully pinned; cancel/demote are
      the owner remedies) and why the bond pull is late (D1).
- [ ] 1.4 Implement `cancelCertification(target, selector)` (`onlyOwner`,
      `NoPendingCertification` guard, delete + `CertificationCancelled`) and
      `setCertifyDelay(delay)` (`InvalidDelay` outside bounds,
      `CertifyDelaySet`; natspec states readyAt pinning — changes affect
      future proposals only). Add `pendingCertificationOf(target, selector)`
      view returning the struct (mirrors `bondOf`).
- [ ] 1.5 Update the contract-level and `certify`-area natspec: two-step flow,
      the announcement window as the proxy-discipline enforcement aid, and
      the D5 note that proposing is legal while an old bond releases (the
      two timelocks overlap). Keep every demotion-path natspec untouched.

## 2. Test updates — existing suites (72 call sites, 8 files)

- [ ] 2.1 Add a shared helper (in the fixture/harness each suite already
      uses, or locally per suite where no shared fixture exists):
      `_certifyNow(reg, target, selector, tier, bound, submitter)` =
      `vm.prank(owner) proposeCertification(...)` →
      `vm.warp(vm.getBlockTimestamp() + reg.certifyDelay())` →
      `reg.certify(target, selector)`. MUST use `vm.getBlockTimestamp()`
      (repo guardrail: the optimizer CSEs `block.timestamp` across
      `vm.warp`); hoist any argument-position calls before `vm.prank`
      (repo guardrail: argument evaluation consumes a pending prank).
- [ ] 2.2 Migrate `test/TierRegistry.t.sol` (51 sites). Sites that TEST the
      old instant path's guards (InvalidTier/BoundRequired/NotAContract/
      ZeroAddressSubmitter/BondActive/BondPendingRelease reverts) move to
      the step where the guard now lives: input guards →
      `proposeCertification`, bond-conflict guards → two-step then `certify`.
- [ ] 2.3 Migrate the seven governor/e2e suites (13 + 2 + 2 + 1 + 1 + 1 + 1
      sites): `test/governor/TierResolution.t.sol`,
      `test/GovernorCoverageGates.t.sol`,
      `test/integration/TierEndToEnd.t.sol`, `test/SlashGasCeiling.t.sol`,
      `test/TokenCourtEndToEnd.t.sol`, `test/ChallengeEndToEnd.t.sol`,
      `test/CoverageEndToEnd.t.sol`. These certify in setUp/fixtures — the
      helper's forward warp shifts each suite's base timestamp by
      `certifyDelay`; audit each suite for absolute-timestamp assertions
      and challenge/court window arithmetic that could be affected.
- [ ] 2.4 Run the full suite; triage with `sort | uniq -c` on the FAIL lines
      (repo guardrail: `sort -u` hides identical setUp failures across
      suites).

## 3. New tests — timelock behaviors (spec delta scenarios)

- [ ] 3.1 Propose: records pending + event fields (incl. pinned bond,
      codehash, readyAt); `tierOf` unchanged while pending; input-guard
      reverts at propose; non-owner revert; re-proposal overwrites
      everything and restarts the clock.
- [ ] 3.2 Execute: revert before `readyAt`; revert with no pending; success
      exactly at/after `readyAt` by a third-party caller matches the
      announced params; pending deleted after execution.
- [ ] 3.3 Codehash: mid-window code change → `CodehashChanged` revert and no
      state written (use an etch/metamorphic fixture); re-proposal against
      the new code then succeeds.
- [ ] 3.4 Cancel: clears pending (subsequent certify reverts
      `NoPendingCertification`); does not disturb a live certification or
      its bond; non-owner revert.
- [ ] 3.5 Delay governance: `setCertifyDelay` bounds (`InvalidDelay` below
      1 day / above 30 days); delay change does NOT move an existing
      pinned `readyAt` (propose at D, floor the delay, assert
      `CertifyDelayNotElapsed` before the original readyAt).
- [ ] 3.6 Bond timing: pinned amount pulled at execution
      (`totalBondedWood` + balance invariant asserted); bond config change
      mid-window does not reprice the pull; zero-pinned-amount skips the
      pull even after the config was raised; lapsed approval → execution
      reverts, retryable after re-approval.
- [ ] 3.7 Bond conflicts at execution: `BondActive` over a live bond;
      demote → propose during release timelock → `BondPendingRelease`
      before claim → success after claim (the overlap case from D5).
- [ ] 3.8 Demotion unaffected: `demote` / `poke` / `demoteByChallenge` all
      work instantly while an unrelated pending certification exists, and
      demoting a pair does not touch that pair's pending record.

## 4. Scripts and docs

- [ ] 4.1 script/Deploy.s.sol — update the TierRegistry comment block
      (line ~277: "so `certify`/`demote` listing can run before the
      multisig") and the ownership-handoff runbook console output for the
      two-step flow: propose launch set under deployer ownership → hand off
      → anyone executes after the delay.
- [ ] 4.2 script/DeployPlanB.s.sol — update the "TierRegistry redeploy +
      recertify" wording (header ~lines 50-51 and the line-835 console log)
      to the propose → delay → certify sequence, including the
      populate-before-rewire ordering from the design's Migration Plan.
- [ ] 4.3 Grep docs/ and openspec/specs/operator-docs + deployment-docs for
      prose describing single-step certification; update any hit (expected:
      none or minimal — `certify` is not referenced by other capability
      specs' requirement text).
- [ ] 4.4 Confirm script/check-layout-goldens.sh needs NO change
      (TierRegistry is not pinned; gate list unchanged) — note this in the
      PR description rather than touching the script.

## 5. Verification

- [ ] 5.1 `forge build` + full `forge test` green (serialize with the forge
      lock guard if other builds may be running — 16 GB machine OOM
      guardrail).
- [ ] 5.2 `forge fmt` with a CI-matching forge version (repo guardrail:
      local 1.7.1 wrapping differs from CI nightly on some constructs).
- [ ] 5.3 `openspec validate --strict` passes for this change; spec delta
      headers match the main tier-policy spec exactly for MODIFIED/REMOVED
      requirements.
- [ ] 5.4 Re-read the issue #45 test list and confirm every bullet has a
      covering test: certify-before-readyAt revert, mid-window codehash
      change voids, cancel then certify reverts, delay bounds, demotion
      unaffected while pending, layout-goldens N/A note.

## 6. Audit remediation (PR #156 Pashov review, 6 confirmed findings)

See design.md "Audit Remediation" for the rationale behind each design call.

- [x] 6.1 Finding #1 (confidence 92): add `bondToken` (`IERC20`) to
      `PendingCertification`, snapshot `wood` into it in
      `proposeCertification`, pull via `p.bondToken.safeTransferFrom(...)`
      in `certify` instead of the live `wood` state variable.
- [x] 6.2 Finding #2 (confidence 85): `_demote` also deletes `_pending[k]`
      and emits `CertificationCancelled` when a same-key pending
      certification exists, across all three demotion paths (`demote`,
      `demoteByChallenge`, `poke`).
- [x] 6.3 Finding #3 (confidence 85): `certify` reverts `NotSubmitter` when
      `p.bondAmount != 0 && msg.sender != p.submitter` — conditioned on a
      non-zero pinned bond so the unbonded case stays fully permissionless
      (design.md R3 explains why the unconditional form was rejected).
- [x] 6.4 Finding #4 (confidence 80): broadened the contract-level codehash
      natspec to cover any fund-routing-relevant mutable storage, not just
      recognized proxy shapes. Process/documentation only — no code change.
- [x] 6.5 Finding #5 (confidence 80): new constant `MAX_CERTIFY_WINDOW = 14
      days`; `certify` reverts `CertificationExpired` past
      `readyAt + MAX_CERTIFY_WINDOW`. Live `submitterBondWood` re-validation
      considered and rejected as redundant given 6.3 (design.md R5).
- [x] 6.6 Finding #6 (confidence 75): `proposeCertification` gained a
      required `expectedCodehash` parameter; reverts `CodehashChanged` when
      the target's live codehash at propose-time execution doesn't match
      the caller-supplied value, closing the propose-time TOCTOU gap.
- [x] 6.7 Updated all `proposeCertification` call sites (58 across 9 test
      files) for the new `expectedCodehash` argument; added
      `vm.prank(submitter)` before bonded `certify` calls in
      `test/TierRegistry.t.sol` and
      `test/TierRegistryCertificationTimelock.t.sol` per 6.3.
- [x] 6.8 New adversarial tests in `test/TierRegistryCertificationTimelock.t.sol`
      mirroring each finding's own proof: `setWood` mid-window doesn't
      retoken the pull (F1); `demoteByChallenge`/`demote`/`poke` all cancel
      a same-key pending renewal, scoped to that key only (F2); a
      non-submitter (including the owner) cannot trigger a bonded `certify`,
      while the unbonded case stays permissionless (F3); `certify` expires
      at `readyAt + MAX_CERTIFY_WINDOW` and is recoverable via re-proposal
      (F5); `proposeCertification` reverts on an `expectedCodehash` mismatch
      and succeeds when it matches (F6).
- [x] 6.9 Updated proposal.md, design.md, and this spec delta
      (specs/tier-policy/spec.md) to describe the remediated behavior.
