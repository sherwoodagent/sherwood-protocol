# Pin SyndicateVault's storage layout (golden + forge-test pins) (issue #148)

## Why

`SyndicateVault` is a UUPS proxy (`_authorizeUpgrade` is factory-gated,
`src/SyndicateVault.sol:1817-1819`) and the one contract in the protocol that
custodies LP assets — yet nothing in CI or the test suite pins its storage
layout:

- `script/check-layout-goldens.sh` gates exactly four contracts
  (`SyndicateGovernor`, `SyndicateFactory`, `GuardianRegistry`, `StakedWood`);
  the vault is not among them.
- The only forge-level layout-pin tests are
  `test/GuardianRegistryLayoutPins.t.sol` and
  `test/governor/GovernorLayoutPins.t.sol`. There is no vault equivalent.

A field reorder, insertion, or deletion anywhere in the vault's storage block
(`src/SyndicateVault.sol:106-238`) would compile, pass CI, and pass the full
test suite today with no automated signal. That is exactly the class of change
that turns an ordinary refactor into a storage collision — and fund loss — on
the first upgraded live proxy. The gap surfaced while scoping the Lane A
retirement (#54): deleting `_laneALockPid`, a mid-layout mapping, would have
silently shifted every subsequent field down one slot.

No vault proxy is live yet (owner-confirmed, recorded in `retire-lane-a`'s
design "Deployment reality"), which is why this pin must land NOW: today the
baseline is free to establish; from the first mainnet deploy onward the layout
becomes append-only-forever, the same way `StakedWood`'s already is.

## What Changes

- **New golden**: `script/syndicate-vault-layout.golden.json`, generated once
  during implementation by the existing checker's own `--update-golden` mode
  (which runs `forge build` + `forge inspect SyndicateVault storageLayout
  --json` and canonicalizes). No new schema — the exact format
  `canonical_layout` already emits for the other four contracts.
- **Wire the vault into `script/check-layout-goldens.sh`**: one new
  `check_contract SyndicateVault script/syndicate-vault-layout.golden.json`
  line, matching the existing calling convention, plus header/echo updates so
  the script's self-description stays truthful.
- **New pin test**: `test/VaultLayoutPins.t.sol`, transcribing the structure,
  naming, and assertion style of the two existing pin-test files (raw
  `vm.load` slot pins against sentinels; positive pins, never zero-checks for
  moved-field detection; gap-start check with the field above wired).
- **No `src/` changes.** Purely additive test + CI-script change. CI cost is
  one more `forge inspect` inside a step that already exists
  (`.github/workflows/ci.yml:166`) — no new machinery.

Sequencing: this change SHOULD land BEFORE the Lane A retirement (#54,
`retire-lane-a`, branch `chore/retire-lane-a`), which deletes four vault
storage fields and regrows `__gap`. See design.md "Sequencing vs.
retire-lane-a" for the recommendation and the fallback if #54 lands first.

## Impact

- Affected specs: `syndicate-vault` (one ADDED requirement).
- Affected code: `script/check-layout-goldens.sh` (one call + comments),
  `script/syndicate-vault-layout.golden.json` (new, generated),
  `test/VaultLayoutPins.t.sol` (new). Nothing in `src/`.
- Affected in-flight work: `retire-lane-a` (#54) will trip this gate by
  design when it deletes vault fields — that is the gate working, and the
  regeneration ceremony is already documented in the checker's header.
- Independent of #35 and #45; touches nothing in their scope.
