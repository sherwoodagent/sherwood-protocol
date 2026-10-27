# Operator Docs Specification

## Purpose

Requirements on operator-facing procedural documentation for actions that are not fully enforced on-chain — starting with adapter onboarding/de-onboarding, a two-gate procedure (tier certification + adapter allowlisting) where nothing on-chain today ties the two gates together.
## Requirements
### Requirement: Venue onboarding is a written dual-gate procedure
`docs/adapter-onboarding-checklist.md` SHALL walk an operator through the two independent `onlyOwner` writes on `TierRegistry` that onboard a venue, in order: the dual-gate explanation — tier certification (`certify` / `certifyClass`, read through `tierOf`), which prices a call, and the counterparty allowlist (`setCounterpartyAllowed`, read through `isCounterpartyAllowed`), which decides whether a strategy template may bind the address as a venue — with both silent-failure directions; the prohibition on onboarding a generic executor; the requirement to sign off a selector inventory before certifying; the prohibition on onboarding a proxied venue; the same-session rule for flipping both gates together; concrete `cast call` verification reads for `tierOf` and `isCounterpartyAllowed`; and the de-onboarding order.

The onboarding section SHALL document the counterparty grant's codehash binding: `setCounterpartyAllowed(x, true)` snapshots the address's code at grant time and `isCounterpartyAllowed` answers true only while the live code still matches, so the grant MUST be made after the final code is deployed and verified, and a legitimate bytecode change needs a fresh grant. The binding, like `tierOf`'s, cannot see proxy implementation swaps.

The de-onboarding section SHALL state that demotion (`demote`, `demoteByChallenge`) removes the tier certification and bars the address from reading a class tier, but does NOT touch the counterparty allowlist, so de-onboarding a venue is an explicit `setCounterpartyAllowed(x, false)`; and that `AdapterDemotionFailed` from the challenge game means the demotion did not happen and must be applied by the owner's `demote`.

#### Scenario: Operator onboards a venue
- **WHEN** an operator follows `docs/adapter-onboarding-checklist.md`
- **THEN** they encounter the dual-gate explanation with both silent-failure directions, the generic-executor and proxy prohibitions, the selector-inventory sign-off, the same-session rule, and `cast call` reads for `tierOf` and `isCounterpartyAllowed`

#### Scenario: Operator de-onboards a venue
- **WHEN** an operator reads the de-onboarding section after a demotion
- **THEN** the document tells them the counterparty allowlist is still set and must be cleared with `setCounterpartyAllowed(x, false)`, and that `AdapterDemotionFailed` requires an owner `demote`

