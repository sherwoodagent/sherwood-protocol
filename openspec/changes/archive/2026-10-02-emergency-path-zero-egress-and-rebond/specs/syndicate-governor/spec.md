## MODIFIED Requirements

### Requirement: Emergency settlement paths
For a proposal stuck in `Executed` past `executedAt + strategyDuration`, the vault owner SHALL have two escape hatches. (1) `unstick`: run the governance-approved pre-committed settlement calls (no guardian review required, no owner stake required — the calls were already voted on) with the effective settlement caps and the same zero net-outflow budget as `settleProposal`, revert `StrategyNotSettled` while the strategy still answers `executed() == true`, apply the settle-price floor at `MAX_STAMP_DRAWDOWN_BPS` (9_000), then finalize settlement. (2) Owner-supplied calls: `emergencySettleWithCalls` SHALL open a guardian review on the registry keyed by the hash of the supplied calls (so a blocked earlier round resolves and slashes first) and SHALL then revert `OwnerBondInsufficient` unless the owner's bonded stake in the guardian registry is non-zero and meets the required owner bond; `cancelEmergencySettle` withdraws an open review (`EmergencyNotProposed` when none is open); `finalizeEmergencySettle` SHALL, after the registry review resolves, revert with `EmergencySettleBlocked` if guardians blocked it, revert `OwnerBondInsufficient` if the owner's stake is zero, otherwise execute the registry-stored calls with empty per-call caps and a net-outflow budget of ZERO, and finalize settlement, with no unwind check and no price floor. Every emergency call SHALL still pass the vault's structural batch rules. Net outflow is measured across the whole batch: vault float MAY leave inside the batch only if at least as much returns before the batch ends (a solvent repay the vault fronts and the redeemed collateral returns passes), and asset the strategy returns MAY be passed on; an insolvent unwind needs funds delivered to the strategy from outside the vault. All emergency entrypoints SHALL require the caller to be the vault owner, the proposal to be in `Executed` state, and SHALL share the governor's reentrancy lock.

#### Scenario: Unstick before duration elapses is rejected
- **WHEN** the vault owner calls `unstick` or `emergencySettleWithCalls` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Guardians block owner-supplied emergency calls
- **WHEN** the guardian review of an emergency settle reaches block quorum
- **THEN** `finalizeEmergencySettle` SHALL revert with `EmergencySettleBlocked` and the owner-supplied calls SHALL never execute

#### Scenario: Under-bonded owner cannot propose custom calls
- **WHEN** the vault owner's registry stake is below the required owner bond
- **THEN** `emergencySettleWithCalls` SHALL revert with `OwnerBondInsufficient`

#### Scenario: Emergency batch cannot move vault float
- **WHEN** an unblocked emergency batch on a proposal that deployed nothing calls `asset.transfer(recipient, n)` for any `n > 0`
- **THEN** `finalizeEmergencySettle` SHALL revert `MaxNetOutflowExceeded(n, 0)` and the vault balance SHALL be unchanged

#### Scenario: Vault-fronted repay returned within the batch
- **WHEN** an unblocked emergency batch sends `R` of the asset to the strategy, and the strategy repays its lender and returns at least `R` of the asset to the vault before the batch ends
- **THEN** `finalizeEmergencySettle` SHALL succeed under the zero budget; if the batch returns less than `R` (an insolvent position) it SHALL revert `MaxNetOutflowExceeded`

#### Scenario: Capital returned in the batch may be redirected
- **WHEN** an unblocked emergency batch makes the strategy return `C` of the asset and then transfers `C` to another address
- **THEN** the batch SHALL succeed (net outflow zero), and transferring `C + 1` SHALL revert `MaxNetOutflowExceeded(1, 0)`; the guardian review is the control on this residual

### Requirement: Factory lifecycle-gated administration
The factory SHALL gate structural changes on the governor's lifecycle state. `rotateOwner(vault, newOwner)` SHALL require the caller to be the current vault owner or the vault's creator record (which every rotation overwrites with the new owner), the old owner stake to be fully withdrawn (`VaultStillStaked`), and the incoming owner's prior vault-specific consent to the stake binding (recorded on sWOOD by `newOwner` via `approveOwnerStakeBinding(vault)` — adversary: a current owner of an empty-slot vault must not be able to spend a third party's escrowed prepared stake by rotating the vault onto them); when `newOwner` differs from the current owner it SHALL additionally require both `getActiveProposal() == 0` and `openProposalCount() == 0`. A rotation to the current owner is a re-bond (for example after a blocked emergency round burned the bond) and SHALL be allowed while a proposal is open; it spends only the owner's own prepared stake with the owner's own consent. `rotateOwner` SHALL transfer vault ownership, rebind the owner-stake slot on sWOOD (consuming the consent), and update the creator record. The signature and single-call semantics of `rotateOwner` SHALL be unchanged — consent is enforced at the sWOOD spend site, not by a new factory entrypoint. `upgradeVault(vault, expectedImpl)` SHALL require upgrades enabled, the caller to be the creator, `vaultImpl == expectedImpl` (so a factory-owner impl swap cannot land an implementation the creator did not opt into), and both lifecycle gates. `pushWiring(governor)` SHALL be factory-owner-only, SHALL verify the target is a governor this factory deployed (via the unforgeable `governor.vault()` → `governorOf` round-trip), and SHALL push only the factory's currently-set tier registry / exposure ledger / bond escrow — never writing zero, so wiring can be added but never silently removed. The factory's guardian registry is set once at `initialize`; there is no setter.

The factory SHALL additionally own the batch-executor migration primitives: `setExecutorImpl(newImpl)` SHALL be factory-owner-only, reject the zero address (`InvalidExecutorImpl`), and change which executor library NEW syndicates are wired to at creation (existing vaults are untouched by it). `pushExecutor(vault)` SHALL be factory-owner-only, SHALL verify the vault is one this factory deployed (`VaultNotDeployed`), SHALL require the vault's governor lifecycle quiet (`getActiveProposal() == 0` and `openProposalCount() == 0` — a re-point under a live proposal would swap the meter out from under stored, coverage-priced calls), and SHALL push the factory's current executor into the vault via the vault's factory-only re-point, which updates the executor address AND re-stamps the expected executor codehash atomically. A vault whose executor was not migrated after a library ABI change SHALL fail closed on its next governor batch (unknown selector, no fallback on the library) — strategies unavailable, funds and LP exits unaffected — until `pushExecutor` runs.

#### Scenario: Rotation blocked mid-lifecycle
- **WHEN** `rotateOwner` to an address other than the current owner, or `upgradeVault`, is called while the vault's governor has an executing proposal or any open proposal
- **THEN** the call SHALL revert (`ProposalActive` / `StrategyActive` or `ProposalsOpen`)

#### Scenario: Same-owner re-bond mid-lifecycle
- **WHEN** the vault's bond slot is empty, the current owner has prepared a stake and approved `vault` for binding, and calls `rotateOwner(vault, owner)` while a proposal is open
- **THEN** the call SHALL succeed and the owner-stake slot SHALL hold the prepared stake, so a new emergency round can open

#### Scenario: Rotation without the incoming owner's consent
- **WHEN** `rotateOwner(vault, newOwner)` passes the caller and lifecycle gates but `newOwner` has not approved `vault` for stake binding on sWOOD
- **THEN** the call SHALL revert with `BindingNotApproved`, and no vault ownership, owner-stake, or creator-record state SHALL change

#### Scenario: pushWiring rejects foreign governors
- **WHEN** `pushWiring` targets an address that is not a governor deployed by this factory
- **THEN** the call SHALL revert with `NotFactoryGovernor`
