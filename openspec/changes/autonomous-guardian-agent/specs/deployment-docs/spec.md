## MODIFIED Requirements

### Requirement: Guardian-network simulation preconditions
To make guardian blocking real (not the cold-start bypass), total staked guardian weight at review-open SHALL exceed `MIN_COHORT_STAKE_AT_OPEN` = 50,000 WOOD — e.g. ≥6 wallets staking 10,000 WOOD each. `agentId = 0` is acceptable (no agentRegistry on the fork). Guardians become active at `block.timestamp`, and checkpoints are read at `t−1`, so the operator SHALL advance time by ≥1s (`evm_increaseTime 1`) between staking and opening a review.

Clearing the cohort floor is necessary but NOT sufficient, because the two sides of the block-quorum comparison are measured differently: `cohortTooSmall` and the quorum denominator read `getPastTotalVotes`, which is RAW staked WOOD ("totals stay raw"), while a blocker's contribution reads `getPastVotes`, which applies `_ageFactorBps` on top. Fresh stake therefore counts in full against the bar it must clear and at only `ageFloorBps` (25%) toward clearing it. A cohort whose stake is all fresh cannot reach a 30% block quorum even at 100% participation — 0.25 × 60,000 = 15,000 against the 18,000 required. This asymmetry is deliberate: it denies an attacker a veto bought with stake parked seconds before the review. The operator SHALL therefore age the cohort before opening a review that is meant to be blocked, advancing time by at least `maturationPeriod × (blockQuorumBps − ageFloorBps) / (10 000 − ageFloorBps)` — 2 days at the fork's defaults (30 d, 30%, 25%) — and proportionally more when participation is partial.

Reviews snapshot cohort stake + `blockQuorumBps` at entry; 30% of cohort stake voting Block rejects the proposal, slashes approvers (WOOD burned), and attributes blockers for off-chain Merkl rewards. Vote-change is allowed until the final 10% of the window; approvers are capped at 100/proposal, blockers uncapped. Slash severity is NOT voted: `voteOnProposal(address,uint256,GuardianVoteType)` carries no severity argument, and `_severityBps(Review storage)` derives it deterministically from the review — a quadratic ramp from `minSlashBps` to `maxSlashBps` that saturates at a 66.67% block supermajority, with the bounds snapshotted at `openReview` (stored plus one, so a genuine snapshot can never read as the unset sentinel) to deny an owner any mid-review re-rating. The own bond is the only slash leg (DPoS delegation removed/postponed 2026-07-26). `emergencySettleWithCalls` re-checks `requiredOwnerBond = max(minOwnerStake, MIN_OWNER_BOND_FLOOR = 1,000 WOOD)` at call time (TVL scaling is not implemented in V1 → flat 10k floor at the deployed `minOwnerStake`), and additionally requires the posted bond to be strictly positive. The Slash Appeal Reserve is NOT auto-seeded by the mainnet deploy override — the operator SHALL seed it post-deploy (`approve` + `registry.fundSlashAppealReserve`).

#### Scenario: Cold-start floor cleared
- **WHEN** six guardians each stake 10,000 WOOD and time advances 1s before a review opens
- **THEN** cohort stake 60,000 > 50,000 clears `cohortTooSmall`, so the review is votable rather than auto-cleared

#### Scenario: Fresh cohort cannot reach the block quorum
- **WHEN** all six guardians vote Block on a review opened 1s after staking
- **THEN** their combined age-weighted weight is 15,000 against an 18,000 bar and the proposal is NOT rejected — the sim MUST advance time ≥2 days after staking for a block to be achievable

#### Scenario: Aged cohort blocks
- **WHEN** the operator advances `evm_increaseTime 172800` after staking and then opens the review
- **THEN** `_ageFactorBps` has reached 30%, and 30% of the snapshot voting Block rejects the proposal and slashes approvers

#### Scenario: Appeal without a seeded reserve
- **WHEN** `refundSlash` is attempted before the Slash Appeal Reserve is funded
- **THEN** the refund cannot be paid — seeding the reserve is a required post-deploy step
