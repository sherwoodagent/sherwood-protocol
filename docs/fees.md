# Fees

Sherwood charges depositors exactly **two fees** — a management fee and a performance
fee. Everyone who earns (agent, protocol, guardian network, vault owner) is paid out
of those two numbers through governance-set splits. There are no deposit fees, exit
fees, staking fees, or referral fees anywhere in the protocol.

## The two-number model

| Fee | Base | Default | Hard cap | Charged |
|---|---|---|---|---|
| **Management** | fund assets × time deployed (asset-seconds) | 0.5%/yr | 5%/yr | every settlement — profit, flat, or loss |
| **Performance** | value above the fund's previous peak price per share (high-water mark) | 5% | 30% protocol ceiling (20% per-vault default cap) | profitable settlements only |

## Management fee

- **Rate source:** `vault.managementFeeBps()`, stamped once at vault creation from
  `SyndicateFactory.managementFeeBps` (`src/SyndicateFactory.sol:342`). There is no
  per-vault setter — changing the factory value only affects *new* vaults.
- **Bounds:** 0 → `MAX_MANAGEMENT_FEE_BPS = 500` bps (5%/yr), enforced at vault
  `initialize` (`src/SyndicateFactory.sol:282`) and at the factory setter
  (`src/SyndicateFactory.sol:554`). Deploy scripts seed 50 bps (0.5%/yr).
- **Accrual:** the vault integrates *asset-seconds* — a running sum of
  `fund assets × elapsed time` (`src/SyndicateVault.sol:1554`). The clock only runs
  while a strategy is deployed: `startManagementAccrual()` starts it at
  `executeProposal` and `consumeManagementAccrual()` stops and zeroes it at
  settlement. **Idle capital between proposals accrues nothing.**
- **Formula:** `fee = assetSeconds × rateBps / (10 000 × 365 days)`
  (`src/SyndicateGovernor.sol:1672`).
- **Conservative base stamping:** the base re-reads `totalAssets()` behind a
  `try/catch`; if pricing reverts it falls back to idle float, so the fee can only
  under-count, never inflate (`src/SyndicateVault.sol:1578`).

### Management split (`ProtocolConfig.mgmtSplit`)

| Leg | Default | Recipient |
|---|---|---|
| Agent | 70% | lead proposer (+ co-proposers) |
| Protocol | 20% | `protocolFeeRecipient` |
| Guardians | 10% | `guardiansFeeRecipient` |

Legs must sum to exactly 10 000 bps (`src/ProtocolConfig.sol:92-97`); individual legs
have no floor or ceiling. An unset (zero-address) protocol/guardian recipient folds
that leg into the agent's remainder rather than stranding it.

## Performance fee

- **Rate source:** `vault.agentFeeBps()`, owner-settable. Default 5%
  (`FeeConstants.DEFAULT_AGENT_FEE_BPS`); explicit 0% is legal.
- **Three stacked limits** (`src/FeeConstants.sol:13-19`):
  1. `MAX_PERFORMANCE_FEE_BPS = 3000` (30%) — absolute protocol ceiling, checked at
     `setAgentFeeBps` (`src/SyndicateVault.sol:1131`).
  2. Per-vault governor cap `maxPerformanceFeeBps` — default 2000 (20%), settable by
     the vault owner between proposals up to 30%
     (`src/GovernorParameters.sol:222`, `:346`).
  3. The vault's own `agentFeeBps` — default 500 (5%).
- **Double clamp:** the fee is clamped against the governor cap at **propose** time
  (snapshotted onto the proposal, `src/SyndicateGovernor.sol:325`) and re-clamped at
  **settle** against the live cap (`src/SyndicateGovernor.sol:1745`) so a later cap
  reduction still bites. Clamping emits `FeeClamped` and continues — never reverts.
- **High-water mark:** the fee applies only to assets above the highest price per
  share ever charged at (`aboveHighWaterMark()`, `src/SyndicateVault.sol:1686`). The
  mark ratchets monotonically at settlement (`ratchetHighWaterMark`,
  `src/SyndicateVault.sol:1700`) — losses leave it in place, so recovery back to the
  old peak is free. It is seeded at the fund's first deposit.

### Performance split (`ProtocolConfig.perfSplit`)

| Leg | Default | Recipient |
|---|---|---|
| Agent | 60% | lead proposer (+ co-proposers) |
| Protocol | 15% | `protocolFeeRecipient` |
| Guardians | 15% | `guardiansFeeRecipient` |
| Vault owner | 10% | `vault.owner()` (read live at settle) |

Sum must equal 10 000 bps (`src/ProtocolConfig.sol:103-108`).

## Settlement ordering (load-bearing)

`_finalizeSettlement` (`src/SyndicateGovernor.sol:1554-1585`) charges in a fixed
order so no fee is charged on assets another fee already took:

1. **Management fee** — lowers vault assets, therefore lowers price per share.
2. **Performance fee** — reads `aboveHighWaterMark()` *after* the management fee.
3. **High-water mark ratchet** — against the post-fee price.
4. **Queue settle price stamped** — Lane B redeemers/depositors settle at post-fee NAV.

Fee splits are snapshotted from `ProtocolConfig` at **propose** time — a mid-proposal
governance change never affects an in-flight strategy.

## Fee delivery and escrow

- `_payFee` wraps the transfer in `try/catch`: a failing recipient (e.g. blacklisted)
  escrows the amount in the governor instead of bricking settlement
  (`src/SyndicateGovernor.sol:1837`). Anyone can later push it out via the
  permissionless `claimUnclaimedFees(vault, token)` (`src/SyndicateGovernor.sol:1862`).
- The vault refuses to pay fees out of float reserved for stamped queue redemptions
  (`transferPerformanceFee` subtracts `reservedQueueAssets()`,
  `src/SyndicateVault.sol:1054`).
- The guardian slice is paid in the vault's asset to `guardiansFeeRecipient` and
  converted to WOOD off-chain (weekly Merkl buyback). `GuardianFeeAccrued` is emitted
  only on actual delivery, never on escrow.

## Co-proposer splits

Collaborative proposals sub-split the **agent slice** of both fees
(`_distributeAgentFee`, `src/SyndicateGovernor.sol:1799`):

- Each co-proposer's `splitBps` ≥ 100 (1%) — `SplitTooLow` otherwise.
- Total co-proposer split ≤ 9 000 bps — the lead proposer always keeps ≥ 10%.
- Max 10 co-proposers (`ABSOLUTE_MAX_CO_PROPOSERS`).

## Other charges (not depositor fees)

| Item | What it is | Bounds |
|---|---|---|
| Vault creation fee | optional absolute ERC-20 amount pulled at `createSyndicate`; default **0** (free) | no bounds; owner-set (`src/SyndicateFactory.sol:503`) |
| Idle-liquidity floor `minBufferBps` | batch-execution guard, not a charge | 0 (off) → 5 000 bps (50%) |
| Challenge bonds / burns | guardian-accountability economics (bond-and-burn, not fees) | see [guardian-network.md](guardian-network.md) |
| WOOD staking | **no** staking fee, **no** reward emissions; slashed WOOD is burned to `0x…dEaD` | — |

## Consolidated bounds table

| Parameter | Units | Default | Min | Max | Enforced at |
|---|---|---|---|---|---|
| `managementFeeBps` | bps/yr | 50 | 0 | 500 | `SyndicateFactory.sol:282`, `:554` |
| `agentFeeBps` | bps | 500 | 0 | 3 000 | `SyndicateVault.sol:1131` |
| `maxPerformanceFeeBps` (per-vault cap) | bps | 2 000 | 0 | 3 000 | `GovernorParameters.sol:346` |
| Mgmt split legs | bps | 7000/2000/1000 | 0/leg | sum == 10 000 | `ProtocolConfig.sol:92` |
| Perf split legs | bps | 6000/1500/1500/1000 | 0/leg | sum == 10 000 | `ProtocolConfig.sol:103` |
| Co-proposer `splitBps` | bps | per-proposal | 100 | 9 000 total | `SyndicateGovernor.sol:1498` |
| `creationFee` | absolute | 0 | — | unbounded | `SyndicateFactory.sol:503` |
| `minBufferBps` | bps | 0 | 0 | 5 000 | `SyndicateVault.sol:1140` |
