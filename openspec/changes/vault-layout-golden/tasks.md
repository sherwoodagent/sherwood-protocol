## 1. Forge-level layout pin test

- [ ] 1.1 Add `test/VaultLayoutPins.t.sol` mirroring `test/GuardianRegistryLayoutPins.t.sol` / `test/governor/GovernorLayoutPins.t.sol`: deploy a `SyndicateVault` implementation, wrap it in an `ERC1967Proxy`, call `initialize` with sentinel values, and assert every top-level storage slot/offset via `vm.load`.
- [ ] 1.2 Pin every declared variable in `src/SyndicateVault.sol`'s storage section (`_agents` through `__gap`, currently lines ~109-238) at its actual compiler-assigned slot — read the real layout with `forge inspect SyndicateVault storageLayout` rather than hand-computing slots, since packed fields (`minBufferBps`/`minHoldingPeriod`/`instantExitFeeBps` share a slot; `_mgmtBase`/`_mgmtLastUpdate` share a slot; `_crystallizedMgmt`/`_crystallizedPerf` share a slot) must match the compiler's actual packing, not an assumed one.
- [ ] 1.3 Pin `_agents` (mapping) and `_agentSet` (EnumerableSet) at their base slots using the same derived-slot technique `GuardianRegistryLayoutPinsTest` uses for `vaultOf` (`keccak256(abi.encode(key, baseSlot))`), wiring a real agent via `registerAgent` so the assertion is positive, not a zero-check.
- [ ] 1.4 Pin `_laneALockPid` (mapping) the same way: write it via a reachable path (or `vm.store`, see 1.6) and assert `keccak256(abi.encode(holder, baseSlot))` holds the written pid.
- [ ] 1.5 Pin `_approvedDepositors` (EnumerableSet) via `approveDepositor`, and the scalar fields (`_executorImpl`, `_openDeposits`, `_agentRegistry`, `_managementFeeBps`, `_factory`, `_expectedExecutorCodehash`, `_cachedDecimalsOffset`, `_withdrawalQueue`, `_agentFeeBpsPlusOne`, packed `minBufferBps`/`minHoldingPeriod`/`instantExitFeeBps`, `_interimNetFlow`, `lastDepositAt` mapping, `_mgmtAssetSeconds`, packed `_mgmtBase`/`_mgmtLastUpdate`, `_highWaterPricePerShare`, packed `_crystallizedMgmt`/`_crystallizedPerf`) each at their frozen slot/offset, positively (via init values or a setter) wherever a zero-check alone would not distinguish "correct slot, unset" from "wrong slot".
- [ ] 1.6 For fields with no direct owner/factory setter reachable from a minimal fixture (`_laneALockPid`, `lastDepositAt`, `_interimNetFlow`, `_mgmtAssetSeconds`, `_mgmtBase`/`_mgmtLastUpdate`, `_highWaterPricePerShare`, `_crystallizedMgmt`/`_crystallizedPerf`), use `vm.store` to write a sentinel directly at the slot the compiler layout says it occupies, then confirm via the field's own getter (where one exists) that the write lands where the contract itself reads from — this proves the assumed slot is the one the contract actually uses, not just the one this test wrote to.
- [ ] 1.7 Assert `__gap` starts at the correct slot (immediately after `_crystallizedPerf`) and that its first word is unwritten in a fresh proxy.
- [ ] 1.8 Add a test-file header natspec block, in the style of the two existing layout-pin files, stating why the guard exists, that new fields are APPEND-ONLY carved from the front of `__gap`, and the FUTURE convention for a removed field (same-slot placeholder, e.g. `uint256[1] private __deprecated_x;`, or fold into `__gap` — never delete outright, since deleting a slot corrupts every field below it on the next upgrade).

## 2. Golden-JSON CI gate

- [ ] 2.1 Add `check_contract SyndicateVault script/syndicate-vault-layout.golden.json` to `script/check-layout-goldens.sh`, alongside the existing four `check_contract` calls, with a short comment (matching the existing per-contract comments) noting this is the vault — the one UUPS proxy holding user assets — and that it is a fresh deployment (no live mainnet lineage per `chains/4663.json`), so this is the layout's initial baseline, not a re-baseline.
- [ ] 2.2 Update the script's header comment (`# check-layout-goldens.sh — ...`) and the final `echo "layout-goldens: OK — ..."` line to list `SyndicateVault` alongside the other four contracts.
- [ ] 2.3 Generate the golden: `./script/check-layout-goldens.sh --update-golden`, confirm `script/syndicate-vault-layout.golden.json` is produced and non-empty (has a populated `storage` array), and commit it.

## 3. Verify

- [ ] 3.1 Acquire the shared build lock (`/tmp/sherwood-forge.lock`, mkdir+pid+trap) before every `forge` invocation, per repo convention.
- [ ] 3.2 `forge build` clean.
- [ ] 3.3 `forge test` — full suite green (the pre-existing `test_cancelUnstakeGuardian_afterSlash_revertsNoActiveStake` skip is unrelated and expected).
- [ ] 3.4 `forge fmt` (apply, not just `--check`) with a CI-matching forge; re-run `forge build`/`forge test` if formatting touched anything.
- [ ] 3.5 `./script/check-layout-goldens.sh` (no `--update-golden`) passes for all five contracts including the new `SyndicateVault` entry.
- [ ] 3.6 `openspec validate vault-layout-golden --strict` passes (pre-existing unrelated failures on `ci-fork-and-coverage` / `wood-price-twap-ceiling` are known and out of scope).
- [ ] 3.7 Confirm zero `src/` changes: `git diff origin/main --stat` touches only `test/`, `script/`, and `openspec/`.
