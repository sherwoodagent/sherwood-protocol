# epoch-nav (delta)

The four PriceRouter/live-NAV requirements are removed with Lane A (issue #54):
`src/pricing/PriceRouter.sol` and `src/interfaces/IPriceRouter.sol` are deleted, and
the vault no longer carries a live-NAV term. **Everything else in this capability
survives untouched** — the WOOD feed-first pricing, the governance cap, the WOOD
haircut, vault-asset staleness gating, coverage epochs, bounded duration, and the
hardened Chainlink reads all live in `ExposureLedger` / `WoodTwapOracle`, which have
zero references to `PriceRouter`, `Position`, or `laneA` (verified;
`WoodTwapOracle` is wired exclusively through `ExposureLedger.setWoodTwapOracle` —
`ExposureLedger.sol:6,217,526-533,663`). Do not let "pricing" folder intuition
delete `WoodTwapOracle.sol` — it is the guardian-bond WOOD/USD feed, not Lane A.

## REMOVED Requirements

### Requirement: Strategy valuation is router-priced and fail-closed

**Reason**: `PriceRouter.valueStrategy` and its sole caller (`SyndicateVault.
_laneState`) are deleted with Lane A; the strategy `positions()` hook it consumed is
removed from `IStrategy`/`BaseStrategy` (no other consumer exists). The fail-closed
property ("unpriceable ⇒ no instant exit") is subsumed by the vault's stronger v1
rule: an active proposal closes instant exits unconditionally.
**Migration**: None on-chain (the router was deployed with zero adapters on the
testnet lineage and was never load-bearing). V2 reintroduces vault-side pricing
together with the lane it serves.

### Requirement: Single-position pricing applies haircut and instant cap

**Reason**: `PriceRouter.valuePosition`, the per-kind adapters (`IPriceAdapter`),
haircuts, and instant caps are deleted with the router.
**Migration**: None.

### Requirement: Router pricing parameters are owner-gated with a one-way haircut

**Reason**: The router and all its governance surface (`registerAdapter`,
`setHaircutBps`, `setInstantCap`, `setLaneAEnabled`) are deleted.
**Migration**: None.

### Requirement: Vault NAV is idle float plus router-priced live NAV

**Reason**: The live-NAV term is deleted; vault NAV is defined float-only by the
modified "ERC-4626 share accounting and NAV" requirement in the `syndicate-vault`
capability (idle balance minus the queue reserve, floored at zero).
**Migration**: See `syndicate-vault` delta in this change.
