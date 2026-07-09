# Sherwood Protocol

Solidity contracts for agent-managed investment funds (syndicates). Depositors pool
capital into an ERC-4626 vault; a registered agent proposes strategies; shareholders
vote under optimistic governance; staked WOOD guardians review calldata before
execution. Contracts enforce the rules — agents manage, humans watch.

Built with Foundry and OpenZeppelin (UUPS upgradeable), Solidity `0.8.28`, `via_ir`
compilation. Full protocol docs: **https://docs.sherwood.sh/**

## Contracts

### Core

| Contract | Description |
|----------|-------------|
| `src/SyndicateVault.sol` | ERC-4626 vault + `ERC20Votes` for governance snapshots. The onchain identity — holds every position. Two-lane liquidity while a proposal is live (Lane A oracle-instant, Lane B async queue), instant against float otherwise. Strategy execution runs only through the governor via `executeGovernorBatch` (delegatecall to the executor lib); no arbitrary-calldata owner entrypoint. Active-strategy share hooks `strategyMint` / `strategyBurn` let a custody strategy service its own deposits/redeems. |
| `src/SyndicateGovernor.sol` | Proposal lifecycle: propose → vote → guardian review → execute → settle. Optimistic voting, collaborative (multi-agent) proposals, permissionless settlement, P&L from balance-snapshot diffs, protocol/agent/management/guardian fees. Inherits `GovernorParameters` + `GovernorEmergency`. |
| `src/GovernorParameters.sol` | Abstract. Owner-instant parameter setters with hardcoded bounds; emits a uniform `ParameterChangeFinalized(key, old, new)`. No onchain timelock — owner is a multisig that enforces its own delay. |
| `src/GovernorEmergency.sol` | Abstract. Emergency-settle entrypoints: `unstick`, `emergencySettleWithCalls`, `cancelEmergencySettle`, `finalizeEmergencySettle`. Emergency review state lives in the registry. |
| `src/GuardianRegistry.sol` | UUPS. Guardian review / emergency-review lifecycle and the slash-appeal reserve. Holds zero assets — reads vote weight from sWOOD and calls sWOOD to slash. Computes the graduated (stake-weighted-median) voted slash severity. |
| `src/StakedWood.sol` | UUPS. Sole WOOD custodian for the guardian layer: guardian stake, owner bonds, checkpointed vote weight, DPoS delegation, commission, slashing + burn. Non-transferable vote-escrow — no ERC-20 transfer surface. |
| `src/StakedWoodDelegation.sol` | Abstract inherited by `StakedWood`. Share-factor (ERC-4626-style) delegation pools — one write slashes every delegator pro-rata — plus unstake cooldown and DPoS commission with a per-epoch raise cap. |
| `src/SyndicateFactory.sol` | UUPS. Deploys each vault as an immutable ERC-1967 proxy in one tx, registers its ENS subname and withdrawal queue, and binds the owner stake. `governor` and staking contract are set-once at init. |
| `src/BatchExecutorLib.sol` | Stateless 63-line batch executor. Vaults delegatecall it to run protocol calls as themselves. The vault pins the executor codehash at init and reverts on drift. |
| `src/StrategyFactory.sol` | Atomic clone + initialize for strategy templates — closes the front-run window on separate `clone` / `initialize` txs. Templates gated by an owner allowlist; callers gated to the vault owner / registered agents. |
| `src/WoodToken.sol` | WOOD — LayerZero OFT + `ERC20Permit`, hard 1B supply cap. Pure value token; vote weight lives in `StakedWood`. (Reference fixture — production WOOD is an external token.) |

### Pricing (Lane A) & queue (Lane B)

| Contract | Description |
|----------|-------------|
| `src/pricing/PriceRouter.sol` | UUPS, governance-owned. Prices a strategy's reported `positions()` per position `kind` via registered adapters, with a monotone haircut, an instant-size cap, and a per-kind `laneAEnabled` flag. Fail-closed → `(0, false)` → Lane B. |
| `src/pricing/adapters/` | `MoonwellSupplyAdapter`, `HyperliquidPerpAdapter`, `AerodromeLPAdapter` — per-kind instant-pricing adapters that validate the venue before pricing. |
| `src/queue/VaultWithdrawalQueue.sol` | Per-vault async request queue. Escrows redeem shares / deposit assets while a proposal is live; at settlement the vault stamps one frozen price per proposal and every request claims at that single realized price. |

### Strategy templates (`src/strategies/`)

ERC-1167 clonable. The vault calls `execute()` / `settle()` via batch; `positions()`
reports on-venue holdings for vault-side pricing (empty array = Lane B only).

| Template | Venue |
|----------|-------|
| `BaseStrategy.sol` | Abstract base (custody, state machine, proposer-tunable params) |
| `MoonwellSupplyStrategy.sol` | Supply to Moonwell (mToken) for yield |
| `WstETHMoonwellStrategy.sol` | wstETH supply on Moonwell |
| `AerodromeLPStrategy.sol` | Aerodrome liquidity provision |
| `HyperliquidPerpStrategy.sol` | Hyperliquid perpetuals |
| `HyperliquidGridStrategy.sol` | Hyperliquid ATR grid |
| `PortfolioStrategy.sol` | Multi-asset portfolio with rebalancing |
| `MamoYieldStrategy.sol` | Mamo optimized yield (Moonwell core + Morpho) |
| `VeniceInferenceStrategy.sol` | Venice inference funding |
| `LeveragedAerodromeCLStrategy.sol` | Net-short leveraged Slipstream CL (Moonwell collateral, borrow, AERO gauge). Strategy-serviced custody via the vault share hooks; helpers in `LeveragedAeroManager` / `LeveragedAeroValuation` / `LeveragedAeroFees`. Spec & integration guide: [`docs/LeveragedAerodromeCLStrategy.md`](docs/LeveragedAerodromeCLStrategy.md). |

## Key concepts

- **Optimistic governance** — proposals pass by default when voting ends; only rejected
  if AGAINST votes reach `vetoThresholdBps`. Vote weight comes from `ERC20Votes`
  timestamp checkpoints. One strategy live per vault at a time.
- **Guardian review** — a `GuardianReview` window (default 24h) sits between `Pending`
  and `Approved`. Guardians stake WOOD (in sWOOD) and review calldata; a block quorum
  rejects the proposal and slashes approvers (WOOD burned). Slash severity is a
  stake-weighted median of blockers' proposed `slashBps`.
- **Two-lane liquidity** — while a proposal is live the vault is not instant against
  float. **Lane A** is oracle-instant entry/exit, available only when the
  `PriceRouter` prices the active strategy's positions within its gates (per-share
  lockup until settle). **Lane B** is the universal async queue with one frozen
  per-proposal settle price. Everything fails closed to Lane B.
- **First-depositor / inflation protection** — dynamic `_decimalsOffset()` = the
  asset's decimals, scaling the ERC-4626 virtual-shares defense to any denomination.
- **Transient reentrancy guards** — `ReentrancyGuardTransient` (EIP-1153) across the
  vault, registry, queue, and strategies.
- **Delegatecall containment** — the vault only delegatecalls `BatchExecutorLib`,
  enforced by a codehash pin stamped at init (`ExecutorCodehashMismatch` on drift).
- **UUPS upgradeable** — vault / governor / factory / registry / sWOOD / router are
  proxies. Never reorder storage slots; append only and shrink the `__gap`.

## Directory layout

```
src/            Contracts (core, strategies/, pricing/, queue/, adapters/, interfaces/, libraries/)
test/           Foundry tests (unit + fork/integration under test/integration/)
script/         Deploy + admin scripts (inherit script/ScriptBase.sol)
chains/         Per-chain deployed addresses, {chainId}.json (auto-written by deploy scripts)
lib/            Vendored deps (forge-std, OpenZeppelin, OpenZeppelin-upgradeable, LayerZero-v2)
```

## Quick Start

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation)
(`curl -L https://foundry.paradigm.xyz | bash && foundryup`).

```bash
forge build

# Unit tests. --no-match-path skips fork/integration tests that need an RPC URL.
forge test --no-match-path "test/integration/**"

forge test                 # everything, including fork tests (needs RPC endpoints)
forge fmt                  # format (CI runs forge fmt --check)
forge build --sizes        # runtime bytecode sizes (some contracts sit near the EIP-170 limit)
```

`via_ir = true` in `foundry.toml` makes compilation ~2× slower than the legacy
pipeline — it is required to fit the governor under the bytecode limit.

## Deployment

Sherwood currently deploys on **Robinhood testnet (chain 46630)**. Deploy scripts
write resolved addresses to `chains/{chainId}.json` (CAPS_SNAKE_CASE keys —
`SYNDICATE_FACTORY`, `SYNDICATE_GOVERNOR`, `GUARDIAN_REGISTRY`, `STAKED_WOOD`,
`PRICE_ROUTER`, …); admin scripts read the same JSON. Setters are owner-instant, so
the owning multisig points directly at `setProtocolFeeBps(...)`, `setGuardianFeeBps(...)`,
etc.

## Docs

Full protocol, governance, and integration documentation: **https://docs.sherwood.sh/**
