# Audit 2026-10-02: documents and specs aligned with the code on v1-deploy

## Why

Several normative specs and operator documents describe behaviour the contracts on `v1-deploy` do not
have. They are the next auditor's baseline and the guardians' operating reference, so they must say
what the code does.

## What Changes

Documents only. No executable source changes; natspec comments only in `src/` and one test comment.

- Guardian review and emergency block votes weigh raw `getPastStake` at the proposal's snapshot (one second before it entered Pending);
  on `post-audit-v2` challenge ballots are raw too, and no contract reads the age-weighted `getPastVotes`
  (on `v1-deploy`, where this change was written, `TokenCourt.vote` read it).
- Per-vault voting period floor is 1 hour on the mainnet implementation (factory default 24 hours);
  veto threshold bounds are 20–80%; votingPeriod maximum is 3 days; strategy duration maximum 30 days.
- The slash is the approver's lock, floored at `minSlashBps` of the basis; a blocked review scales it
  by severity. There is no slash bounty.
- The WOOD price is `haircut(min(feed, cap))` with no fallback and no detail view; the cap has no
  on-chain rate limit; an approve vote reverts during a WOOD-price or asset-feed outage and a block
  vote lands.
- The approve-time slot floor, the coverage measurement that scales a partial book, and the absence
  of a quorum tier threshold.
- Queued deposits claim at the live `previewDeposit` price, behind the pause and the depositor
  whitelist; the settle stamp divides by `_pricingSupply()`. Request cancellation is specified by
  `audit-1002-vault-governor-gates` and is not repeated here.
- Docs: the emergency path in `docs/guardian-network.md` (what an unblocked round lets the owner do,
  the snapshot electorate, the reviewer rule); lock retention after a cancel and price outages
  during the challenge window in `docs/coverage.md`; the management-fee base and `setProtocolConfig`
  in `docs/fees.md`.

## Capabilities

### Modified Capabilities

- `guardian-staking`: vote-read consumers (raw for every vote; the age-weighted getter has no on-chain reader on `post-audit-v2`).
- `guardian-agent`: the block-reachability check uses raw snapshot stake.
- `deployment-docs`: guardian simulation preconditions; WOOD price outage semantics and monitoring.
- `syndicate-governor`: governance parameter bounds.
- `guardian-slashing`: lock-based slash rate; no bounty; coverage scales rather than gates.
- `guardian-coverage`: cap-only WOOD pricing; approval recording; execute-time coverage measurement.
- `dimensional-conventions`: the cap is an upper cap; vote weight has no delegated term.
- `syndicate-vault`: settle stamp denominator; deposit claim pricing; deposit cancellation.

## Archive order

This change archives cleanly on its own against `openspec/specs/` (checked with
`openspec archive --yes` in a scratch copy). Requirements whose scenarios no longer fit are
REMOVED and re-ADDED under a new name. Other open changes still carry older text for some of the
same requirements and need a sync before they are archived after this one:

- `per-call-capital-declarations`: "Governance parameter management" (votingPeriod floor 24h,
  veto ceiling 50%, duration 3650d, performance-fee cap 1,500).
- `declared-coverage-locks`: "Execute-time approve quorum" (all-or-nothing, `quorumTierThreshold`),
  "Booking failures never fail the approve vote" (never reverts), "Review-path slash
  (registry-only)" in guardian-staking (no severity scaling), and "Approval recording books a
  guardian-declared WOOD lock" (no slot floor); this change adds a requirement of that name, so
  the two must converge.
- `proportional-quorum-sizing`: "Execute-time approve quorum" (reservation wording,
  `quorumTierThreshold`).
- `anchor-coverage-at-execution`: allocation and settlement requirements this change does not
  touch, against a reservation model the code no longer has.

Already corrected elsewhere and not repeated: the emergency finalize budget
(`emergency-path-zero-egress-and-rebond`), the batch recipient rules (`structural-batch-rules`),
the per-approver slash rate, allocation and fee attribution (`declared-coverage-locks`), and
request cancellation and the rescue recipient (`audit-1002-vault-governor-gates`).

## Impact

`docs/`, `openspec/`, natspec in `src/ChallengeGame.sol`, `src/ExposureLedger.sol`,
`src/GovernorParameters.sol`, `src/ProtocolConfig.sol`, `src/SyndicateFactory.sol`,
`src/SyndicateGovernor.sol`, `src/SyndicateVault.sol`, `src/interfaces/IGuardianRegistry.sol`,
`src/interfaces/IStakedWood.sol`, `src/pricing/WoodPoolFeed.sol`,
`src/strategies/ConcentratedLiquidityStrategy.sol`, and one comment in `test/ChallengeEndToEnd.t.sol`.
No storage, ABI or behaviour change.
