# Design: timelock-certification-grant

## Context

See proposal.md — Why. Current state that constrains the design:

- `TierRegistry` (src/TierRegistry.sol) is a plain, non-upgradeable
  `Ownable2Step` contract deployed with `new TierRegistry(deployer)`
  (script/Deploy.s.sol:282) and wired into every governor through
  `SyndicateFactory.setTierRegistry`. It is NOT among the contracts pinned by
  script/check-layout-goldens.sh (SyndicateGovernor, SyndicateFactory,
  GuardianRegistry, StakedWood only), so storage additions carry no
  golden-regeneration step and no proxy-lineage compatibility constraint.
  Shipping the change to a live chain is a fresh deploy + factory rewire +
  re-listing — the pattern DeployPlanB already documents as a manual
  follow-up ("TierRegistry redeploy + recertify", script/DeployPlanB.s.sol:835).
- `certify` today (src/TierRegistry.sol:198-229): input guards → bond-conflict
  guards against `_bonds[k]` → optional bond pull via `safeTransferFrom` →
  config write with codehash snapshot → `TierCertified`.
- The contract already contains the two patterns this change generalizes:
  `Ownable2Step` (announced, two-step power transfer) and `releasableAt`
  (a deadline pinned at intent time from a live parameter,
  src/TierRegistry.sol:320).
- The read-side interface `ITierRegistry` exposes only `tierOf` and
  `isAdapterAllowed`; no other contract calls `certify`, so the ABI break is
  contained to tests and operational tooling.

## Goals / Non-Goals

Goals:
- Every tier grant is announced on-chain, with its full content pinned, for a
  bounded minimum window before it can take effect.
- The announced content is exactly what executes: parameters, bond amount, and
  target bytecode are all pinned at proposal time.
- Demotion latency is untouched in every path.
- Existing bond invariants (`wood.balanceOf == totalBondedWood`, one bond per
  key, no bond overwrite) survive without new states or refund paths.

Non-Goals:
- No emergency bypass (`certifyImmediate`) — see Decisions.
- No changes to the coverage model, the allowlist axis, demotion, bond
  release, or any consumer contract.
- No pending-queue enumeration on-chain; indexers consume the events.

## Decisions

### D1. Bond pulled at execution, amount pinned at proposal

Alternatives considered:
- (a) Pull at `proposeCertification`, hold in the registry during the window.
- (b) Pull at `certify` execution, reading `submitterBondWood` live.
- (c) **Chosen**: pull at execution, amount snapshotted at proposal.

(a) locks submitter capital for `certifyDelay` with nothing certified,
requires a refund path for cancel / voided-codehash / overwrite-by-reproposal,
and forces a third bond state ("pending") into a mapping whose two existing
states (`releasableAt == 0` live, `!= 0` releasing) are load-bearing in
`certify`'s conflict guards and in `claimSubmitterBond`. It also breaks the
one-bond-per-key rule during demote→re-certify overlap (old bond releasing +
new bond pending on the same key = two bonds, which the current struct cannot
represent). All of that machinery buys nothing: the bond's purpose is to be at
stake while a certification is LIVE, and during the window nothing is live.

(b) lets an owner repricing `submitterBondWood` mid-window change what a
permissionless executor pulls from the submitter — the submitter approved a
known amount against a known announcement; execution must not be able to pull
a different one. Pinning at proposal follows the same intent-time discipline
as `readyAt` (D3).

(c) keeps `_bonds` exactly as it is: a bond exists iff an executed
certification (or its release tail) exists. The registry WOOD invariant needs
no amendment. Failure mode of the late pull — submitter approval lapsed when
a third party executes — is a clean revert, retryable, and doubles as the
submitter's live consent: withholding approval withholds the certification.
The theoretical `setWood` mid-window interaction (token swapped while a
pending carries a pinned amount) is fail-safe for the same reason: the pull
in the new token has no approval and reverts; the owner cancels and
re-proposes. `setWood` already requires `totalBondedWood == 0`, so this is a
rare, ceremonial state documented in the runbook, not a code path.

### D2. Execution step keeps the name `certify`, drops to two arguments

`certify(target, selector)` reads everything else from the pending record.
Passing the five original arguments and requiring a match was considered and
rejected: it re-introduces a way for the transaction content to differ from
the announcement (mismatch reverts are just noise), bloats calldata, and
implies the caller chooses parameters — the whole point is that they cannot.
Keeping the name `certify` preserves the event vocabulary (`TierCertified`
still marks the moment of effect) and makes every stale call site a loud
compile error rather than a silently different behavior. Arity now mirrors
`demote`/`poke`.

### D3. `readyAt` pinned at proposal; `setCertifyDelay` affects future proposals only

The codebase's uniform discipline is to pin delay-derived deadlines at intent
time (`releasableAt` in this contract; the same pattern in the
governor/challenge stack). Floating `readyAt` against the live delay would
let a delay shortening ripen an already-announced grant early — the emitted
`readyAt` must be trustworthy as the earliest possible activation or the
watchtower story collapses. Floating also breaks monotonicity in the other
direction (a lengthening would retroactively push announced deadlines).
Pinned deadlines make `CertificationProposed` a complete, immutable
commitment; the only way to change an announcement is to re-propose, which
restarts the clock.

Note the residual, accepted limit: an owner can set the delay to the floor
FIRST and then propose — the effective minimum announcement is
`MIN_CERTIFY_DELAY`, not the configured default. That is what the floor is
for; `CertifyDelaySet` is itself an announced, indexable event.

### D4. Bounds and default: `[1 days, 30 days]`, default `3 days`

Floor 1 day matches `MIN_BOND_RELEASE_DELAY`'s magnitude and guarantees at
least one full waking cycle for every monitoring party in every timezone;
issue #45's 2–7-day band is satisfied by the 3-day default. Ceiling 30 days
(not `bondReleaseDelay`'s 365) because the failure modes differ: an
over-long bond release delay strands one submitter's WOOD; an over-long
certify delay stalls ALL adapter onboarding — a month is already generous
for review, and a governance error above it should be un-settable rather
than survivable.

### D5. Bond-conflict guards stay at execution; proposing is never bond-gated

`BondActive` / `BondPendingRelease` move with the config write to the
execution step, where the new bond would actually be recorded — that is the
only place they are authoritative, since bond state can change during the
window (a release timelock can lapse and be claimed). Deliberate consequence:
the owner can ANNOUNCE a replacement certification while the old bond is
still releasing, so the certify delay and the bond-release timelock run
concurrently. The demote→claim→re-certify cycle, which today serializes
tier-2 downtime after the claim, now overlaps: total downtime is
`max(bondReleaseDelay, certifyDelay)`-ish instead of the sum. No safety is
lost — execution still refuses while any bond exists.

### D6. Codehash re-check is stateless; a voided pending is inert, not auto-deleted

Execution compares the live codehash to the proposal-time snapshot and
reverts `CodehashChanged` on mismatch. The pending record is not deleted on
a failed execution (reverts don't write state) and there is no expiry clock.
A "voided" pending is permanently inert unless the target's bytecode returns
to the announced hash — and bytecode equality means behavior equality, so
executing against restored identical bytecode certifies exactly what was
announced. Alternatives considered: an `executableUntil` expiry window
(rejected: adds a liveness cliff to the launch runbook and another constant
to govern, while the thing it bounds — a stale announcement executing — is
already bounded by the announcement being permanently public and by owner
`cancelCertification`; the spec's discipline requirement makes cancelling
stale pendings an operator obligation instead).

### D7. No `certifyImmediate`

Issue #45 offers it as an option ("better a named bypass than an unnamed
default") and this design rejects even the named bypass:

1. There is no incident class it serves. Incident response in this protocol
   is revocation-shaped — `poke`, `demote`, `demoteByChallenge`, guardian
   blocks — and all of it stays instant. The "emergency" on the grant side
   would be needing a NEW adapter certified faster than the delay; but an
   uncertified adapter is not blocked, it is priced at tier 2 — proposals
   through it execute today with full-notional coverage. Urgency has a
   working path whose cost is more guardian coverage, not an outage.
2. Held by the owner, `certifyImmediate` IS the current `certify` — the
   asymmetry table row this change exists to fix would be reproduced
   verbatim under a different selector.
3. Held by a distinct role, it adds a second trust root whose compromise
   restores the original problem, plus wiring, rotation, and audit surface —
   against no identified benefit (see 1).
4. The launch-set bootstrap, the one real operational cost, dissolves in the
   deploy ceremony: propose the launch set while the deployer owns the
   registry, hand off ownership immediately (proposals are already made),
   and let anyone execute after the delay. Announcement and handoff overlap;
   nothing serializes.

### D8. Storage: new mapping + delay param, appended

```solidity
struct PendingCertification {
    uint8 tier;               // ┐
    uint16 extractableBoundBps; // │ one slot: 1+2+20+8 = 31 bytes
    address submitter;        // │
    uint64 readyAt;           // ┘ 0 = no pending (existence sentinel)
    uint96 bondAmount;        //   pinned submitterBondWood at proposal
    bytes32 codehash;         //   proposal-time EXTCODEHASH snapshot
}
mapping(bytes32 configKey => PendingCertification) private _pending;
uint256 public certifyDelay = 3 days;
```

Three slots per pending, two new top-level declarations placed after
`authorizedDemoter` (textual append; layout freedom is real since the
contract is not proxied, but append-only remains the house hygiene). A
public getter `pendingCertificationOf(target, selector)` returning the
struct mirrors `bondOf` for UIs/watchtowers. `bondAmount` is `uint96` for
the same provably-lossless reason as `SubmitterBond.amount`
(`setSubmitterBondWood` rejects amounts above `type(uint96).max`).

New errors: `NoPendingCertification`, `CertifyDelayNotElapsed`,
`CodehashChanged`. Reused: `InvalidTier`, `BoundRequired`, `NotAContract`,
`ZeroAddressSubmitter`, `BondActive`, `BondPendingRelease`, `InvalidDelay`.
New events: `CertificationProposed`, `CertificationCancelled`,
`CertifyDelaySet`.

## Risks / Trade-offs

- [72 test call sites break on the ABI change] → One fixture helper
  (propose → `vm.warp(vm.getBlockTimestamp() + certifyDelay)` → execute)
  converts most sites mechanically; the helper must use
  `vm.getBlockTimestamp()`, never a cached `block.timestamp` local, because
  this repo's optimizer CSEs `block.timestamp` across `vm.warp` (known
  foundry guardrail). Suites whose setUp certifies fixtures will advance the
  base timestamp by `certifyDelay`; forward-only warps in setUp are safe,
  but any test asserting absolute timestamps needs review.
- [Race: owner cancel vs third-party execute after `readyAt`] → Accepted.
  Before `readyAt` cancel always wins. After it, a front-run execute beats a
  cancel, but the executed state is precisely the announced one and instant
  `demote` reverses it in the same block if needed.
- [Stale pending executes long after everyone stopped watching] → Mitigated
  by the operator obligation (spec: cancel obsolete announcements) and by
  the announcement being permanent public state; considered expiry rejected
  in D6.
- [Submitter griefs by revoking approval, blocking execution] → Accepted and
  reframed: the bond is the submitter's stake, so their live approval is
  live consent. Owner cancels and re-proposes with another submitter; the
  key is not damaged.
- [Owner floors the delay before proposing, minimizing the window] → The
  floor (1 day) IS the guarantee; `CertifyDelaySet` is indexable and a
  sudden floor-set is itself a watchtower signal.
- [Fresh registry deploy needed on live chains] → Already the documented
  operational pattern for registry changes (DeployPlanB manual follow-ups);
  the factory rewire (`setTierRegistry`) propagates to existing governors
  via the factory owner path.

## Migration Plan

1. Implement in `src/TierRegistry.sol` (no other contract changes).
2. Update the 8 test suites via the fixture helper; add the new
   timelock-behavior suites (tasks.md).
3. Update comment/console text in script/Deploy.s.sol and
   script/DeployPlanB.s.sol; extend the Deploy ceremony notes: propose
   launch set under deployer ownership → transfer ownership → executions
   land permissionlessly after the delay.
4. On any chain with a live registry: deploy new registry, re-propose the
   live certification set, after the delay execute, then
   `factory.setTierRegistry(new)` — sequenced so governors switch registries
   only once the new one is populated (avoiding a window where every pair
   reads tier 2 through the new empty registry). Re-apply
   `setAdapterAllowed` entries and `setAuthorizedDemoter` before the switch.
   Rollback is `factory.setTierRegistry(old)` — the old registry remains
   intact throughout.

## Open Questions

None — parameter values (`3 days` default, `[1, 30] days` bounds) are
proposed here and cheap to adjust at review time without touching the
approach.
