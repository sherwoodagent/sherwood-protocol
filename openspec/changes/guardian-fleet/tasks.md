All groups land in the `sherwood-guardian` repo. This repo carries the spec only.

## 1. Decide the fleet before writing code

- [ ] 1.1 Set M from an uptime target, and record the target — M buys availability and key containment only, never blocking power
- [ ] 1.2 Set the operator's intended share of total staked WOOD, since that number and not M decides whether the cohort can block at all
- [ ] 1.3 Fix the per-identity stake allocation before staking; `FLOOR_LOOKBACK` is 30 days and reallocation costs a full lookback of fleet weight
- [ ] 1.4 Decide whether the keeper serves every governor it sees or a configured vault list; every governor is the safer default

## 2. Keeper role

- [x] 2.1 Add a role selector so one image runs as keeper or voter, defaulting to voter
- [x] 2.2 Build the keeper loop on the existing `openReview` and `resolveReview` in `src/signer.ts` — both are implemented and unreachable from `src/index.ts` today
- [x] 2.3 Schedule work from `ReviewRegistered` rather than reacting to `ReviewOpened`, so the keeper acts on reviews that have not opened yet
- [x] 2.4 Open a review as soon as chain time passes its `voteEnd`; the cohort's usable voting time is `reviewEnd - openedAt` minus the late-vote lockout, so keeper delay silences the cohort
- [x] 2.5 Add randomized jitter before sending, and treat a losing race as a successful no-op rather than an error
- [x] 2.6 Pass `registrationSearchFromBlock` from the registry's deployment block — `src/index.ts` passes no options today, so the default of `0n` rescans from genesis on every cold start
- [x] 2.7 Refuse to start a keeper that holds stake, and refuse to start a voter configured to open or resolve reviews
- [x] 2.8 Unit-test that a keeper casts no vote, and that a second keeper acting on an already-opened review records a no-op rather than a failure

## 3. Identity isolation

- [ ] 3.1 Give each identity its own Railway service, signing key, volume, and health port
- [x] 3.2 Refuse to start when two instances are configured with the same signing key
- [x] 3.3 Verify `assertNotAnAgent` runs for every identity against every vault it reviews, not only the first
- [x] 3.4 Document the gas funding path for M voter plus K keeper accounts, without a single funder account as a serialization point

## 4. Shared simulation, per-guardian policy

- [ ] 4.1 Split the review pipeline out of the voting loop; the pipeline holds no signing key
- [ ] 4.2 Define the evidence record — risk findings, simulation outcome, invariant measurements, coverage inputs — and persist one per review
- [ ] 4.3 Move per-guardian policy into configuration: drawdown bound, posture, coverage ceiling, whether a model is consulted
- [ ] 4.4 Abstain across every identity when no evidence record exists for a review, rather than voting on absent evidence
- [ ] 4.5 Give the pipeline the same heartbeat and staleness treatment as the daemons — it holds no stake, but its failure silences every guardian at once
- [ ] 4.6 Unit-test that two policies over one evidence record can reach different verdicts

## 5. Blockable capacity

- [x] 5.1 Compute fleet weight with the registry's own growth gate, so the reported number matches what the contract would compute
- [x] 5.2 Count an identity only when its heartbeat is fresh and its gas balance is above the level needed to send a vote
- [x] 5.3 Expose blockable capacity against `blockQuorumBps × totalStake` as a distinct signal from per-instance health
- [x] 5.4 Alert on loss of blockable capacity, not on individual instance liveness
- [x] 5.5 Unit-test that an unfunded identity is excluded from capacity rather than counted as healthy

## 6. Deployment

- [ ] 6.1 Extend `railway.json` for the keeper and voter roles and the pipeline service
- [ ] 6.2 Verify the mainnet posture gate still refuses `autonomous` on every chain but the fork, for every service in the fleet
- [ ] 6.3 Document the fleet as an operator-run cohort, not a decentralised one, wherever the guardian network is described
