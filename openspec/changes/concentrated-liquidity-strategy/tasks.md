## 1. Vendor the Uniswap surface

- [ ] 1.1 Resolve the Uniswap V3 position-manager and factory addresses on Robinhood Chain (4663) and confirm each holds code via `cast code`; record them in `addresses/` alongside the existing entries
- [ ] 1.2 Add `src/vendor/uniswap/INonfungiblePositionManager.sol` and `src/vendor/uniswap/IUniswapV3Pool.sol` with only the functions used (mint, increaseLiquidity, decreaseLiquidity, collect, burn, positions; slot0, observe, tickSpacing, liquidity, token0/token1, fee)
- [ ] 1.3 Register the vendored files in `lib/VENDOR-MANIFEST.json` following the `src/vendor/morpho/` entries
- [ ] 1.4 Confirm `forge build` succeeds with no pragma conflicts

## 2. Template skeleton and initialization

- [ ] 2.1 Create `src/strategies/ConcentratedLiquidityStrategy.sol` extending `BaseStrategy`, with `name()` returning "Concentrated Liquidity LP" and per-clone storage for pool, position manager, Morpho market params, tick range, borrow amount, collateral amount, and tunables
- [ ] 2.2 Declare errors, one per init check, each with natspec naming its adversary per the repo's house style
- [ ] 2.3 Implement `_initialize` decode and checks 1–6 in the spec's stated order (pool exists and quotes vault asset; market exists and lends vault asset; borrow ≤ lendable liquidity; LTV ≤ LLTV − buffer; notional ≤ pool-share cap; tick range ordered, non-empty, spacing-aligned)
- [ ] 2.4 Decide pool-share cap and LLTV buffer as constants vs `ProtocolConfig` reads (design Open Question 2) and implement the chosen form
- [ ] 2.5 Grep `test/` for existing vault/governor/Morpho stand-ins and add every new selector this contract calls to them **in this same commit** — a typed call against a mock lacking the selector reverts undecodably in the caller's frame

## 3. Execute path

- [ ] 3.1 Implement the spot-vs-TWAP guard as a raw `staticcall` to `observe` with an explicit `ret.length` check and `abi.decode`, reverting on any failure (fail-closed, design Decision 5)
- [ ] 3.2 Implement `_execute`: pull vault asset, supply collateral to Morpho, borrow the vault asset, mint one position over the fixed tick range, and store the returned token id
- [ ] 3.3 Assert post-execute invariants in-contract where cheap: exactly one position held, borrow amount matches the configured amount
- [ ] 3.4 Emit an execute event carrying pool, token id, tick range, liquidity, borrowed, and collateral

## 4. Rerange

- [ ] 4.1 Store the rerange policy at init (half-width ticks, trigger fraction, min interval, max count, slippage floor) and validate it: half-width ≥ one tick spacing, trigger fraction in (0, 1], max count bounded
- [ ] 4.2 Implement the deterministic new-range derivation — approved half-width centered on the current TWAP tick, snapped to tick spacing — as a `public view` so callers can simulate the exact result before sending
- [ ] 4.3 Implement permissionless `rerange()` with all five admissibility conditions (Executed; trigger reached; interval elapsed; count below max; spot within the TWAP bound), each with its own error
- [ ] 4.4 Implement the rerange body: burn position, collect fees, re-mint over the new range subject to the slippage floor, increment the count; assert borrow and collateral are untouched
- [ ] 4.5 Emit a rerange event carrying old range, new range, TWAP tick, rerange index, and liquidity before/after

## 5. Settle and sweep

- [ ] 5.1 Implement `_settle` in the required order: decrease liquidity to zero → collect fees → repay borrow → withdraw collateral → push entire vault-asset balance to the vault
- [ ] 5.2 Convert non-vault-asset proceeds subject to the tunable slippage floor, reusing the existing `UniswapSwapAdapter` route rather than a new swap path
- [ ] 5.3 Implement deliverable-maximum behavior for the repay and withdraw legs, emitting `SettlementIncomplete` with remaining debt and collateral instead of reverting
- [ ] 5.4 Implement permissionless post-settlement `sweep()` gated on `State.Settled`, idempotent and safe to call with nothing to move
- [ ] 5.5 Implement `_updateParams` accepting only slippage floors and settlement deadline, rejecting range and every rerange-policy field, and reverting outside `State.Executed`

## 6. Unit tests

- [ ] 6.1 Lifecycle: execute-from-foreign-proposal reverts; double execute reverts; settle-before-execute reverts; at most one position held across a rerange
- [ ] 6.2 Init validation: one test per check in 2.3, each asserting the specific error, plus the rerange-policy validations from 4.1
- [ ] 6.3 TWAP guard: spot outside bound reverts; insufficient observation cardinality reverts
- [ ] 6.4 Tunables: proposer may retune slippage; range, pool, and every rerange-policy field revert; non-proposer updates revert
- [ ] 6.5 Rerange admissibility: one test per condition (not Executed; before trigger; inside min interval; at max count; spot outside TWAP bound), each asserting its own error
- [ ] 6.6 Rerange determinism: two different callers in identical state produce the identical range; the `view` derivation from 4.2 matches what `rerange()` actually mints
- [ ] 6.7 Rerange invariants: borrow and collateral unchanged; count increments; position replaced not added; at the cap the position stays settleable
- [ ] 6.8 Rerange griefing bound: `maxReranges` consecutive reranges cost no more than `maxReranges × (swap cost + slippage floor)` — pin the worst case as a test
- [ ] 6.9 Full settlement: zero liquidity, zero debt, zero collateral, vault receives full proceeds — both without a rerange and after one
- [ ] 6.10 Partial settlement: each partial-failure combination (repay short, withdraw short, both) emits the event and does not revert
- [ ] 6.11 Sweep: recovers residue after conditions improve; idempotent; reverts before settlement
- [ ] 6.12 Fee accrual in the non-vault-asset token is converted and included in the returned amount

## 7. Fork test

- [ ] 7.1 Add `test/fork/ConcentratedLiquidityStrategyFork.t.sol` pinned to a fixed Robinhood Chain block, exercising a full mint → accrue → rerange → settle cycle against the live pool and Morpho market
- [ ] 7.2 Confirm the fork test is excluded from the default CI job per the existing fork-test convention

## 8. Deployment

- [ ] 8.1 Add `script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol` asserting the position manager and Morpho singleton both hold code before deploying the template
- [ ] 8.2 Extend `script/DeployStrategyFactory.s.sol` template approvals to include the new template
- [ ] 8.3 Verify the deployed template's runtime size against the 98,304-byte Robinhood limit
- [ ] 8.4 Document the per-proposal operator step in the runbook: `setAdapterAllowed(clone, true)` before the batch executes, and that the clone must stay allowlisted for the whole strategy period because `rerange()` is batch-reachable

## 9. Verification

- [ ] 9.1 Run the full `forge test` suite and confirm no pre-existing suite regressed — compare the failure list against the baseline, not against zero
- [ ] 9.2 Run `forge fmt --check` with a forge matching CI
- [ ] 9.3 Run `openspec validate concentrated-liquidity-strategy --strict` (positional change name; `--change` is not a flag on this command)
