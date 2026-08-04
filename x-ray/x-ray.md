# X-Ray Report

> Sherwood Protocol | 8894 nSLOC | `8b82598` (`main`) | Foundry | 04/08/26

---

## 1. Protocol Overview

**What it does:** AI agents propose pre-committed trading strategies for ERC-4626 syndicate vaults; shareholders vote optimistically, staked-WOOD guardians underwrite the execution with slashable bonds, and anyone can bond-file a challenge afterwards to slash the approvers.

- **Users**: LP depositors (capital), agents (strategy proposers), guardians (stake WOOD, review proposals, absorb slash), challengers (bond WOOD to accuse), vault owners (per-vault governance), protocol admin (wiring + parameters).
- **Core flow**: agent proposes a batch of calls → shareholders vote (veto-threshold, not FOR-quorum) → guardians review and book USD coverage against their bond → `executeProposal` dispatches the batch through the vault under coverage-scaled per-call caps → `settleProposal` runs the pre-committed closing batch and charges fees.
- **Key mechanism**: optimistic governance over pre-committed call batches, collateralized by a USD-denominated guardian coverage ledger and priced by a challenge game whose only enforcement is economic.
- **Token model**: WOOD (governance/stake, external ERC-20), sWOOD (`StakedWood` — sole custodian of guardian stake and vault-owner bonds; non-transferable, checkpointed for vote weight), vault shares (ERC-4626 + ERC20Votes).
- **Admin model**: `SyndicateFactory` owner (protocol admin) deploys and wires everything; each of `ExposureLedger`, `ChallengeGame`, `TierRegistry`, `TokenCourt`, `ProtocolConfig`, `WoodTwapOracle` carries its own `Ownable`/`Ownable2Step` owner with instant setters. Per-vault governance belongs to the vault owner, expected off-chain to be a multisig — there is no on-chain timelock on the operational surface.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault | SyndicateVault, SyndicateVaultAdminLib, BatchExecutorLib, VaultWithdrawalQueue | 935 | ERC-4626 vault, async deposit/redeem queue, stateless delegatecall batch executor |
| Governance | SyndicateGovernor, GovernorParameters, GovernorEmergency, GovernorBeacon, ProposalLifecycle | 1298 | Proposal state machine, voting, execution, settlement, fee distribution, emergency unwind |
| Factory & Config | SyndicateFactory, ProtocolConfig, FeeConstants | 493 | Deploys vault/governor/queue triples; protocol-wide fee splits and ceilings |
| Guardian economics | GuardianRegistry, StakedWood, ExposureLedger, ProposerBondEscrow | 1927 | Guardian review + slash, WOOD custody, USD coverage accounting, proposer bonds |
| Dispute | ChallengeGame, TokenCourt, TierRegistry | 1023 | Bonded challenges, WOOD-weighted verdicts, call-tier certification and adapter allowlist |
| Strategies & routing | BaseStrategy, PortfolioStrategy, MorphoSupplyStrategy, StrategyFactory, UniswapSwapAdapter, SynthraSwapAdapter, SynthraDirectAdapter | 1246 | Strategy clone lifecycle and the DEX/lending adapters batches route through |
| Pricing | WoodTwapOracle, ChainlinkReader, LiquidityAmounts, TickMath | 466 | WOOD/USD TWAP with a Chainlink ETH leg; math helpers |
| Vesting | TokenVesting, VestingFactory | 153 | Standalone linear vesting wallets; no coupling to the rest of the protocol |

### How It Fits Together

**The core trick:** a proposal is not a permission to trade — it is a *priced* permission. The tier of every `(target, selector)` in the batch determines how much of the deployed capital counts as extractable; that number becomes a USD coverage requirement; guardians who approve book that USD against their own slashable WOOD bond. Execution is gated on enough coverage having been booked, and a challenger who later proves the extraction happened is paid out of the guardians' bond and the proposer's.

### Propose → Execute

```
Agent → SyndicateGovernor.propose(execCalls, execCaps, settleCalls, settleCaps, coProposers)
  ├─ SyndicateVault.isAgent(msg.sender)                    ← must be a registered agent
  ├─ _scanCalls → TierRegistry.tierOf(target, selector)    ← per-call tier + extractable bound
  │     └─ requiredCoverage = maxCapital × Σ boundBps / 10_000
  ├─ ExposureLedger.requireWithinCoveredTvlCap / requireWithinCoverageHorizon
  ├─ ProposerBondEscrow.lockBond(pid, proposer, bondWood)  ← pulls WOOD; escrow pinned on the proposal
  └─ GuardianRegistry.registerReview(pid, voteEnd, reviewEnd)

  [voting period — SyndicateGovernor.vote, ERC20Votes weight at snapshotTimestamp]
  [guardian review — GuardianRegistry.voteOnProposal → ExposureLedger.recordApproval]

Anyone → SyndicateGovernor.executeProposal(pid)
  ├─ re-resolve tier + coverage; revert on TierRegressed / CoverageRegressed
  ├─ _activeProposal = pid; proposal.executedAt = now   ← must precede the quorum gate (issue #35)
  ├─ ExposureLedger.requireApproveQuorum → effectiveMaxCapital
  ├─ _scaleCaps: Σ floor(cap_i × s) ≤ effectiveMaxCapital
  └─ SyndicateVault.executeGovernorBatch(calls, scaledCaps, maxNetOutflow)
        ├─ _guardBatchCalls: privileged-target screen + adapter allowlist
        └─ delegatecall → BatchExecutorLib.executeBatch   ← per-call gross-outflow metering
```

### Settle → Fee Distribution

```
Anyone → SyndicateGovernor.settleProposal(pid)
  ├─ SyndicateVault.executeGovernorBatch(settlementCalls, effectiveSettlementCaps)
  └─ _finishSettlement
        ├─ _chargeManagementFee   ← asset-seconds × managementFeeBps, profit-independent
        ├─ _chargePerformanceFee  ← high-water-mark gated
        │     └─ SyndicateVault.transferPerformanceFee(...)  per snapshotted split
        │           └─ on revert: escrow into _unclaimedFees, pull via claimUnclaimedFees
        ├─ SyndicateVault.onProposalSettled(pid)
        │     └─ VaultWithdrawalQueue.stampSettlement(pid, num, den)  ← freezes ONE price, post-fee
        └─ _activeProposal = 0; _decOpen()   ← cleared LAST, after every transfer (issue #181 #24)
```

### Two-Lane Liquidity

```
No proposal open (Lane A)                 Proposal open (Lane B)
  SyndicateVault.deposit/redeem             SyndicateVault.requestDeposit/requestRedeem
    └─ synchronous, live NAV                  └─ VaultWithdrawalQueue escrow
                                                   ├─ cancel()  ← owner only, pre-stamp
                                                   └─ claim()   ← anyone, at the frozen price
```

### Challenge → Slash

```
Challenger → ChallengeGame.file(pid, predicate, adapterTarget, selector, evidenceURI)
  ├─ bond = coverageUsd × challengerBondBps, pulled in WOOD
  └─ ExposureLedger.freezeCoverage(governor, pid)   ← locks every approver's stake

  ├─ [silence past autoSlashDelay] → resolve() → _settle
  └─ [dispute() funds counter-bond to target] → TokenCourt.refer
        └─ TokenCourt.vote (WOOD-weighted at executedAt-1) → finalize → ChallengeGame.rule
              ├─ Guilty     → _settle  → StakedWood.slashVerdict → burn
              │                        → ProposerBondEscrow.forfeitBond → fee + burn
              │                        → TierRegistry.demoteByChallenge (best-effort)
              ├─ NotGuilty  → _fail    → burn a slice of the challenger's bond
              └─ Inconclusive → _refundAll → escalating burn, re-arm the window
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator / Vault** with **Governance** and **Liquid Staking** characteristics

ERC-4626 share accounting, a strategy pattern with `execute`/`settle`, and `totalAssets()` put the primary weight on the vault profile. `propose`/`vote`/`execute` with snapshot voting power, a veto threshold, and a beacon-upgradeable per-vault governor add the governance profile. `StakedWood` is a stake-and-slash system with a withdrawal cooldown, checkpointed vote weight, and an age-weighting curve — liquid-staking threats apply to it even though no transferable derivative is minted.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Protocol admin (factory owner) | Trusted | 16 instant setters: vault + executor impls, beacon, `protocolConfig`, `guardianRegistry`, `tierRegistry`, `exposureLedger`, `bondEscrow`, management-fee cap, `upgradesEnabled`; plus `forceSetParams` on any governor and `pushExecutor`/`pushWiring`. No on-chain delay on any of it. |
| ExposureLedger owner | Trusted | 12 instant setters incl. `setWoodUsdPrice` (the cap every coverage number derives from), `setCoverageFreezer`, `setKNumerator`, `setCoveredTvlCapUsd`, `setChallengeWindow`. Not pausable. |
| ChallengeGame owner | Trusted | 13 instant setters incl. all five economic knobs (`settleBurnBps`, `forfeitBurnBps`, `inconclusiveBurnBps`, `challengerBondBps`, `prosecutorFeeBps`) and `setFilingsPaused`. `renounceOwnership` disabled. |
| StakedWood owner | Trusted | 10 instant setters incl. `setAuthorizedSlasher`, `setMinSlashBps`/`setMaxSlashBps`, `setAgeFloorBps`, `setCooldownPeriod`; also the UUPS upgrade authority over all guardian WOOD custody. |
| GuardianRegistry owner | Trusted | `setReviewPeriod`, `setBlockQuorumBps`, `setExposureLedger`, `pause`, `fundSlashAppealReserve`, `refundSlash`; UUPS upgrade authority. `unpause` becomes permissionless after `DEADMAN_UNPAUSE_DELAY`. |
| TierRegistry owner | Trusted | `proposeCertification` → `certify` behind a 1–30 day `certifyDelay`, but `setAdapterAllowed` and `demote` are **instant**. Ownable2Step. |
| Vault owner | Bounded (per-vault; cannot move assets except via rescue when unlocked) | 11 governance-param setters (frozen while a proposal is open), agent registry, depositor whitelist, pause, `setAgentFeeBps`, `setMinBufferBps`, `rescueEth`/`rescueERC20`/`rescueERC721` (blocked while redemptions locked), `vetoProposal`, `emergencyCancel`, and the whole `GovernorEmergency` unwind surface. |
| Agent (proposer) | Bounded (must be vault-registered; posts a WOOD bond per proposal) | `propose`, `cancelProposal` before `voteEnd`, `rejectCollaboration`; on a live strategy clone, `rebalance` / `rebalanceDelta` / `updateParams`. |
| Guardian | Bounded (stake is slashable; weight is age-floored and lookback-gated) | `voteOnProposal` (approve books USD coverage against their bond; block counts toward the veto quorum), `voteBlockEmergencySettle`. Cannot unstake while coverage is open or frozen. |
| LP / shareholder | Untrusted | Deposit/redeem (whitelist-gated unless `openDeposits`), vote on proposals by share weight, queue requests during a live proposal. |
| Challenger | Untrusted (bonded) | `file` against any executed proposal, `dispute` any live filing, `resolve`, `claimContribution`. |
| WOOD holder | Untrusted (weight snapshotted pre-execution) | `TokenCourt.vote` on disputed cases, unless accused or the challenger. |

**Adversary Ranking** (ordered by threat level for this protocol type, adjusted by git evidence):

1. **Compromised or coerced protocol admin** — five separately-owned contracts each expose instant, un-timelocked control over the numbers that price the entire economic-security layer.
2. **Malicious agent / proposer** — chooses every call in the batch, the adapters they route through, and the strategy clone, and is the party the whole coverage-and-challenge apparatus exists to bound.
3. **Colluding guardian cohort** — approvals are what unlock execution, and the same cohort's stake is the only collateral behind it.
4. **Griefing challenger** — filing is permissionless and freezes every approver's stake for the duration.
5. **Share-inflation / queue-timing attacker** — the async lane freezes one price per proposal, so every rounding or ordering asymmetry there is directly monetizable.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Protocol admin → every vault's assets** — `SyndicateFactory.setVaultImpl` + `upgradeVault` (creator-initiated, `upgradesEnabled`-gated) and `setExecutorImpl`/`pushExecutor` reach the delegatecall target of every vault; no timelock on the path. *Git signal: `SyndicateVault.sol` is the #1 hotspot at 35 modifications.*

- **StakedWood UUPS owner → all guardian WOOD** — `_authorizeUpgrade` is bare `onlyOwner` (`StakedWood.sol:1731`) on the sole custodian of every guardian stake and owner bond. The `Ownable2Step` used elsewhere in the codebase is not used here.

- **ExposureLedger owner → the price of all coverage** — `setWoodUsdPrice` is the cap in `min(marketSource, cap)` ([I-15](invariants.md#i-15)); lowering it deflates every guardian's `slashableBondUsd` and the batching cap with it, instantly.

- **Vault owner → per-vault governance** — 11 parameter setters are frozen while a proposal is open ([G-23](invariants.md#g-23)), which bounds mid-flight manipulation, but between proposals each is instant. The spec calls the owner *"a multisig expected to enforce its own external delay"* — nothing on-chain enforces that.

- **TierRegistry: two axes, two different delays** — certification runs `proposeCertification` → `certifyDelay` → `certify` ([I-39](invariants.md#i-39)), but `setAdapterAllowed` — the gate `SyndicateVault._guardBatchCalls` actually consults ([G-5](invariants.md#g-5)) — is instant.

- **ChallengeGame owner → the sign of the challenger's payoff** — five economic knobs, each bounded only against its own ceiling and none cross-checked against `honestFilingBreaksEven()` ([E-2](invariants.md#e-2)).

- **Governor → vault** — `executeGovernorBatch` is `onlyGovernor` and the vault re-screens every call target itself rather than trusting the governor's tier scan; `transferPerformanceFee` is the one path that moves assets out on the governor's word alone.

### Key Attack Surfaces

- **Cross-contract window couplings that fail open** &nbsp;&#91;[X-4](invariants.md#x-4), [X-3](invariants.md#x-3), [I-32](invariants.md#i-32)&#93; — `ExposureLedger.setChallengeWindow:1010-1041` mirrors both the registry and the game bounds inside `try … catch {}` gated on `code.length`, and `setCoverageFreezer:1052` may zero the freezer, vacating the second mirror entirely. Worth tracing which of the four checks is load-bearing when a counterparty is unset or reverting.

- **Queue reserve accounting uses saturating subtraction** &nbsp;&#91;[I-4](invariants.md#i-4), [G-2](invariants.md#g-2)&#93; — `queue/VaultWithdrawalQueue.sol:241` and `:246` clamp `_reservedAssets` and `_stampedUnclaimedShares` at zero rather than reverting, while `stampSettlement` accumulates them exactly. Worth confirming no claim ordering drives `release` above the aggregate.

- **Two definitions of "open exposure" feed the batching cap** &nbsp;&#91;[I-5](invariants.md#i-5), [I-6](invariants.md#i-6), [E-1](invariants.md#e-1)&#93; — `openExposureUsd:2625` walks at most `MAX_SCAN_BUCKETS = 16` epochs while `_liveBookedUsd` is exact and unbounded; `recordApproval:1318` gates on the bounded one. Worth checking a guardian's exposure profile once it spans more than 16 epochs.

- **Protocol-admin operational powers without timelock** — `SyndicateFactory` (16 setters), `ExposureLedger` (12), `ChallengeGame` (13), `StakedWood` (10), `GuardianRegistry` (6) all execute instantly, and several are UUPS upgrade authorities over live custody. Worth confirming which are intended to sit behind an off-chain multisig delay and whether any need an on-chain one.

- **Guardian slash accounting branches on unstake state** &nbsp;&#91;[I-3](invariants.md#i-3)&#93; — `StakedWood._slashOne:1665-1673` decrements `totalGuardianStake` only when `unstakeRequestedAt == 0`, and separately clears the request stamp when a slash empties the stake. Worth tracing the interleaving of `requestUnstakeGuardian`, `cancelUnstakeGuardian`, and a slash landing between them.

- **Five independent economic knobs decide whether anyone files** &nbsp;&#91;[I-13](invariants.md#i-13), [E-2](invariants.md#e-2)&#93; — the `inconclusiveBurnBps ≤ settleBurnBps` cross-check was deliberately removed (second-audit finding C); rounds 1–3 are still clamped inside `_inconclusiveBurnBpsForRound`, round 4+ is not. Worth confirming the honest-filer payoff stays positive across the full escalation ladder.

- **Adapter certification is blind to proxy upgrades** &nbsp;&#91;[X-9](invariants.md#x-9), [X-8](invariants.md#x-8)&#93; — `TierRegistry` pins `target.codehash`, which for a proxy never changes. The spec's answer is a governance rule, not code. Worth checking what happens if an allowlisted adapter is, or becomes, a proxy.

- **Registry ↔ ledger binding is checked in one direction** &nbsp;&#91;[X-10](invariants.md#x-10)&#93; — `GuardianRegistry.setExposureLedger:1284` verifies the ledger points back, but `ExposureLedger.setGuardianRegistry:948` has no reverse check. Worth tracing what a one-sided re-point does to in-flight approvals.

- **Slasher binding is not pinned per challenge** &nbsp;&#91;[X-11](invariants.md#x-11)&#93; — `StakedWood.setAuthorizedSlasher:1287` has no live-challenge guard, unlike `setCoverageFreezer` which refuses while anything is frozen ([G-35](invariants.md#g-35)). Worth confirming a mid-challenge rotation cannot leave a conviction half-applied.

- **`BatchExecutorLib` is an unowned contract with no access control** &nbsp;&#91;[G-1](invariants.md#g-1), [X-12](invariants.md#x-12)&#93; — `executeBatch` is callable directly by anyone; safety rests entirely on the vault having run `_guardBatchCalls` before delegatecalling, plus the codehash pin. An empty `caps` array disables per-call metering by design. Worth confirming no vault path reaches it with an empty `caps`.

- **`ChallengeGame._settle` makes five external calls to owner-repointable contracts** &nbsp;&#91;[I-20](invariants.md#i-20)&#93; — sWOOD, the ledger, the escrow, and the tier registry, with `try/catch` on some legs and not others. Worth mapping which legs may fail and what a partial settle leaves behind.

### Upgrade Architecture Concerns

- **Beacon upgrade is a fleet-wide operation** — `GovernorBeacon` (`UpgradeableBeacon`, `onlyOwner`) backs every per-vault `BeaconProxy` governor; one `upgradeTo` replaces the proposal state machine for every syndicate at once.

- **Four separate upgrade authorities over live custody** — `SyndicateFactory` (UUPS, `onlyOwner`), `SyndicateVault` (UUPS, `_authorizeUpgrade:1854` factory-only), `StakedWood` (UUPS, `onlyOwner`), `GuardianRegistry` (UUPS, `onlyOwner`), with no shared delay.

- **Storage-layout discipline is documentation, not code** — README states *"Never reorder storage slots; append only and shrink the `__gap`."* `SyndicateVault` carries `__gap[31]`, `SyndicateGovernor` `__gap[28]`, `GovernorParameters` `__paramsGap[6]`, `ProposalLifecycle` `__lifecycleGap[10]`, `GovernorEmergency` `__emergencyGap[10]`. CI runs a storage-layout gate; nothing on-chain enforces it.

- **Vault upgrade is creator-initiated but admin-controlled** — `SyndicateFactory.upgradeVault:801` requires `upgradesEnabled` (admin), `creator == msg.sender`, and `vaultImpl == expectedImpl`, so the admin chooses the code and the creator chooses the moment.

### Protocol-Type Concerns

**As a Yield Aggregator / Vault:**
- `SyndicateVault.totalAssets()` and `_stampMgmtBase` both go through `try this.totalAssets()` with a raw-balance fallback — worth confirming the fallback cannot understate the management-fee base while a strategy holds the assets.
- The high-water mark resets to zero on `totalSupply() == 0` ([I-18](invariants.md#i-18)) — worth tracing whether a full exit and re-entry can reset it deliberately.
- `_cachedDecimalsOffset` is captured at `initialize` from the asset's live `decimals()`; the ERC-4626 inflation defense depends on that one reading.

**As a Governance system:**
- Voting power comes from `IVotes.getPastVotes` at `proposal.snapshotTimestamp`, but the snapshot is written when the proposal reaches Pending — in the collaborative path that is `approveCollaboration:912`, not `propose`. Worth confirming the co-proposer quorum cannot be timed to pick a favourable snapshot.
- There is no FOR-quorum; a proposal passes unless AGAINST reaches `vetoThresholdBps`. Combined with a whitelist-gated depositor set, worth checking what share concentration the veto actually requires.

**As a Liquid Staking system:**
- `_slashableAt` uses `min(max(liabilityAt, votableAt), live)` across three separate `Checkpoints.Trace224` traces (`_stakeCheckpoints`, `_liabilityCheckpoints`, `_anchorCheckpoints`). Worth confirming the three cannot disagree at a boundary timestamp.
- Age-weighting ramps from `ageFloorBps` to par over `maturationPeriod`, and `stakeAsGuardian` re-anchors `stakedAt` by weighted average on a top-up — worth checking whether a large top-up dilutes an approaching slash anchor.

### Temporal Risk Profile

**Deployment & Initialization:**
- Cross-contract invariants are seated by setters that stay vacuous until both sides are wired ([X-1b](invariants.md#x-1b), [X-3](invariants.md#x-3)) — deployment order determines whether `coolDownPeriod ≥ reviewPeriod` and the challenge-window floors actually hold.
- `BaseStrategy` templates disable their own `initialize` in the constructor (`strategies/BaseStrategy.sol:87`) and `StrategyFactory` clones atomically, closing the classic clone front-run window ([I-24](invariants.md#i-24)).
- `SyndicateVault` seeds `_highWaterPricePerShare` on the first deposit into an empty vault; the first depositor sets the mark every later performance fee is measured against.

**Market Stress:**
- `WoodTwapOracle.consult()` fails to `(0, false)` rather than reverting ([I-34](invariants.md#i-34)); every consumer must handle a missing price, and `ExposureLedger` then falls back to the governance cap alone ([I-15](invariants.md#i-15)).
- `MorphoSupplyStrategy._settle` deliberately takes the market's deliverable maximum instead of reverting under high utilization, leaving a residue recoverable only via the permissionless `sweep()`.
- `SLASH_GAS_PER_APPROVER = 180_000` / `SLASH_GAS_BASE = 2_000_000` in `ChallengeGame` are sized against a 32M chain tx cap; a 100-approver cohort sits close to that ceiling.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Chainlink price feeds (WOOD/USD, per-asset)** — via `ExposureLedger._feedPriceX8`, `coverageUsd:1119`
> - Assumes: positive answer, `updatedAt` within the per-feed `maxDelay`, `decimals()` matching the value recorded at `setAssetFeed`
> - Validates: `f.feed == address(0) → FeedNotConfigured`, `age > f.maxDelay → StalePrice`, non-positive answer rejected
> - Mutability: Chainlink aggregator behind an upgradeable proxy, governed by Chainlink
> - On failure: WOOD leg falls back to the governance cap `woodUsdPriceX8` (fail-open to a cap); the per-asset coverage leg reverts (fail-closed)

> **Chainlink Data Streams verifier** — via `PortfolioStrategy._verifyPrice:1148-1171`
> - Assumes: `report.feedId` matches the pinned `_feedIds[i]`, `report.price > 0`, `report.expiresAt > block.timestamp`
> - Validates: all three, hard revert on each
> - Mutability: verifier proxy address set at strategy init, immutable thereafter
> - On failure: reverts — no try/catch, used only in `rebalanceDelta` where fail-closed is safe

> **Uniswap V3/V4 + Synthra routers, quoters, pools** — via `adapters/*`, reached from `SyndicateVault.executeGovernorBatch`
> - Assumes: quoter output is a usable floor; pool callbacks come only from the resolved pool
> - Validates: caller-supplied `amountOutMin` plus per-hop floors (V3 mode 1 only); `SynthraDirectAdapter` bounds the callback to the transient-staged `amountIn`; V4 has a terminal floor only
> - Mutability: pools and routers are third-party; adapter reachability is gated by `TierRegistry.isAdapterAllowed`
> - On failure: reverts — no try/catch anywhere in the adapters

> **Morpho Blue** — via `strategies/MorphoSupplyStrategy`
> - Assumes: market exists (`lastUpdate != 0`), `loanToken == vault.asset()`, honest share accounting
> - Validates: both, once, at init
> - Mutability: Morpho market params are immutable per `Id`; the Morpho contract itself is not
> - On failure: `_settle` takes the deliverable maximum and emits `SettlementIncomplete` rather than reverting — deliberate anti-hostage design, residue swept later

> **WOOD ERC-20** — via `StakedWood`, `ChallengeGame`, `ProposerBondEscrow`, `TierRegistry`
> - Assumes: standard ERC-20 — no fee-on-transfer, no rebase, no transfer hooks (spec-stated)
> - Validates: nothing; `SafeERC20` handles non-reverting returns only
> - Mutability: external token, outside protocol control
> - On failure: `_burnWood` catches and queues into `_pendingBurn` with a permissionless `flushBurn` retry; other paths revert

> **ENS L2 registrar** — via `SyndicateFactory.createSyndicate`
> - Assumes: `available()` / `register()` behave; the subdomain is cosmetic
> - Validates: wrapped in `try/catch`
> - Mutability: external, admin-settable via `setEnsRegistrar`
> - On failure: swallowed — vault creation proceeds without the subname

**Token Assumptions** *(unvalidated only)*:
- Vault asset: no fee-on-transfer check — `BatchExecutorLib` meters outflow via `balanceOf` deltas, but `_deposit`/`_withdraw` use OZ ERC-4626 defaults. Impact if violated: internal share accounting exceeds the real balance.
- Vault asset: no rebase handling — `totalAssets()` reads a live balance, so a rebasing asset moves share price with no deposit. Impact if violated: unearned high-water-mark movement and performance fees.
- Vault asset: blocklist tokens (USDC/USDT) can freeze the vault or the queue mid-settlement, since `settleRedeem` pushes assets to a recorded owner address.
- WOOD: assumed hook-free; a callback-bearing WOOD would reach `ChallengeGame.dispute` and `claimContribution` — both are CEI-ordered, which is the mitigation.

**Shared State Exposure:**
- Strategy batches route through public Uniswap/Synthra pools; a large `executeGovernorBatch` moves the same pool prices other protocols read.
- `WoodTwapOracle` reads a UniswapV2-style WOOD/WETH pair whose depth the natspec puts around $437k — the `MAX_IDLE_SPAN_DIVISOR = 20` extrapolation bound is the stated defense.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **40 Enforced Guards** (`G-1` … `G-40`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **39 Single-Contract Invariants** (`I-1` … `I-39`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **13 Cross-Contract Invariants** (`X-1` … `X-12`, incl. `X-1b`) — caller/callee pairs that cross contract boundaries
> - **5 Economic Invariants** (`E-1` … `E-5`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **14 On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-4]`, `[I-4]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` (190 lines) — architecture, fee model, upgradeability rules, two-lane liquidity |
| NatSpec | Extensive | Near-universal on external/public functions; many `@dev` blocks name the specific audit finding or issue the code answers (`#181`, `#116`, `#117`, `#33`, `#84`) |
| Spec/Whitepaper | Present | 12 `openspec/specs/*/spec.md` (~2,600 lines) with normative SHALL language, plus 11 change proposals under `openspec/changes/` |
| Inline Comments | Thorough | Rationale-dense — several comments explain why an alternative was *rejected*, which is unusual and directly useful for review |

Spec-derived claims in this report are tagged where they are spec-stated rather than code-verified. One doc inconsistency worth resolving: `openspec/specs/guardian-coverage/spec.md` states `MAX_PERFORMANCE_FEE_BPS = 1500`, while `src/FeeConstants.sol` sets it to `3000` and README describes a 30% hard ceiling with a 20% default. The code value is 3000 (per code).

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 174 | File scan (always reliable) |
| Test functions | 1964 | File scan (always reliable) |
| Line coverage | Unavailable — `forge coverage` exits non-zero | Coverage tool (requires compilation + passing tests) |
| Branch coverage | Unavailable — same | Coverage tool |

Coverage was attempted twice. The default profile fails to compile (`Stack too deep` under the coverage-forced non-via-ir pipeline); the `--ir-minimum` retry compiles and runs the suite, where **1936 tests pass and 9 fail** — all in `test/integration/strategies/UniswapAdapterFork.t.sol`, reverting at ~6k gas, the signature of a fork test with no RPC endpoint configured in this environment. The non-zero exit suppresses the coverage summary. This is an environment gap, not a test gap: `foundry.toml` documents a deliberate per-file compilation-restriction scheme so the eight largest contracts keep `via_ir` under coverage, and notes those eight are consequently absent from the coverage report entirely.

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit + integration | 1964 test functions across 174 files | Broad — dedicated suites per subsystem, plus `test/audit-fixes/` regression suites keyed to individual findings |
| Fork | 4 files | UniswapAdapter, strategy integrations |
| Stateless Fuzz | 12 | `testFuzz*` across fee, staking, and coverage math |
| Stateful Fuzz (Foundry) | 19 invariant functions, 6 files with `StdInvariant`/`targetContract` | Vault accounting, exposure ledger, challenge game |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 | none |
| Formal Verification (Certora) | 0 | none |
| Formal Verification (Halmos) | 0 | none |
| Formal Verification (HEVM) | 0 | none |

### Gaps

- **No formal verification of any kind.** For a codebase whose core is USD-denominated shared-collateral accounting (`ExposureLedger`'s partition-of-unity across `_liveBookedUsd` / `_livePledgedUsd` / `_buckets`), this is the highest-impact gap — exactly the properties a solver handles well and a fuzzer does not.
- **No external stateful fuzzer** (Echidna/Medusa). Foundry invariants exist but 19 functions across 6 files is thin relative to 8894 nSLOC, and the cross-contract couplings ([X-1](invariants.md#x-1) … [X-12](invariants.md#x-12)) are precisely the multi-contract sequences a single-contract invariant suite will not reach.
- **The 14 On-chain=No invariants have no corresponding invariant tests.** Several are conservation properties (`I-4`, `I-5`, `I-8`) a stateful fuzzer could falsify directly.
- **Fork tests do not run in this environment** — no RPC configured, so 9 tests revert at setup. CI runs them separately.

---

## 6. Developer & Git History

> Repo shape: **normal_dev** — 213 of 532 commits touch source files, over 29 days (2026-07-06 → 2026-08-04). Git analysis was run at `cab5731`; the invariant and entry-point analysis was re-verified against `8b82598` (`main`), which adds PR #190 (governance-bound tightening) on top.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Ana Bittencourt | 410 | +42,408 / −15,914 | 79.2% |
| Carlos Beltran | 12 | +16,868 / −99 | 13.8% |
| Ana (second identity) | 99 | +4,267 / −4,121 | 6.7% |
| Carlos (second identity) | 11 | +478 / −18 | 0.4% |

Two humans, four git identities. Combined, Ana's two identities account for **85.9%** of source line additions.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 4 identities / 2 people | Effectively single-developer with one collaborator |
| Merge commits | 131 of 532 (24.6%) | PR-based workflow in use |
| Repo age | 2026-07-06 → 2026-08-04 | 29 days |
| Recent source activity (30d) | Effectively all of it | The entire history sits inside the 30-day window |
| Test co-change rate | 82.6% | Share of source-changing commits that also modify test files — co-modification, not coverage |
| Fix-without-test rate | 0.0% | Every scored fix commit also touched tests |
| Avg commit size | 676.5 lines | Large |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `src/SyndicateVault.sol` | 35 | High churn — also the delegatecall host and the asset custodian |
| `src/SyndicateGovernor.sol` | 34 | High churn — the largest contract at 927 nSLOC |
| `src/StakedWood.sol` | 33 | High churn — sole custodian of all staked WOOD |
| `src/ChallengeGame.sol` | 30 | High churn — the entire economic-enforcement path |
| `src/TokenCourt.sol` | 25 | High churn — verdict authority |
| `src/ExposureLedger.sol` | 23 | High churn — 699 nSLOC of shared-collateral accounting |
| `src/GuardianRegistry.sol` | 16 | Moderate churn |
| `src/TierRegistry.sol` | 12 | Moderate churn |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals in a commit: message keywords, diff patterns (deletes code, changes `require`/`assert`, touches access control or accounting), and change shape. **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| `bc66fad` | 2026-07-27 | guardian economic-security v1b part 1 — slash rails + compensation escrow (#24) | 21 | Spans 6 security domains; +7 guards, +12 access-control; >500 source lines |
| `79bea56` | 2026-08-03 | remediate 17 critical/high findings from audit #181 | 19 | Urgent/critical fix; +7 guards, +3 access-control; token-transfer logic |
| `2dc4d14` | 2026-07-27 | guardian economic-security v1a — coverage ledger, bonds | 19 | +8 guards, +41/−1 access-control; token-transfer logic |
| `edd9c21` | 2026-07-26 | close the queue pay-through drain; bind the slash ceiling per verdict | 19 | Bug fix touching both queue accounting and slash ceilings |
| `a3aba69` | 2026-07-30 | price the freeze on the Inconclusive path too (review #1) | 18 | Oracle/pricing + access-control + token-transfer |
| `ed52239` | 2026-08-03 | remediate 9 medium/low findings from audit #181 | 17 | +5 guards |
| `80f11a5` | 2026-08-03 | guard Permit2-batch/DSToken-push/ERC1363 selectors (round 3) | 17 | Signature/auth handling — third round on the same surface |
| `1123984` | 2026-08-03 | guard Permit2/DSToken selectors, scope self-transfer fast-path | 17 | Signature/auth handling |
| `33581df` | 2026-07-31 | close two permanent-wedge paths (PR #56 B1, M2) | 17 | **Removes** 2 runtime guards while adding 1 access-control check |
| `e5a622d` | 2026-07-31 | remove `strategyMint`/`strategyBurn` — unbounded share issuance | 17 | **Loosens** access control by −6 (feature removal) |

### Dangerous Area Evolution

| Security Area | Commits | Key Files (src only) |
|--------------|--------:|-----------|
| access_control | 182 | SyndicateVault, SyndicateGovernor, StakedWood |
| fund_flows | high | SyndicateVault, ChallengeGame, ProposerBondEscrow, StakedWood |
| oracle_price | moderate | ExposureLedger, WoodTwapOracle, PortfolioStrategy |
| state_machines | moderate | ProposalLifecycle, ChallengeGame, TokenCourt |
| signatures | moderate | SyndicateVault (Permit2 / ERC1363 / DSToken selector guards) |

The analyzer's raw file lists for these areas are dominated by `lib/` vendored code; only `src/` files are named above.

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| openzeppelin-contracts | `lib/openzeppelin-contracts` | OpenZeppelin | Internalized (not a submodule) | 454 `.sol`; 15 distinct pragmas incl. `>=0.4.11`; may contain modifications |
| openzeppelin-contracts-upgradeable | `lib/openzeppelin-contracts-upgradeable` | OpenZeppelin | Internalized (not a submodule) | 767 `.sol`; 16 distinct pragmas; may contain modifications |
| LayerZero-v2 | `lib/LayerZero-v2` | unknown | Internalized (not a submodule) | 53 `.sol`; **no `src/` file imports it** — dead weight in the dependency tree |

Internalized rather than submoduled means upstream security fixes will not auto-propagate, and local divergence is invisible to `git submodule status`. Worth diffing the OZ trees against the pinned upstream tags before relying on them.

### Technical Debt Markers

None. `tech_debt.total_count = 0` — no TODO / FIXME / HACK / XXX anywhere in `src/`.

### Security Observations

- **Effective single-developer codebase** — Ana's two git identities are 85.9% of source line additions; Carlos's 13.8% arrives in 12 commits.
- **Four git identities for two people** — `Ana Bittencourt` / `Ana` and `Carlos Beltran` / `Carlos` split the blame history, distorting any per-author attribution not normalized first.
- **Every hotspot is a custody or enforcement contract** — the top six churned files hold assets, gate execution, or decide slashes; none is peripheral.
- **Three consecutive rounds on the same batch-guard surface** — `1123984`, `80f11a5` (both 2026-08-03) plus the earlier `#166` callee-gate work, all on `SyndicateVault._guardBatchCalls` selector screening.
- **Two high-scored commits *remove* guards** — `33581df` (−2 runtime guards) and `e5a622d` (−6 access-control lines); both are intentional feature removals per their messages, worth confirming against the diff.
- **Test co-change is strong but coverage is unmeasured** — 82.6% co-change and a 0% fix-without-test rate, with no line/branch numbers to corroborate them.
- **LayerZero-v2 is vendored but unused** by anything in `src/` — 53 unreferenced Solidity files in the build tree.

### Cross-Reference Synthesis

- **`ExposureLedger.sol` is #6 in churn but #1 in unenforced invariants** — 5 of the 14 On-chain=No blocks ([I-5](invariants.md#i-5), [I-6](invariants.md#i-6), [X-3](invariants.md#x-3), [X-4](invariants.md#x-4), [E-1](invariants.md#e-1)) sit in 699 nSLOC of shared-collateral accounting with zero formal verification → highest-leverage review target.
- **The audit-#181 remediation is 3 days old and ~2,484 source lines** — `79bea56` + `ed52239` + `08823f2` all landed 2026-08-03/04 across 8 of the 9 hotspot files; the fixes have had one CI cycle and no independent review pass.
- **`X-4`'s fail-open `try/catch` is *itself* an audit-#181 fix** — the mirror check was added for finding D ("window coupling is one-sided"), then wrapped in a catch for setter liveness → the fix moved the failure mode from one-sided to fail-open, but did not close it.
- **Zero TODO markers alongside 82.6% test co-change reads as disciplined**, not as absence of known issues — unresolved items are tracked in `openspec/changes/` and GitHub issues (`#84`, `#116`, `#117`, `#33`) and cited inline in natspec instead.

---

## X-Ray Verdict

**ADEQUATE** — strong tests and exceptional documentation sit on an access-control model where five separately-owned contracts hold instant, un-timelocked control over the economic parameters that price the entire security layer.

**Structural facts:**
1. 8894 nSLOC across 8 subsystems and 52 source files; the four largest contracts (SyndicateGovernor 927, ExposureLedger 699, SyndicateVault 630, GuardianRegistry 619) are 32% of the codebase.
2. 1964 test functions in 174 files, with 12 stateless-fuzz and 19 Foundry-invariant functions, and zero formal verification of any kind.
3. Four UUPS upgrade authorities (`SyndicateFactory`, `SyndicateVault`, `StakedWood`, `GuardianRegistry`) plus one `UpgradeableBeacon` that upgrades every per-vault governor at once.
4. ~91 protocol-admin `onlyOwner` entry points across 10 contracts; exactly one of them (`TierRegistry.certify`) sits behind an on-chain delay.
5. Two developers wrote 100% of the code across four git identities in 29 days, with the audit-#181 remediation landing in the final 48 hours.
6. 14 of 57 inferred invariants are not enforced on-chain, concentrated in the exposure ledger and the withdrawal queue.
