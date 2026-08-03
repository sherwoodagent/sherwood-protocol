## MODIFIED Requirements

### Requirement: Factory lifecycle-gated administration
The factory SHALL gate structural changes on the governor's lifecycle state. `rotateOwner(vault, newOwner)` SHALL require the caller to be the current vault owner or the original creator, the old owner stake to be fully withdrawn, both `getActiveProposal() == 0` and `openProposalCount() == 0`, and the incoming owner's prior vault-specific consent to the stake binding (recorded on sWOOD by `newOwner` via `approveOwnerStakeBinding(vault)` — adversary: a current owner of an empty-slot vault must not be able to spend a third party's escrowed prepared stake by rotating the vault onto them); it SHALL transfer vault ownership, rebind the owner-stake slot on sWOOD (consuming the consent), and update the creator record. The signature and single-call semantics of `rotateOwner` SHALL be unchanged — consent is enforced at the sWOOD spend site, not by a new factory entrypoint. `upgradeVault(vault, expectedImpl)` SHALL require upgrades enabled, the caller to be the creator, `vaultImpl == expectedImpl` (so a factory-owner impl swap cannot land an implementation the creator did not opt into), and the same two lifecycle gates. `pushWiring(governor)` SHALL be factory-owner-only, SHALL verify the target is a governor this factory deployed (via the unforgeable `governor.vault()` → `governorOf` round-trip), and SHALL push only the factory's currently-set tier registry / exposure ledger / bond escrow — never writing zero, so wiring can be added but never silently removed. `setGuardianRegistry` SHALL fail-closed unless the new registry advertises this factory (or address(0) for a stateless stub).

#### Scenario: Rotation blocked mid-lifecycle
- **WHEN** `rotateOwner` or `upgradeVault` is called while the vault's governor has an executing proposal or any open proposal
- **THEN** the call SHALL revert (`ProposalActive` / `StrategyActive` or `ProposalsOpen`)

#### Scenario: Rotation without the incoming owner's consent
- **WHEN** `rotateOwner(vault, newOwner)` passes the caller and lifecycle gates but `newOwner` has not approved `vault` for stake binding on sWOOD
- **THEN** the call SHALL revert with `BindingNotApproved`, and no vault ownership, owner-stake, or creator-record state SHALL change

#### Scenario: pushWiring rejects foreign governors
- **WHEN** `pushWiring` targets an address that is not a governor deployed by this factory
- **THEN** the call SHALL revert with `NotFactoryGovernor`
