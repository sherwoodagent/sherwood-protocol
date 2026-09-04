# Fees

Sherwood charges depositors exactly **two fees** — a management fee and a performance
fee. Everyone who earns (agent, protocol, guardian network, vault owner) is paid out
of those two numbers through governance-set splits. There are no deposit fees, exit
fees, staking fees, or referral fees anywhere in the protocol.

## The two-number model

| Fee | Base | Default | Hard cap | Charged |
|---|---|---|---|---|
| **Management** | fund assets × time deployed (asset-seconds) | 2%/yr | 3%/yr | every settlement — profit, flat, or loss |
| **Performance** | value above the fund's previous peak price per share (high-water mark) | 20% | 25% protocol ceiling (20% per-vault default cap) | profitable settlements only |

The headline is **2-and-20**. The management number is load-bearing for guardian
economics rather than for revenue: 20% of it funds the guardian pool, and it is the
only leg that pays when markets are flat or down — the performance leg pays nothing
below the high-water mark while review workload is unchanged. See
[guardian-network.md](guardian-network.md).

## Management fee

- **Rate source:** `vault.managementFeeBps()`, stamped once at vault creation from
  `SyndicateFactory.managementFeeBps` (`src/SyndicateFactory.sol:136`) and stamped
  into the vault's init params at `:374`. There is no per-vault setter — changing
  the factory value only affects *new* vaults.
- **Bounds:** 0 → `MAX_MANAGEMENT_FEE_BPS = 300` bps (3%/yr), enforced at
  `SyndicateFactory.initialize` (`src/SyndicateFactory.sol:288`, check at `:309`) and
  at the factory setter (`src/SyndicateFactory.sol:593`). The vault-side write is a
  bare assignment with no bound of its own — the factory is the only gate.
  Deploy scripts seed 200 bps (2%/yr); `script/testnet/Deploy.s.sol` seeds 50 (0.5%).
- **Sticky per vault:** `_managementFeeBps` is written once at the vault's `initialize`
  (`src/SyndicateVault.sol:601`) and the vault exposes only a getter
  (`:1467`) — there is no per-vault setter, and `SyndicateFactory.setManagementFeeBps`
  reaches new vaults only. A fund created under the wrong rate keeps it forever.
- **Accrual:** the vault integrates *asset-seconds* — a running sum of
  `fund assets × elapsed time` (`src/SyndicateVault.sol:2686`). The clock only runs
  while a strategy is deployed: `startManagementAccrual()` starts it at
  `executeProposal` and `consumeManagementAccrual()` stops and zeroes it at
  settlement. **Idle capital between proposals accrues nothing.**
- **Formula:** `fee = assetSeconds × rateBps / (10 000 × 365 days)`
  (`src/SyndicateGovernor.sol:2384`).
- **Conservative base stamping:** the base re-reads `totalAssets()` behind a
  `try/catch`; if pricing reverts it falls back to idle float, so the fee can only
  under-count, never inflate (`src/SyndicateVault.sol:2702`).

### Management split (`ProtocolConfig.mgmtSplit`)

| Leg | Default | Recipient |
|---|---|---|
| Agent | 60% | lead proposer (+ co-proposers) |
| Protocol | 20% | `protocolFeeRecipient` |
| Guardians | 20% | `guardiansFeeRecipient` |

Seeded in the constructor (`src/ProtocolConfig.sol:76`) so a config is valid from
birth — the contract is not upgradeable, so adopting a new split means deploying a
fresh one and re-pointing governors via `setProtocolConfig`.

Legs must sum to exactly 10 000 bps (`src/ProtocolConfig.sol:101`); individual legs
have no floor or ceiling. An unset (zero-address) protocol/guardian recipient folds
that leg into the agent's remainder rather than stranding it.

**That fold is a deployment hazard, not just a nicety.** `ProtocolConfig`'s
constructor seeds the splits but leaves both recipients zero, so a ceremony that
forgets `setGuardiansFeeRecipient` pays the guardians' 20% of management and 25% of
performance to the *proposer* — silently, at a fee level chosen to fund a guardian
pool that receives nothing. Deploy scripts seat both recipients inside the broadcast
and assert both afterwards.

## Performance fee

- **Rate source:** `vault.agentFeeBps()`, owner-settable. Default 20%
  (`FeeConstants.DEFAULT_AGENT_FEE_BPS = 2000`); explicit 0% is legal. Stored with a
  +1 sentinel so an explicit zero is distinguishable from unset
  (`src/SyndicateVault.sol:1485`).
- **Three stacked limits** (`src/FeeConstants.sol:13-19`):
  1. `MAX_PERFORMANCE_FEE_BPS = 2500` (25%) — absolute protocol ceiling, checked at
     `setAgentFeeBps` (`src/SyndicateVault.sol:1482`).
  2. Per-vault governor cap `maxPerformanceFeeBps` — default 2000 (20%), settable by
     the vault owner between proposals up to 25%
     (`src/GovernorParameters.sol:222`, `:345`).
  3. The vault's own `agentFeeBps` — default 2000 (20%), equal to the per-vault cap
     by design, so the default vault charges its full allowance until the owner
     lowers either number.
- **Double clamp:** the fee is clamped against the governor cap at **propose** time
  (snapshotted onto the proposal, `src/SyndicateGovernor.sol:660`) and re-clamped at
  **settle** against the live cap (`src/SyndicateGovernor.sol:2446`) so a later cap
  reduction still bites. Clamping emits `FeeClamped` and continues — never reverts.
- **High-water mark:** the fee applies only to assets above the highest price per
  share ever charged at (`aboveHighWaterMark()`, `src/SyndicateVault.sol:2796`). The
  mark ratchets monotonically at settlement (`ratchetHighWaterMark`,
  `src/SyndicateVault.sol:2810`) — losses leave it in place, so recovery back to the
  old peak is free. It is seeded at the fund's first deposit.

### Performance split (`ProtocolConfig.perfSplit`)

| Leg | Default | Recipient |
|---|---|---|
| Agent | 50% | lead proposer (+ co-proposers) |
| Protocol | 15% | `protocolFeeRecipient` |
| Guardians | 25% | `guardiansFeeRecipient` |
| Vault owner | 10% | `vault.owner()` (read live at settle) |

Seeded in the constructor (`src/ProtocolConfig.sol:80`). Sum must equal 10 000 bps
(`src/ProtocolConfig.sol:112`). The vault-owner leg exists only here, not on the
management split: the owner earns on the profit side rather than on assets under
management.

## Settlement ordering (load-bearing)

The settlement fee waterfall (`src/SyndicateGovernor.sol:2218-2240`, calling
`_chargeManagementFee` at `:2369` and `_chargePerformanceFee` at `:2431`) charges in a fixed
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
  (`src/SyndicateGovernor.sol:2554`). Anyone can later push it out via the
  permissionless `claimUnclaimedFees(vault, token)` (`src/SyndicateGovernor.sol:2640`).
- The vault refuses to pay fees out of float reserved for stamped queue redemptions
  (`transferPerformanceFee` subtracts `reservedQueueAssets()`,
  `src/SyndicateVault.sol:1358`).
- The guardian slice is paid in the vault's asset to `guardiansFeeRecipient` and
  converted to WOOD off-chain (weekly Merkl buyback). `GuardianFeeAccrued` is emitted
  only on actual delivery, never on escrow.

## Co-proposer splits

Collaborative proposals sub-split the **agent slice** of both fees
(`_distributeAgentFee`, `src/SyndicateGovernor.sol:2508`):

- Each co-proposer's `splitBps` ≥ 100 (1%) — `SplitTooLow` otherwise.
- Total co-proposer split ≤ 9 000 bps — the lead proposer always keeps ≥ 10%.
- Max 10 co-proposers (`ABSOLUTE_MAX_CO_PROPOSERS`).

## Other charges (not depositor fees)

| Item | What it is | Bounds |
|---|---|---|
| Vault creation fee | optional absolute ERC-20 amount pulled at `createSyndicate`; default **0** (free) | no bounds; owner-set (`src/SyndicateFactory.sol:546`) |
| Idle-liquidity floor `minBufferBps` | batch-execution guard, not a charge | 0 (off) → 5 000 bps (50%) |
| Challenge bonds / burns | guardian-accountability economics (bond-and-burn, not fees) | see [guardian-network.md](guardian-network.md) |
| WOOD staking | **no** staking fee, **no** reward emissions; slashed WOOD is burned to `0x…dEaD` | — |

## Consolidated bounds table

| Parameter | Units | Default | Min | Max | Enforced at |
|---|---|---|---|---|---|
| `managementFeeBps` | bps/yr | 200 | 0 | 300 | `SyndicateFactory.sol:309`, `:593` |
| `agentFeeBps` | bps | 2 000 | 0 | 2 500 | `SyndicateVault.sol:1482` |
| `maxPerformanceFeeBps` (per-vault cap) | bps | 2 000 | 0 | 2 500 | `GovernorParameters.sol:345` |
| Mgmt split legs | bps | 6000/2000/2000 | 0/leg | sum == 10 000 | `ProtocolConfig.sol:101` |
| Perf split legs | bps | 5000/1500/2500/1000 | 0/leg | sum == 10 000 | `ProtocolConfig.sol:112` |
| Co-proposer `splitBps` | bps | per-proposal | 100 | 9 000 total | `SyndicateGovernor.sol:2181` |
| `creationFee` | absolute | 0 | — | unbounded | `SyndicateFactory.sol:546` |
| `minBufferBps` | bps | 0 | 0 | 5 000 | `SyndicateVault.sol:1491` |
