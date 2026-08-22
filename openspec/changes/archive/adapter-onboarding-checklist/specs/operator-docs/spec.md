# operator-docs (delta)

## ADDED Requirement: Adapter onboarding is a written dual-gate procedure

#### Scenario: operator onboards an adapter

- **WHEN** an operator follows `docs/adapter-onboarding-checklist.md`
- **THEN** they encounter, in order: the dual-gate explanation with both
  silent-failure directions; the generic-executor prohibition; the
  selector-inventory sign-off requirement; the same-session rule for
  flipping both gates; concrete `cast call` verification reads for
  `tierOf` and `isAdapterAllowed`; the proxied-adapter prohibition; and the
  safe de-onboarding order (allowlist off before decertification).

#### Scenario: reviewer audits an onboarding

- **WHEN** a reviewer checks a completed onboarding against the checklist
- **THEN** every item is verifiable from on-chain reads or written artifacts
  (the selector inventory + sign-off), with no item relying on memory.

#### Scenario: checklist stays honest about enforcement

- **THEN** the document states explicitly that nothing on-chain enforces the
  pairing today, and points at #45 (certify timelock) and the CI-invariant
  idea as tracked follow-ups.
