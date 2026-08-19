## ADDED Requirements

### Requirement: Governor-gated sandbox minting and funding
The vault SHALL expose a governor-only entry point that mints a per-proposal sandbox from an implementation address fixed at vault deployment, transfers the proposal's declared funding to it, and dispatches its stored calls. The entry point SHALL be `nonReentrant`, SHALL be blocked while the vault is paused, and SHALL meter the funding transfer against the proposal's effective capital exactly as a batch outflow is metered.

The adversary is a second caller: this function moves vault assets to a freshly created contract without passing the batch callee gate, so its authorization must be the governor and nothing else — the same posture `settleRedeem` / `settleDeposit` take toward the queue.

The sandbox implementation SHALL be bound factory-only and set-once, with no re-pointing path of any kind, mirroring `setWithdrawalQueue`. The adversary is an owner who re-points the code the vault mints after guardians have reviewed proposals on the strength of what it does — so the binding must be unrepeatable rather than merely owner-gated. Replacing it is a redeployment, not a configuration change.

#### Scenario: Only the governor may mint and fund a sandbox
- **WHEN** any address other than the governor calls the sandbox entry point
- **THEN** the call SHALL revert

#### Scenario: Funding is metered like any outflow
- **WHEN** a sandbox is funded during proposal execution
- **THEN** the transferred amount SHALL count against the proposal's effective capital, and exceeding it SHALL revert the execution

#### Scenario: Paused vault mints no sandbox
- **WHEN** the vault is paused
- **THEN** the sandbox entry point SHALL revert, matching the freeze `executeGovernorBatch` is subject to

#### Scenario: The sandbox implementation cannot be re-pointed
- **WHEN** any caller, including the owner or the factory, attempts to change the sandbox implementation after it has been bound
- **THEN** the call SHALL revert — the binding is set-once and no re-pointing path exists

#### Scenario: Only the factory may bind it
- **WHEN** any address other than the factory calls the binding function
- **THEN** the call SHALL revert `NotFactory`

### Requirement: Sandboxes participate in the residue machinery
The vault SHALL record each proposal's sandbox so the existing residue path reaches it: the sandbox SHALL be readable by `collectResidue`, SHALL contribute its undelivered value to the deposit-pricing figure, and SHALL hold the deposit gate shut while it reports unvalued residue.

The adversary is a sandbox left holding value after settlement: without this the vault would price deposits against float alone while a sandbox still held assets, which is finding #3's shape reintroduced through a new path. Routing sandboxes through the same machinery means the deposit gate, the residue bound and the permissionless collection all apply without a parallel implementation.

#### Scenario: A funded sandbox is recorded at settlement
- **WHEN** a proposal with a sandbox settles
- **THEN** the vault SHALL record the sandbox against that proposal so a later arrival can be routed and collected

#### Scenario: Residue collection reaches a sandbox directly
- **WHEN** `collectResidue` is called against a recorded sandbox
- **THEN** it SHALL sweep by a direct call, requiring no governor batch, no allowlist entry and no owner action

#### Scenario: Unvalued sandbox residue holds the deposit gate
- **WHEN** a recorded sandbox reports unvalued residue
- **THEN** the vault SHALL refuse deposits until the residue is cleared
