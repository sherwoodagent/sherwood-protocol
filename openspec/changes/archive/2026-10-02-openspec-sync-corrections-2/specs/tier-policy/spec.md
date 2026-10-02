## MODIFIED Requirements

### Requirement: Governance certification discipline
Certification SHALL be treated as a governance judgment the code cannot check: governance SHALL NOT certify proxied adapters at tier 0/1 (the codehash guard cannot see implementation swaps), and SHALL NOT certify with a loose `extractableBoundBps` — an over-generous bound slides the economics continuously back toward the tier-2 result while looking safe. Coverage sizing consumes the bound per call (`requiredCoverage = Σ cap_i × boundBps_i / 10_000` over the execute and settlement legs, a tier-2 call contributing its full cap), so the bound is the real risk parameter.

#### Scenario: Loose bound distorts coverage
- **WHEN** a tier-0 certification carries a bound far above the adapter's true extractable value
- **THEN** every proposal touching it demands correspondingly inflated guardian coverage priced as if the leak were real — the certification is worse than refusing to certify

### Requirement: Config keying
Tier configuration SHALL support two keying modes held in separate mappings. Address-keyed configuration SHALL be keyed by `keccak256(abi.encodePacked(target, selector))`, exposed as the pure function `key(address target, bytes4 selector)`. Class-keyed configuration SHALL be keyed by the class fingerprint and the selector, where the fingerprint is `keccak256(abi.encodePacked(cloneCodehash, _classEpoch[cloneCodehash]))`, `cloneCodehash` is the ERC-1167 runtime codehash derived from a template address (`cloneCodehashOf(template)`), and `_classEpoch[cloneCodehash]` advances when a re-certification finds the template's code changed, orphaning every config certified against the old code. Certification and demotion operate on whichever key the entry was created under; the two namespaces SHALL be independent and SHALL NOT alias.

#### Scenario: Same target, different selectors are independent
- **WHEN** two selectors on the same target are certified separately
- **THEN** each `(target, selector)` pair carries its own tier config; demoting one does not affect the other

#### Scenario: Same class, different selectors are independent
- **WHEN** two selectors on the same code class are certified separately
- **THEN** each `(class, selector)` pair carries its own tier config; demoting one does not affect the other

#### Scenario: Address and class keys never collide
- **WHEN** an address entry and a class entry exist whose raw key preimages could otherwise coincide
- **THEN** they remain distinct entries — the two keying modes occupy separate mappings and neither can be written through the other's entry point
