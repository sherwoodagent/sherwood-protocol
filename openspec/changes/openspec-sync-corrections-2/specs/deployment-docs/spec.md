## MODIFIED Requirements

### Requirement: Fork funding via Tenderly cheats only
Three cheats are available: `tenderly_setBalance` (native), `tenderly_setErc20Balance`, and `tenderly_setStorageAt` (any slot). Time travel uses `evm_increaseTime` + `evm_mine`, and `evm_snapshot` / `evm_revert` are available for baseline resets.

**`tenderly_setErc20Balance` IS available and is the preferred ERC-20 path.** Verified 2026-08-20 against both WOOD (a plain OZ ERC20) and USDG (a proxy) — the balance lands and `balanceOf` reads it back. An earlier measurement on an older vnet said the method did not exist; that claim did not survive re-measurement and SHALL NOT be restored without one. It matters beyond convenience: `cli/src/e2e` funds every scenario through that method, so "unavailable" implied the e2e harness could never run against the fork.

The direct-storage route remains the DOCUMENTED FALLBACK for a vnet or token where the cheat does not work: write the `_balances` mapping slot as `keccak256(abi.encode(holder, balancesSlot))`, with WOOD at slot 0 and USDG at slot 1 (slot 0 holds other proxy state). `cast rpc` params SHALL be passed as separate positional args, not one JSON array (the array form returns `-32602`). For an unlisted token, the balances slot SHALL be discovered by brute-forcing slots 0..40 (write a sentinel to `keccak(holder, S)`, read `balanceOf`), falling back to the OZ v5 ERC-7201 namespaced location.

#### Scenario: Funding an ERC-20 to a wallet
- **WHEN** the operator calls `tenderly_setErc20Balance` with the token, holder and amount over the admin RPC
- **THEN** `balanceOf(wallet)` returns the written amount, for both plain and proxied tokens

#### Scenario: Funding WOOD by direct storage write
- **GIVEN** a vnet or token where the ERC-20 cheat does not take
- **WHEN** the operator computes `KEY=$(cast index address <wallet> 0)` and writes it on the WOOD token via `tenderly_setStorageAt`
- **THEN** `balanceOf(wallet)` returns the written amount

#### Scenario: Array-form RPC params rejected
- **WHEN** `cast rpc tenderly_setStorageAt '["<tok>","<slot>","<val>"]'` is issued
- **THEN** the RPC returns `-32602`; the positional form succeeds

### Requirement: DeployPlanB asserts delegation is off
`DeployPlanB`'s post-broadcast pre-flights SHALL fail the run if the sWOOD answers `delegationEnabled()` with a non-zero word, naming the delegator-walkout hole. The probe is a staticcall: the current `StakedWood` has no delegation and no such selector, so the probe reads false and passes; it exists to refuse a future sWOOD that turns delegation on.

#### Scenario: Delegation accidentally on
- **GIVEN** `delegationEnabled` reads true on the target chain
- **WHEN** the post-broadcast pre-flights run
- **THEN** the run FAILS with a message naming the delegator-walkout hole

#### Scenario: Preflight tests cover both invariants
- **THEN** `test/deploy/DeployPlanBPreflight.t.sol` covers: the duration ceiling seated; delegation-on fails the named assert and delegation-off passes; a code-less feed refused; a zero `maxDelay` refused; a foreign `StakedWood.exposureLedger` slot refused (the `GuardianRegistry` slot is covered in `test/deploy/DeployAll.t.sol`); and the two post-broadcast price checks (unset cap, cap with nothing priced beneath it)
