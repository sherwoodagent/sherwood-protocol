# Bind VeniceInferenceStrategy's proposer-supplied aeroRouter/sVVV to the tier-registry allowlist (issue #155)

## Why

`VeniceInferenceStrategy._initialize` accepts proposer-supplied `aeroRouter`
and `sVVV` addresses with only a non-zero check (`src/strategies/VeniceInferenceStrategy.sol:117-119`),
then assigns them directly. There is no allowlist, registry, or provenance
check. Both addresses are later handed ERC-20 approvals over vault capital:

- `IERC20(asset).forceApprove(aeroRouter, assetAmount)` (`:150`), whenever
  `needsSwap()` is true.
- `IERC20(vvv).forceApprove(sVVV, vvvToStake)` followed by
  `IVeniceStaking(sVVV).stake(agent, vvvToStake)` (`:171`).

This is the same gap class fixed for `PortfolioStrategy` in #147 (PR #165,
merged): `SyndicateVault._guardBatchCalls` gates the spender/recipient of
value-moving ERC-20 selectors inside a governor batch's own calldata, but
`strategy.execute()` is the batch call — the `forceApprove` happens one frame
deeper, inside the strategy's own logic, where the guard cannot see it. A
proposer (who must already be `vault.isAgent(msg.sender)` to reach `propose()`
— reachability is bounded but real, per #147's own reasoning) could name an
`aeroRouter`/`sVVV` they control and drain the resulting approval in a later,
separate transaction.

`VeniceInferenceStrategy` is a distinct contract with its own init signature
and no slippage-floor equivalent (no `maxSlippageBps` parameter exists here at
all — the swap uses `minVVV`, already validated non-zero when swapping), so
this is a distinct change, not a re-open of #147.

## What changes

**`_requireAllowedAdapter` in `VeniceInferenceStrategy`** — a private view
check, called from `_initialize` before any state write, once per address
that receives an approval: `aeroRouter_` (only when `p.asset != p.vvv`, since
that is the only condition under which `aeroRouter` is used at all — see
`needsSwap()`) and `sVVV_` (always, since `stake()` runs unconditionally in
`_execute`). It walks `vault() → governor() → tierRegistry()` with
length-checked raw staticcalls and requires
`isAdapterAllowed(<address>)` in the resolved registry — the SAME
`TierRegistry` `SyndicateVault._guardBatchCalls` and `PortfolioStrategy`
already consult. Skips (does not revert) when the walk resolves no registry —
the same condition under which `_guardBatchCalls` itself disables, and one
the proposer cannot steer, since no hop of the walk is proposer input (the
walk starts at `vault()`, fixed `BaseStrategy` state before `_initialize`
runs). A registry that DOES resolve but cannot vouch (revert, malformed
return) fails CLOSED with `AdapterNotAllowed(adapter, registry)`.

## What does NOT change

- No slippage-floor equivalent — `VeniceInferenceStrategy` has no
  `maxSlippageBps` parameter; `minVVV` is already required non-zero when a
  swap is needed (`_initialize`'s existing `if (p.minVVV == 0)
  revert InvalidAmount()`), and that validation is out of scope for this
  change.
- `weth`, `aeroFactory`, `agent` — not spender/recipient addresses for any
  ERC-20 approval, out of scope.
- `_execute`/`_settle` are NOT re-checked post-init — same capital-hostage
  rationale as `PortfolioStrategy`: re-checking would let a post-execute
  demotion strand capital already committed to the loan.
- No re-check on `updateParams` (`VeniceInferenceStrategy` has no equivalent
  of `PortfolioStrategy.rebalance`/`rebalanceDelta` that re-touches
  `aeroRouter`/`sVVV` post-init — `updateParams` only adjusts
  `repaymentAmount`, never the router/staking addresses).

## Refs

- Issue #155
- Issue #147 / PR #165 (the sibling `PortfolioStrategy` fix this mirrors)
- Issue #137 (codehash-aware `isAdapterAllowed`) strengthens this
  automatically — same external signature, no coupling required here either
