# syndicate-vault (delta)

<!-- Change: vault-layout-golden (issue #148). Adds a single requirement about
     the vault's storage layout being pinned; no other syndicate-vault
     requirement is touched. -->

## ADDED Requirements

### Requirement: Storage layout is pinned and golden-guarded
`SyndicateVault`'s storage layout SHALL be pinned by two independent, CI-enforced guards, matching the guarantee already provided for the protocol's other upgradeable contracts (`SyndicateGovernor`, `SyndicateFactory`, `GuardianRegistry`, `StakedWood`): a forge-level slot/offset assertion test covering every top-level storage variable, and a compiler-emitted golden-JSON snapshot diffed on every run. New storage fields SHALL be appended only, carved from the front of the trailing `__gap`; a field SHALL never be deleted outright — a removed field SHALL become a same-slot placeholder or fold into `__gap`, so no live proxy's slot assignment ever needs to disappear.

#### Scenario: A storage reorder is caught before merge
- **WHEN** a change reorders, inserts ahead of, or retypes an existing `SyndicateVault` storage variable
- **THEN** either the forge-level layout-pin test or the golden-JSON CI gate (or both) fails, before the change can reach a live proxy

#### Scenario: An append-only change passes cleanly
- **WHEN** a new field is carved from the front of `__gap` and the golden is regenerated in the same change
- **THEN** both guards pass, and every pre-existing field's pinned slot/offset is unchanged
