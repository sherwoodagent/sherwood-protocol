# Tasks — rotate-owner-consent

## 1. StakedWood consent surface

- [x] 1.1 Add `mapping(address owner => address vault) public approvedBindVault` to `src/StakedWood.sol` (append after existing owner-bond state; no reordering — UUPS layout), plus error `BindingNotApproved()` and events `OwnerStakeBindingApproved(address indexed owner, address indexed vault)` / `OwnerStakeBindingRevoked(address indexed owner, address indexed vault)`.
- [x] 1.2 Implement `approveOwnerStakeBinding(address vault)` (reject `address(0)`, overwrite-on-approve, emit) and `revokeOwnerStakeBinding()` (delete, emit with the vault being cleared). Natspec states the adversary per house style (empty-slot vault owner spending a third party's escrow).
- [x] 1.3 In `transferOwnerStakeSlot` (src/StakedWood.sol:1032), after the existing prepared-stake guards, revert `BindingNotApproved` unless `approvedBindVault[newOwner] == vault`; `delete approvedBindVault[newOwner]` on the successful path (before the event, no external calls — CEI preserved).
- [x] 1.4 Clear stale consent across the escrow lifecycle: `delete approvedBindVault[msg.sender]` in `cancelPreparedStake` and in `prepareOwnerStake` (Decision 3 replay hazard). Add a natspec line to `bindOwnerStake` stating why the creation-time bind needs no approval (structural consent).
- [x] 1.5 Declare `approveOwnerStakeBinding`, `revokeOwnerStakeBinding`, and the `approvedBindVault` view in `src/interfaces/IStakedWood.sol`; mirror in `test/mocks/MockStakedWood.sol` if the mock implements the interface's owner-bond surface.

## 2. Factory documentation (no code change)

- [x] 2.1 Update `SyndicateFactory.rotateOwner` natspec (src/SyndicateFactory.sol:698-713) to document the new precondition: `newOwner` must have called `approveOwnerStakeBinding(vault)` on sWOOD, else the rotation reverts `BindingNotApproved`; note the two-transaction UX and that the consent revert atomically unwinds `rotateOwnership`.

## 3. Tests

- [x] 3.1 Negative test reproducing issue #98's exact 4-step trace: (1) Alice `prepareOwnerStake(50_000e18)`, assert `canCreateVault(alice)`; (2) Mallory holds a vault V with `ownerStake(V) == 0` and no open proposals; (3) Mallory calls `rotateOwner(V, alice)` — expect revert `BindingNotApproved`; (4) assert post-state unchanged: `ownerStake(V) == 0`, V's owner still Mallory, Alice's prepared stake unbound, `cancelPreparedStake()` succeeds and refunds. Place in `test/audit-fixes/` per repo convention (arm `vm.expectRevert` immediately before the call; hoist any argument-position reads — repo prank-consumption gotcha).
- [x] 3.2 Positive test: Alice approves V, rotation succeeds, `_ownerStakes[V]` names Alice with her amount, `approvedBindVault[alice]` cleared, `OwnerStakeSlotTransferred` emitted; a second rotation attempt naming Alice reverts.
- [x] 3.3 Approval-lifecycle tests: vault-specific mismatch (approved A, rotate B → `BindingNotApproved`); revoke-then-rotate reverts; approval cleared by `cancelPreparedStake`; approval cleared by fresh `prepareOwnerStake` (stale-consent replay from Decision 3 must fail); approve rejects `address(0)`; approval without a prepared stake is inert (transfer still reverts on the prepared-stake guards).
- [x] 3.4 Update existing rotation happy paths to add the consent step (`vm.prank(newOwner); swood.approveOwnerStakeBinding(vault);` — use `startPrank` or hoist args): `test/factory/OwnerStakeAtCreation.t.sol` (rotateOwner section, ~lines 191-252) and `test/audit-fixes/SyndicateFactory_rotateOwner_proposalGuard.t.sol` (~lines 168-260). Guard-order note: tests that expect `ProposalActive`/`ProposalsOpen`/`VaultStillStaked` fire before the sWOOD call, so they need no approval — verify rather than blanket-add.

## 4. Verification

- [x] 4.1 Run the full suite in the foreground (`forge test`), serialized against concurrent solc (`while pgrep -x solc >/dev/null; do sleep 30; done` first); triage failures with `sort | uniq -c`, not `sort -u`.
- [x] 4.2 `forge fmt` with a CI-matching forge, then `openspec validate --change rotate-owner-consent --strict`.
