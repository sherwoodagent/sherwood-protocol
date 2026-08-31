# Tasks

## 0. Kill-risk spike first (cheapest possible death)

- [ ] 0.1 Fork test (pinned block, mainnet 4663): swap through the Bankr
      AI/NVDA pool (`PoolManager.unlock` + `swap`) from a CONTRACT caller.
      If the hook blocks or skims contract flow, STOP and re-plan route A
      through the Universal Router before any other task.
- [ ] 0.2 In the same fork test, read `extsload` slot0 and assert the price
      matches the pool's swap execution price within the fee — pins the
      storage-slot derivation against a live venue, not a unit fixture.

## 1. Template

- [ ] 1.1 `src/strategies/BasisArbStrategy.sol` extending `BaseStrategy`:
      `Leg`/route storage, `_initialize` with endpoint-chain validation
      (spec: fail at init), `_execute` = custody only.
- [ ] 1.2 Price reads: v3 `slot0()`, v4 `extsload(keccak256(poolId .
      uint256(6)))`; live lpFee decode (bits 208–231, pips).
- [ ] 1.3 `pokeArb(dir, minOut)`: recompute basis, live-fee-sum + margin
      guard, `minProfitBps` enforcement, atomic route execution, flat-at-end
      assertion. Follow `rerange()`'s permissionless-poke conventions.
- [ ] 1.4 `_settle` push-all + `sweep()` vault-only residue path, matching
      the template conventions (`MorphoSupplyStrategy.sweep` as the model).
- [ ] 1.5 Factory allowlist entry + deploy-script wiring.

## 2. Tests (each guard mutation-verified — drop it, a test must fail)

- [ ] 2.1 Unit: endpoint-chain validation reverts on every mis-wiring
      (wrong asset, broken middle link, token/pool mismatch).
- [ ] 2.2 Unit: basis math against fixed sqrtPriceX96 fixtures including
      the live-validated bankr word; decimals asymmetry (USDG 6dp) pinned.
- [ ] 2.3 Unit: thin basis reverts; dynamic-fee hike reverts; hostile
      `minOut` cannot force a loss; flat-at-end holds after success.
- [ ] 2.4 Fork: one full profitable poke round-trip on the real four pools
      (manufacture the basis by trading the fork first); settle delivers.
- [ ] 2.5 Lifecycle harness run (pid-22 style) with this template.

## 3. Guardian side (sherwood-guardian repo, after 0–2 merge)

- [ ] 3.1 Chain book: v4 PoolManager + Universal Router as known targets.
- [ ] 3.2 Fleet dry-run on the vnet: propose a clone, confirm the risk
      rules produce no unknown-counterparty critical.

## 4. Deployment gate (blocks proposing, not merging)

- [ ] 4.1 ≥7 days of `samples2.csv`; compute the |basis| distribution.
- [ ] 4.2 Go/no-go per proposal.md's ship-gate (≥0.5% of samples beyond
      fee floor + 30bps). No-go → template stays shelved for the next pair.
