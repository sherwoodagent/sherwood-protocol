# Entry Point Map

> Sherwood Protocol | ~195 entry points | ~50 permissionless | ~50 role-gated | ~95 admin-only

Counts come from the grep-verified signature scan over `src/` (interfaces and mocks excluded), cross-checked against per-contract access maps. `~` reflects that a handful of functions are permissionless at the modifier layer but self-scoped by key derivation; those are classified by effective reach, not by modifier presence.

---

## Protocol Flow Paths

### Protocol Setup (Admin)

`SyndicateFactory.initialize()` → `setBeacon()` → `setVaultImpl()` → `setExecutorImpl()` → `setProtocolConfig()` → `setGuardianRegistry()` → `setTierRegistry()` → `setExposureLedger()` → `setBondEscrow()`

`StakedWood.initialize()` → `setRegistry()` ◄── one-shot latch → `setExposureLedger()` → `setAuthorizedSlasher()`

`GuardianRegistry.initialize()` → `setExposureLedger()` ◄── ledger must point back at this registry

`ExposureLedger` (constructor) → `setWoodUsdPrice()` ◄── required; zero reverts every price read
                              → `setWoodTwapOracle()` → `setAssetFeed()` → `setGuardianRegistry()` → `setCoverageFreezer()`

`ChallengeGame` (constructor) → `setExposureLedger()` → `setStakedWood()` → `setCourt()` ◄── window-fit invariant checked from both sides
`TokenCourt` (constructor) → `setChallengeGame()` → `setStakedWood()` ◄── participationFloorBps < ageFloorBps

`TierRegistry.setWood()` → `setSubmitterBondWood()` → `setAuthorizedDemoter(challengeGame)` → `setAdapterAllowed(adapter)`

### Vault Creation (Owner)

`StakedWood.prepareOwnerStake()` → `SyndicateFactory.createSyndicate()`
   └─ inside one tx: deploy vault proxy → deploy `VaultWithdrawalQueue` → `SyndicateVault.setWithdrawalQueue()`
      → deploy governor `BeaconProxy` → `GuardianRegistry.addGovernor()` → `StakedWood.bindOwnerStake()`
      → `SyndicateGovernor.setTierRegistry/setExposureLedger/setBondEscrow()` → ENS `register()` (best-effort)

`[createSyndicate above]` → `SyndicateVault.registerAgent()` → `approveDepositor()` (or `setOpenDeposits(true)`)

### Depositor Flow

`[vault created above]` → `SyndicateVault.deposit()` / `mint()`  ◄── whitelist or openDeposits; `minHoldingPeriod` starts
                              ├─→ `withdraw()` / `redeem()`  ◄── only while no proposal is open
                              └─→ `requestRedeem()`  ◄── only while redemptionsLocked
                                     ├─→ `VaultWithdrawalQueue.cancel()`  ◄── request owner only, pre-stamp
                                     └─→ `VaultWithdrawalQueue.claim()`   ◄── after stamp, after unlock

### Guardian Flow

`StakedWood.stakeAsGuardian()` ◄── ≥ minGuardianStake
   → `[proposal reaches GuardianReview]` → `GuardianRegistry.voteOnProposal()`
        ├─ Approve → `ExposureLedger.recordApproval()`  ◄── books USD against bond, batching-capped
        └─ Block   → counts toward blockQuorumBpsAtOpen
   → `GuardianRegistry.openReview()` ◄── after voteEnd, permissionless
   → `GuardianRegistry.resolveReview()` ◄── after reviewEnd, permissionless → `StakedWood.slashGuardians()` if blocked

`StakedWood.requestUnstakeGuardian()` → [coolDownPeriod elapses] → `claimUnstakeGuardian()`
                                                                     ◄── reverts while openExposureUsd ≠ 0 or coverage frozen
      └─→ `cancelUnstakeGuardian()`  ◄── only before claim, only with stake remaining

### Agent / Proposal Flow

`[agent registered above]` → `StrategyFactory.cloneAndInit()` ◄── template allowlisted; caller is vault owner or agent
   → `SyndicateGovernor.propose()`  ◄── no open proposal; locks the proposer bond
        ├─→ [collaborative] `approveCollaboration()` × N → Pending    │  or `rejectCollaboration()` → Cancelled
        ├─→ `vote()` ◄── share weight at snapshotTimestamp
        ├─→ `vetoProposal()` ◄── vault owner, while Pending
        ├─→ `cancelProposal()` ◄── proposer, before voteEnd
        └─→ `emergencyCancel()` ◄── vault owner, Draft or Pending

   → [voteEnd + reviewEnd pass, guardian quorum met] → `executeProposal()` ◄── permissionless
        → `SyndicateVault.executeGovernorBatch()` → delegatecall `BatchExecutorLib.executeBatch()`
             → `PortfolioStrategy.rebalance()` / `rebalanceDelta()` ◄── proposer only, while Executed

   → [strategyDuration elapses] → `settleProposal()` ◄── permissionless
        ├─→ [if stuck] `GovernorEmergency.unstick()` ◄── vault owner, replays pre-voted settlement calls
        └─→ [if unwind needed] `emergencySettleWithCalls()` → [reviewPeriod] → `finalizeEmergencySettle()`
                                    ◄── vault owner, bonded by ownerStake; guardians may block via `voteBlockEmergencySettle()`
                                    └─→ `cancelEmergencySettle()`

   → `reclaimProposerBond()` ◄── terminal state + strategyDuration + challengeWindow + not frozen + past file's own deadline

### Challenger Flow

`[proposal Executed above]` → `ChallengeGame.file()` ◄── inside challengeableUntil, not already convicted, bond in WOOD
   ├─→ [silence past autoSlashDelay] → `resolve()` → Settled → `StakedWood.slashVerdict()` + `ProposerBondEscrow.forfeitBond()`
   ├─→ `dispute()` × N until the counter-bond target is met → Disputed → `TokenCourt.refer()`
   │      → `TokenCourt.vote()` ◄── WOOD weight at executedAt−1; accused and challenger barred
   │      → [voteWindow elapses] → `TokenCourt.finalize()` → `ChallengeGame.rule()`
   │           ├─ Guilty       → Settled
   │           ├─ NotGuilty    → Failed        → `claimContribution()`
   │           └─ Inconclusive → Inconclusive  → `claimContribution()`, window re-armed
   └─→ [disputeTimeout with no verdict] → `resolve()` → Failed

### Maintenance (Permissionless Keepers)

`WoodTwapOracle.update()` ◄── no-ops unless span ≥ twapWindow
`ExposureLedger.settleCoverage()` ◄── rebooks approvals down to actual need
`ExposureLedger.retireApproval()` ◄── after bucket expiry + challengeWindow, unfrozen, unpinned
`StakedWood.flushBurn()` ◄── retries a burn transfer that previously failed
`TierRegistry.poke()` ◄── demotes a certification whose target codehash drifted
`MorphoSupplyStrategy.sweep()` ◄── after Settled, recovers residual supply

---

## Permissionless

Entry points callable by any address with no effective access restriction. Sorted by value flow: tokens-in first, tokens-out second, no-token-movement last.

### `SyndicateVault.deposit()` / `mint()`

| Aspect | Detail |
|--------|--------|
| Visibility | public (inherited `ERC4626Upgradeable`) |
| Caller | LP depositor |
| Parameters | `assets` / `shares` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ SyndicateVault._deposit() → IERC20.safeTransferFrom() → SyndicateVault._initHighWaterMarkIfUnset()` |
| State modified | `balanceOf`, `totalSupply`, `lastDepositAt`, `_highWaterPricePerShare` (first deposit only), ERC20Votes checkpoints |
| Value flow | Tokens: depositor → Vault |
| Reentrancy guard | yes (`nonReentrant` on the internal override) |

### `SyndicateVault.requestDeposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | LP depositor, during a live proposal |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ IERC20.safeTransferFrom() → VaultWithdrawalQueue.queueDeposit()` |
| State modified | Queue `_requests`, `_byOwner`, `_pendingDepositAssets` |
| Value flow | Tokens: depositor → Queue (escrow) |
| Reentrancy guard | no explicit guard on this function |

### `SyndicateFactory.createSyndicate()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Prospective vault owner holding an agent NFT and a prepared owner stake |
| Parameters | `creatorAgentId` (user-controlled, must be owned by caller), `config` (user-controlled: subdomain, metadata, asset) |
| Call chain | `→ StakedWood.canCreateVault() → IERC20.safeTransferFrom() (creation fee) → new ERC1967Proxy(vaultImpl) → new VaultWithdrawalQueue() → SyndicateVault.setWithdrawalQueue() → new BeaconProxy(governor) → GuardianRegistry.addGovernor() → StakedWood.bindOwnerStake() → SyndicateGovernor.setTierRegistry/setExposureLedger/setBondEscrow()` |
| State modified | `syndicateCount`, `syndicates`, `vaultToSyndicate`, `subdomainToSyndicate`, `_governorOf`, `_activeSyndicateIds` |
| Value flow | Tokens: creator → creationFeeRecipient |
| Reentrancy guard | no |

### `ChallengeGame.file()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | `proposalId` (protocol-derived), `predicate` (user-controlled, **not verified on-chain**), `adapterTarget` / `adapterSelector` (user-controlled), `evidenceURI` (user-controlled) |
| Call chain | `→ SyndicateGovernor.getProposal()/getExecuteCalls() → ExposureLedger.approversOf()/unsharedLiabilityUsd()/woodPriceX8() → StakedWood.verdictSlashed() → IERC20.safeTransferFrom() → ExposureLedger.freezeCoverage()` |
| State modified | `challengeCount`, `_challenges`, `_lastChallenge`, `_liveByChallenger`, `_liveCount`, `bondedWood`, `inconclusiveRounds` |
| Value flow | Tokens: challenger → ChallengeGame (bond) |
| Reentrancy guard | no (CEI-ordered) |

### `ChallengeGame.dispute()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (explicitly open — the defense pool is crowdfunded) |
| Parameters | `challengeId` (protocol-derived), `amountWood` (user-controlled) |
| Call chain | `→ IERC20.safeTransferFrom() → ITokenCourt.refer()` (best-effort, try/catch) |
| State modified | `_contributed`, `_contributors`, `c.counterBondWood`, `c.status` (Filed → Disputed on pool completion), `bondedWood` |
| Value flow | Tokens: contributor → ChallengeGame (counter-bond) |
| Reentrancy guard | no (CEI-ordered; writes precede the transfer) |

### `StakedWood.stakeAsGuardian()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Anyone becoming a guardian |
| Parameters | `amount` (user-controlled, ≥ `minGuardianStake` in total), `agentId` (user-controlled, first stake only) |
| Call chain | `→ IERC20.safeTransferFrom()` |
| State modified | `_guardians[msg.sender]` (stakedAmount, stakedAt weighted-average re-anchor, agentId), `totalGuardianStake`, `_stakeCheckpoints`, `_liabilityCheckpoints`, `_totalStakeCheckpoint`, `_anchorCheckpoints` |
| Value flow | Tokens: guardian → StakedWood |
| Reentrancy guard | yes |

### `StakedWood.prepareOwnerStake()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Prospective vault owner |
| Parameters | `amount` (user-controlled, ≥ `minOwnerStake`) |
| Call chain | `→ IERC20.safeTransferFrom()` |
| State modified | `_prepared[msg.sender]`, `approvedBindVault[msg.sender]` (cleared) |
| Value flow | Tokens: owner → StakedWood (escrow, pre-binding) |
| Reentrancy guard | yes |

### `SyndicateVault.withdraw()` / `redeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | public (inherited `ERC4626Upgradeable`) |
| Caller | LP shareholder |
| Parameters | `assets` / `shares` (user-controlled), `receiver`, `owner` (user-controlled) |
| Call chain | `→ SyndicateVault._withdraw() → IERC20.safeTransfer()` |
| State modified | `balanceOf`, `totalSupply`, `_highWaterPricePerShare` (reset if supply hits 0) |
| Value flow | Tokens: Vault → receiver |
| Reentrancy guard | yes |

### `SyndicateVault.requestRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant`, `whenNotPaused` |
| Caller | LP shareholder, during a live proposal |
| Parameters | `shares` (user-controlled), `owner_` (user-controlled; spends allowance if not the caller) |
| Call chain | `→ ERC20._spendAllowance() → ERC20._transfer(owner_, queue, shares) → VaultWithdrawalQueue.queueRedeem()` |
| State modified | Vault `balanceOf`; queue `_requests`, `_byOwner`, `_pendingShares`, `_pidRedeemShares` |
| Value flow | Shares: owner → Queue (escrow) |
| Reentrancy guard | yes |

### `VaultWithdrawalQueue.claim()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Anyone (payout always goes to `r.owner`, regardless of caller) |
| Parameters | `requestId` (protocol-derived) |
| Call chain | Redeem: `→ SyndicateVault.settleRedeem() → ERC20._burn() → IERC20.safeTransfer()`. Deposit: `→ IERC20.safeTransfer(vault) → SyndicateVault.settleDeposit() → ERC20._mint()` |
| State modified | `r.claimed`, `r.closedAt`, `_pendingShares` / `_pendingDepositAssets`, `_pidRedeemShares`, `_pidReserved`, `_reservedAssets`, `_stampedUnclaimedShares` |
| Value flow | Tokens/shares: Queue + Vault → request owner |
| Reentrancy guard | yes |

### `SyndicateGovernor.settleProposal()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Anyone (the proposer gets a shorter minimum wait, enforced in the body, not as a caller restriction) |
| Parameters | `proposalId` (protocol-derived) |
| Call chain | `→ SyndicateVault.executeGovernorBatch(settlementCalls) → _finishSettlement → SyndicateVault.consumeManagementAccrual()/aboveHighWaterMark()/transferPerformanceFee()/ratchetHighWaterMark()/onProposalSettled() → VaultWithdrawalQueue.stampSettlement()` |
| State modified | `_activeProposal`, `_openProposalCount`, `_lastSettledAt`, `p.state`, `_capitalSnapshots` (deleted), `_unclaimedFees` (on transfer failure), vault fee/HWM state, queue settle price |
| Value flow | Tokens: Vault → protocol / guardian / agent(s) / owner fee recipients |
| Reentrancy guard | yes |

### `SyndicateGovernor.reclaimProposerBond()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Anyone (pays the proposer of record) |
| Parameters | `proposalId` (protocol-derived) |
| Call chain | `→ ProposerBondEscrow.bondOf() → ExposureLedger.challengeWindow()/isCoverageFrozen()/coverageFreezer() → ChallengeGame.challengeWindow()/challengeableUntil() → ProposerBondEscrow.releaseBond() → IERC20.safeTransfer() → ExposureLedger.settleCoverage()` (best-effort) |
| State modified | `proposal.proposerBondWood` → 0; escrow `_bonds[key]` deleted |
| Value flow | Tokens: Escrow → proposer |
| Reentrancy guard | yes |

### `SyndicateGovernor.claimUnclaimedFees()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Anyone (scoped to `msg.sender`'s own escrow key — cannot claim another recipient's) |
| Parameters | `vault` (user-controlled), `token` (user-controlled) |
| Call chain | `→ SyndicateVault.transferPerformanceFee()` |
| State modified | `_unclaimedFees[keccak256(vault, msg.sender, token)]` → 0 |
| Value flow | Tokens: Vault → msg.sender |
| Reentrancy guard | yes |

### `ChallengeGame.claimContribution()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (payout scoped to `_contributed[id][msg.sender]`) |
| Parameters | `challengeId` (protocol-derived) |
| Call chain | `→ IERC20.safeTransfer()` |
| State modified | `_contributed[id][msg.sender]` → 0, `unclaimedWood` |
| Value flow | Tokens: ChallengeGame → contributor |
| Reentrancy guard | no (CEI-ordered) |

### `TierRegistry.claimSubmitterBond()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (payout fixed to the recorded `b.submitter`) |
| Parameters | `target`, `selector` (protocol-derived) |
| Call chain | `→ IERC20.safeTransfer()` |
| State modified | `_bonds[k]` deleted, `totalBondedWood` |
| Value flow | Tokens: TierRegistry → submitter |
| Reentrancy guard | no (CEI-ordered) |

### `StakedWood.claimUnstakeGuardian()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (self-scoped to `_guardians[msg.sender]`) |
| Parameters | none |
| Call chain | `→ ExposureLedger.openExposureUsd()/hasFrozenCoverage() → IERC20.safeTransfer()` |
| State modified | `_guardians[msg.sender]` deleted, `_liabilityCheckpoints` push 0 |
| Value flow | Tokens: StakedWood → guardian |
| Reentrancy guard | no (delete precedes the transfer) |

### `StakedWood.cancelPreparedStake()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (self-scoped to `_prepared[msg.sender]`) |
| Parameters | none |
| Call chain | `→ IERC20.safeTransfer()` |
| State modified | `_prepared[msg.sender]`, `approvedBindVault[msg.sender]` deleted |
| Value flow | Tokens: StakedWood → owner |
| Reentrancy guard | no (delete precedes the transfer) |

### `StakedWood.flushBurn()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (retry mechanism, deliberately open) |
| Parameters | none |
| Call chain | `→ IERC20.safeTransfer(BURN_ADDRESS)` |
| State modified | `_pendingBurn[address(this)]` → 0 |
| Value flow | Tokens: StakedWood → burn address |
| Reentrancy guard | no (CEI-ordered) |

### `TokenVesting.release()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (payout fixed to `beneficiary`) |
| Parameters | none |
| Call chain | `→ IERC20.safeTransfer(beneficiary)` |
| State modified | `released` |
| Value flow | Tokens: Vesting wallet → beneficiary |
| Reentrancy guard | no |

### `VestingFactory.createVesting()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (unowned factory by design — consumers must filter `VestingCreated` by the indexed `creator`) |
| Parameters | `beneficiary`, `owner`, `token`, `start`, `cliffDuration`, `duration`, `cancelable`, `amount` (all user-controlled) |
| Call chain | `→ Clones.clone() → TokenVesting.initialize() → IERC20.safeTransferFrom()` (only if `amount > 0`) |
| State modified | `_walletsOf[beneficiary]` push |
| Value flow | Tokens: creator → the new vesting wallet |
| Reentrancy guard | no |

### `UniswapSwapAdapter.swap()` / `SynthraSwapAdapter.swap()` / `SynthraDirectAdapter.swap()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (self-limiting: the caller supplies and receives their own tokens) |
| Parameters | `tokenIn`, `tokenOut`, `amountIn`, `amountOutMin`, `extraData` (all caller-controlled) |
| Call chain | `→ IERC20.safeTransferFrom() → forceApprove() → ISwapRouter.exactInputSingle()/exactInput()`, or `→ IPoolManager.unlock() → unlockCallback()`, or `→ ISynthraPool.swap() → synthraV3SwapCallback()` |
| State modified | None persistent (adapter storage is immutable; `SynthraDirectAdapter` uses transient storage for its callback guard) |
| Value flow | Tokens: caller → adapter → pool → caller |
| Reentrancy guard | no persistent guard; `SynthraDirectAdapter` stages a transient expected-pool and caps the callback at the staged `amountIn` |

### `BatchExecutorLib.executeBatch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone at this contract's own address; **intended** to be reached only via `delegatecall` from a vault |
| Parameters | `calls[]` (caller-controlled), `asset` (caller-controlled), `caps[]` (caller-controlled; an empty array disables metering by design) |
| Call chain | `→ calls[i].target.call{value:}(calls[i].data) → IERC20Balance.balanceOf()` |
| State modified | None at this contract (stateless); under delegatecall, the caller's storage |
| Value flow | Arbitrary, determined by `calls[]` |
| Reentrancy guard | no — safety depends entirely on the delegatecalling vault having run `_guardBatchCalls` first |

### `SyndicateGovernor.executeProposal()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Anyone, once the proposal is Approved |
| Parameters | `proposalId` (protocol-derived) |
| Call chain | `→ IERC4626.asset()/IERC20.balanceOf() → SyndicateVault.startManagementAccrual() → TierRegistry.tierOf() → ExposureLedger.requireApproveQuorum() → SyndicateVault.executeGovernorBatch() → delegatecall BatchExecutorLib.executeBatch()` |
| State modified | `_capitalSnapshots`, `_activeProposal`, `p.executedAt`, `p.state`, `p.effectiveMaxCapital`, `_effectiveSettlementCallCaps` |
| Value flow | Tokens: Vault → strategy / adapters (per batch) |
| Reentrancy guard | yes |

### `SyndicateGovernor.vote()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Any address with nonzero past voting weight |
| Parameters | `proposalId` (protocol-derived), `support` (user-controlled) |
| Call chain | `→ IVotes.getPastVotes()` |
| State modified | `_hasVoted`, `p.votesFor` / `votesAgainst` / `votesAbstain` |
| Value flow | None |
| Reentrancy guard | yes |

### `SyndicateGovernor.resolveProposalState()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Anyone (documented as a permissionless state flush) |
| Parameters | `proposalId` (protocol-derived) |
| Call chain | `→ _commitState → GuardianRegistry.resolveReview()/cancelReview() → StakedWood.slashGuardians()` |
| State modified | `p.state`, `_openProposalCount`, `_lastSettledAt`; registry review state; guardian stake on the slash path |
| Value flow | None directly; the slash path burns guardian WOOD |
| Reentrancy guard | yes |

### `GuardianRegistry.openReview()` / `resolveReview()` / `resolveEmergencyReview()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused` |
| Caller | Anyone (keeper role, unincentivized) |
| Parameters | `governor`, `proposalId` (protocol-derived) |
| Call chain | `openReview → StakedWood.getPastTotalVotes()`; `resolveReview → StakedWood.slashGuardians()`; `resolveEmergencyReview → StakedWood.slashOwnerBond()` |
| State modified | `r.opened`, `r.totalStakeAtOpen`, `r.blockQuorumBpsAtOpen`, `r.openedAt`, `r.cohortTooSmall`, `r.resolved`, `r.blocked`; `er.resolved` |
| Value flow | Slashed WOOD → burn address (via StakedWood) |
| Reentrancy guard | `ReentrancyGuardTransient` is inherited but not applied to these functions |

### `GuardianRegistry.unpause()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Owner at any time; **anyone** after `DEADMAN_UNPAUSE_DELAY` from `pausedAt` |
| Parameters | none |
| Call chain | none |
| State modified | `paused`, `pausedAt` |
| Value flow | None |
| Reentrancy guard | no |

### `ExposureLedger.settleCoverage()` / `retireApproval()`

| Aspect | Detail |
|--------|--------|
| Visibility | external (documented "PERMISSIONLESS AND SAFE TO SKIP") |
| Caller | Anyone |
| Parameters | `governor`, `proposalId`, `guardian` (all protocol-derived) |
| Call chain | `settleCoverage → SyndicateGovernor.getProposalView()/getRequiredCoverage() → SyndicateVault.asset() → this.coverageUsd()/this.woodPriceX8() → Chainlink / TWAP reads`. `retireApproval` makes no external calls. |
| State modified | `settleCoverage`: `_settled`, `_recorded[..].usd`, `_buckets`, `_liveBookedUsd`. `retireApproval`: `_buckets`, `_committedUsd`, `_liveBookedUsd`, `_livePledgedUsd`, `_recorded`, `_reservedUsd`, `_approversOf`, `_approverIndex` |
| Value flow | None (USD accounting only) |
| Reentrancy guard | no |

### `TokenCourt.refer()` / `vote()` / `finalize()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | `refer` and `finalize`: anyone. `vote`: any WOOD holder except the accused and the challenger. |
| Parameters | `challengeId` / `caseId` (protocol-derived), `guilty` (user-controlled) |
| Call chain | `refer → ChallengeGame.challengeOf() → ExposureLedger.pledgedOf() → StakedWood.getPastStake()`; `vote → StakedWood.getPastVotes()/getPastStake()/getPastTotalVotes()/getVotes()`; `finalize → ChallengeGame.rule()` (try/catch swallowing only `WrongStatus`) |
| State modified | `caseCount`, `caseOfChallenge`, `_cases`, `isAccused`, `_accused`, `voteOf`, `c.guiltyVotes` / `notGuiltyVotes`, `c.verdict`, `c.finalizedAt`, `c.phase` |
| Value flow | None — the court holds no WOOD by design |
| Reentrancy guard | no (CEI-ordered; `refer` claims the case slot before any external read) |

### `ChallengeGame.resolve()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | `challengeId` (protocol-derived) |
| Call chain | `→ _settle / _fail / _refundAll → StakedWood.slashVerdict() → ProposerBondEscrow.forfeitBond() → TierRegistry.demoteByChallenge() → ExposureLedger.unfreezeCoverage()/pinCoverageUntil() → IERC20.safeTransfer()` |
| State modified | `c.status`, `bondedWood`, `unclaimedWood`, `_convicted`, `_liveCount`, `challengeableUntil`, `inconclusiveRounds`, `c.forfeitPayoutWood` |
| Value flow | Tokens: ChallengeGame → challenger + burn address; Escrow → challenger + burn |
| Reentrancy guard | no (CEI-ordered) |

### `TierRegistry.certify()` / `poke()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | `certify`: the pending submitter when a bond is pinned, **anyone** when `bondAmount == 0`. `poke`: anyone. |
| Parameters | `target`, `selector` (protocol-derived) |
| Call chain | `certify → IERC20.safeTransferFrom()`; `poke` makes no external calls (EXTCODEHASH is an opcode, not a call) |
| State modified | `certify`: `_pending[k]` deleted, `_bonds[k]`, `totalBondedWood`, `_configs[k]`. `poke`: `_configs[k]` deleted, `_pending[k]` deleted, `b.releasableAt`, `_adapterAllowed[target]` deleted |
| Value flow | `certify`: submitter → TierRegistry |
| Reentrancy guard | no |

### `WoodTwapOracle.update()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (no-ops rather than reverting on an early call, so no caller can grief another) |
| Parameters | none |
| Call chain | `→ IUniswapV2PairMinimal.getReserves()/price0CumulativeLast()/price1CumulativeLast()` |
| State modified | `latestObservation`, `previousObservation` |
| Value flow | None |
| Reentrancy guard | no |

### `MorphoSupplyStrategy.sweep()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone, only after `_state == Settled` |
| Parameters | none |
| Call chain | `→ IMorpho.expectedMarketBalances()/position()/withdraw() → IERC20.balanceOf()/safeTransfer(vault)` |
| State modified | None locally |
| Value flow | Tokens: Morpho → Strategy → Vault |
| Reentrancy guard | no |

### `ProposerBondEscrow.releaseBond()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone at the modifier layer; effectively governor-only because the bond key is `_key(msg.sender, proposalId)` — a non-governor addresses an always-empty slot and reverts `NoBond` |
| Parameters | `proposalId` (protocol-derived) |
| Call chain | `→ IERC20.safeTransfer()` |
| State modified | `_bonds[key]` deleted |
| Value flow | Tokens: Escrow → recorded proposer |
| Reentrancy guard | no (CEI-ordered) |

### `BaseStrategy.initialize()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, one-shot via the `_initialized` latch |
| Caller | Anyone on a fresh clone; `StrategyFactory` clones and initializes atomically, so the front-run window is closed in practice. The template's own `initialize` is permanently disabled in its constructor. |
| Parameters | `vault_`, `proposer_`, `data` (all caller-controlled) |
| Call chain | `→ virtual _initialize(data)` (subclass-specific token / feed / adapter wiring) |
| State modified | `_initialized`, `_vault`, `_proposer`, `_state`, plus subclass storage |
| Value flow | None |
| Reentrancy guard | no |

### `SyndicateVaultAdminLib.*` (6 external library functions)

`approveDepositor`, `removeDepositor`, `approveDepositors`, `registerAgent`, `removeAgent`, `drainAgents` are `external` on a deployed library reached by `delegatecall`. Called directly at the library's own address they operate on the library's own permanently-empty storage and have no protocol effect. Listed for completeness of the external surface.

---

## Role-Gated

Entry points restricted by a modifier or an internal `msg.sender` check.

### Vault owner

| Contract | Function | Restriction | State Modified |
|----------|----------|-------------|----------------|
| SyndicateVault | `approveDepositor()`, `removeDepositor()`, `approveDepositors()` | `onlyOwner` | `_approvedDepositors` |
| SyndicateVault | `setOpenDeposits()` | `onlyOwner` | `_openDeposits` |
| SyndicateVault | `registerAgent()`, `removeAgent()` | `onlyOwner` | `_agents`, `_agentSet` |
| SyndicateVault | `pause()`, `unpause()` | `onlyOwner` | `_paused` |
| SyndicateVault | `setAgentFeeBps()`, `setMinBufferBps()` | `onlyOwner` | `_agentFeeBpsPlusOne`, `minBufferBps` |
| SyndicateVault | `rescueEth()`, `rescueERC20()`, `rescueERC721()` | `onlyOwner`, blocked while `redemptionsLocked()` | none (transfers out) |
| GovernorParameters | 11 setters (`setVotingPeriod` … `setTier2CallCapBps`) | `onlyVaultOwner` + `whenNoActiveProposal` | `_params`, `_maxCapitalBps`, `_tier2CallCapBps` |
| SyndicateGovernor | `vetoProposal()`, `emergencyCancel()` | `_requireVaultOwner()` | `p.state`, `_openProposalCount` |
| GovernorEmergency | `unstick()`, `emergencySettleWithCalls()`, `cancelEmergencySettle()`, `finalizeEmergencySettle()` | `_requireVaultOwner()` + `emergencyNonReentrant` | registry emergency review; vault batch execution |
| SyndicateFactory | `updateMetadata()`, `deactivate()`, `upgradeVault()` | `s.creator != msg.sender` revert | `syndicates`, `_activeSyndicateIds`, vault impl |
| SyndicateFactory | `rotateOwner()` | current vault owner **or** creator | `syndicates[..].creator`, vault owner, sWOOD owner-stake slot |

### Agent / proposer

| Contract | Function | Restriction | State Modified |
|----------|----------|-------------|----------------|
| SyndicateGovernor | `propose()` | `SyndicateVault.isAgent(msg.sender)` | `_proposalCount`, `_proposals`, `_openProposalCount`, `_executeCalls`, `_settlementCalls`, caps arrays; locks the proposer bond |
| SyndicateGovernor | `cancelProposal()` | `msg.sender != proposal.proposer` revert; before `voteEnd` | `p.state`, `_openProposalCount` |
| SyndicateGovernor | `approveCollaboration()` | listed co-proposer **and** currently-registered agent | `coProposerApprovals`, `_approvedCount`, `p.state` + timing fields |
| SyndicateGovernor | `rejectCollaboration()` | `proposal.proposer != msg.sender` revert | `p.state`, `_openProposalCount` |
| PortfolioStrategy | `rebalance()`, `rebalanceDelta()` | `onlyProposer` | `_allocations`, `_rebalancing` |
| BaseStrategy | `updateParams()` | `onlyProposer`, only while `_state == Executed` | subclass params |
| StrategyFactory | `cloneAndInit()`, `cloneAndInitDeterministic()` | vault registered **and** caller is vault owner or registered agent; template allowlisted; `proposer == msg.sender` | none locally (deploys a clone) |

### Guardian

| Contract | Function | Restriction | State Modified |
|----------|----------|-------------|----------------|
| GuardianRegistry | `voteOnProposal()` | `StakedWood.isActiveGuardian(msg.sender)`, `whenNotPaused` | `_votes`, `_voteStake`, `r.approveStakeWeight` / `blockStakeWeight`, `_approvers` / `_blockers`; calls `ExposureLedger.recordApproval` / `releaseApproval` |
| GuardianRegistry | `voteBlockEmergencySettle()` | `isActiveGuardian`, `whenNotPaused` | `_emergencyBlockVotes`, `er.blockStakeWeight` |
| StakedWood | `requestUnstakeGuardian()`, `cancelUnstakeGuardian()` | self-scoped to `_guardians[msg.sender]` | `g.unstakeRequestedAt`, `g.cooldownAtRequest`, `g.stakedAt`, `totalGuardianStake`, checkpoints |
| StakedWood | `approveOwnerStakeBinding()`, `revokeOwnerStakeBinding()` | self-scoped consent write | `approvedBindVault[msg.sender]` |
| StakedWood | `requestUnstakeOwner()`, `claimUnstakeOwner()` | `s.owner != msg.sender` revert; blocked while the vault has an active or open proposal | `s.unstakeRequestedAt`, `_ownerStakes[vault]` |

### Contract-to-contract

| Contract | Function | Restriction | Caller |
|----------|----------|-------------|--------|
| SyndicateVault | `executeGovernorBatch()`, `transferPerformanceFee()`, `onProposalSettled()`, `startManagementAccrual()`, `consumeManagementAccrual()`, `ratchetHighWaterMark()` | `onlyGovernor` | SyndicateGovernor |
| SyndicateVault | `rotateOwnership()`, `setWithdrawalQueue()`, `setExecutorImpl()`, `_authorizeUpgrade()` | `msg.sender != _factory` revert | SyndicateFactory |
| SyndicateVault | `settleRedeem()`, `settleDeposit()` | `msg.sender != _withdrawalQueue` revert | VaultWithdrawalQueue |
| VaultWithdrawalQueue | `queueRedeem()`, `queueDeposit()`, `stampSettlement()` | `onlyVault` | SyndicateVault |
| VaultWithdrawalQueue | `cancel()` | `msg.sender != r.owner` revert, `nonReentrant` | request owner |
| SyndicateGovernor | `setProtocolConfig()`, `setTierRegistry()`, `setExposureLedger()`, `setBondEscrow()`, `forceSetParams()` | `onlyFactory` | SyndicateFactory |
| GuardianRegistry | `registerReview()`, `cancelReview()`, `openEmergency()`, `cancelEmergency()`, `finalizeEmergency()` | `onlyGovernor` (member of `_authorizedGovernors`) | per-vault governors |
| GuardianRegistry | `addGovernor()` | `msg.sender != factory` revert | SyndicateFactory |
| ExposureLedger | `recordApproval()`, `releaseApproval()` | `onlyRegistry` | GuardianRegistry |
| ExposureLedger | `freezeCoverage()`, `unfreezeCoverage()`, `pinCoverageUntil()` | `onlyFreezer` | ChallengeGame |
| StakedWood | `slashGuardians()`, `slashOwnerBond()` | `onlyRegistry` | GuardianRegistry |
| StakedWood | `slashVerdict()` | `onlyAuthorizedSlasher` | ChallengeGame |
| StakedWood | `bindOwnerStake()`, `transferOwnerStakeSlot()` | `onlyFactory` | SyndicateFactory |
| ProposerBondEscrow | `lockBond()` | `onlyGovernor` (via `registry.isAuthorizedGovernor`) | per-vault governors |
| ProposerBondEscrow | `forfeitBond()` | `msg.sender != exposureLedger.coverageFreezer()` revert | ChallengeGame |
| ChallengeGame | `rule()` | `msg.sender != court` revert | TokenCourt |
| TierRegistry | `demoteByChallenge()` | `msg.sender != authorizedDemoter` revert | ChallengeGame |
| BaseStrategy | `execute()`, `settle()` | `onlyVault` | SyndicateVault (via the batch) |
| UniswapSwapAdapter | `unlockCallback()` | `msg.sender != poolManager` revert | Uniswap V4 PoolManager |
| SynthraDirectAdapter | `synthraV3SwapCallback()` | `msg.sender != transient staged pool` revert | the resolved Synthra pool |

---

## Admin-Only

Owner-restricted configuration surfaces. These configure the protocol rather than operate it.

| Contract | Functions | Count | Delay |
|----------|-----------|------:|-------|
| SyndicateFactory | `setCreationFee`, `setVaultImpl`, `setExecutorImpl`, `pushExecutor`, `setManagementFeeBps`, `setUpgradesEnabled`, `setEnsRegistrar`, `setBeacon`, `setProtocolConfig`, `setParamsOverride`, `setGuardianRegistry`, `setTierRegistry`, `setExposureLedger`, `setBondEscrow`, `pushWiring`, `_authorizeUpgrade` | 16 | none |
| ChallengeGame | `setCourt`, `setExposureLedger`, `setTierRegistry`, `setChallengeWindow`, `setChallengerBondBps`, `setForfeitBurnBps`, `setStakedWood`, `setAutoSlashDelay`, `setDisputeTimeout`, `setSettleBurnBps`, `setProsecutorFeeBps`, `setInconclusiveBurnBps`, `setFilingsPaused` | 13 | none (`renounceOwnership` disabled) |
| ExposureLedger | `setWoodUsdPrice`, `setWoodFeed`, `setWoodTwapOracle`, `setWoodHaircutBps`, `setGuardianRegistry`, `setChallengeWindow`, `setCoverageFreezer`, `setKNumerator`, `setCoveredTvlCapUsd`, `setQuorumTierThreshold`, `setProposerBondBps`, `setAssetFeed` | 12 | none |
| StakedWood | `setRegistry`, `setMinGuardianStake`, `setCooldownPeriod`, `setMinOwnerStake`, `setMinSlashBps`, `setMaxSlashBps`, `setAgeFloorBps`, `setMaturationPeriod`, `setExposureLedger`, `setAuthorizedSlasher`, `_authorizeUpgrade` | 11 | none |
| TierRegistry | `setWood`, `setSubmitterBondWood`, `setBondReleaseDelay`, `proposeCertification`, `cancelCertification`, `setCertifyDelay`, `setAuthorizedDemoter`, `demote`, `setAdapterAllowed` | 9 | `proposeCertification` → `certifyDelay` (1–30 d) → `certify`; every other setter instant |
| GuardianRegistry | `fundSlashAppealReserve`, `refundSlash`, `pause`, `setReviewPeriod`, `setBlockQuorumBps`, `setExposureLedger`, `_authorizeUpgrade` | 7 | none |
| ProtocolConfig | `setMgmtSplit`, `setPerfSplit`, `setMaxStrategyDuration`, `setProtocolFeeRecipient`, `setGuardiansFeeRecipient` | 5 | none (Ownable2Step) |
| TokenCourt | `setChallengeGame`, `setStakedWood`, `setVoteWindow`, `setParticipationFloorBps` | 4 | none (`renounceOwnership` reverts) |
| WoodTwapOracle | `setTwapWindow`, `setMaxTwapAge`, `setEthUsdMaxDelay` | 3 | none (Ownable2Step) |
| GovernorBeacon | `upgradeTo` (inherited `UpgradeableBeacon`) | 1 | none — upgrades every per-vault governor at once |
| StrategyFactory | `setTemplateApproval` | 1 | none |

---

## Initialization

One-time entry points guarded by OZ `Initializable`. These remain attackable during deployment if the deploy transaction and the initialize transaction are separate.

| Contract | Function | Guard | Note |
|----------|----------|-------|------|
| SyndicateFactory | `initialize(InitParams)` | `initializer` | Deployed as an ERC1967 proxy |
| SyndicateVault | `initialize(InitParams)` | `initializer` | Called by the factory in the same tx as the proxy deployment |
| SyndicateGovernor | `initialize(vault, registry, config, factory, params)` | `initializer` | Called by the factory in the same tx as the BeaconProxy deployment |
| StakedWood | `initialize(InitParams)` | `initializer` | UUPS proxy |
| GuardianRegistry | `initialize(owner, factory, swood, reviewPeriod, blockQuorumBps)` | `initializer` | UUPS proxy |
| TokenVesting | `initialize(owner, beneficiary, token, start, cliff, duration, cancelable)` | `initializer` | Called by `VestingFactory` in the same tx as the clone |
| BaseStrategy | `initialize(vault, proposer, data)` | `_initialized` latch | The template's own copy is disabled in its constructor; `StrategyFactory` clones and initializes atomically |
