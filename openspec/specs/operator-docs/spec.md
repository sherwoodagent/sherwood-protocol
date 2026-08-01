# Operator Docs Specification

## Purpose

Requirements on operator-facing procedural documentation for actions that are not fully enforced on-chain — starting with adapter onboarding/de-onboarding, a two-gate procedure (tier certification + adapter allowlisting) where nothing on-chain today ties the two gates together.

## Requirements

### Requirement: Adapter onboarding is a written dual-gate procedure
`docs/adapter-onboarding-checklist.md` SHALL walk an operator through, in order: the dual-gate explanation covering both silent-failure directions (allowlisted-but-undercertified and certified-but-unlisted); the prohibition on onboarding a generic executor adapter; the requirement to sign off a selector inventory before onboarding; the same-session rule for flipping both gates together; concrete `cast call` verification reads for `tierOf` and `isAdapterAllowed`; the prohibition on onboarding a proxied adapter; and the safe de-onboarding order (allowlist off before decertification).

#### Scenario: Operator onboards an adapter
- **WHEN** an operator follows `docs/adapter-onboarding-checklist.md`
- **THEN** they encounter, in order: the dual-gate explanation with both silent-failure directions; the generic-executor prohibition; the selector-inventory sign-off requirement; the same-session rule for flipping both gates; concrete `cast call` verification reads for `tierOf` and `isAdapterAllowed`; the proxied-adapter prohibition; and the safe de-onboarding order (allowlist off before decertification)

#### Scenario: Reviewer audits an onboarding
- **WHEN** a reviewer checks a completed onboarding against the checklist
- **THEN** every item is verifiable from on-chain reads or written artifacts (the selector inventory + sign-off), with no item relying on memory

#### Scenario: Checklist stays honest about enforcement
- **WHEN** the operator reads the enforcement caveat
- **THEN** the document states explicitly that nothing on-chain enforces the tier/allowlist pairing today, and points at the certify-timelock proposal and a CI-invariant idea as tracked follow-ups
