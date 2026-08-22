## 1. Vendor the Uniswap surface

- [x] 1.1 Resolve the Uniswap V3 position-manager and factory addresses on Robinhood Chain (4663) and confirm each holds code via `cast code`; record them in `addresses/` alongside the existing entries
      - Resolved: factory `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`, position manager `0x73991a25c818bf1f1128deaab1492d45638de0d3`; recorded in `addresses/4663.json`.
      - **Code presence is not sufficient on this chain.** The canonical mainnet addresses (`0xC36442b4…`, `0x1F98431c…`) each hold ~2110 bytes of an unrelated contract and answer no Uniswap selector, so `code.length != 0` passes on the wrong address. Identity was proven instead: `symbol() == "UNI-V3-POS"`, `factory()` agreeing with a live pool's own `factory()`. Task 8.1 is amended accordingly.
- [x] 1.2 Add `src/vendor/uniswap/INonfungiblePositionManager.sol` and `src/vendor/uniswap/IUniswapV3Pool.sol` with only the functions used (mint, increaseLiquidity, decreaseLiquidity, collect, burn, positions; slot0, observe, tickSpacing, liquidity, token0/token1, fee)
      - Added `factory()` to both (identity assertion, see 1.1) and `increaseObservationCardinalityNext` to the pool (fork-test remediation). `increaseLiquidity` was NOT vendored: the strategy mints once and reranges by burn/re-mint, so nothing calls it — vendoring it would widen the surface for no caller.
- [x] 1.3 ~~Register the vendored files in `lib/VENDOR-MANIFEST.json` following the `src/vendor/morpho/` entries~~ — **premise corrected, not done as written.**
      - There are no `src/vendor/morpho/` entries in that manifest. It declares exactly three `local_path`s, all under `lib/` (`forge-std`, `openzeppelin-contracts`, `openzeppelin-contracts-upgradeable`), and `script/check-vendor-provenance.sh` (run by `.github/workflows/provenance.yml`) fetches each pinned upstream and `diff -r`s it against the vendored tree.
      - Registering `src/vendor/uniswap/` there would fail CI: the files are reduced-surface, pragma-changed, and live at paths upstream does not have, which the script reports as `upstream has no such path at the pinned ref` plus a non-empty diff. `local_modifications` cannot express this — it pins a sha256 per file that must still exist upstream.
      - Followed the actual `src/vendor/morpho/` convention instead: an in-file provenance natspec header naming upstream repo, path, licence, what was reduced, and how the pragma change is behaviour-preserving. Done in 1.2.
- [x] 1.4 Confirm `forge build` succeeds with no pragma conflicts
      - `forge build` exit 0; artifacts emitted for both interfaces; no diagnostic references `vendor/uniswap`. (Remaining warnings are pre-existing lints in `SyndicateVault.sol`.)

## 2. Template skeleton and initialization

- [x] 2.1 Create `src/strategies/ConcentratedLiquidityStrategy.sol` extending `BaseStrategy`, with `name()` returning "Concentrated Liquidity LP" and per-clone storage for pool, position manager, Morpho market params, tick range, borrow amount, collateral amount, and tunables
- [x] 2.2 Declare errors, one per init check, each with natspec naming its adversary per the repo's house style
- [x] 2.3 Implement `_initialize` decode and checks 1–6 in the spec's stated order (pool exists and quotes vault asset; market exists and lends vault asset; borrow ≤ lendable liquidity; LTV ≤ LLTV − buffer; notional ≤ pool-share cap; tick range ordered, non-empty, spacing-aligned)
- [x] 2.4 Decide pool-share cap and LLTV buffer as constants vs `ProtocolConfig` reads (design Open Question 2) and implement the chosen form
- [x] 2.5 Grep `test/` for existing vault/governor/Morpho stand-ins and add every new selector this contract calls to them **in this same commit** — a typed call against a mock lacking the selector reverts undecodably in the caller's frame

## 3. Execute path

- [x] 3.1 Implement the spot-vs-TWAP guard as a raw `staticcall` to `observe` with an explicit `ret.length` check and `abi.decode`, reverting on any failure (fail-closed, design Decision 5)
- [x] 3.2 Implement `_execute`: pull vault asset, supply collateral to Morpho, borrow the vault asset, mint one position over the fixed tick range, and store the returned token id
- [x] 3.3 Assert post-execute invariants in-contract where cheap: exactly one position held, borrow amount matches the configured amount
- [x] 3.4 Emit an execute event carrying pool, token id, tick range, liquidity, borrowed, and collateral

## 4. Rerange

- [x] 4.1 Store the rerange policy at init (half-width ticks, trigger fraction, min interval, max count, slippage floor) and validate it: half-width ≥ one tick spacing, trigger fraction in (0, 1], max count bounded
- [x] 4.2 Implement the deterministic new-range derivation — approved half-width centered on the current TWAP tick, snapped to tick spacing — as a `public view` so callers can simulate the exact result before sending
- [x] 4.3 Implement permissionless `rerange()` with all five admissibility conditions (Executed; trigger reached; interval elapsed; count below max; spot within the TWAP bound), each with its own error
- [x] 4.4 Implement the rerange body: burn position, collect fees, re-mint over the new range subject to the slippage floor, increment the count; assert borrow and collateral are untouched
- [x] 4.5 Emit a rerange event carrying old range, new range, TWAP tick, rerange index, and liquidity before/after

## 5. Settle and sweep

- [x] 5.1 Implement `_settle` in the required order: decrease liquidity to zero → collect fees → repay borrow → withdraw collateral → push entire vault-asset balance to the vault
- [x] 5.2 Convert non-vault-asset proceeds subject to the tunable slippage floor, reusing the existing `UniswapSwapAdapter` route rather than a new swap path
- [x] 5.3 Implement deliverable-maximum behavior for the repay and withdraw legs, emitting `SettlementIncomplete` with remaining debt and collateral instead of reverting
- [x] 5.4 Implement permissionless post-settlement `sweep()` gated on `State.Settled`, idempotent and safe to call with nothing to move
- [x] 5.5 Implement `_updateParams` accepting only slippage floors and settlement deadline, rejecting range and every rerange-policy field, and reverting outside `State.Executed`

## 6. Unit tests

- [x] 6.1 Lifecycle: execute-from-foreign-proposal reverts; double execute reverts; settle-before-execute reverts; at most one position held across a rerange
- [x] 6.2 Init validation: one test per check in 2.3, each asserting the specific error, plus the rerange-policy validations from 4.1
- [x] 6.3 TWAP guard: spot outside bound reverts; insufficient observation cardinality reverts
- [x] 6.4 Tunables: proposer may retune slippage; range, pool, and every rerange-policy field revert; non-proposer updates revert
- [x] 6.5 Rerange admissibility: one test per condition (not Executed; before trigger; inside min interval; at max count; spot outside TWAP bound), each asserting its own error
- [x] 6.6 Rerange determinism: two different callers in identical state produce the identical range; the `view` derivation from 4.2 matches what `rerange()` actually mints
- [x] 6.7 Rerange invariants: borrow and collateral unchanged; count increments; position replaced not added; at the cap the position stays settleable
- [x] 6.8 Rerange griefing bound: `maxReranges` consecutive reranges cost no more than `maxReranges × (swap cost + slippage floor)` — pin the worst case as a test
- [x] 6.9 Full settlement: zero liquidity, zero debt, zero collateral, vault receives full proceeds — both without a rerange and after one
- [x] 6.10 Partial settlement: each partial-failure combination (repay short, withdraw short, both) emits the event and does not revert
- [x] 6.11 Sweep: recovers residue after conditions improve; idempotent; reverts before settlement
- [x] 6.12 Fee accrual in the non-vault-asset token is converted and included in the returned amount

## 7. Fork test

- [x] 7.1 ~~Add `test/fork/ConcentratedLiquidityStrategyFork.t.sol`~~ — **path corrected.** Added as `test/integration/strategies/ConcentratedLiquidityMainnetFork.t.sol`, pinned to Robinhood block 27_800_000, exercising mint → rerange → settle against the live pool, position manager and Morpho market.
      - The task's path would have broken CI: `.github/workflows/ci.yml` excludes `test/integration/**`, **not** `test/fork/**`. A suite at `test/fork/` runs in the default CI job with no RPC and fails. Placed under the path CI actually excludes, matching `MorphoSupplyMainnetFork` / `UniswapAdapterRobinhoodFork`.
- [x] 7.2 Confirm the fork test is excluded from the default CI job per the existing fork-test convention

## 8. Deployment

- [x] 8.1 Add `script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol` asserting the position manager and Morpho singleton both hold code before deploying the template
      - **Strengthened beyond the task: code presence alone is not sufficient on this chain** (see 1.1). The script asserts IDENTITY — `symbol() == "UNI-V3-POS"` and `factory()` agreeing with the configured factory — because the canonical Uniswap addresses hold ~2110 bytes of unrelated code on 4663 and would pass a bare `code.length != 0` check.
- [x] 8.2 Extend `script/DeployStrategyFactory.s.sol` template approvals to include the new template
- [x] 8.3 Verify the deployed template's runtime size against the 98,304-byte Robinhood limit
- [x] 8.4 Document the per-proposal operator step in the runbook: `setAdapterAllowed(clone, true)` before the batch executes, and that the clone must stay allowlisted for the whole strategy period because `rerange()` is batch-reachable

## 9. Verification

- [x] 9.1 Run the full `forge test` suite and confirm no pre-existing suite regressed — compare the failure list against the baseline, not against zero
- [x] 9.2 Run `forge fmt --check` with a forge matching CI
- [x] 9.3 Run `openspec validate concentrated-liquidity-strategy --strict` (positional change name; `--change` is not a flag on this command)
