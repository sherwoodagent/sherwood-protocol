# Proposal: timelock-certification-grant

GitHub issue: #45 — "Timelock certify() — the largest unreviewable power in the
protocol takes effect instantly"

## Why

`TierRegistry.certify(target, selector, tier, extractableBoundBps, submitter)`
(src/TierRegistry.sol:198) is `onlyOwner` and takes effect in the transaction
that lands it — no delay, no announcement, no appeal. That one call decides
what an adapter is worth to an attacker for **every vault at once**:
`TierRegistry` is a global singleton wired into every governor by the factory
(src/SyndicateFactory.sol:366), and the certified `extractableBoundBps` is the
number the whole coverage model prices off
(`requiredCoverage = maxCapital × Σ boundBps / 10_000`, tier-policy spec,
"Governance certification discipline").

Every other privileged power in the protocol is delayed, bonded, or
appealable — a court panel ruling has a 7-day window and a full sWOOD vote, a
guardian approval has a review window and block quorum, a proposer envelope
has vote + review + depositor veto. Certification — the input that decides how
much those layers are even protecting against — is a single instant write. The
asymmetry is precisely backwards, because the fast direction is already fully
served: `poke` is permissionless, `demote` is owner-callable,
`demoteByChallenge` lands on a passed challenge, and `tierOf` re-checks the
codehash on every read. **Revoking trust is instant and available to
everyone; granting it is instant and available to one key.** A delay on grant
costs nothing operationally (certification already trails an off-chain
process measured in weeks) while converting the largest unreviewable power
into an announced one: guardians can reprice, depositors can exit,
watchtowers can inspect the target — in particular, catch a proxied adapter
in the queue, the exact hazard the tier-policy spec can only prohibit by
discipline, not check in code.

## What Changes

- **BREAKING (external ABI + flow)**: certification becomes two-step.
  - `proposeCertification(target, selector, tier, extractableBoundBps,
    submitter, expectedCodehash)` — `onlyOwner`. Runs all of today's input
    guards (`InvalidTier`, `BoundRequired`, `NotAContract`,
    `ZeroAddressSubmitter` when a bond is armed), plus `CodehashChanged` when
    the target's live codehash doesn't match the caller-supplied
    `expectedCodehash` (audit remediation, finding #6 — asserts the owner's
    off-chain review against propose-time reality rather than blindly
    re-photographing whatever is live when the transaction mines). Snapshots
    the target's current `EXTCODEHASH`, the current `wood` token address
    (finding #1), and the current `submitterBondWood`, records
    `readyAt = block.timestamp + certifyDelay`, emits
    `CertificationProposed(target, selector, tier, extractableBoundBps,
    submitter, bondAmount, codehash, readyAt)`.
  - `certify(target, selector)` — **permissionless when the pinned bond
    amount is zero; restricted to the pinned `submitter` when it is
    non-zero** (finding #3 — an owner-named `submitter` has no proof of
    consent for a specific grant, so execution that would pull funds is
    gated to the party those funds belong to). Callable once `readyAt` has
    passed and only until `readyAt + MAX_CERTIFY_WINDOW` (finding #5), and
    only if the target's live codehash still matches the proposal-time
    snapshot (a code change mid-window voids the pending grant rather than
    certifying something else). Pulls the pinned submitter bond (if any)
    against the pinned bond TOKEN, not the live `wood` (finding #1), applies
    the config, deletes the pending record, emits the existing
    `TierCertified`. The old five-argument instant `certify` signature is
    removed.
  - `cancelCertification(target, selector)` — `onlyOwner`, withdraws a
    pending grant, emits `CertificationCancelled`. A same-key pending
    certification is now ALSO cancelled automatically as a side effect of
    that key's demotion (`demote` / `demoteByChallenge` / `poke`) — finding
    #2, closing the gap where a for-cause revocation could be silently
    overridden by an announcement that predates it.
- New owner parameter `certifyDelay` (default 3 days) with
  `setCertifyDelay(delay)` bounded to
  `[MIN_CERTIFY_DELAY = 1 days, MAX_CERTIFY_DELAY = 30 days]` — a floor so
  the delay cannot be zeroed back to the instant path, a ceiling so a
  governance error cannot brick onboarding. Changing it never moves an
  already-announced `readyAt`: deadlines are pinned at propose time, same
  discipline as `releasableAt` in this same contract.
- **Demotion paths are untouched.** `demote`, `demoteByChallenge`, `poke`,
  and the lazy `tierOf` codehash check all stay instant. The delay applies
  only to granting a lower tier, never to revoking one.
- **No emergency bypass.** Issue #45 floats an optional `certifyImmediate`
  behind a distinct role; this proposal deliberately omits it — see
  design.md ("No certifyImmediate") for the argument. Incident response in
  this protocol is revocation-shaped, and an un-certified adapter is not
  blocked, only priced at tier 2.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tier-policy`: the "Certification is owner-only with strict input guards"
  requirement is replaced by a two-step announced-grant requirement
  (propose → delay → permissionless execute, with codehash re-verification
  and cancel); the "Submitter bond pulled at certification when configured"
  requirement changes to pin the bond amount at propose time and pull it at
  execute time; a new requirement covers `certifyDelay` and its bounds and
  pinning; the "Governance certification discipline" requirement gains the
  announcement window as the enforcement aid for the proxy prohibition.
  Demotion, bond-release, allowlist, and ownership requirements are
  unchanged.

## Impact

- `src/TierRegistry.sol` only. New storage (a pending-certification mapping
  and `certifyDelay`) appended after the existing declarations. TierRegistry
  is **not** behind a proxy (plain `Ownable2Step`, deployed with
  `new TierRegistry(...)` in script/Deploy.s.sol:282) and is **not** one of
  the contracts pinned by script/check-layout-goldens.sh (that gate covers
  SyndicateGovernor, SyndicateFactory, GuardianRegistry, StakedWood) — no
  golden exists or needs regenerating. Shipping this change to a live chain
  means a fresh registry deploy + `factory.setTierRegistry` rewire +
  re-listing, which is already the documented operational pattern
  (script/DeployPlanB.s.sol:835 "TierRegistry redeploy + recertify").
- `src/interfaces/ITierRegistry.sol` is untouched — it exposes only the
  read side (`tierOf`, `isAdapterAllowed`), so no governor/vault/game code
  changes.
- Tests: 72 direct `certify(` call sites across 8 suites become two-step
  (via a fixture helper that proposes, warps past `readyAt`, executes);
  full list in tasks.md. New suites cover the timelock behaviors from
  issue #45's test list.
- Scripts: no script calls `certify` on-chain. Comment/console text in
  script/Deploy.s.sol (deploy-ceremony note, line 277) and
  script/DeployPlanB.s.sol (lines 50–51, 835) updated for the two-step
  flow. The deploy ceremony gains a runbook property: the launch adapter
  set is *proposed* while the deployer still owns the registry, ownership
  handoff proceeds immediately, and anyone (deployer, multisig, a bot) can
  execute the certifications after the delay — announcement and handoff
  overlap instead of serializing.
- No changes to any other contract, no coverage-model changes, no changes
  to `ITierRegistry` consumers.
