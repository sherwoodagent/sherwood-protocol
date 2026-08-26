## ADDED Requirements

### Requirement: Sandbox calls are proposal data priced at full notional
A proposal MAY carry a sandbox payload — an ordered call set, a funding amount, and a declared token set — stored at propose time alongside the execute and settlement calls. The payload SHALL be immutable once stored and readable in full for the whole review period. Its funding amount SHALL contribute to required coverage at full notional (`10_000` bps), and the proposal's tier SHALL therefore be 2 whenever a sandbox payload is present.

The adversary is a payload that is priced as if it were bounded: a sandbox executes proposer-authored calldata against unreviewed targets, so no certified `extractableBoundBps` can describe it and any bound below full notional would under-price the guardian coverage that is the actual review. Storing it at propose is what makes the review possible at all — a payload supplied at execute time would be approved unseen.

#### Scenario: A sandbox payload forces tier 2
- **WHEN** a proposal carries a sandbox payload
- **THEN** its resolved tier SHALL be 2 and the funding amount SHALL contribute its full value to required coverage

#### Scenario: The payload is immutable after propose
- **WHEN** anyone attempts to alter a stored sandbox payload after the proposal is created
- **THEN** the attempt SHALL revert

#### Scenario: The payload is readable during review
- **WHEN** a guardian reads a proposal during the review period
- **THEN** the complete call set, funding amount and declared token set SHALL be returned by a public view

#### Scenario: Agent gate is unchanged
- **WHEN** a non-agent attempts to create a proposal carrying a sandbox payload
- **THEN** the call SHALL revert `NotRegisteredAgent`, exactly as for any other proposal

### Requirement: Sandbox funding is scaled by raised coverage
When a proposal carrying a sandbox payload executes, the governor SHALL dispatch the sandbox through the vault's governor-only entry point, and SHALL scale the funding amount by the same raised-over-required coverage ratio it applies to effective capital and per-call caps. A funding amount that scales to zero SHALL execute no sandbox rather than executing an unfunded one.

The adversary is a partially-covered proposal executing at full size: the coverage quorum's scaling is what makes under-raised approval safe rather than binary, and a sandbox funded at full amount under partial coverage would be the one path that escapes it.

#### Scenario: Partial coverage funds a proportionally smaller sandbox
- **WHEN** approvers raise half the required coverage for a proposal with a sandbox payload
- **THEN** the sandbox SHALL be funded with half the declared amount

#### Scenario: Coverage scaling to zero runs no sandbox
- **WHEN** the scaled funding amount floors to zero
- **THEN** no sandbox SHALL be minted or funded, and the proposal SHALL continue without it
