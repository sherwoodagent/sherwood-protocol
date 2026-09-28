# Tasks

## 1. sWOOD — the predicate and the way back

- [x] 1.1 `StakedWood.ownerBondLive(address)` returning `owner != address(0) && unstakeRequestedAt == 0` (design D1).
- [x] 1.2 `StakedWood.cancelUnstakeOwner(address)` clearing `unstakeRequestedAt` and `cooldownAtRequest`, with `OwnerUnstakeCancelled` (design D2).
- [x] 1.3 Declare both on `IStakedWood`; patch every test stand-in that implements the interface.

## 2. Registry passthrough

- [x] 2.1 `GuardianRegistry.ownerBondLive(address)` forwarding to sWOOD, declared on `IGuardianRegistry` (design D4).
- [x] 2.2 `MockRegistryMinimal` gains the selector with a `true` default, pinned both ways.

## 3. Governor — both legs

- [x] 3.1 `_propose` refuses with `OwnerBondNotLive` when the predicate is false.
- [x] 3.2 `executeProposal` re-asserts the same gate before the opening batch (design D3).
- [x] 3.3 `OwnerBondNotLive` on `ISyndicateGovernor`.

## 4. Tests

- [x] 4.1 `test/audit-fixes/StakedWood_she215OwnerBondLive.t.sol` — both clauses, the zero-bond onboarding vault, the registry passthrough asserted across a state change, and the four `cancelUnstakeOwner` cases including the slashed slot.
- [x] 4.2 `test/audit-fixes/Governor_she215OwnerBondGate.t.sol` — propose and execute legs, their controls, and recovery in window.
- [x] 4.3 Fizz: a top-level handler that restores a live owner bond after a slash, so the propose→settle lifecycle stays reachable for the rest of a run.

## 5. Validation

- [x] 5.1 `forge fmt --check src test script`, `forge build`, `forge test --no-match-path "test/integration/**"`, `script/check-layout-goldens.sh`.
- [x] 5.2 `openspec validate --all --strict`.
- [x] 5.3 Record the sWOOD → registry → beacon upgrade ordering as a ceremony note on SHE-36.
