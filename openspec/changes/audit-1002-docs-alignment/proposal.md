# Audit 2026-10-02: documents and specs aligned with the code on v1-deploy

## Why

Several normative specs and operator documents describe behaviour the contracts on `v1-deploy` do not
have. They are the next auditor's baseline and the guardians' operating reference, so they must say
what the code does.

## What Changes

Documents only. No executable source changes; natspec comments only in `src/` and one test comment.

- Guardian review and emergency block votes weigh raw `getPastStake` at the propose-time snapshot;
  only `TokenCourt.vote` uses the age-weighted `getPastVotes`.
- Per-vault voting period floor is 1 hour on the mainnet implementation (factory default 24 hours);
  veto threshold bounds are 20–80%; votingPeriod maximum is 3 days; strategy duration maximum 30 days.
- The slash is the approver's lock, floored at `minSlashBps` of the basis; a blocked review scales it
  by severity. There is no slash bounty.
- The WOOD price is `haircut(min(feed, cap))` with no fallback and no detail view; the cap has no
  on-chain rate limit; an approve vote reverts during a WOOD-price or asset-feed outage and a block
  vote lands.
- The approve-time slot floor, the coverage measurement that scales a partial book, and the absence
  of a quorum tier threshold.
- Queued deposits claim at the live `previewDeposit` price and cancel at any time until claimed; the
  settle stamp divides by `_pricingSupply()`.
- Docs: the emergency path in `docs/guardian-network.md` (what an unblocked round lets the owner do,
  the propose-time electorate, the reviewer rule); lock retention after a cancel and price outages
  during the challenge window in `docs/coverage.md`; the management-fee base and `setProtocolConfig`
  in `docs/fees.md`.

## Capabilities

### Modified Capabilities

- `guardian-staking`: vote-read consumers (raw for reviews, aged for the court).
- `guardian-agent`: the block-reachability check uses raw snapshot stake.
- `deployment-docs`: guardian simulation preconditions; WOOD price outage semantics and monitoring.
- `syndicate-governor`: governance parameter bounds.
- `guardian-slashing`: lock-based slash rate; no bounty; coverage scales rather than gates.
- `guardian-coverage`: cap-only WOOD pricing; approval recording; execute-time coverage measurement.
- `dimensional-conventions`: the cap is an upper cap; vote weight has no delegated term.
- `syndicate-vault`: settle stamp denominator; deposit claim pricing; deposit cancellation.

## Archive order

Several open changes modify the same requirements with text that predates the code
(`declared-coverage-locks`, `proportional-quorum-sizing`, `anchor-coverage-at-execution`,
`per-call-capital-declarations`, `structural-batch-rules`). Archive this change after them so its
text is the one that lands. The emergency finalize budget and the batch recipient rules are already
corrected in `emergency-path-zero-egress-and-rebond` and `structural-batch-rules`, and the per-approver
slash-rate, allocation and fee-attribution requirements in `declared-coverage-locks`; this change does
not repeat them.

## Impact

`docs/`, `openspec/`, natspec in `src/ChallengeGame.sol`, `src/ExposureLedger.sol`,
`src/GovernorParameters.sol`, `src/ProtocolConfig.sol`, `src/SyndicateFactory.sol`,
`src/SyndicateGovernor.sol`, `src/SyndicateVault.sol`, `src/interfaces/IGuardianRegistry.sol`,
`src/interfaces/IStakedWood.sol`, `src/pricing/WoodPoolFeed.sol`,
`src/strategies/ConcentratedLiquidityStrategy.sol`, and one comment in `test/ChallengeEndToEnd.t.sol`.
No storage, ABI or behaviour change.
