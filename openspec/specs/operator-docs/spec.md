# Operator Docs Specification

## Purpose

Requirements on operator-facing procedural documentation for actions that are not fully enforced on-chain — starting with adapter onboarding/de-onboarding, a two-gate procedure (tier certification + adapter allowlisting) where nothing on-chain today ties the two gates together.
## Requirements
### Requirement: Adapter onboarding is a written dual-gate procedure
`docs/adapter-onboarding-checklist.md` SHALL walk an operator through, in order: the dual-gate explanation covering both silent-failure directions (allowlisted-but-undercertified and certified-but-unlisted); the prohibition on onboarding a generic executor adapter; the requirement to sign off a selector inventory before onboarding; the same-session rule for flipping both gates together; concrete `cast call` verification reads for `tierOf` and `isAdapterAllowed`; the prohibition on onboarding a proxied adapter; and the safe de-onboarding order (allowlist off before decertification).

The onboarding section SHALL additionally document the allowlist's codehash binding:

- `setAdapterAllowed(adapter, true)` snapshots the adapter's code at grant time, and `isAdapterAllowed` answers true only while the live code still matches — so the grant MUST be made AFTER the adapter's final code is deployed and verified, never against a predicted (counterfactual) address.
- After any legitimate bytecode change at the adapter's address, the funds path stays closed until the owner re-attests the new code with a fresh `setAdapterAllowed(adapter, true)`; this is the designed recovery ceremony, mirroring the demote → re-certify cycle for tiers.
- The binding, like `tierOf`'s, cannot see proxy implementation swaps — the proxied-adapter prohibition covers the allowlist gate for the same reason it covers certification.

The de-onboarding section SHALL additionally document the on-chain auto-clear and the watcher's NARROWED remaining job:

- Every persisted demotion (`demote`, `demoteByChallenge`, `poke`) now clears the adapter's allowlist entry on-chain, atomically, emitting `AdapterAllowedSet(adapter, false)`; the operator no longer needs to react to `TierDemoted` with a manual `setAdapterAllowed(adapter, false)` for that adapter.
- The clear is over-broad by design (one selector's demotion de-allowlists the whole adapter); restoring the surviving selectors' adapter is an explicit owner `setAdapterAllowed(adapter, true)` call, and re-certification never restores it.
- The one case the auto-clear structurally CANNOT cover: the ChallengeGame calls `demoteByChallenge` best-effort inside a `try/catch`, so a REVERTED demotion (e.g. the demoter role was rotated away mid-challenge) runs no `_demote` and clears nothing — only `AdapterDemotionFailed` is emitted. `AdapterDemotionFailed` therefore remains a mandatory allowlist alarm: on it, the operator applies the lost demotion via owner `demote` (which itself clears the allowlist) or calls `setAdapterAllowed(adapter, false)` directly.
- The lazy path is now a HYGIENE item, not a live funds-path hazard: on a codehash mismatch both `tierOf` AND `isAdapterAllowed` self-heal on read, so vault funds cannot reach a code-changed adapter even before anyone calls `poke`. What survives un-poked is only stale STORAGE and stale indexer state (`AdapterAllowedSet` history says allowed; the read says no); the drift sweep (reconciling `AdapterAllowedSet` against certified, current-codehash pairs) remains in force to persist demotions via `poke` where a certification exists, and to owner-clear allowlist-only entries (which `poke` cannot reach — it reverts `NotCertified` for uncertified pairs).

#### Scenario: Operator onboards an adapter
- **WHEN** an operator follows `docs/adapter-onboarding-checklist.md`
- **THEN** they encounter, in order: the dual-gate explanation with both silent-failure directions; the generic-executor prohibition; the selector-inventory sign-off requirement; the same-session rule for flipping both gates; concrete `cast call` verification reads for `tierOf` and `isAdapterAllowed`; the proxied-adapter prohibition; and the safe de-onboarding order (allowlist off before decertification)

#### Scenario: Operator learns the grant binds to the deployed code
- **WHEN** an operator reads the onboarding section's allowlist step
- **THEN** the document tells them to grant only after the final code is deployed and verified, that any later code change closes the funds path on the next read without waiting for `poke`, and that re-attesting after a verified upgrade is a fresh explicit `setAdapterAllowed(adapter, true)`

#### Scenario: Reviewer audits an onboarding
- **WHEN** a reviewer checks a completed onboarding against the checklist
- **THEN** every item is verifiable from on-chain reads or written artifacts (the selector inventory + sign-off), with no item relying on memory

#### Scenario: Checklist stays honest about enforcement
- **WHEN** the operator reads the enforcement caveat
- **THEN** the document states explicitly that nothing on-chain enforces the tier/allowlist pairing today, and points at the certify-timelock proposal and a CI-invariant idea as tracked follow-ups

#### Scenario: Operator learns what the auto-clear does and does not cover
- **WHEN** an operator reads the de-onboarding section after a demotion event
- **THEN** the document tells them that persisted demotions cleared the allowlist on-chain already, that `AdapterDemotionFailed` remains the mandatory manual-action alarm, that un-poked codehash drift is stale storage/indexer state rather than an open funds path (both reads self-heal), and that re-allowlisting after any clear is an explicit owner decision

