# Tier Policy — Delta: timelock-certification-grant

## ADDED Requirements

### Requirement: Certification grant is announced before it takes effect
Granting a tier-0/1 certification SHALL be a two-step process: an owner-only
proposal, a mandatory delay, then a permissionless execution. The adversary is
the certification key itself — a compromised or coerced owner certifying a
malicious target at a basis-points bound, instantly repricing extractable
value for every vault at once. The announcement window is the review the
other layers (guardians repricing, depositors exiting, watchtowers
inspecting the target) act in.

`proposeCertification(target, selector, tier, extractableBoundBps, submitter,
expectedCodehash)` SHALL be owner-only and SHALL enforce every input guard the
instant path enforced: revert `InvalidTier` when `tier >= 2`; `BoundRequired`
when `extractableBoundBps` is `0` or `>= 10_000`; `NotAContract` when the
target's codehash is `bytes32(0)` or `keccak256("")`; `ZeroAddressSubmitter`
when the current `submitterBondWood` is non-zero and `submitter` is
`address(0)`. It SHALL additionally revert `CodehashChanged` when the
target's LIVE codehash (read at this call's own execution time) does not
equal the caller-supplied `expectedCodehash` — the hash the owner actually
reviewed off-chain (PR #156 audit remediation, finding #6 — closes a
propose-time TOCTOU: without this check, a gap between off-chain review and
on-chain mining, e.g. mempool or multisig confirmation latency, would let a
third party — the target's own deployer, not this registry's owner —
redeploy different bytecode at `target` before the proposal transaction
lands, silently pinning a codehash nobody actually reviewed; `certify`'s own
codehash re-check only re-verifies THIS snapshot and can never detect that
the snapshot itself was wrong).

On success it SHALL record a pending certification for the key carrying the
proposed `(tier, extractableBoundBps, submitter)`, the target's current
`EXTCODEHASH`, the current `wood` token address as the pinned bond token
(finding #1 — see the modified bond requirement below), the current
`submitterBondWood` as the pinned bond amount, and
`readyAt = block.timestamp + certifyDelay`, and SHALL emit
`CertificationProposed(target, selector, tier, extractableBoundBps, submitter,
bondAmount, codehash, readyAt)`.

Re-proposing a key that already has a pending certification SHALL overwrite
the pending record entirely (fresh parameters, fresh codehash snapshot, fresh
pinned bond amount and token, fresh `readyAt`) — a re-announcement restarts
the clock, it never shortens it.

A pending certification SHALL have no effect on `tierOf` or on the adapter
allowlist until executed — announcement is not certification. It SHALL,
however, be cancelled as a side effect of a same-key demotion (finding #2 —
see the new demotion-cancels-pending requirement below); that exception
exists precisely so a for-cause revocation can never be silently overridden
by an announcement that predates it.

#### Scenario: Proposal records intent without changing the effective tier
- **WHEN** the owner proposes a certification for an uncertified pair
- **THEN** `CertificationProposed` is emitted with the pinned parameters,
  codehash, bond amount, and `readyAt`, and `tierOf` still returns
  `(2, 10_000)` for the pair

#### Scenario: Proposal enforces the instant path's input guards
- **WHEN** the owner proposes with `tier = 2`, or a bound of `0` or
  `>= 10_000`, or an EOA / empty-code target, or a zero submitter while the
  bond is armed
- **THEN** the call reverts with the same error the instant `certify` raised
  for that input (`InvalidTier` / `BoundRequired` / `NotAContract` /
  `ZeroAddressSubmitter`)

#### Scenario: Proposal enforces the reviewed-codehash assertion
- **WHEN** the owner proposes with `expectedCodehash` set to the bytecode
  hash they reviewed off-chain, but a third party has redeployed different
  bytecode at `target` before this transaction mines
- **THEN** the call reverts `CodehashChanged` and no pending record is
  written — the owner's stale review can never be blindly re-photographed
  into a pinned certification for bytecode nobody actually reviewed

#### Scenario: Non-owner cannot propose
- **WHEN** a non-owner calls `proposeCertification`
- **THEN** the call reverts (Ownable)

#### Scenario: Re-proposal restarts the clock and re-pins everything
- **WHEN** the owner proposes again for a key with an existing pending
  certification, after the bond config, the bond token, or the delay changed
- **THEN** the pending record carries only the new parameters, the new
  codehash snapshot, the newly pinned bond amount and token, and a new
  `readyAt = block.timestamp + certifyDelay` — nothing from the old
  announcement survives

### Requirement: Certification execution is permissionless when unbonded, submitter-gated when bonded, delayed, code-pinned, and time-bounded
`certify(target, selector)` SHALL be callable by anyone when the pending
certification's pinned bond amount is zero. When the pinned bond amount is
non-zero, `certify` SHALL revert `NotSubmitter` unless
`msg.sender == p.submitter` (PR #156 audit remediation, finding #3). Without
this restriction, `submitter` — an arbitrary address the owner names at
proposal time with no signature or `msg.sender` tie-in — could have their
bond pulled by any permissionless caller off whatever STANDING ERC20
allowance that address already happens to have on this registry, never
scoped to this specific certification, even though that address never saw
or approved this particular grant. Gating execution to the submitter
whenever funds are actually at stake turns a stale, general-purpose
allowance into live, in-the-moment consent: the party whose funds are at
risk is also the only one who can put them at risk. An unbonded
certification has no funds to consent about, so it stays fully
permissionless — narrowing "anyone can trigger" only where fund custody is
actually in play.

`certify` SHALL revert when no pending certification exists for the key
(`NoPendingCertification`), when `block.timestamp < readyAt`
(`CertifyDelayNotElapsed`), when `block.timestamp > readyAt +
MAX_CERTIFY_WINDOW` (`CertificationExpired` — finding #5, see below), and
when the target's live codehash no longer equals the proposal-time snapshot
(`CodehashChanged`) — a code change during the window voids the grant rather
than certifying different bytecode under an old announcement. The
bond-conflict guards SHALL be enforced here, at execution (see the modified
re-certification requirement below).

On success it SHALL pull the pinned bond, using the bond TOKEN pinned at
proposal time rather than the live `wood` state variable (see the modified
bond requirement below), write the tier config with the snapshotted
codehash, delete the pending record, and emit the existing `TierCertified`.

Permissionless (or submitter-gated) execution is safe because every
parameter was pinned and announced at proposal time: an executing party can
choose only the timing after `readyAt` and before `readyAt +
MAX_CERTIFY_WINDOW`, never the content. The announcement is the owner's
consent; the owner's remedies against an execution it no longer wants are
`cancelCertification` before execution and instant `demote` after it.

The registry SHALL carry a constant `MAX_CERTIFY_WINDOW = 14 days` bounding
how long after `readyAt` a pending certification may still be executed
(finding #5). Without an upper bound, a submitter fully controls WHEN to
trigger a permissionless-or-self-gated execution and can wait out a price
collapse on the bond token's liquidity before posting badly-stale collateral
against an unchanged extractable bound. `MAX_CERTIFY_WINDOW` is a fixed
constant, not an owner-configurable delay (unlike `certifyDelay`), so the
owner has no lever to shorten it and expire someone else's pending
certification early.

#### Scenario: Execution before readyAt refused
- **WHEN** anyone calls `certify` on a pending certification before its
  `readyAt`
- **THEN** the call reverts `CertifyDelayNotElapsed`

#### Scenario: Execution with no announcement refused
- **WHEN** anyone calls `certify` on a key with no pending certification
- **THEN** the call reverts `NoPendingCertification`

#### Scenario: Code change mid-window voids the grant
- **WHEN** the target's bytecode changes after proposal (metamorphic
  redeploy) and anyone calls `certify` after `readyAt`
- **THEN** the call reverts `CodehashChanged` and no certification is
  written — the stale pending record grants nothing and the owner can
  `cancelCertification` or re-propose against the new code

#### Scenario: Third-party execution realizes exactly the announced state (unbonded)
- **WHEN** an unrelated address calls `certify` after `readyAt` on a healthy
  pending certification with a zero pinned bond amount
- **THEN** the pair is certified with precisely the proposed tier, bound, and
  snapshotted codehash, the pending record is deleted, and `TierCertified`
  is emitted — identical to the owner executing it

#### Scenario: A non-submitter cannot trigger a bonded execution
- **WHEN** a pending certification carries a non-zero pinned bond amount and
  any address other than the pinned `submitter` (including the registry
  owner) calls `certify` after `readyAt`
- **THEN** the call reverts `NotSubmitter`, and the pinned submitter's own
  call still succeeds

#### Scenario: Execution refused once the certify window expires
- **WHEN** anyone calls `certify` more than `MAX_CERTIFY_WINDOW` after
  `readyAt`
- **THEN** the call reverts `CertificationExpired`, and the pending record
  is left inert (recoverable only via a fresh `proposeCertification`) —
  identical in spirit to a codehash-voided pending

### Requirement: Pending certification can be cancelled by the owner
`cancelCertification(target, selector)` SHALL be owner-only, SHALL revert
`NoPendingCertification` when no pending record exists, and on success SHALL
delete the pending record and emit `CertificationCancelled(target, selector)`.
Cancellation SHALL NOT touch any live certification, bond, or allowlist state
for the key — it withdraws only the announcement.

#### Scenario: Cancel clears the pending grant
- **WHEN** the owner cancels a pending certification and anyone later calls
  `certify` for that key
- **THEN** the `certify` call reverts `NoPendingCertification`

#### Scenario: Cancel does not disturb a live certification
- **WHEN** a pair is already certified, a replacement is proposed, and the
  owner cancels the replacement
- **THEN** the existing certification, its bond, and the allowlist are
  unchanged

#### Scenario: Non-owner cannot cancel
- **WHEN** a non-owner calls `cancelCertification`
- **THEN** the call reverts (Ownable)

### Requirement: Demotion cancels a same-key pending certification
Every demotion path (`demote`, `demoteByChallenge`, `poke`) SHALL, as part of
the same `_demote` convergence point that clears `_configs[k]`, also delete
any pending certification recorded for that same key and emit
`CertificationCancelled(target, selector)` if one existed (PR #156 audit
remediation, finding #2). Without this, a "renewal" proposed while a
certification is still live would survive that certification's later
for-cause demotion untouched, and would go on to execute at `readyAt`
re-certifying the just-convicted target — possibly at looser terms than
before the conviction. `demoteByChallenge`'s caller (the challenge game) has
no other lever to stop this, since `cancelCertification` is owner-only; this
requirement gives every demotion path — not just the owner's — the power to
void a stale announcement it would otherwise be defenseless against.

This cancellation SHALL be scoped to the demoted key only: an unrelated
key's pending certification SHALL be unaffected by a demotion on a different
key (see the existing "demotion unaffected" scenarios for the un-demoted
side of this same guarantee).

#### Scenario: Challenge-triggered demotion cancels a pending renewal
- **WHEN** a live certification is convicted via `demoteByChallenge` while a
  same-key pending certification (a "renewal") is announced but not yet
  executed
- **THEN** `_configs[k]` is cleared as before, the pending renewal is
  deleted, `CertificationCancelled` is emitted, and a later `certify` call
  for that key reverts `NoPendingCertification` instead of silently
  re-certifying the convicted target

#### Scenario: Owner demotion and permissionless poke cancel identically
- **WHEN** a same-key pending certification exists and the live certification
  is demoted via the owner's `demote` or the permissionless `poke`
- **THEN** the pending record is deleted in both cases, exactly as under
  `demoteByChallenge` — all three paths converge on the same `_demote` logic

#### Scenario: Demoting one key does not cancel another key's pending
- **WHEN** two different keys each carry independent state (one live and
  demoted, one pending) 
- **THEN** demoting the first key's certification leaves the second key's
  pending certification untouched

### Requirement: Certify delay is bounded and announced deadlines are pinned
The registry SHALL carry an owner-settable `certifyDelay` (default `3 days`)
via `setCertifyDelay(delay)`, reverting `InvalidDelay` outside
`[MIN_CERTIFY_DELAY = 1 days, MAX_CERTIFY_DELAY = 30 days]`. The floor
guarantees every grant is announced for at least one full day — the delay can
never be configured back into the instant path; the ceiling bounds governance
error so a mis-set delay cannot stall onboarding indefinitely. The setter
SHALL emit `CertifyDelaySet(delay)`.

Changing `certifyDelay` SHALL NOT move the `readyAt` of any already-pending
certification: `readyAt` is computed once at proposal time and is immutable
thereafter (the same intent-time pinning as `releasableAt`, which reads
`bondReleaseDelay` once at demotion). The adversary is an owner who shortens
the delay to ripen an already-announced grant early — the emitted `readyAt`
is a commitment watchtowers must be able to trust as the earliest possible
activation. Shortening the delay therefore only affects future proposals,
and the only way to apply a new delay to an announced grant is a re-proposal,
which restarts the full window.

#### Scenario: Delay outside bounds refused
- **WHEN** the owner sets a certify delay below 1 day or above 30 days
- **THEN** the call reverts `InvalidDelay`

#### Scenario: Delay change does not move an announced readyAt
- **WHEN** a certification is proposed at delay D, the owner then lowers the
  delay to the floor, and anyone calls `certify` after the floor delay but
  before the original `readyAt`
- **THEN** the call reverts `CertifyDelayNotElapsed` — the pinned `readyAt`
  governs

## MODIFIED Requirements

### Requirement: Submitter bond token and amount are both pinned at proposal, pulled at execution
The bond amount AND the bond token SHALL both be pinned at proposal time and
pulled together at execution time. `proposeCertification` SHALL snapshot the
then-current `submitterBondWood` and the then-current `wood` token address
into the pending record (reverting `ZeroAddressSubmitter` when the amount
snapshot is non-zero and `submitter` is `address(0)`); later changes to
`submitterBondWood` OR to `wood` (via `setWood`) SHALL NOT affect the pending
grant — the submitter consented (via approval on a specific token) to a
known amount denominated in that token, and an executor must not be able to
pull a different amount, or the same amount in a different token, than what
was announced.

Pinning the bond token closes a gap (PR #156 audit remediation, finding #1,
confidence 92): `setWood`'s only guard (`totalBondedWood != 0`) is blind to
unexecuted pending certifications, since `totalBondedWood` is incremented
only inside `certify`. Without pinning the token, an entirely ordinary,
honest token migration (`setWood`) during the certify-delay window would
make execution pull the pinned AMOUNT denominated in whatever token is live
at execution time — not the token the submitter actually approved against —
either silently pulling value in the wrong token (if the submitter happens
to hold a standing approval on it) or permanently bricking the certification
with no expiry (if not). Pinning the token at proposal time makes `setWood`
inert to any already-pending certification's bond economics by
construction, regardless of when it is called relative to execution.

When the pinned amount is non-zero, `certify` SHALL — at execution — record a
`SubmitterBond{submitter, amount, releasableAt: 0}` for the key, add the
pinned amount to `totalBondedWood`, pull it from the recorded submitter via
`safeTransferFrom` on the PINNED bond token (never the live `wood`), and emit
`SubmitterBondLocked`. No WOOD moves at proposal time: the submitter's
capital is not locked during a window in which nothing is certified, and
cancellation or a voided grant needs no refund path. If the pull fails at
execution (allowance revoked, balance insufficient), the `certify` call
reverts and remains retryable — a submitter who withholds approval thereby
withholds the certification, which is the correct reading of a bond as the
submitter's live consent; the owner's remedy is `cancelCertification` and a
re-proposal with a different submitter.

When the pinned amount is zero, execution SHALL write the config without
touching WOOD or the bonds mapping (the Plan A no-bond passthrough), even if
`submitterBondWood` was raised after the proposal.

The registry WOOD balance invariant
(`wood.balanceOf(address(this)) == totalBondedWood`) is unchanged: bonds
exist only for executed certifications, never for pending ones.

#### Scenario: Bonded certification locks WOOD at execution
- **WHEN** a certification proposed with a non-zero pinned bond is executed
  after `readyAt` by the pinned submitter, having approved the registry
- **THEN** exactly the pinned amount transfers from the submitter into the
  registry, `totalBondedWood` increases by it, and `SubmitterBondLocked` is
  emitted

#### Scenario: Bond config change mid-window does not reprice the pull
- **WHEN** the owner raises (or zeroes) `submitterBondWood` after a
  certification was proposed, and the pending certification is then executed
- **THEN** the amount pulled is the amount pinned at proposal time, not the
  live config

#### Scenario: A `setWood` token migration mid-window does not retoken the pull
- **WHEN** a certification is proposed while `wood` is TokenA, the owner
  calls `setWood` to migrate to TokenB before execution (legal because
  `totalBondedWood == 0` while nothing has executed yet), and the pending
  certification is then executed by the pinned submitter
- **THEN** the pull is against TokenA — the token pinned at proposal time —
  and TokenB (the now-live `wood`) is never touched by this certification's
  bond, regardless of what allowances the submitter holds on either token

#### Scenario: Lapsed submitter approval blocks execution retryably
- **WHEN** the submitter revokes their WOOD approval during the window and
  anyone calls `certify` after `readyAt`
- **THEN** the call reverts (SafeERC20), no state changes, and a later
  `certify` succeeds once approval is restored — or the owner cancels and
  re-proposes with a new submitter

#### Scenario: Zero-config bond skips the pull
- **WHEN** `submitterBondWood` was 0 at proposal time
- **THEN** execution records the tier config without touching WOOD or the
  bonds mapping

### Requirement: A key with any existing bond cannot be re-certified
`certify` — the execution step — SHALL revert while ANY bond exists for the
key: `BondActive` when the bond is held under a live certification
(`releasableAt == 0`), `BondPendingRelease` when a demoted bond is in its
release timelock. Replacing a bonded certification still requires demote →
release timelock → claim → execute; during that whole window the key reads
as tier 2, and no path ever swaps a certification out from under a live bond
or strands a submitter's WOOD.

`proposeCertification` SHALL NOT be gated on the key's bond state: the
announcement may be made while the old bond is still active or releasing, so
the certify delay and the bond-release timelock can run concurrently rather
than in series. The bond guard is authoritative at execution, where the bond
is actually written.

#### Scenario: Execute over an active bond refused
- **WHEN** anyone executes a pending certification for a key whose bond is
  still held under a live certification
- **THEN** the call reverts `BondActive`

#### Scenario: Execute during the release timelock refused, then succeeds after claim
- **WHEN** a bonded pair is demoted, a replacement certification is proposed
  during the release timelock, and execution is attempted first before and
  then after `claimSubmitterBond`
- **THEN** the pre-claim attempt reverts `BondPendingRelease` and the
  post-claim attempt (past `readyAt`) succeeds — the two timelocks overlap

### Requirement: Governance certification discipline
Certification SHALL be treated as a governance judgment the code cannot
check: governance SHALL NOT certify proxied adapters at tier 0/1 (the
codehash guard cannot see implementation swaps), and SHALL NOT certify with
a loose `extractableBoundBps` — an over-generous bound slides the economics
continuously back toward the tier-2 result while looking safe. Coverage
sizing consumes the bound directly
(`requiredCoverage = maxCapital × Σ boundBps / 10_000`, tier-2 calls
contributing full notional), so the bound is the real risk parameter.

This discipline is NOT limited to recognized proxy shapes (PR #156 audit
remediation, finding #4): EXTCODEHASH attests only to unchanged bytecode,
never to unchanged behavior. ANY target exposing ordinary, non-`immutable`
storage that is settable after deployment and can affect fund routing — a
beneficiary address, a fee sink, a swap-path parameter, and so on — can have
that state rewired and be certified atomically in the same transaction,
since its codehash never moves. Governance SHALL treat "certifiable at tier
0/1" as bytecode-AND-storage-immutable for every fund-routing-relevant
parameter, not merely "not a known proxy shape": review the target's full
storage layout for post-deployment setters before certifying, not just the
presence or absence of a delegatecall. This is a process/documentation
requirement, not a code-enforced one — the codehash check has no on-chain
way to distinguish a fund-routing setter from an inert one.

The certification timelock is the enforcement aid for this discipline: every
grant is announced at least `MIN_CERTIFY_DELAY` before it can take effect,
with the target, tier, bound, and codehash in the `CertificationProposed`
event, so anyone can inspect the queued target — and in particular flag a
proxied adapter in the queue — before the certification becomes live.
Operators SHALL treat the pending-certification queue as a monitored
surface, and SHALL `cancelCertification` any announcement that is obsolete
or was flagged during its window rather than leaving stale pendings
executable.

#### Scenario: Loose bound distorts coverage
- **WHEN** a tier-0 certification carries a bound far above the adapter's
  true extractable value
- **THEN** every proposal touching it demands correspondingly inflated
  guardian coverage priced as if the leak were real — the certification is
  worse than refusing to certify

#### Scenario: Proxied target is catchable in the queue
- **WHEN** a certification for a proxied adapter is proposed at tier 0/1
- **THEN** the `CertificationProposed` event names the target at least
  `MIN_CERTIFY_DELAY` before the grant can execute, and an owner
  `cancelCertification` during the window prevents it from ever taking
  effect

## REMOVED Requirements

### Requirement: Certification is owner-only with strict input guards
**Reason**: The single-transaction, owner-only, instantly-effective `certify`
is the unreviewable power issue #45 removes. Its input guards are not lost —
they move verbatim to `proposeCertification` — and its effect (config write,
codehash snapshot, `TierCertified`) moves to the permissionless, delayed
execution step. Splitting the requirement in two (announced proposal;
delayed code-pinned execution) states the new contract more precisely than a
modification of the old header, whose "owner-only" no longer describes the
execution step.
**Migration**: Callers of `certify(target, selector, tier,
extractableBoundBps, submitter)` call `proposeCertification` with the same
five arguments plus a sixth, `expectedCodehash` (the bytecode hash reviewed
off-chain — see the propose requirement's `CodehashChanged` guard), wait
`certifyDelay`, then call `certify(target, selector)` — permissionlessly if
the pinned bond amount is zero, or as the pinned `submitter` if it is
non-zero (see the execution requirement's `NotSubmitter` guard), and within
`MAX_CERTIFY_WINDOW` of `readyAt`. Deploy ceremonies propose the launch set
while the deployer still owns the registry and let execution land
permissionlessly (the launch set carries no bond) after handoff.
