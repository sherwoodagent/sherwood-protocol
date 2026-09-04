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
| `src/SyndicateVault.sol` | ERC-4626 vault + `ERC20Votes` for governance snapshots. The onchain identity — holds every position. Two-lane liquidity while a proposal is live (Lane A oracle-instant, Lane B async queue), instant against float otherwise. Strategy execution runs only through the governor via `executeGovernorBatch` (delegatecall to the executor lib); no arbitrary-calldata owner entrypoint. |
| `src/SyndicateVaultAdminLib.sol` | Cold-path admin logic (depositor whitelist + agent management) extracted from the vault and delegatecalled, to free EIP-170 runtime headroom. |
| `src/SyndicateGovernor.sol` | Proposal lifecycle: propose → vote → guardian review → execute → settle. **One governor per vault**, deployed by the factory as a `BeaconProxy` and resolved via `factory.governorOf(vault)`. Optimistic voting, collaborative (multi-agent) proposals, permissionless settlement, P&L from balance-snapshot diffs. Settlement charges the two-number fee model: an always-on management fee off the vault's asset-seconds accumulator, then a performance fee on value above the high-water mark, each divided by the splits snapshotted from `ProtocolConfig` at propose time. Inherits `GovernorParameters` + `GovernorEmergency`. |
| `src/ProposalLifecycle.sol` | Abstract. Owns the proposal lifecycle (propose → vote → guardian review → execute → settle) and its storage. One resolver, `_computeState`, backs the **true view** `stateOf(pid)` — it reports Approved/Rejected/Expired as soon as they are determinable, instead of lagging until a transaction pokes it. `_transition` is the **only** writer of `proposal.state`; `_commitState` persists a transition and fires the registry's economic commit exactly when a guardian review concluded (never for a veto-rejection, a Draft expiry, or an already-Approved re-expiry). Inherited by `GovernorParameters` and `GovernorEmergency`, so `SyndicateGovernor` gets it through both. |
| `src/GovernorParameters.sol` | Abstract. Extends `ProposalLifecycle`. **Per-vault, vault-owner-instant** parameter setters with hardcoded bounds, frozen while a proposal is open (`whenNoActiveProposal`, inherited from the base); emits a uniform `ParameterChangeFinalized(key, old, new)`. No onchain timelock — the vault owner is a multisig that enforces its own delay. |
| `src/GovernorEmergency.sol` | Abstract. Extends `ProposalLifecycle` and reads its proposal/registry storage directly. Emergency-settle entrypoints: `unstick`, `emergencySettleWithCalls`, `cancelEmergencySettle`, `finalizeEmergencySettle`. Emergency review state lives in the registry. |
| `src/GovernorBeacon.sol` | Thin `UpgradeableBeacon` holding the shared `SyndicateGovernor` implementation for every per-vault governor proxy. `upgradeTo(newImpl)` mass-upgrades all vault governors atomically; owner is the factory-owner multisig. |
| `src/ProtocolConfig.sol` | Plain `Ownable2Step`. Protocol-wide settlement config shared by all per-vault governors; read once at propose time and snapshotted into the proposal. Holds the two fee recipients (protocol, guardian network), the protocol-wide `maxStrategyDuration` clamp, and the two splits of the two-number model — `mgmtSplit` (agent/protocol/guardian) and `perfSplit` (agent/protocol/guardian/owner), each required to sum to 10 000 bps and seeded at construction with the launch values (60/20/20 and 50/15/25/10). It sets **no fee rates** — those live on the vault and the per-vault governor. Not upgradeable: replacement is a fresh deploy plus `setProtocolConfig`, which snapshotting makes safe for in-flight proposals. |
| `src/FeeConstants.sol` | Single source of truth for the protocol-wide fee ceilings and the bps denominator: `MAX_PERFORMANCE_FEE_BPS` (25%, the outer bound governance can ever reach), `DEFAULT_MAX_PERFORMANCE_FEE_BPS` (20%, the advertised headline a new vault starts with), `DEFAULT_AGENT_FEE_BPS` (20%). |
| `src/GuardianRegistry.sol` | UUPS. Guardian review / emergency-review lifecycle and the slash-appeal reserve. Holds zero assets — reads vote weight from sWOOD and calls sWOOD to slash. Computes the graduated (stake-weighted-median) voted slash severity. `reviewPeriod` is governance-set between a per-deployment immutable floor (6h on mainnet) and a 7-day ceiling. |
| `src/StakedWood.sol` | UUPS. Sole WOOD custodian for the guardian layer: guardian stake, owner bonds, checkpointed age-weighted vote weight, slashing + burn. Non-transferable vote-escrow — no ERC-20 transfer surface. (DPoS delegation removed/postponed 2026-07-26.) |
| `src/SyndicateFactory.sol` | UUPS. Deploys each vault as an immutable ERC-1967 proxy in one tx, plus a per-vault governor (`BeaconProxy` off the shared `beacon`), registers its ENS subname via the Durin L2 Registrar and its withdrawal queue, and binds the owner stake. Exposes `governorOf(vault)`. Holds the protocol-wide `managementFeeBps` (hard cap `MAX_MANAGEMENT_FEE_BPS = 300`, i.e. 3%) that each new vault is seeded with. The governor `beacon`, `protocolConfig`, and guardian registry are set-once at init; a protocol-wide governor upgrade is one `beacon.upgradeTo(newImpl)`. |
| `src/BatchExecutorLib.sol` | Stateless batch executor. Vaults delegatecall it to run protocol calls as themselves. The vault pins the executor codehash at init and reverts on drift. |
| `src/StrategyFactory.sol` | Atomic clone + initialize for strategy templates — closes the front-run window on separate `clone` / `initialize` txs. Templates gated by an owner allowlist; callers gated to the vault owner / registered agents. |

### Guardian economic security

Bonded, dollar-denominated accountability for the guardians who approve a proposal.
Design paper: [`docs/papers/guardian-network-economic-security.md`](docs/papers/guardian-network-economic-security.md).

| Contract | Description |
|----------|-------------|
| `src/ExposureLedger.sol` | Dollar-denominated coverage accounting. Converts each guardian's sWOOD stake into a haircut USD `slashableBond`, tracks per-epoch committed coverage, and freezes the coverage backing a challenged proposal. Epoch length is immutable (28d initial); the WOOD→USD price is a conservative governance-set 8-decimal value. |
| `src/ProposerBondEscrow.sol` | Holds the risk-scaled proposer bond for the lifetime of a proposal — the proposer is the actual attacker in the threat model, so it posts capital scaled to what the proposal can extract. Accepts forfeitures only from the ledger's `coverageFreezer`. |
| `src/ChallengeGame.sol` | Anyone may post a bonded challenge against an executed proposal, citing one of five predicates plus an evidence pointer. Filing freezes the approvers' committed coverage. Guardians counter-bond within `autoSlashDelay` (hard floor 48h), or silence becomes a slash. |
| `src/TokenCourt.sol` | Single-layer WOOD-vote adjudication of *disputed* challenges. One referral opens one vote window (`MAX_VOTE_WINDOW = 14 days`), one tally against a participation floor produces the verdict. No panel, no appeal, no bad-faith track. |
| `src/TierRegistry.sol` | Adapter-selector tier certification: tier is a property of `(target, selector)`, set at listing by governance and consumed at propose/execute time. Also holds the owner-managed adapter allowlist that `SyndicateVault._guardBatchCalls` checks for the spender/recipient of value-moving ERC-20 calls inside a governor batch. |

### Pricing (Lane A) & queue (Lane B)

| Contract | Description |
|----------|-------------|
| `src/pricing/PriceRouter.sol` | UUPS, governance-owned. Prices a strategy's reported `positions()` per position `kind` via registered adapters, with a monotone haircut, an instant-size cap, and a per-kind `laneAEnabled` flag. Fail-closed → `(0, false)` → Lane B. **Currently inert:** no adapter is registered and no surviving strategy overrides `positions()`, so `valueStrategy` short-circuits on the empty array and every vault takes Lane B. Onboarding a new adapter: [`docs/adapter-onboarding-checklist.md`](docs/adapter-onboarding-checklist.md). |
| `src/queue/VaultWithdrawalQueue.sol` | Per-vault async request queue. Escrows redeem shares / deposit assets while a proposal is live; at settlement the vault stamps one frozen price per proposal and every request claims at that single realized price. |

### Strategy templates (`src/strategies/`)

ERC-1167 clonable. The vault calls `execute()` / `settle()` via batch; `positions()`
reports on-venue holdings for vault-side pricing (the base returns an empty array =
Lane B only, and no current template overrides it).

| Template | Venue |
|----------|-------|
| `BaseStrategy.sol` | Abstract base (custody, state machine, proposer-tunable params) |
| `PortfolioStrategy.sol` | Weighted basket of tokens (e.g. tokenized stocks on Robinhood Chain) — buys to target weights on execute, sells out on settle, rebalanceable by the proposer (sell-all/re-buy or delta-based off Chainlink Data Streams) |

### Swap adapters (`src/adapters/`)

`ISwapAdapter` implementations that strategies route trades through.

| Adapter | Venue |
|----------|-------|
| `UniswapSwapAdapter.sol` | Uniswap V3 (single/multi-hop) and V4 (single-hop, hookless) |
| `SynthraSwapAdapter.sol` | Synthra DEX on Robinhood Chain (V3-compatible, 0.1% treasury fee deducted from swaps) |
| `SynthraDirectAdapter.sol` | Synthra V3 pools directly, bypassing the router's CREATE2 pool derivation |

### Vesting (`src/vesting/`)

Independent of the syndicate machinery — team/contributor token grants.

| Contract | Description |
|----------|-------------|
| `TokenVesting.sol` | ERC-1167 clonable, cancelable linear ERC-20 vesting with optional retroactive cliff. Schedule is immutable after `initialize`; the owner's only power is `cancel()`, and only when the wallet was created cancelable. |
| `VestingFactory.sol` | Permissionless and unowned. Deploys, initializes, and funds a clone atomically — whoever creates a wallet funds it and names its owner. |

## Key concepts

- **Optimistic governance** — proposals pass by default when voting ends; only rejected
  if AGAINST votes reach `vetoThresholdBps` (bounded 20–50%). Vote weight comes from
  `ERC20Votes` timestamp checkpoints. One strategy live per vault at a time.
- **Per-vault governance** — every vault gets its own governor (`BeaconProxy`, resolved
  via `factory.governorOf(vault)`); that vault's owner sets its governance parameters
  instantly, frozen while a proposal is open (`whenNoActiveProposal`). Fee splits live
  in the shared `ProtocolConfig` and are snapshotted onto each proposal at propose time
  (never read live at settle). A protocol-wide governor upgrade is a single
  `beacon.upgradeTo(newImpl)`.
- **Two-number fees** — depositors see two charges; everyone who earns is paid out of
  them through governance-set splits that must each sum to 10 000 bps.

  | Fee | Base | Rate source | Ceiling | Charged | Split |
  |---|---|---|---|---|---|
  | Management | fund assets × time deployed | `vault.managementFeeBps()`, seeded from `factory.managementFeeBps` | `MAX_MANAGEMENT_FEE_BPS` = 3%/yr (`Deploy.s.sol` seeds 2%, testnet 0.5%) | **every** settlement — profit, flat or loss | agent 60 / protocol 20 / guardian 20 |
  | Performance | value above the fund's previous **peak** price per share | `vault.agentFeeBps()` (default 20%), clamped at propose to the governor's `maxPerformanceFeeBps` | per-vault cap defaults to 20%; hard protocol ceiling 25% | profitable settlements only | agent 50 / protocol 15 / guardian 25 / owner 10 |

  Each fee is one division of one base, not a waterfall — no recipient's share is
  reduced by another's. The high-water mark ratchets up only, so a fund that falls
  and recovers is never charged twice on the same dollars. Order is load-bearing:
  the management fee is charged first (it lowers price per share), then the mark is
  compared, then performance. Accrual runs only while a strategy is live; capital
  idle between proposals is free. Instant (Lane A) exits crystallize their accrued
  fees on the way out so exit timing is fee-neutral, and may additionally pay an
  early-exit penalty (`MAX_INSTANT_EXIT_FEE_BPS` = 2%, charged only on the portion
  that exceeds idle float and must be pulled back from the strategy) that accrues to
  the depositors who stay. Full detail:
  [`openspec/specs/management-fee/spec.md`](openspec/specs/management-fee/spec.md),
  [`openspec/specs/performance-fee/spec.md`](openspec/specs/performance-fee/spec.md),
  [`openspec/specs/instant-exit-fees/spec.md`](openspec/specs/instant-exit-fees/spec.md), and
  [`openspec/specs/fee-splits/spec.md`](openspec/specs/fee-splits/spec.md).
- **Guardian review** — a `GuardianReview` window (24h on the current testnet deploy)
  sits between `Pending` and `Approved`. Guardians stake WOOD (in sWOOD) and review
  calldata; a block quorum rejects the proposal and slashes approvers (WOOD burned).
  Slash severity is a stake-weighted median of blockers' proposed `slashBps`.
- **Bonded approval** — approving a proposal commits a guardian's dollar coverage in
  `ExposureLedger`, and the proposer posts a risk-scaled bond in `ProposerBondEscrow`.
  A bonded challenge in `ChallengeGame` freezes that coverage; silence auto-slashes,
  and a counter-bond sends the dispute to `TokenCourt` for a single WOOD vote.
- **Two-lane liquidity** — while a proposal is live the vault is not instant against
  float. **Lane A** is oracle-instant entry/exit, available only when the
  `PriceRouter` prices the active strategy's positions within its gates (per-share
  lockup until settle). **Lane B** is the universal async queue with one frozen
  per-proposal settle price. Everything fails closed to Lane B — and with no adapters
  registered today, every vault is Lane B in practice.
- **First-depositor / inflation protection** — dynamic `_decimalsOffset()` = the
  asset's decimals, scaling the ERC-4626 virtual-shares defense to any denomination.
- **Transient reentrancy guards** — `ReentrancyGuardTransient` (EIP-1153) across the
  vault, registry, queue, and strategies.
- **Delegatecall containment** — the vault only delegatecalls `BatchExecutorLib` and
  `SyndicateVaultAdminLib`; the executor is enforced by a codehash pin stamped at init
  (`ExecutorCodehashMismatch` on drift).
- **Upgradeability** — factory / registry / sWOOD / router / ledger / vault-impl are
  UUPS proxies; each per-vault **governor is a `BeaconProxy`** (protocol-wide upgrade
  via `beacon.upgradeTo`). Never reorder storage slots; append only and shrink the
  `__gap`. Layout goldens live in `script/*.golden.json`, checked by
  `script/check-layout-goldens.sh`.

## Directory layout

```
src/            Contracts (core, strategies/, pricing/, queue/, adapters/, vesting/, interfaces/, libraries/)
test/           Foundry tests (unit + fork/integration under test/integration/, plus invariants/, mocks/)
script/         Deploy + admin scripts (inherit script/ScriptBase.sol) and storage-layout goldens
openspec/       Executable specs (openspec/specs/) and in-flight change proposals (openspec/changes/)
chains/         Per-chain deployed addresses, {chainId}.json (auto-written by deploy scripts)
docs/           Operator docs (adapter onboarding checklist, pre-deployment parameter review) and design papers (docs/papers/)
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
`SYNDICATE_FACTORY`, `GOVERNOR_BEACON`, `PROTOCOL_CONFIG`, `STRATEGY_FACTORY`,
`GUARDIAN_REGISTRY`, `STAKED_WOOD`, `PRICE_ROUTER`, …); admin scripts read the same
JSON. `chains/8453.json` and `chains/84532.json` are a **legacy Base deployment** that
predates the guardian economic-security stack, not a current target.

Protocol-wide settlement config (`ProtocolConfig.setMgmtSplit(...)`,
`setPerfSplit(...)`, `setMaxStrategyDuration(...)`, and the two fee recipients) is set
by the `ProtocolConfig` owner multisig; the management-fee rate new vaults inherit is
set on `SyndicateFactory`; per-vault governance parameters are set on each vault's
governor by that vault's owner.

## Docs

Full protocol, governance, and integration documentation: **https://docs.sherwood.sh/**
