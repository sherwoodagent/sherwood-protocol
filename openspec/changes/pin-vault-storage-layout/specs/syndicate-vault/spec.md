# syndicate-vault (delta)

<!-- Change: pin-vault-storage-layout (issue #148). Adds one requirement:
     the vault's storage layout is pinned by a CI-enforced golden and a
     forge-test pin file. No behavioral requirement is modified. -->

## ADDED Requirements

### Requirement: Storage layout is pinned and CI-enforced

The vault's linear storage layout SHALL be pinned at two independent layers,
mirroring the protocol's existing golden-layout guard for the other
proxy-upgraded contracts:

1. A committed golden snapshot (`script/syndicate-vault-layout.golden.json`)
   in the canonical format emitted by `script/check-layout-goldens.sh` —
   every top-level state variable's label, slot, offset, and normalized type
   in declaration order (AST ids stripped, array lengths preserved), plus the
   internal member layout of every struct transitively reachable from
   storage. `check-layout-goldens.sh` SHALL compare the compiler-emitted
   layout of `SyndicateVault` against this golden via the same
   `check_contract` convention as the other pinned contracts, and CI SHALL
   run it (the existing "Layout goldens" step).
2. A raw-slot pin test (`test/VaultLayoutPins.t.sol`) following the structure
   and assertion style of the existing layout-pin tests: sentinel values
   written through real entry points (or, for fields writable only deep in
   the proposal lifecycle, `vm.store` reverse-pinned through their public
   getters) and asserted at frozen slot indices with `vm.load`, so a
   reorder/insert/retype fails under plain `forge test` even when the shell
   script is not run.

The pinned baseline is the layout at the time this change lands. Because the
vault is a UUPS proxy whose upgrades are factory-gated, once any vault proxy
is live the layout SHALL evolve append-only: new fields are carved from the
FRONT of `__gap` (shrinking it), pins are added but never edited, and the
golden is regenerated with `./script/check-layout-goldens.sh --update-golden`
in the same PR as the storage change. Before any vault proxy is live, a
deliberate layout break MAY re-baseline the golden and the pin test in the
same PR — the diff makes the break reviewed and conscious, which is the
gate's purpose.

#### Scenario: Layout drift fails CI

- **WHEN** a change reorders, inserts, deletes, or retypes any
  `SyndicateVault` state variable, or resizes `__gap` without a matching
  field change, without regenerating the golden
- **THEN** `script/check-layout-goldens.sh` exits non-zero and the CI layout
  step fails

#### Scenario: Slot move fails under plain forge test

- **WHEN** a `SyndicateVault` state variable moves to a different slot or
  intra-slot offset and the test suite runs without the shell script
- **THEN** at least one assertion in `test/VaultLayoutPins.t.sol` fails

#### Scenario: Append-only evolution passes

- **WHEN** a new field is appended by carving it from the front of `__gap`
  (gap length decremented accordingly), the golden is regenerated in the same
  PR, and a pin for the new field is added without editing existing pins
- **THEN** both the golden check and the pin test pass

#### Scenario: Empty or misresolved layout is refused

- **WHEN** the checker's `forge inspect` read for `SyndicateVault` resolves
  to an empty storage layout (e.g. the contract is renamed and the name now
  matches an interface or library)
- **THEN** `script/check-layout-goldens.sh` hard-fails rather than comparing
  or baking a layout that pins nothing
