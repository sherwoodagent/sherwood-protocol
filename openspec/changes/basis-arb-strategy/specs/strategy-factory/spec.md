## MODIFIED Requirements

### Requirement: Template allowlist admits BasisArbStrategy
The owner-managed template allowlist SHALL gain one entry for the
`BasisArbStrategy` template. No other factory behavior changes: cloning,
atomic clone+initialize, and the unlisted-template revert remain exactly as
specified today.

#### Scenario: The new template clones like the existing ones
- **WHEN** a proposal names the allowlisted `BasisArbStrategy` template
- **THEN** the factory SHALL clone and initialize it atomically, and an
  unlisted address SHALL still revert
