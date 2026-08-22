# Tasks — pin-vault-storage-layout

NOTE FOR THE IMPLEMENTER: purely additive — no `src/` file changes. Every
forge invocation: foreground only, generous timeout, serialized behind the
shared build lock (`while pgrep -x forge >/dev/null; do sleep 30; done`, or a
PID-carrying mkdir lock) — concurrent `via_ir` builds OOM-kill each other on
this machine. Line references are against `main` @ `8d9896c`.

## 1. Pre-flight

- [ ] 1.1 Sequencing check: confirm `retire-lane-a` (#54) has NOT merged
      (`git log origin/main --oneline | grep -i "retire-lane-a"` empty, and
      `src/SyndicateVault.sol:154` still declares `_laneALockPid`). If it HAS
      merged: the design.md layout table is stale — re-enumerate the storage
      block from the merged `src/SyndicateVault.sol` (the deletions are
      `_laneALockPid`, `_interimNetFlow`, `_crystallizedMgmt`,
      `_crystallizedPerf`, `instantExitFeeBps` et al., `__gap` regrown) and
      adjust the pin test's slots before proceeding. The golden generation
      command is unchanged either way.

## 2. Wire the checker

- [ ] 2.1 `script/check-layout-goldens.sh`: add the `check_contract
      SyndicateVault script/syndicate-vault-layout.golden.json` line after
      the StakedWood call (line 229) with the comment block from design.md
      "Wiring" item 2; update the header parenthetical (lines 2-3) to name
      all five contracts; extend the final OK echo (line 232) with
      SyndicateVault.

## 3. Generate the golden

- [ ] 3.1 Under the build lock: `./script/check-layout-goldens.sh
      --update-golden`. Verify `git status` shows exactly one NEW file
      (`script/syndicate-vault-layout.golden.json`) and zero modifications
      to the five existing goldens; if any existing golden changed, STOP —
      the tree has drifted from `main`.
- [ ] 3.2 Verify the generated golden against design.md's layout table row
      by row (25 storage entries, slots 0-47, `__gap` as
      `t_array(t_uint256)28_storage` at slot 20; `types` carries
      AgentConfig + AddressSet + Set, with AddressSet/Set byte-identical to
      the entries in `script/guardian-registry-layout.golden.json`). Any
      disagreement with the table: stop and reconcile per design.md before
      committing.
- [ ] 3.3 Run `./script/check-layout-goldens.sh` plain — exits 0, OK line
      names SyndicateVault.

## 4. Pin test

- [ ] 4.1 Create `test/VaultLayoutPins.t.sol` per design.md's test section:
      GuardianRegistryLayoutPins structure/naming, ERC1967Proxy fixture with
      the test as factory, file-level natspec with the condensed layout map,
      the append-only rule, and the explicit golden-only field list (slots
      11, 15, 16, 17).
- [ ] 4.2 Tests: init-written prefix (slots 3, 6, 7, 8, 9, 10); slot-10
      packing via `setWithdrawalQueue`; slot 12 via `setAgentFeeBps`
      (assert stored value is fee+1); slot-13 full packed word via
      `setMinBufferBps` + `setInstantExitFeeBps`; reverse pins (`vm.store` +
      getter) for slots 14 (`interimNetFlow`), 18
      (`highWaterPricePerShare`), 19 composite
      (`crystallizedMgmt`/`crystallizedPerf`); set-length pins for slots 1
      and 4 plus the `_agents` derived-slot read at
      `keccak256(abi.encode(agent, uint256(0)))`; gap start
      (`_slot(20) == 0` with slot 19 wired).
- [ ] 4.3 Under the build lock: `forge test --match-contract
      VaultLayoutPinsTest -vv` — all green. Then `forge fmt` on the new file
      with a forge version matching CI.

## 5. Finish

- [ ] 5.1 `openspec validate --strict pin-vault-storage-layout` passes.
- [ ] 5.2 Commit script + golden + test together (reference #148). Target
      the PR at `main` (stacked PRs get no CI in this repo).
