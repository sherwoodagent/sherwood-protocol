# Tasks

## 1. Voting weight and veto bounds

- [x] 1.1 Raw-stake ballots: `docs/guardian-network.md`, `docs/proposal-lifecycle.md`, guardian-staking, deployment-docs and guardian-agent deltas, `IStakedWood` and `IGuardianRegistry` natspec.
- [x] 1.2 Voting period floor and veto bounds: syndicate-governor delta, `docs/proposal-lifecycle.md`, `GovernorParameters` natspec.

## 2. Slashing and coverage

- [x] 2.1 Lock-based slash rate: guardian-slashing delta, `ChallengeGame` natspec (`rule` on `v1-deploy`; no counterpart on `post-audit-v2`), `test/ChallengeEndToEnd.t.sol` comment.
- [x] 2.2 Cap-only WOOD pricing, approval recording, coverage measurement: guardian-coverage, dimensional-conventions and deployment-docs deltas; `ExposureLedger` header and `setWoodUsdPrice` natspec; runbook and parameter-review monitoring lines.
- [x] 2.3 `docs/coverage.md`: lock retention after a cancel (15–73 days); price outages during the challenge window.

## 3. Emergency path

- [x] 3.1 `docs/guardian-network.md`: what an unblocked round lets the owner do, the snapshot electorate, the reviewer rule.

## 4. Fees, feeds and the queue

- [x] 4.1 Management-fee base stamped once at execute (vault and governor comments, `docs/fees.md`).
- [x] 4.2 `setProtocolConfig` does not reach existing governors (`ProtocolConfig`, `SyndicateFactory` natspec, `docs/fees.md`).
- [x] 4.3 `WoodPoolFeed._meanTick` rounding direction; `maxTwapDeviationBps` is compared in ticks.
- [x] 4.4 syndicate-vault delta and `docs/deposit-withdraw-flow.md`: stamp denominator, live deposit-claim price, deposit cancellation, lock timing.
