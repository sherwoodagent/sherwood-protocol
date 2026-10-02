## ADDED Requirements

### Requirement: Guardian-network simulation stakes before the proposal
To make guardian blocking real, guardians SHALL stake BEFORE the proposal is created. Both sides of the block-quorum comparison are read at the proposal's snapshot `snapshotAt`, one second before the timestamp of the block in which the proposal entered Pending (the `propose` block; for a collaborative proposal, the block of the last co-proposer approval): `openReview` stores `getPastTotalVotes(snapshotAt)` as the denominator and each vote weighs the voter's `getPastStake(voter, snapshotAt)`. Stake checkpointed at a timestamp at or before `snapshotAt` counts; stake checkpointed in that block or later neither votes (`NotActiveGuardian`) nor counts. The operator SHALL therefore advance time by ≥1s (`evm_increaseTime 1`) between staking and `propose`. `agentId = 0` is acceptable (a guardian's `agentId` is recorded, never checked against the identity registry).

Ballots weigh RAW stake, not the age-weighted `getPastVotes`, so a freshly staked cohort can block at once and no ageing step is needed. There is no cohort-size floor: any positive snapshot total decides its own review, and only a zero total fails open.

Reviews snapshot `blockQuorumBps` and the slash envelope at `openReview`; 30% of the snapshot stake voting Block rejects the proposal, slashes approvers (WOOD burned), and attributes blockers for off-chain Merkl rewards. Vote-change is allowed until the final 10% of the window; approvers are capped at 100/proposal, blockers uncapped. Slash severity is NOT voted: `voteOnProposal(address,uint256,GuardianVoteType,uint256)` carries the approver's WOOD lock and no severity argument, and `_severityBps(Review storage)` derives severity deterministically from the review — a quadratic ramp from `minSlashBps` to `maxSlashBps` that saturates at a 66.67% block supermajority, with the bounds snapshotted at `openReview` (stored plus one, so a genuine snapshot can never read as the unset sentinel). Each approver's rate is its lock over its slash basis, multiplied by that severity and clamped into the snapshotted envelope. The own bond is the only slash leg (DPoS delegation removed/postponed 2026-07-26). `emergencySettleWithCalls` re-checks `requiredOwnerBond = max(minOwnerStake, MIN_OWNER_BOND_FLOOR = 1,000 WOOD)` at call time (TVL scaling is not implemented in V1 → flat 10k floor at the deployed `minOwnerStake`), and additionally requires the posted bond to be strictly positive. The Slash Appeal Reserve is NOT auto-seeded by the mainnet deploy override — the operator SHALL seed it post-deploy (`approve` + `registry.fundSlashAppealReserve`).

#### Scenario: Stake placed after propose cannot vote
- **WHEN** a guardian stakes after `propose` and votes on that proposal's review
- **THEN** its snapshot stake is zero and the vote reverts `NotActiveGuardian`

#### Scenario: Fresh cohort blocks
- **WHEN** six guardians each stake 10,000 WOOD, time advances 1s, the proposal is created, and all six vote Block in its review
- **THEN** their raw snapshot weight is 60,000 against an 18,000 bar and the proposal is rejected and any approvers slashed

#### Scenario: Non-voting stake raises the bar
- **WHEN** another 100,000 WOOD is staked before `propose` and never votes
- **THEN** the bar is 30% of 160,000 = 48,000, and the six guardians' 60,000 still clears it; at 150,000 of non-voting stake (bar 63,000) it no longer would

#### Scenario: Appeal without a seeded reserve
- **WHEN** `refundSlash` is attempted before the Slash Appeal Reserve is funded
- **THEN** the refund cannot be paid — seeding the reserve is a required post-deploy step

## MODIFIED Requirements

### Requirement: The WOOD price is market-sourced and governance-capped
`ExposureLedger` SHALL resolve the WOOD price as `haircut(min(market, woodUsdPriceX8))`, floored at 1, where `market` is the wired WOOD/USD feed — on Robinhood the ceremony's own `WoodPoolFeed`, which is Chainlink-shaped — when it is fresh. `woodUsdPriceX8` SHALL NEVER be served as a price. With no market source available, or with a zero cap, the ledger SHALL revert `NoWoodPrice` rather than fall back to the governance scalar (design revision 2, 2026-08-02).

The runbook SHALL state the operational consequences:
- **Seed and maintain the cap ABOVE market.** It bounds upward manipulation and nothing else; a cap at `M×` market caps manipulation at `M×`. It does not need accuracy, because it is never the valuation — a monthly review is sufficient, since a drifted cap simply stops binding. It does need MAINTENANCE: it is the only thing bounding upward manipulation of a ~$438k pool, where moving spot 2× costs ~$91k. A cap seeded or left BELOW market binds on every read and understates every guardian bond, the proposer bond's WOOD price and the challenger bond's WOOD price.
- **Lowering the cap is the emergency brake** — safe direction, unbounded, immediate, and NOT rate-limited on-chain. The ledger's one-move-per-day interval and its 2×-per-raise ceiling were both removed (issue #89); rate limiting is enforced off-chain by a Zodiac module on the owner Safe. See "Rate limiting is enforced off-chain" below.
- **A keeper SHALL call `WoodPoolFeed.update()`**, permissionlessly and on a schedule shorter than the `maxDelay` passed to `setWoodFeed`. A failing keeper is how the feed goes stale, and a stale feed with no other WOOD source is `NoWoodPrice`. `update()` is a no-op when a pool is early or below its depth floor, so a failing keeper looks like nothing at all.
- **`NoWoodPrice` halts new risk.** `recordApproval` lets it revert (the approve-time slot floor values the lock at `woodPriceX8()`), so approve votes revert during an outage while block votes, which read no price, still land. `requireApproveQuorum` (execute), `proposerBondWood` (propose) and `ChallengeGame.file` all let it revert; `proposerBondWood` returns zero before reading the price when the required coverage is zero, so a zero-coverage proposal can still be proposed and executed. `slashBpsFor` reads no price at all, so convictions still compute through a total outage. Net effect: block votes work; approve votes, proposals and execution with non-zero required coverage, and new challenge filings halt; the challenge window keeps running.
- **Monitoring SHALL compare the WOOD feed's answer with `woodUsdPriceX8()`.** The ledger has no detail view and no event for either state. Alert when the cap sits below the feed's answer beyond a short excursion: the cap has drifted BELOW market and is pinning every bond while the market source sits inert. Alert on `woodPriceX8()` reverting at all.

#### Scenario: Operator wires a Chainlink WOOD feed
- **WHEN** the operator wires `setWoodFeed(feed, maxDelay)`
- **THEN** the runbook states that the feed is the market source but is still capped by `woodUsdPriceX8`, that on any of the four degraded shapes (feed unset, non-positive answer, stale, reverting) the ledger has NO market source and reverts `NoWoodPrice`, and that unwiring the feed is therefore never safe

#### Scenario: Operator considers the cap a conservative price
- **WHEN** an operator seeds `woodUsdPriceX8` at or below market, as the retired "≤ 30-day low" instruction said to
- **THEN** the cap binds permanently, every bond is valued at the cap, and the market source can no longer track a crash — the runbook names this as the misconfiguration to avoid, not a conservative choice

#### Scenario: The WOOD feed goes stale
- **WHEN** the keeper stops and the newest snapshot ages past the wired `maxDelay`
- **THEN** block votes continue to land, approve votes revert, new proposals with non-zero required coverage are refused at `propose`, proposals with non-zero required coverage cannot execute, `ChallengeGame.file` reverts `WoodPriceUnset`, and convictions on already-filed challenges still compute

## REMOVED Requirements

### Requirement: Guardian-network simulation preconditions
**Reason**: It described a cohort-size floor (`cohortTooSmall`) and age-weighted ballots that the registry does not have. Ballots weigh raw `getPastStake` at the proposal's snapshot, and any positive snapshot total decides its own review.
**Migration**: Replaced by "Guardian-network simulation stakes before the proposal".
