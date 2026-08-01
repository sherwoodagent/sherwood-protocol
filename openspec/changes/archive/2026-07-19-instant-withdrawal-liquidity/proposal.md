# Instant-Withdrawal Liquidity

> Migrated from docs/superpowers/plans/2026-07-19-instant-withdrawal-liquidity.md + docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md (superpowers workflow) on 2026-08-01.

## Why

An LP could not exit the vault while a strategy proposal was live: `redemptionsLocked()` held for the whole proposal window, `maxWithdraw`/`maxRedeem` returned 0, and the only mid-strategy exit was the Lane B async queue, which pays out only after settlement at the frozen settle price. In practice users waited for the strategy to finish. The goal: LPs can withdraw at any time during a live proposal, via (A) a governance-enforced idle buffer the strategy can never deploy and (B) same-transaction on-demand pulls from strategies that support it — both industry-standard patterns (Yearn v3 `minimum_total_idle`, Morpho V2 `liquidityAdapter`/Yearn withdrawal queue).

## What Changes

- **Part A — enforced idle buffer.** New `minBufferBps` parameter (owner-set, max 5,000 = 50%, default 0 = off) enforced in `executeGovernorBatch`: a governor batch may deploy at most `(1 − minBufferBps)` of the pre-batch float, on top of the existing `reservedQueueAssets()` seniority check. Reverts `BufferBreached` on breach; inflow (settle) batches pass trivially.
- **Part B — strategy-level instant liquidity.** `IStrategy` gains `availableLiquidity()` / `withdrawTo(uint256)` with inert `BaseStrategy` defaults (0 / revert `OnDemandExitUnsupported`), so every existing strategy is unchanged. `SyndicateVault._withdraw` pulls the shortfall beyond idle float from the active strategy in the same tx — all-or-revert, balance-diff verified (`UnwindShortfall` on under-delivery), gated on Lane A live-NAV (no pricing ⇒ no instant exit). `maxWithdraw`/`maxRedeem` capacity becomes float + strategy liquidity. `nonReentrant` added to `_withdraw` alongside the new external call.
- **Settlement PnL correction (also fixes a pre-existing live bug).** New `_interimNetFlow` signed accumulator on the vault (Lane A deposits − instant exits while a proposal is active, reset in `onProposalSettled`); `SyndicateGovernor._finishSettlement` subtracts it from the float delta so mid-proposal LP flows are never charged performance fees or misread as strategy loss. The fee-on-principal bug for Lane A deposits existed before this change.
- **Concrete strategy.** `MoonwellSupplyStrategy` overrides: `availableLiquidity` = redeemable underlying capped by market `getCash()`; `withdrawTo` via `redeemUnderlying` mid-lifecycle partial redeem. `ICToken` gains `getCash()`.
- **EIP-170 size work.** Cold-path admin logic extracted to `SyndicateVaultAdminLib` (delegatecall, storage-ref) to free ~1.2 KB; a further rescue-function extraction was tried and reverted (dispatch overhead exceeded savings).
- **Deferred (documented, not built):** `minHoldingPeriod` anti-flash-arb cooldown (EIP-170 ceiling; the G1 Lane-A per-holder lock already blocks the primary intra-proposal deposit→exit MEV; storage slots reserved), `instantExitFeeBps`, and `maxUnwindSlippageBps`. Pinned-block Base fork test and the invariant fuzz suite deferred to CI follow-ups (no Base RPC in the dev sandbox).

## Capabilities

- syndicate-vault
- syndicate-governor

## Impact

- `src/interfaces/ISyndicateVault.sol` — errors (`BufferTooHigh`, `BufferBreached`, `UnwindShortfall`), events, setters, `interimNetFlow()` view
- `src/SyndicateVault.sol` — storage (3 slots from `__gap`), buffer enforcement, same-tx strategy pull, netflow tracking
- `src/SyndicateVaultAdminLib.sol` — new (EIP-170 extraction)
- `src/interfaces/IStrategy.sol`, `src/strategies/BaseStrategy.sol` — on-demand exit interface + inert defaults
- `src/strategies/MoonwellSupplyStrategy.sol`, `src/interfaces/ICToken.sol` — concrete overrides
- `src/SyndicateGovernor.sol` — netflow-adjusted PnL in `_finishSettlement`
- `test/SyndicateVault.InstantLiquidity.t.sol` — new suite (buffer, pull, netflow)
