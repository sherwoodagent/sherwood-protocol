## MODIFIED Requirements

### Requirement: Adapter onboarding is a written dual-gate procedure
`docs/adapter-onboarding-checklist.md` SHALL walk an operator through, in order: the dual-gate explanation covering both silent-failure directions (allowlisted-but-undercertified and certified-but-unlisted); the prohibition on onboarding a generic executor adapter; the requirement to sign off a selector inventory before onboarding; the same-session rule for flipping both gates together; concrete `cast call` verification reads for `tierOf` and `isAdapterAllowed`; the prohibition on onboarding a proxied adapter; and the safe de-onboarding order (allowlist off before decertification).

The de-onboarding section SHALL additionally document the on-chain auto-clear and the watcher's NARROWED remaining job:

- Every persisted demotion (`demote`, `demoteByChallenge`, `poke`) now clears the adapter's allowlist entry on-chain, atomically, emitting `AdapterAllowedSet(adapter, false)`; the operator no longer needs to react to `TierDemoted` with a manual `setAdapterAllowed(adapter, false)` for that adapter.
- The clear is over-broad by design (one selector's demotion de-allowlists the whole adapter); restoring the surviving selectors' adapter is an explicit owner `setAdapterAllowed(adapter, true)` call, and re-certification never restores it.
- The one case the auto-clear structurally CANNOT cover: the ChallengeGame calls `demoteByChallenge` best-effort inside a `try/catch`, so a REVERTED demotion (e.g. the demoter role was rotated away mid-challenge) runs no `_demote` and clears nothing — only `AdapterDemotionFailed` is emitted. `AdapterDemotionFailed` therefore remains a mandatory allowlist alarm: on it, the operator applies the lost demotion via owner `demote` (which itself clears the allowlist) or calls `setAdapterAllowed(adapter, false)` directly.
- The lazy path also stays with the watcher: `tierOf` reporting tier 2 on a codehash mismatch writes no state, so until someone calls `poke` the stored allowlist entry survives; the drift sweep (reconciling `AdapterAllowedSet` against certified, current-codehash pairs) remains in force.

#### Scenario: Operator onboards an adapter
- **WHEN** an operator follows `docs/adapter-onboarding-checklist.md`
- **THEN** they encounter, in order: the dual-gate explanation with both silent-failure directions; the generic-executor prohibition; the selector-inventory sign-off requirement; the same-session rule for flipping both gates; concrete `cast call` verification reads for `tierOf` and `isAdapterAllowed`; the proxied-adapter prohibition; and the safe de-onboarding order (allowlist off before decertification)

#### Scenario: Reviewer audits an onboarding
- **WHEN** a reviewer checks a completed onboarding against the checklist
- **THEN** every item is verifiable from on-chain reads or written artifacts (the selector inventory + sign-off), with no item relying on memory

#### Scenario: Checklist stays honest about enforcement
- **WHEN** the operator reads the enforcement caveat
- **THEN** the document states explicitly that nothing on-chain enforces the tier/allowlist pairing today, and points at the certify-timelock proposal and a CI-invariant idea as tracked follow-ups

#### Scenario: Operator learns what the auto-clear does and does not cover
- **WHEN** an operator reads the de-onboarding section after a demotion event
- **THEN** the document tells them that persisted demotions cleared the allowlist on-chain already, that `AdapterDemotionFailed` and un-poked lazy (codehash-mismatch) demotions are the remaining cases requiring manual allowlist action, and that re-allowlisting after any clear is an explicit owner decision
