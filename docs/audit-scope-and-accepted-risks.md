# Audit scope and accepted risks

Reference for the external audit of `post-audit-v2`. Every statement describes the code on this
branch; file and function are cited so each can be checked.

## 1. Scope and branches

- **Audit scope:** `post-audit-v2` at `<post-audit-v2 freeze commit>`, the contracts under `src/`.
- **`v1-deploy`** at `<v1-deploy deploy commit>` is an ancestor of the scope. It is the code deployed
  first on Robinhood Chain (chain id 4663). Mainnet later moves to the audited code per
  [upgrade-v1-to-v2-runbook.md](upgrade-v1-to-v2-runbook.md): governors and the guardian registry are
  upgraded in place, `ChallengeGame` is redeployed, and the v1 `ExposureLedger` and
  `ProposerBondEscrow` are kept.
- The main difference: on `v1-deploy` a challenge is decided by a counter-bond and `TokenCourt`; on
  this branch it is decided by a guardian vote in `ChallengeGame.voteOnChallenge` / `resolve`, and
  `TokenCourt` does not exist.

## 2. Trust model

- **Untrusted:** agents and proposers, depositors, guardians, challengers, keepers, and any caller of
  a permissionless function (`executeProposal`, `settleProposal` after the strategy duration,
  `openReview`, `resolveReview`, `resolve`, `retireApproval`, `rerange`, `WoodPoolFeed.update`).
- **Semi-trusted: the vault owner.** Sets its vault's parameters, whitelist, agents and pause
  (`SyndicateVault`, `GovernorParameters`), and runs the emergency path, which is constrained by a
  guardian block vote and an owner bond (`GovernorEmergency`, `GuardianRegistry.openEmergency`).
- **Trusted: the protocol owner,** a Safe. It owns the factory, guardian registry and sWOOD (UUPS,
  `_authorizeUpgrade` is `onlyOwner`), the `GovernorBeacon` (`upgradeTo` upgrades every governor),
  the ledger, the tier registry, the strategy factory and the game. No contract imposes a timelock on
  it. The Safe cannot upgrade a vault (`SyndicateFactory.upgradeVault` is creator-only and needs
  `upgradesEnabled`).

## 3. Launch configuration

Set in `script/robinhood-mainnet/DeployAll.s.sol` (`deployAll`, checked again in `_validateAll`)
with values from `RobinhoodParams.sol`:

- **Who may create a vault.** `SyndicateFactory.createSyndicate` requires a prepared owner stake
  (`StakedWood.canCreateVault`, `MIN_OWNER_STAKE` 10,000 WOOD), ownership of an ERC-8004 agent id in
  the registry at `AGENT_REGISTRY`, and a creation fee of `INVITE_ONLY_CREATION_FEE` (1,000,000 WOOD)
  unless the Safe has called `setCreationSponsored(creator, true)`. Until the last step of run 2 the
  factory points at `AGENT_REGISTRY_CLOSED` (codeless), so every `createSyndicate` reverts.
- **Who may propose.** `ownerOnlyProposals` is on: `SyndicateGovernor._requireLaunchProposer` admits
  only the vault owner, with no co-proposers (`CollaborationDisabled`).
- **Who may deposit.** `depositsRestricted` is on: `SyndicateVault._depositsOpen` is false, so
  `deposit`, `mint`, `requestDeposit` and `settleDeposit` admit only addresses the vault owner added
  with `approveDepositor`.
- **Identity gating.** `createSyndicate` and `SyndicateVault.registerAgent` check ERC-8004 ownership
  against the factory's live `agentRegistry`, at registration time only.
- **The Safe can relax each flag at once:** `setOwnerOnlyProposals(false)`,
  `setDepositsRestricted(false)`, `setCreationFee`, `setCreationSponsored`, and `setAgentRegistry`
  (zero turns identity gating off).

## 4. Prior review

- Nethermind, report NM-0999: 31 findings, final fix-review commit `191901c`; every finding is fixed
  or mitigated. The report is not published.
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
  only the owner can unpause, and the management fee accrues for the time the proposal stays open
  (`SyndicateGovernor._chargeManagementFee`).

A blocked round slashes the owner bond (`requiredOwnerBond`, at least `MIN_OWNER_STAKE`), and the same
owner may re-bond and retry (`SyndicateFactory.rotateOwner` to itself is allowed mid-proposal). The
veto electorate is the proposal's propose-time snapshot (`openEmergency` reads
`getPastTotalVotes(snapshotAt)`, ballots read `getPastStake(voter, snapshotAt)`): stake that does not
vote raises the bar, and guardians who have since left still count. Accepted because the path exists
to unwind a stuck strategy and an on-chain check that the strategy unwound would lock it again.
Bounded by the guardian review and the bond. Reviewer rule: `docs/guardian-network.md`, "Reviewer
rule".

**5.2 Challenge vote.** A ballot is `min(getPastStake(voter, filedAt − 1), getPastStake(voter,
snapshotAt))` (`ChallengeGame.voteOnChallenge`), so only stake held at the propose-time snapshot
votes. The quorum base is read at filing (`ChallengeGame.file`) and includes stake that cannot vote:
stake added after `snapshotAt` and the stake of the challenger, proposer and co-proposers. A filing can
be admitted that no ballots can win, and a holder of such stake can push a conviction out of reach
without slash exposure. A bloc staked before `snapshotAt` that is not accused can still convict or
acquit by majority, and a ballot may land in the last second of `voteWindowAtFiling`. Accepted as the
cost of a snapshot electorate; bounded by `challengeQuorumBps` (owner-set in [10%, 100%]) and the
one-shot re-arm. Documented in the challenge-game spec and `docs/guardian-network.md`.

**5.3 Price outages halt the protocol while the challenge window runs.** If WOOD cannot be priced
(`ExposureLedger._woodPrice` reverts `NoWoodPrice`: zero cap, stale `WoodPoolFeed`, ETH/USD older than
`ETH_USD_MAX_AGE`, V3 liquidity below `MIN_V3_LIQUIDITY` or V2 WETH reserve below `MIN_WETH_RESERVE`),
or the vault-asset feed is stale (`coverageUsd` reverts `StalePrice`), then proposing with coverage,
approve votes (`ExposureLedger.recordApproval`), execution and challenge filing (`ChallengeGame.file`
reverts `WoodPriceUnset`) all revert. Block votes, settle, `voteOnChallenge` and `resolve` read no
price. The filing deadline is not extended. A challenger can restore a pool-depth floor for one block
and file (the floors are read-time checks; `WoodPoolFeed.update` is permissionless); nothing but the
Safe fixes a stale Chainlink feed. The Safe can re-point `setWoodFeed` / `setAssetFeed` with no delay,
and can raise `ExposureLedger.setChallengeWindow` and `ChallengeGame.setChallengeWindow` (the
deadline reads the live window) until the approvers' locks are retired (`retireApproval`). Accepted:
fail-closed pricing over a fallback price. Documented in `docs/coverage.md`.

**5.4 Locks on a cancelled or expired proposal are retained.** A lock clears only when its epoch
bucket expires (`ExposureLedger.retireApproval`), executed or not: 15–73 days after a cancel at
shipped parameters (`docs/coverage.md`). The proposer can cause this by cancelling. The lock carries
no slash risk, since an unexecuted proposal cannot be challenged.

**5.5 A convicted approver loses its lock, not its bond.** The rate is `ceil(lock / basis)` of the
slash basis at `executedAt` (`ExposureLedger.slashBpsForAt`), clamped into `[minSlashBps,
maxSlashBps]` (`StakedWood.slashVerdict`; 10% and 100% at launch). Slashed WOOD is burned
(`StakedWood._burnWood`); depositors are not compensated from it.

**5.6 Concentrated-liquidity strategy.** Swap floors are anchored on the pool's spot price
(`ConcentratedLiquidityStrategy._poolAnchoredMinOut`) after a TWAP check (`_requireSpotNearTwap`,
`maxTwapDeviationBps` compared in ticks), so the deviation bound, the pool fee and the slippage stack.
The 10% pool-share cap reads `pool.liquidity()` in the execute transaction (`_execute`,
`_requireWithinPoolShare`) and is not re-checked by `rerange`. `rerange` is permissionless within its
trigger, `minInterval` and `maxReranges`. LP mint and withdraw pass `amount0Min = amount1Min = 0`
(`_mintPosition`, `_closePosition`), relying on the swap floors and the TWAP check.

**5.7 Strategy registration proves shape only.** `StrategyFactory.registerStrategy` is permissionless
and checks that `vault()`, `proposer()` and `executed()` answer. A batch may call the vault asset or
any registered strategy (`SyndicateVault._guardBatchCalls`); containment comes from the per-call caps
(`BatchExecutorLib.executeBatch`), the net-outflow ceiling (`executeGovernorBatch`), the asset-call
rules (`AssetCallRules.spenderOf`, allowances reset after each batch) and guardian review.

**5.8 New vaults ship with the capital caps inert.** `maxCapitalBps()` and `tier2CallCapBps()` read
100% until set, and `minBufferBps` is 0 (`GovernorParameters`, `SyndicateVault.setMinBufferBps`). Only
the vault owner sets them (`docs/pre-deployment-parameter-review.md`).

**5.9 The vault owner can shorten the LP veto.** `setVotingPeriod` accepts
[`MIN_VOTING_PERIOD`, 3 days] and `setVetoThresholdBps` [20%, 80%] (`GovernorParameters`);
`MIN_VOTING_PERIOD` is 1 hour in the shipped governor implementation (`RobinhoodParams`), against a
24-hour factory default. Both take effect at once, frozen only while a proposal is open.

**5.10 Protocol-owner changes take effect with no on-chain delay.** `SyndicateFactory.setTierRegistry`,
`setExposureLedger`, `setBondEscrow` (for governors created afterwards) and `pushWiring` (existing
governors); `setParamsOverride` (overwrites a vault's governor parameters within bounds, even
mid-proposal); `ExposureLedger.setWoodFeed`, `setAssetFeed`; `SyndicateFactory.setProtocolConfig`,
which reaches only governors created afterwards. Raising `minOwnerStake` above a vault's posted bond
makes `emergencySettleWithCalls` revert `OwnerBondInsufficient` for that vault, and the owner cannot
top up or re-bond while the bond is non-zero, until the Safe lowers it again.

**5.11 External dependencies.**
- USDG on 4663 can be paused and can freeze addresses. The vault resets every approved spender after
  a batch (`executeGovernorBatch`, `forceApprove(spender, 0)`), so a frozen spender named in a stored
  approve call makes normal settle and `unstick` revert; the owner's emergency path remains. A frozen
  vault or a paused USDG halts every path.
- The ERC-8004 identity registry is an outside-owned upgradeable contract; the Safe can re-point or
  disable it (`setAgentRegistry`).
- Chainlink feeds on 4663 have no sequencer-uptime feed (`ExposureLedger.coverageUsd`).
- A single holder of most WOOD pool liquidity can halt the WOOD price by withdrawing below
  `MIN_V3_LIQUIDITY` (`WoodPoolFeed.latestRoundData`; `docs/coverage.md`).

**5.12 Portfolio, Morpho and stray tokens.** The Portfolio strategy runs only on a vault asset the
ledger prices within `PEG_TOLERANCE_BPS` (1%) of $1, at init and execute
(`PortfolioStrategy._requireUsdPegged`). Morpho markets are admitted by market id
(`TierRegistry.isMorphoMarketAllowed`, checked by `MorphoSupplyStrategy` and the CL strategy). A
non-asset token in a vault can only be sent to a strategy clone of that vault
(`SyndicateVault.rescueERC20`); one that no clone can sell stays in the vault, outside the share price.

**5.13 Share transfers are not gated.** `SyndicateVault._update` applies no depositor check, so a
whitelisted holder can transfer shares to any address while `depositsRestricted` is on.

## 6. Documents

`docs/` describes the code on this branch. `openspec/specs/` is the archived baseline;
`openspec/changes/*/specs/` hold deltas not yet archived, and where they differ the delta is
current. Some open changes still carry older text for requirements a later change also modifies;
prefer the later change:

- `per-call-capital-declarations`: "Governance parameter management" (older bounds); superseded by
  `audit-1002-docs-alignment`.
- `declared-coverage-locks`: "Execute-time approve quorum", "Booking failures never fail the approve
  vote", the review-path slash and "Approval recording books a guardian-declared WOOD lock" are
  superseded by `audit-1002-docs-alignment`; "Challenger bond sized to the coverage the filing
  freezes" is superseded by `audit-1002-v2-challenge-game-docs`.
- `proportional-quorum-sizing`: "Execute-time approve quorum" (reservation wording); superseded by
  `audit-1002-docs-alignment`.
- `anchor-coverage-at-execution`: allocation and settlement requirements written against a
  reservation model the code no longer has.

The reasoning is in `openspec/changes/audit-1002-docs-alignment/proposal.md` and
`openspec/changes/audit-1002-v2-challenge-game-docs/proposal.md`.
