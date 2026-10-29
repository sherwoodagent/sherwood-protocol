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
| `src/SyndicateVault.sol` | ERC-4626 vault + `ERC20Votes` for governance snapshots. The onchain identity — holds every position. Instant deposits and exits against float while no proposal is open; from `propose` until the proposal settles or ends, instant deposit, withdraw and redeem are closed and LPs use the async queue (`requestDeposit` / `requestRedeem`). Strategy execution runs only through the governor via `executeGovernorBatch` (delegatecall to the executor lib); no arbitrary-calldata owner entrypoint. |
| `src/SyndicateVaultAdminLib.sol` | Cold-path admin logic (depositor whitelist + agent management) extracted from the vault and delegatecalled, to free EIP-170 runtime headroom. |
| `src/SyndicateGovernor.sol` | Proposal lifecycle: propose → vote → guardian review → execute → settle. **One governor per vault**, deployed by the factory as a `BeaconProxy` and resolved via `factory.governorOf(vault)`. Optimistic voting, collaborative (multi-agent) proposals, permissionless settlement, P&L from balance-snapshot diffs. Settlement charges the two-number fee model: an always-on management fee off the vault's asset-seconds accumulator, then a performance fee on value above the high-water mark, each divided by the splits snapshotted from `ProtocolConfig` at propose time. Inherits `GovernorParameters` + `GovernorEmergency`. |
| `src/ProposalLifecycle.sol` | Abstract. Owns the proposal lifecycle (propose → vote → guardian review → execute → settle) and its storage. One resolver, `_computeState`, backs the **true view** `stateOf(pid)` — it reports Approved/Rejected/Expired as soon as they are determinable, instead of lagging until a transaction pokes it. `_transition` is the **only** writer of `proposal.state`; `_commitState` persists a transition and fires the registry's economic commit exactly when a guardian review concluded (never for a veto-rejection, a Draft expiry, or an already-Approved re-expiry). Inherited by `GovernorParameters` and `GovernorEmergency`, so `SyndicateGovernor` gets it through both. |
| `src/GovernorParameters.sol` | Abstract. Extends `ProposalLifecycle`. **Per-vault, vault-owner-instant** parameter setters with hardcoded bounds, frozen while a proposal is open (`whenNoActiveProposal`, inherited from the base); emits a uniform `ParameterChangeFinalized(key, old, new)`. No onchain timelock — the vault owner is a multisig that enforces its own delay. |
| `src/GovernorEmergency.sol` | Abstract. Extends `ProposalLifecycle` and reads its proposal/registry storage directly. Emergency-settle entrypoints: `unstick`, `emergencySettleWithCalls`, `cancelEmergencySettle`, `finalizeEmergencySettle`. Emergency review state lives in the registry. |
| `src/GovernorBeacon.sol` | Thin `UpgradeableBeacon` holding the shared `SyndicateGovernor` implementation for every per-vault governor proxy. `upgradeTo(newImpl)` mass-upgrades all vault governors atomically; owner is the factory-owner multisig. |
| `src/ProtocolConfig.sol` | Plain `Ownable2Step`. Protocol-wide settlement config shared by all per-vault governors; read once at propose time and snapshotted into the proposal. Holds the two fee recipients (protocol, guardian network), the protocol-wide `maxStrategyDuration` clamp, and the two splits of the two-number model — `mgmtSplit` (agent/protocol/guardian) and `perfSplit` (agent/protocol/guardian/owner), each required to sum to 10 000 bps and seeded at construction with the launch values (60/20/20 and 50/15/25/10). It sets **no fee rates** — those live on the vault and the per-vault governor. Not upgradeable: replacement is a fresh deploy plus the factory's `setProtocolConfig`, which snapshotting makes safe for in-flight proposals, and which reaches only governors created afterwards (no factory path re-points a live governor's config). |
| `src/FeeConstants.sol` | Single source of truth for the protocol-wide fee ceilings and the bps denominator: `MAX_PERFORMANCE_FEE_BPS` (25%, the outer bound governance can ever reach), `DEFAULT_MAX_PERFORMANCE_FEE_BPS` (20%, the per-vault cap a new vault starts with), `DEFAULT_AGENT_FEE_BPS` (20%). |
| `src/GuardianRegistry.sol` | UUPS. Guardian review / emergency-review lifecycle and the slash-appeal reserve. Holds no guardian stake — reads vote weight from sWOOD and calls sWOOD to slash; its only WOOD is the owner-funded slash-appeal reserve. Computes the deterministic slash severity (`_severityBps`, not voted). `reviewPeriod` is governance-set between a per-deployment immutable floor (`minReviewPeriod`, 30 min on mainnet) and a 3-day ceiling. |
| `src/StakedWood.sol` | UUPS. Sole WOOD custodian for the guardian layer: guardian stake, owner bonds, checkpointed age-weighted vote weight, slashing + burn. Non-transferable vote-escrow — no ERC-20 transfer surface. (DPoS delegation deferred to v2 on 2026-07-26 and removed from the code on 2026-07-27, #29.) |
| `src/SyndicateFactory.sol` | UUPS. Deploys each vault as an ERC-1967 proxy in one tx, plus a per-vault governor (`BeaconProxy` off the shared `beacon`), records its subdomain in the factory's `subdomainToSyndicate` map (the Durin ENS registrar is retired) and its withdrawal queue, and binds the owner stake. The vault is UUPS, upgradeable only by its creator through `upgradeVault` and only while the factory owner has set `upgradesEnabled` (false on 4663). Exposes `governorOf(vault)`. Holds the protocol-wide `managementFeeBps` (hard cap `MAX_MANAGEMENT_FEE_BPS = 300`, i.e. 3%) that each new vault is seeded with. The guardian registry is set once at init; `setBeacon` and `setProtocolConfig` re-point only what governors created afterwards use. A protocol-wide governor upgrade is one `beacon.upgradeTo(newImpl)`. |
| `src/BatchExecutorLib.sol` | Stateless batch executor. Vaults delegatecall it to run protocol calls as themselves. The vault pins the executor codehash at init (re-pinned only by the factory's `pushExecutor`) and reverts on drift. |
| `src/StrategyFactory.sol` | Atomic clone + initialize for strategy templates — closes the front-run window on separate `clone` / `initialize` txs. Templates gated by an owner allowlist; cloning is permissionless, and the named proposer must be the caller. |

### Guardian economic security

Bonded accountability, booked in WOOD, for the guardians who approve a proposal.
Design paper: [`docs/papers/guardian-network-economic-security.md`](docs/papers/guardian-network-economic-security.md).

| Contract | Description |
|----------|-------------|
| `src/ExposureLedger.sol` | WOOD-denominated coverage accounting. An approving guardian declares a WOOD amount and the ledger locks `min(declared, k × slashable stake − open exposure)`: one figure that is its booking, its pledge and the base a conviction burns. Tracks per-epoch exposure and freezes the locks backing a challenged proposal. USD enters only at the covered-TVL cap, the proposer bond, the approve-time slot floor, the execute-time quorum and the liability views. Epoch length is immutable (7 d on 4663); WOOD is priced by its market feed, capped by the governance-set 8-decimal `woodUsdPriceX8` and haircut (`woodPriceX8`). Plain `Ownable2Step`, not upgradeable. |
| `src/ProposerBondEscrow.sol` | Holds the risk-scaled proposer bond for the lifetime of a proposal — the proposer is the actual attacker in the threat model, so it posts capital scaled to what the proposal can extract. Accepts forfeitures only from the ledger's `coverageFreezer`. |
| `src/ChallengeGame.sol` | Anyone may post a bonded challenge against an executed proposal, citing one of five predicates plus an evidence pointer. Filing freezes the approvers' locks. Anyone may fund the proposal's counter-bond pool within `autoSlashDelay` (7 d default, hard floor 48h); a pool completed in time disputes the challenge and sends it to `TokenCourt`. Otherwise silence convicts once anyone calls `resolve` before `disputeTimeout` (30 d). A conviction burns the approvers' locks, the completed pool, and the proposer's bond less a prosecutor fee. Filing is paused on 4663 (`filingsPaused() == true`). |
| `src/TokenCourt.sol` | Single-layer WOOD-vote adjudication of *disputed* challenges. One referral opens one vote window (`MAX_VOTE_WINDOW = 14 days`; 5 days live), one tally against a participation floor produces the verdict. Only a challenge that pinned a court at filing can be referred. The accused, the challenger, the bonded proposer and every counter-bond contributor are barred from voting. No panel, no appeal, no bad-faith track. |
| `src/TierRegistry.sol` | Adapter-selector tier certification: tier is a property of `(target, selector)`, set at listing by governance and consumed at propose/execute time. Also holds the owner-managed counterparty allowlist that strategy templates (`MorphoSupplyStrategy`, `ConcentratedLiquidityStrategy`) check when they bind, and points at the `StrategyFactory` that `SyndicateVault._guardBatchCalls` reads: every non-asset call in a governor batch must target a strategy that factory registered, and asset calls must pass `AssetCallRules`. |

### Pricing & queue

| Contract | Description |
|----------|-------------|
| `src/pricing/WoodV3TwapFeed.sol`, `src/pricing/WoodPoolFeed.sol` | WOOD/USD sources on the `AggregatorV3` surface (8 decimals) for `ExposureLedger.woodPriceX8`. On 4663 the ledger reads `WoodV3TwapFeed` (`WOOD_USD_TWAP_FEED`, `maxDelay` 1h); the booked `WOOD_USD_FEED` (`WoodPoolFeed`) is retired and its `latestRoundData()` reverts `PriceUnavailable`. `PriceRouter` and Lane A are gone on this line (issue #54): no vault prices a live strategy's positions, so there are no oracle-instant entries or exits. |
| `src/queue/VaultWithdrawalQueue.sol` | Per-vault async request queue. Escrows redeem shares / deposit assets while a proposal is open. At settlement the vault stamps one frozen price per proposal and every redeem tagged to it claims at that price; a deposit claims at the live price once no proposal is open. A redeem tagged to a proposal that ends without settling is never stamped and can only be cancelled. |

### Strategy templates (`src/strategies/`)

ERC-1167 clonable. The vault calls `execute()` / `settle()` via batch. There is no
`positions()` hook: with Lane A retired, the vault never prices a live strategy.

| Template | Venue |
|----------|-------|
| `BaseStrategy.sol` | Abstract base (custody, state machine, proposer-tunable params) |
| `PortfolioStrategy.sol` | Weighted basket of tokens (e.g. tokenized stocks on Robinhood Chain) — buys to target weights on execute, sells out on settle, drift-only `rebalanceDelta()` off the aggregators bound at init |
| `MorphoSupplyStrategy.sol` | Supplies the vault asset to one Morpho Blue market fixed at init; settle withdraws the whole position |
| `ConcentratedLiquidityStrategy.sol` | Concentrated liquidity over a bounded tick range in one Uniswap V3 pool, funded by borrowing the vault asset against stable collateral |

### Swap adapters (`src/adapters/`)

`ISwapAdapter` implementations that strategies route trades through.

| Adapter | Venue |
|----------|-------|
| `UniswapSwapAdapter.sol` | Uniswap V3 (single-hop) and V4 (single- and multi-hop, hookless); the V3 multi-hop mode is retired |

The Synthra adapters (`SynthraSwapAdapter`, `SynthraDirectAdapter`) are not on this
line; Uniswap is the only swap adapter.

### Vesting (`src/vesting/`)

Independent of the syndicate machinery — team/contributor token grants.

| Contract | Description |
|----------|-------------|
| `TokenVesting.sol` | ERC-1167 clonable, cancelable linear ERC-20 vesting with optional retroactive cliff. Schedule is immutable after `initialize`; the owner's only power is `cancel()`, and only when the wallet was created cancelable. |
| `VestingFactory.sol` | Permissionless and unowned. Deploys, initializes, and funds a clone atomically — whoever creates a wallet funds it and names its owner. |

## Key concepts

- **Optimistic governance** — proposals pass by default when voting ends; only rejected
  if AGAINST votes reach `vetoThresholdBps` (bounded 20–80%). Vote weight comes from
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
  | Management | fund assets × time deployed | `vault.managementFeeBps()`, seeded from `factory.managementFeeBps` | `MAX_MANAGEMENT_FEE_BPS` = 3%/yr (4663 seeds 2%) | **every** settlement — profit, flat or loss | agent 60 / protocol 20 / guardian 20 |
  | Performance | value above the fund's previous **peak** price per share | `vault.agentFeeBps()` (default 20%), clamped to the governor's `maxPerformanceFeeBps` at propose and again at settle | per-vault cap defaults to 20%; hard protocol ceiling 25% | profitable settlements only | agent 50 / protocol 15 / guardian 25 / owner 10 |

  Each fee is one division of one base, not a waterfall — no recipient's share is
  reduced by another's. The high-water mark ratchets up only, so a fund that falls
  and recovers is never charged twice on the same dollars. Order is load-bearing:
  the management fee is charged first (it lowers price per share), then the mark is
  compared, then performance. Accrual runs only while a strategy is live; capital
  idle between proposals is free. There is no early-exit fee: instant exits while a
  strategy is live, their fee crystallisation and their penalty were retired with
  Lane A, so an LP exits a live strategy only through the queue at its settle price.
  Full detail:
  [`openspec/specs/management-fee/spec.md`](openspec/specs/management-fee/spec.md),
  [`openspec/specs/performance-fee/spec.md`](openspec/specs/performance-fee/spec.md), and
  [`openspec/specs/fee-splits/spec.md`](openspec/specs/fee-splits/spec.md).
- **Guardian review** — a `GuardianReview` window (24 h seed, 30 min live on 4663)
  sits between `Pending` and `Approved`. Guardians stake WOOD (in sWOOD) and review
  calldata; a block quorum rejects the proposal and slashes approvers (WOOD burned,
  never less than `minSlashBps` of each approver's stake).
  Slash severity is deterministic: a quadratic ramp of block-side decisiveness
  from the at-open quorum to a 2/3 supermajority (`_severityBps`), not voted.
- **Bonded approval** — approving a proposal locks WOOD against the guardian's stake in
  `ExposureLedger` (the lock is what a conviction burns), and the proposer posts a
  risk-scaled bond in `ProposerBondEscrow`. A bonded challenge in `ChallengeGame`
  freezes those locks. Silence convicts once anyone calls `resolve` before the dispute
  timeout; a counter-bond pool completed in time sends the dispute to `TokenCourt`
  for a single WOOD vote. A conviction burns the locks (each at least `minSlashBps`
  of the approver's stake), the pool, and the proposer's bond less a prosecutor fee.
- **Liquidity** — instant against float while no proposal is open. From `propose`
  until the proposal settles or ends, instant deposit and exit are closed and every
  vault uses the async queue, with one frozen per-proposal settle price for redeems.
  Lane A (oracle-instant entry/exit priced by `PriceRouter`) was retired; the queue
  is the only path while a proposal is open.
- **First-depositor / inflation protection** — dynamic `_decimalsOffset()` = the
  asset's decimals, scaling the ERC-4626 virtual-shares defense to any denomination.
- **Transient reentrancy guards** — `ReentrancyGuardTransient` (EIP-1153) in the
  vault, queue, sWOOD, and the Portfolio and ConcentratedLiquidity strategies.
- **Delegatecall containment** — the vault only delegatecalls `BatchExecutorLib` and
  `SyndicateVaultAdminLib`; the executor is enforced by a codehash pin stamped at init
  (`ExecutorCodehashMismatch` on drift).
- **Upgradeability** — factory / registry / sWOOD / vaults are UUPS proxies (a vault
  upgrades only through `factory.upgradeVault`, gated by `upgradesEnabled`); the
  ledger, game, court, tier registry and `ProtocolConfig` are plain `Ownable2Step`,
  replaced by redeploy; each per-vault **governor is a `BeaconProxy`** (protocol-wide upgrade
  via `beacon.upgradeTo`). Never reorder storage slots; append only and shrink the
  `__gap`. Layout goldens live in `script/*.golden.json`, checked by
  `script/check-layout-goldens.sh`.

## Directory layout

```
src/            Contracts (core, strategies/, pricing/, queue/, adapters/, vesting/, interfaces/, vendor/)
test/           Foundry tests (unit + fork/integration under test/integration/, plus invariants/, mocks/)
script/         Deploy + admin scripts (inherit script/ScriptBase.sol) and storage-layout goldens
openspec/       Executable specs (openspec/specs/) and in-flight change proposals (openspec/changes/)
chains/         Per-chain deployed addresses, {chainId}.json (auto-written by deploy scripts)
docs/           Operator docs (adapter onboarding checklist, pre-deployment parameter review) and design papers (docs/papers/)
lib/            Vendored deps (forge-std, OpenZeppelin, OpenZeppelin-upgradeable, eas-contracts)
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

Sherwood is deployed on **Robinhood Chain mainnet (chain 4663)**; `chains/9994663.json`
is the fork book. Deploy scripts write resolved addresses to `chains/{chainId}.json`
(CAPS_SNAKE_CASE keys —
`SYNDICATE_FACTORY`, `GOVERNOR_BEACON`, `PROTOCOL_CONFIG`, `STRATEGY_FACTORY`,
`GUARDIAN_REGISTRY`, `STAKED_WOOD`, `EXPOSURE_LEDGER`, `CHALLENGE_GAME`, …); admin
scripts read the same JSON. The legacy Base books (`chains/8453.json`,
`chains/84532.json`) and the `PRICE_ROUTER` key are not on this line.

Protocol-wide settlement config (`ProtocolConfig.setMgmtSplit(...)`,
`setPerfSplit(...)`, `setMaxStrategyDuration(...)`, and the two fee recipients) is set
by the `ProtocolConfig` owner multisig; the management-fee rate new vaults inherit is
set on `SyndicateFactory`; per-vault governance parameters are set on each vault's
governor by that vault's owner.

## Docs

Full protocol, governance, and integration documentation: **https://docs.sherwood.sh/**

## License

MIT. See [LICENSE](./LICENSE).
