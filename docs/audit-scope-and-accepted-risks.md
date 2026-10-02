# Audit scope and accepted risks

Reference for the external audit of `post-audit-v2`. Every statement describes the code on this
branch; file and function are cited so each can be checked.

## 1. Scope and branches

- **Audit scope:** the `post-audit-v2` commit named in the handover to the auditor; this file is part
  of that commit. In scope: the contracts under `src/`.
- **`v1-deploy`** at `1d38a28701cf7949f1a420b1bedb4ce36447620c` is an ancestor of the scope. It is the
  code deployed first on Robinhood Chain (chain id 4663). Mainnet later moves to the audited code per
  [upgrade-v1-to-v2-runbook.md](upgrade-v1-to-v2-runbook.md): governors and the guardian registry are
  upgraded in place, `ChallengeGame` is redeployed, and the v1 `ExposureLedger` and
  `ProposerBondEscrow` are kept.
- The main difference: on `v1-deploy` a challenge is decided by a counter-bond and `TokenCourt`; on
  this branch it is decided by a guardian vote in `ChallengeGame.voteOnChallenge` / `resolve`, and
  `TokenCourt` does not exist.

## 2. Trust model

- **Untrusted:** agents and proposers, depositors, guardians, challengers, keepers, and any caller of
  a permissionless function (`executeProposal`, `settleProposal` after the strategy duration,
  `resolveProposalState`, `reclaimProposerBond`, `openReview`, `resolveReview`,
  `resolveEmergencyReview`, `ChallengeGame.file` / `resolve`, `retireApproval`, the queue's `claim`,
  `rerange`, `WoodPoolFeed.update`). At launch every proposer power (proposing, cancelling,
  self-settle after `MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE` = 1 h, Portfolio `rebalanceDelta`) is
  held by the vault owner, because only the owner may propose (§3).
- **Semi-trusted: the vault owner.** Sets its vault's parameters, whitelist, agents and pause
  (`SyndicateVault`, `GovernorParameters`), and runs the emergency path, which is constrained only by
  a guardian block vote and an owner bond (`GovernorEmergency`, `GuardianRegistry.openEmergency`).
- **Trusted: the protocol owner,** a Safe. It owns the factory, guardian registry and sWOOD (UUPS,
  `_authorizeUpgrade` is `onlyOwner`), the `GovernorBeacon` (`upgradeTo` upgrades every governor),
  the ledger, the tier registry, the strategy factory and the game. No contract imposes a timelock on
  it. The Safe cannot call `upgradeVault` (creator-only, needs `upgradesEnabled`), but it controls
  vault code indirectly. It can upgrade the factory, which is the vault's only upgrade authority
  (`SyndicateVault._authorizeUpgrade`). It can re-point every vault's delegatecalled executor
  (`SyndicateFactory.setExecutorImpl` + `pushExecutor`, outside a proposal). It upgrades every
  governor, the vault's only batch caller, through the beacon.

## 3. Launch configuration

Set in `script/robinhood-mainnet/DeployAll.s.sol` (`deployAll`, checked again in `_validateAll`)
with values from `RobinhoodParams.sol`:

- **Who may create a vault.** `SyndicateFactory.createSyndicate` requires a prepared owner stake
  (`StakedWood.canCreateVault`, `MIN_OWNER_STAKE` 10,000 WOOD), ownership of an ERC-8004 agent id in
  the registry at `AGENT_REGISTRY`, and a creation fee of `INVITE_ONLY_CREATION_FEE` (1,000,000 WOOD)
  unless the Safe has called `setCreationSponsored(creator, true)`. The factory points at
  `AGENT_REGISTRY_CLOSED` (codeless), so every `createSyndicate` reverts until run 2 opens creation,
  one step before the ownership handoff (`deployAll`, `setAgentRegistry` then `_handoffAll`).
- **Who may propose.** `ownerOnlyProposals` is on: `SyndicateGovernor._requireLaunchProposer` admits
  only the vault owner, who must first register itself as an agent (`propose` requires
  `isAgent(msg.sender)`), with no co-proposers (`CollaborationDisabled`).
- **Who may deposit.** `depositsRestricted` is on: `SyndicateVault._depositsOpen` is false, so
  `deposit`, `mint`, `requestDeposit` and `settleDeposit` admit only receivers the vault owner added
  with `approveDepositor`. The check is on the receiver, not the payer (anyone can pay on behalf of an
  approved receiver), and the owner can approve itself.
- **Identity gating.** `createSyndicate` and `SyndicateVault.registerAgent` check ERC-8004 ownership
  against the factory's live `agentRegistry`, at registration time only.
- **The Safe can relax each flag at once:** `setOwnerOnlyProposals(false)`,
  `setDepositsRestricted(false)`, `setCreationFee`, `setCreationSponsored`, and `setAgentRegistry`
  (zero turns identity gating off).

## 4. Prior review

- Nethermind, report NM-0999: 31 findings; at the final fix-review commit `191901c` every finding is
  fixed or mitigated. The report keeps its standard recommendation of a further independent review,
  and code written after `191901c` was outside its scope. The report is not published.
- Internal adversarial reviews on 1 and 2 October 2026. Their fixes are merged into this branch.

## 5. Accepted risks and known limitations

Each item: what the code allows; why it is accepted; what bounds it; where it is documented.

**5.1 The emergency path is controlled only by the guardian veto.** An emergency round
(`GovernorEmergency.emergencySettleWithCalls` → `finalizeEmergencySettle`) runs owner-written calls
with per-call caps off and a zero net-outflow budget measured on the vault's pre-batch balance
(`SyndicateVault.executeGovernorBatch`). If guardians do not reach block quorum, the owner can:
- take what the strategy returns inside the batch: `[clone.rescueTo(asset), asset.transfer(owner, x)]`
  passes, because asset `transfer` to any address is allowed (`AssetCallRules.spenderOf`) and only the
  net change of the vault balance is metered;
- close a proposal with capital still on the strategy: `finalizeEmergencySettle` checks neither
  `IStrategy.executed()` nor the settle-price floor (an empty call list finalizes), and deposits and
  redemptions reopen at a share price that excludes the position (`SyndicateVault.depositsLocked`);
- cancel a round for free while block weight is below quorum (`GuardianRegistry.cancelEmergency`),
  and reopen one `reviewPeriod` later; emergency block votes have no late-vote lockout;
- pause the vault (`SyndicateVault.pause`) with a proposal executed, which blocks `settleProposal`,
  `unstick` and `finalizeEmergencySettle` (all go through `executeGovernorBatch`, `whenNotPaused`);
  only the owner can unpause, and the management fee keeps accruing (5.14).

A blocked round burns the whole posted owner bond (`StakedWood.slashOwnerBond`; the bond is at least
`requiredOwnerBond` = max(`minOwnerStake`, `MIN_OWNER_BOND_FLOOR`)), and the same owner may re-bond and
retry (`SyndicateFactory.rotateOwner` to itself is allowed mid-proposal). The veto electorate is the
proposal's propose-time snapshot: `openEmergency` stores `getPastTotalVotes(snapshotAt)` as
`totalStakeAtOpen` and `snapshotAt` itself as `er.openedAt` (falling back to `block.timestamp − 1` only
for a review registered before `snapshotAt` existed), and each block vote weighs
`getPastStake(voter, er.openedAt)` (`voteBlockEmergencySettle`). Stake that does not vote raises the
bar, and guardians who have since left still count. Accepted because the path exists to unwind a stuck
strategy and an on-chain check that the strategy unwound would lock it again. Bounded only by the
guardian review and the bond. Reviewer rule: `docs/guardian-network.md`, "Reviewer rule".

**5.2 Challenge vote.** A ballot is `min(getPastStake(voter, filedAt − 1), getPastStake(voter,
snapshotAt))` (`ChallengeGame.voteOnChallenge`), so only stake held at the propose-time snapshot
votes, and only from an active guardian (`isActiveGuardian`). The quorum base is read at filing
(`ChallengeGame.file`) and includes stake that cannot vote: stake added after `snapshotAt`, the stake
of the challenger, proposer and co-proposers, and the stake of any guardian that requests unstake
after the filing. A filing can be admitted that no ballots can win, and a holder of such stake can
push a conviction out of reach without slash exposure. A bloc staked before `snapshotAt` that is not
accused can still convict or acquit by majority, and a ballot may land in the last second of
`voteWindowAtFiling`. The challenger's terms, the quorum and its base, and the vote window are pinned
at filing; the approvers' slash rates are read at settlement (`_settle` → `slashBpsFor`) and clamped
by sWOOD's live `minSlashBps` / `maxSlashBps`. Accepted as the cost of a snapshot electorate; bounded
by `challengeQuorumBps` (owner-set in [10%, 100%]) and the one-shot re-arm. Documented in the
challenge-game spec and `docs/guardian-network.md`.

**5.3 Price outages halt the protocol while the challenge window runs.** A stale vault-asset feed
makes every `propose` revert (`ExposureLedger.requireWithinCoveredTvlCap` → `coverageUsd` reverts
`StalePrice`). A WOOD outage (`NoWoodPrice`: zero cap; `WoodPoolFeed` reverting `PriceUnavailable` —
no window spanned, ETH/USD older than `ETH_USD_MAX_AGE`, V3 in-range liquidity below
`MIN_V3_LIQUIDITY`, V2 WETH reserve below `MIN_WETH_RESERVE`; or the feed older than the ledger's
`maxDelay`) makes `propose` revert when it sizes a proposer bond (`proposerBondWood`). Either outage
makes `recordApproval` (approve votes), execution of a proposal with non-zero `requiredCoverage`
(`requireApproveQuorum`), and `ChallengeGame.file` revert (`file` reports both as `WoodPriceUnset`).
Block votes, `resolveReview`, `voteOnChallenge` and `resolve` read no price; settle reads no ledger
price, but a strategy's `_settle` reads its own feeds and reverts on their outage (Portfolio
`_feedPrice`, 26 h bound; the CL strategy's pool TWAP and spot, and the Morpho oracle when it
deleverages). The filing deadline is not extended. A challenger can restore the V3 depth floor for
the filing block (the floors are read-time checks). A lapsed V2 leg is restored in one block by adding
reserves and calling the permissionless `WoodPoolFeed.update`, provided the last snapshot is less than
`MAX_SNAPSHOT_SPAN` (7 days) old; otherwise it needs one more window. Nothing but the Safe fixes a
stale Chainlink feed. The Safe can re-point `setWoodFeed` / `setAssetFeed` with no delay, and can
raise `ExposureLedger.setChallengeWindow` and `ChallengeGame.setChallengeWindow` (the deadline reads
the live window) until the approvers' locks are retired (`retireApproval`). Accepted: fail-closed
pricing over a fallback price. Documented in `docs/coverage.md`.

**5.4 Locks on a cancelled or expired proposal are retained.** A lock clears only when its epoch
bucket expires (`ExposureLedger.retireApproval`), executed or not: about 15–73 days after a cancel at
the 24 h factory `executionWindow` (14–79 days across its allowed range of 1 h–7 d), plus any review
time left at the cancel (`docs/coverage.md`). Meanwhile the lock consumes the guardian's approve
budget and blocks `StakedWood.claimUnstakeGuardian`. The proposer can cause this by cancelling
(`SyndicateGovernor.cancelProposal`). The lock carries no slash risk, since an unexecuted proposal
cannot be challenged.

**5.5 Slash size.** A convicted approver loses max(lock, `minSlashBps` × slash basis), capped at the
basis and at `maxSlashBps` × basis. The basis is min(max(stake checkpoint, liability checkpoint) at
`executedAt` − 1, live stake), the liability checkpoint keeping unstake-requested stake slashable until
it is claimed (`StakedWood._slashableAt`); the rate is `ceil(lock / basis)`
(`ExposureLedger.slashBpsForAt`), raised to `minSlashBps` and capped at `maxSlashBps`
(`StakedWood.slashVerdict`; 10% and 100% at launch). A guardian whose lock is below the floor loses
more than it locked. A blocked guardian review slashes approvers at lock rate × severity, clamped the
same way (`GuardianRegistry._reviewSlashRates`). All slashed WOOD is burned (`StakedWood._burnWood`);
depositors are not compensated from it.

**5.6 Concentrated-liquidity strategy.** Execute and rerange floor each swap at max(adapter quote,
pool anchor); settle floors on the pool anchor alone (`ConcentratedLiquidityStrategy._floorFor`,
`_swapToAsset`). The pool anchor is the pool's spot price (`_poolAnchoredMinOut`) after a TWAP check
(`_requireSpotNearTwap`), so the deviation bound, the pool fee and the slippage stack.
`maxTwapDeviationBps` is at most 1,000 and is compared in TICKS (about 10.5%), and the TWAP window can
be as short as 300 s (`MIN_TWAP_WINDOW`); both are proposer-chosen. The 10% pool-share cap reads
`pool.liquidity()` — in-range liquidity — in the execute transaction (`_execute`,
`_requireWithinPoolShare`), `executeProposal` is permissionless, and `rerange` never re-checks it.
Liquidity added in the same block passes the 10% cap; it is a measurement at one instant. `rerange` is
permissionless within its trigger, `minInterval` (which may be 0) and `maxReranges` (≤ 20). LP mint
and withdraw pass `amount0Min = amount1Min = 0` (`_mintPosition`, `_closePosition`). At settle the LP
withdrawal (zero mins) runs before the TWAP check, which runs only if an `otherToken` balance remains.

**5.7 Strategy registration proves shape only.** `StrategyFactory.registerStrategy` is permissionless
and checks that `vault()`, `proposer()` and `executed()` answer. A batch may call the vault asset or
any registered strategy (`SyndicateVault._guardBatchCalls`); containment comes from the per-call caps
(`BatchExecutorLib.executeBatch`), the net-outflow ceiling (`executeGovernorBatch`), the asset-call
rules (`AssetCallRules.spenderOf`, allowances reset after each batch) and guardian review.
It also requires code and pins the codehash; a proxy keeps its codehash when its implementation is
swapped, and a registered target need not name the vault whose batch calls it.

**5.8 New vaults ship with the capital caps inert.** `maxCapitalBps()` and `tier2CallCapBps()` read
100% until set, and `minBufferBps` is 0 (`GovernorParameters`, `SyndicateVault.setMinBufferBps`). Only
the vault owner sets them (`docs/pre-deployment-parameter-review.md`).

**5.9 The vault owner can shorten the LP veto.** `setVotingPeriod` accepts
[`MIN_VOTING_PERIOD`, 3 days] and `setVetoThresholdBps` [20%, 80%] (`GovernorParameters`);
`MIN_VOTING_PERIOD` is 1 hour in the shipped governor implementation (`RobinhoodParams`), against a
24-hour factory default. Both take effect at once, frozen only while a proposal is open.

**5.10 Protocol-owner changes take effect with no on-chain delay.**
- `SyndicateFactory.setTierRegistry`, `setExposureLedger`, `setBondEscrow` (for governors created
  afterwards) and `pushWiring` (existing governors); `setParamsOverride` (overwrites a vault's governor
  parameters within bounds, even mid-proposal); `setProtocolConfig` (reaches only governors created
  afterwards); `setVaultImpl`, `setExecutorImpl` / `pushExecutor`, `setBeacon`.
- `TierRegistry.setStrategyFactory`: re-pointing it (zero is refused) makes `_guardBatchCalls` reject
  every strategy the old factory registered, halting settle, `unstick` and emergency rounds for every
  vault. Also `setMorphoMarketAllowed`, `setCounterpartyAllowed`, `setPriceSourceForToken`, `certify` /
  `certifyClass` / `demote`.
- `ExposureLedger.setWoodFeed`, `setAssetFeed`, `setWoodUsdPrice`, `setWoodHaircutBps`,
  `setCoveredTvlCapUsd`, `setProposerBondBps`. Lowering the game's `challengeWindow` retroactively closes filing deadlines of executed
  proposals; lowering the ledger's too (game first: the ledger refuses a window below the game's, or
  below `reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW`) frees locks sooner.
- `GuardianRegistry.pause` halts review voting and `openEmergency` / `finalizeEmergency` (anyone may
  unpause after `DEADMAN_UNPAUSE_DELAY` = 7 days); `refundSlash` pays out of the appeal reserve.
- Raising `minOwnerStake` above a vault's posted bond makes `emergencySettleWithCalls` revert
  `OwnerBondInsufficient` for that vault, and the owner cannot top up or re-bond while the bond is
  non-zero, until the Safe lowers it again.

**5.11 External dependencies.**
- USDG on 4663 can be paused and can freeze addresses; this is a property of the external token,
  observed on chain and not verifiable from this repository. The vault resets every approved spender
  after a batch (`executeGovernorBatch`, `forceApprove(spender, 0)`), so a frozen spender named in a
  stored approve call makes normal settle and `unstick` revert; the owner's emergency path remains. A
  frozen vault or a paused USDG halts every path.
- The ERC-8004 identity registry is an outside-owned upgradeable contract; the Safe can re-point or
  disable it (`setAgentRegistry`).
- Chainlink feeds on 4663 have no sequencer-uptime feed, and none is checked: `ExposureLedger.coverageUsd`,
  `WoodPoolFeed._ethUsdX8`, `PortfolioStrategy._feedPrice`. Min/max-answer clamping is not detected.
- A holder of most of the V3 in-range liquidity, or of most of the V2 pair's WETH, can halt the WOOD
  price by withdrawing. Anyone can halt it for as long as they hold the price there, by swapping the V3
  tick out of the range that holds the liquidity (not possible while all V3 liquidity is full-range)
  or draining the pair's WETH below `MIN_WETH_RESERVE`, at the cost of price impact; a filing near its
  deadline can be front-run this way (`WoodPoolFeed._poolTwapX112`, `_twapX112`; `docs/coverage.md`).

**5.12 Portfolio, Morpho and stray tokens.** The Portfolio strategy runs only on a vault asset the
ledger prices within `PEG_TOLERANCE_BPS` (1%) of $1, at init and execute
(`PortfolioStrategy._requireUsdPegged`). Morpho markets are admitted by market id
(`TierRegistry.isMorphoMarketAllowed`, checked by `MorphoSupplyStrategy` and the CL strategy). A
non-asset token in a vault can only be sent to a strategy clone of that vault
(`SyndicateVault.rescueERC20`); one that no clone can sell stays in the vault, outside the share price.

**5.13 Share transfers are not gated.** `SyndicateVault._update` applies no depositor check, so a
whitelisted holder can transfer shares to any address while `depositsRestricted` is on.

**5.14 Management fee.** The base is `totalAssets()` stamped once at execute, before the batch
(`SyndicateVault.startManagementAccrual` from `executeProposal`): the whole fund, not the deployed
capital. It accrues until settle regardless of P&L, including while the vault is paused or settle is
blocked (`SyndicateGovernor._chargeManagementFee`). At launch the proposer is the owner, so the agent
share goes to the owner.

**5.15 Guardian review.** Review ballots weigh raw stake at the propose-time snapshot
(`getPastStake(voter, snapshotAt)`, `GuardianRegistry.voteOnProposal`). There is no age discount;
`ageFloorBps` / `maturationPeriod` have no on-chain reader. Stake placed one second before `propose`
votes at full weight. Blockers are uncapped and carry no slash exposure. Block weight reaching
`blockQuorumBps` (30%) of `getPastTotalVotes(snapshotAt)` rejects the proposal and slashes every
approver at lock rate × severity (`resolveReview`, `_reviewSlashRates`); severity ramps from
`minSlashBps` to `maxSlashBps` as block weight approaches the supermajority (`_severityBps`). Stake
that does not vote raises the bar.

**5.16 Ceremony windows.** Both `ProtocolConfig` fee recipients are seeded to the deployer key
(`Deploy._seatOwnerWrites`) until the Safe calls `setProtocolFeeRecipient` /
`setGuardiansFeeRecipient`. Recipients are snapshotted at `propose`
(`SyndicateGovernor._snapshotFeeConfig`), so any proposal made before then pays the deployer at
settle. Creation opens one step before the handoff. `ProtocolConfig`, `TierRegistry`,
`ExposureLedger` and `ChallengeGame` are `Ownable2Step` and stay deployer-owned until the Safe calls
`acceptOwnership` (`DeployAll._handoffAll`). The deployer keeps `Create3Factory` ownership and can
deploy at unused salts.

**5.17 Stamped redeem waits a cycle.** A redeem stamped at settle but not claimed before the next
proposal opens cannot be claimed (`VaultWithdrawalQueue.claim` reverts `VaultLocked`) or cancelled
(`cancel` reverts `AlreadySettled`) until that proposal settles. Its assets stay reserved at the
stamped price. The owner sets the cooldown between proposals (minimum 1 h).

**5.18 Settle can be sandwiched to its floor.** `settleProposal` is permissionless after the duration,
and the settler chooses the block. Portfolio sells each token at the Chainlink value less
`maxSlippageBps` (0.5–10%), with feeds up to 26 h old, treating one asset unit as $1
(`PortfolioStrategy._sellFloor`, `_feedPrice`). CL settle floors on pool spot within
`maxTwapDeviationBps` ticks (≤ about 10.5%) of a TWAP that may be 300 s long (`_swapToAsset`). Each
settle swap, and each CL rerange (≤ 20), can be sandwiched to its floor.

**5.19 Morpho liquidity and liquidation.** `MorphoSupplyStrategy._settle` withdraws all shares and
reverts while the market lacks liquidity, which also blocks `unstick`. The CL strategy fixes its LTV at
init, at most LLTV − 5 percentage points (`MIN_LLTV_BUFFER_BPS`), borrows at execute, and has no
relief before settle, so interest
can push it into Morpho liquidation; if proceeds do not cover the debt, settle reverts until someone
transfers the asset to the clone (`_repayAndWithdraw`, `_deleverage`). The market-id allowlist is the
only check. Before allowing an id the Safe must review collateral token, oracle, lltv, irm and
liquidity.

**5.20 Portfolio after execute.** The ±1% peg is checked only at init and execute, never at
`rebalanceDelta` or settle. A depeg loosens the floors, or makes them unreachable and settle revert.
`rebalanceDelta` is proposer-only, with no rate limit, over the routes set in the strategy's
parameters, each swap floored at feed − `maxSlippageBps`.

**5.21 CL TWAP grief.** On a low-cardinality pool, anyone can make execute, rerange or settle revert
`TwapUnavailable` with a few small swaps in separate blocks (`_tryTwapTick`). The permissionless remedy
is `increaseObservationCardinalityNext` on the pool.

## 6. Documents

`docs/` describes the code on this branch. `docs/papers/` is design rationale; where it differs from
the code, the code and `docs/` govern.

`openspec/specs/` is current with the code as of this commit: every change whose behaviour is
implemented here has been archived into it (`openspec/changes/archive/2026-10-02-*`), with its deltas
corrected against the code first, and `openspec-sync-corrections` fixed the remaining requirements no
change had touched. The archive folders are history; their `design.md`, `proposal.md` and `tasks.md`
files (some of which describe `TokenCourt` and other `v1-deploy` mechanisms) are not normative. Two
archived changes, `wood-price-twap-ceiling` and `propose-time-target-validation`, were archived without
applying their deltas because their behaviour shipped in a different shape; each proposal says where
the normative text lives.

Two change folders remain open under `openspec/changes/`, and neither describes code on this branch:

- `permissionless-tier2-sandbox`: a per-proposal sandbox for arbitrary tier-2 calls. Not
  implemented; no sandbox contract exists.
- `target-based-batch-gating`: an adapter-allowlist callee gate for governor batches. Not
  implemented; superseded by the registered-strategy batch rule (`SyndicateVault._guardBatchCalls`).

Known limits of the specs:

- `## Purpose` paragraphs cannot be changed through an OpenSpec delta, and some still carry history
  that the requirements beneath them supersede: `epoch-nav` (names `WoodTwapOracle`, the retired
  `PriceRouter` and a fallback rule), `syndicate-vault` (Lane A), `dimensional-conventions`
  ("insurance", reserved/allocated subtypes), `guardian-staking` ("age-weighted vote checkpoints"),
  `guardian-coverage` ("USD exposure"), `challenge-game` (omits the convict-majority condition),
  `guardian-fleet` and `fee-splits`. `portfolio-strategy`, `strategy-lifecycle` and
  `continuous-integration` carry the tool's placeholder Purpose. Where a Purpose and a requirement
  differ, the requirement governs.
- `guardian-agent` and `guardian-fleet` specify an off-chain daemon that is not in this repository;
  only the on-chain facts they cite were checked.
- `operator-docs` requires an onboarding checklist that `docs/adapter-onboarding-checklist.md` does
  not yet meet; that document is marked stale at its top.
