## Why

`autonomous-guardian-agent` specifies one guardian. Production needs several, and the reasons for
several are narrower than they first appear.

Splitting stake across M addresses buys **no additional blocking power**: `GuardianRegistry._isBlocked`
compares accumulated block weight against `blockQuorumBpsAtOpen × totalStakeAtOpen`, and M addresses
sum back to the same weight one address would have carried. It buys no additional capital either —
the same bond, sliced finer. What it does buy is availability, key blast-radius containment, and
graded slash exposure. Since a single operator owns every bond, correlated failure across them is not
a diversification loss but simply the operator's position; paying M times over for M identical
simulations therefore buys nothing at all.

The availability argument is the load-bearing one, and it is a systems argument rather than an
economic one. Two hot-standby processes sharing one guardian key contend for the same nonce and need
leader election or a nonce lease to be safe. M distinct identities on M distinct EOAs share no
mutable on-chain state, so redundancy comes for free. M is set by an uptime target, not by anything
about stake.

Two defects make a fleet unbuildable as things stand:

1. **Nothing opens reviews.** `openReview` and `resolveReview` are implemented in
   `sherwood-guardian/src/signer.ts` and are never called from `src/index.ts`, whose loop imports
   only `assertModeAllowedOnChain`, `assertNotAnAgent`, and `castVote`. The watcher keys on
   `ReviewOpened`. A review nobody opens is never seen, and `SyndicateGovernor`'s mutating
   `_resolveState` then resolves it inline as not blocked and executes — the CLI records this as
   the cold-start norm, noting that `openReview` is production-gated on a guardian cohort. Adding
   a second guardian produces two daemons waiting for an event neither of them causes.

2. **Cold start rescans from genesis.** `src/index.ts` calls `fetchNewReviews(client, registry,
   state.lastBlock)` with no options, so `registrationSearchFromBlock` defaults to `0n` and any
   registration older than the poll window triggers a `getLogs` across the whole chain. The option
   exists and is documented in `src/watcher.ts`; it is simply never passed. With M instances
   restarting, that is M full-history scans.

A third gap is operational rather than a defect: per-instance health answers "is guardian 3 up",
while the question that decides whether the layer works is whether the guardians that are *currently
alive* could still reach the block quorum.

## What Changes

- Split the daemon into two roles. A **keeper** holds no stake and only gas, discovers work from
  `ReviewRegistered`, and calls `openReview` at `voteEnd` and `resolveReview` at `reviewEnd`. A
  **voter** holds stake and only votes. The keeper's failure mode is missed liveness; it can never
  be slashed, which is what makes it safe to run redundantly.
- Run keepers **redundantly with randomized jitter**, accepting that losers of the race pay gas for
  a successful no-op. Both entrypoints are permissionless and return early rather than reverting, so
  a race wastes gas and cannot corrupt state.
- Deploy each guardian identity as **its own Railway service with its own key and its own volume**,
  so nonces never contend and one leaked key costs one bond.
- Run **one simulation per proposal**, publish its evidence, and let each guardian apply its own
  policy to it. Diversify thresholds and postures, not simulations.
- Measure fleet health as **blockable capacity** — whether guardians with a fresh heartbeat and a
  funded gas balance still carry enough weight to reach the block quorum — and alert on that rather
  than on per-instance liveness.
- Record that **fleet composition is fixed before staking**. `GuardianRegistry.FLOOR_LOOKBACK` is 30
  days and `_growthGatedVoteWeight` clamps any voter whose raw stake grew to its value 30 days
  earlier, so moving stake between the operator's own guardians reduces total fleet weight for a
  full lookback period.
- Pass `registrationSearchFromBlock` from the registry's deployment block.

Not in scope: third-party guardian operators, the review's own depth (that is
`guardian-review-depth`), challenge filing, TokenCourt voting, and any dashboard.

## Capabilities

### New Capabilities

- `guardian-fleet`: operating several guardian identities as one production service — the keeper
  role and its redundancy, per-identity isolation, the shared-evidence and per-guardian-policy
  split, the blockable-capacity health signal, and the staking-time constraints on fleet
  composition.

No existing capability is modified. `guardian-agent` continues to describe one agent's behaviour —
its posture gate, coverage ceiling, and deterministic-Approve rule all hold unchanged for every
voter in the fleet. The narrowing of a voter's signing surface to `voteOnProposal` is a consequence
of the keeper role and is specified under `guardian-fleet`, so that `guardian-agent` remains
readable as the single-agent contract it is.

## Impact

- **`sherwood-guardian` repo**: `src/index.ts` (role selection; wire the keeper loop that today is
  dead code in `src/signer.ts`), `src/watcher.ts` (schedule from `ReviewRegistered`; pass
  `registrationSearchFromBlock`), `src/health.ts` (gas balance, blockable capacity), `src/env.ts`
  (role, jitter, per-guardian policy), `railway.json`.
- **This repo**: spec only. No Solidity changes.
- **Contracts read**: `GuardianRegistry` (`openReview`, `resolveReview`, `blockQuorumBps`,
  `getReviewState`, `reviewWindow`), `StakedWood` (`getPastStake`, `getPastTotalVotes`).
- **Infrastructure**: M voter services plus 2–3 keeper services on Railway, each with its own key
  and volume. Every EOA needs a funded gas balance; a guardian that cannot pay gas is silently
  non-voting and today looks identical to a healthy one that saw nothing.
- **Depends on** `autonomous-guardian-agent` for the `guardian-agent` capability, whose `tasks.md` is
  stale — groups 2 through 5 are implemented and unticked — and should be reconciled before archive.
