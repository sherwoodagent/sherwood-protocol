## MODIFIED Requirements

### Requirement: The counterparty allowlist is the only venue allowlist
The registry SHALL maintain exactly one owner-managed counterparty (venue) allowlist, `setCounterpartyAllowed(counterparty, allowed)` (emitting `CounterpartyAllowedSet`; read via `isCounterpartyAllowed(counterparty)`), answering one question: may a certified strategy template bind this address as a venue inside the template's own reviewed code. It SHALL confer nothing to a governor batch: the vault's batch guard does not read it. The grant SHALL snapshot the counterparty's effective codehash (normalizing `bytes32(0)` and `keccak256("")` to one "no code" value) and `isCounterpartyAllowed` SHALL return true only while the live effective codehash equals the snapshot — the same lazy self-heal as `tierOf`; a re-grant re-attests the current code. There SHALL be no class fallback, no implication from any other standing, and no certification action SHALL set or restore an entry. It is not the registry's only owner-managed axis: the token↔price-source attestation (`setPriceSourceForToken`, "Token↔price-source attestation is a separate axis") and the Morpho market-id allowlist (`setMorphoMarketAllowed`, "Morpho markets are allowlisted by market id") are separate ones.

#### Scenario: Granting is owner-only
- **WHEN** a non-owner calls `setCounterpartyAllowed`
- **THEN** the call reverts (Ownable)

#### Scenario: Codehash drift closes the entry on the next read
- **WHEN** code is replaced at a listed counterparty after the grant
- **THEN** `isCounterpartyAllowed` returns false without any state write, until the owner re-grants

#### Scenario: A template binds only a listed venue
- **WHEN** a template's `initialize` names a venue whose `isCounterpartyAllowed` is false
- **THEN** the clone reverts at init with the template's own "not allowed" error naming the venue and the registry (`MorphoNotAllowed(morpho, registry)`, `AdapterNotAllowed(swapAdapter, registry)`, `PriceSourceNotAllowed(priceSource, registry)`, `CounterpartyNotAllowed(counterparty, registry)`)
