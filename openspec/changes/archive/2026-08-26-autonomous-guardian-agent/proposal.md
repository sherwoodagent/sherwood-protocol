## Why

The guardian network is the protocol's human-vetoable safety layer, but nothing exercises it
autonomously. `sherwood-guardian` V1 simulates proposals and prints a verdict — it never signs, it
hardcodes Base mainnet (8453), and it assumes a single governor address. On the Robinhood fork
(`chains/9994663.json`, `SYNDICATE_GOVERNOR = 0x0`) governors are minted per vault, so V1 cannot even
find a review to look at.

Until a guardian actually votes on the fork, the whole review path — `openReview` → age-weighted vote
accumulation → `resolveReview` → slash — is unproven outside unit tests. The fork exists, is deployed,
and is the only place where an approve vote can be exercised without risking real WOOD.

## What Changes

- Promote `sherwood-guardian` to a **signing** daemon that casts `openReview`, `resolveReview`, and
  `voteOnProposal` transactions on the Robinhood Tenderly vnet fork (chain 9994663).
- Add a **hybrid verdict pipeline**: deterministic fork-replay plus risk codes decide `BLOCK` and
  `APPROVE`; an LLM judge is consulted only for the residual "clean but unfamiliar" band and may
  return `BLOCK` or `ABSTAIN` only. `APPROVE` — the sole slashable action — is unreachable from the
  LLM.
- Add an **ExposureLedger pre-check**: refuse to approve when `requiredCoverage` exceeds the agent's
  free sWOOD or a configured per-proposal ceiling.
- Replace the hardcoded `chains.ts` map with a loader over the committed `chains/<chainId>.json`
  address books, making `UNKNOWN_TARGET` mean "not sanctioned by the deploy ceremony".
- Re-key the watcher on `ReviewRegistered(address indexed governor, uint256 indexed proposalId, …)`
  so per-vault governors are discovered from logs rather than configured.
- Gate autonomy behind `GUARDIAN_MODE` (`observe` | `defend` | `autonomous`), where `autonomous`
  refuses to arm on any chain other than 9994663 — mirroring the existing `SKIP_MULTISIG_HANDOFF` /
  `ALLOW_FIXTURE_WOOD` fork-posture convention.
- Deploy as an independent Railway service, following `spectator/railway.json`. It is deliberately
  **not** a `hermes-plugin` role: that plugin is the agent-operator (proposer) side, and collapsing
  proposer and reviewer into one process and one derived key makes the review meaningless.
- Correct the guardian-sim bootstrap in `deployment-docs`: a freshly staked cohort cannot reach the
  block quorum at all, because the quorum denominator is raw stake while the numerator is
  age-weighted. Stake must age past the point where `_ageFactorBps` crosses `blockQuorumBps`.

Not in scope: challenge filing, TokenCourt voting, chains other than the fork, notification
transports, and any dashboard.

## Capabilities

### New Capabilities

- `guardian-agent`: the autonomous guardian daemon — what it watches, how it reaches a verdict, what
  it is permitted to sign, its posture gating, and its fail-safe behaviour under partial failure.

### Modified Capabilities

- `deployment-docs`: the guardian-sim bootstrap requirement gains a stake-maturation step (a
  freshly staked cohort is structurally unable to block), and its slash-severity sentence is
  corrected — severity is derived from the review by `_severityBps`, not voted per blocker.

## Impact

- **`sherwood-guardian` repo** (external to this one, as `deployment-docs` already does for
  `cli/` and `app/`): `src/chains.ts`, `src/watcher.ts`, `src/index.ts`, plus new `src/ledger.ts`,
  `src/judge.ts`, `src/signer.ts`. `Dockerfile` currently carries unresolved
  `REPLACE_FOUNDRY_DIGEST` / `REPLACE_NODE_DIGEST` placeholders and cannot build until they are pinned.
- **This repo**: `openspec/specs/deployment-docs/spec.md` only. No Solidity changes — the agent is a
  consumer of the deployed contracts, not a modification to them.
- **Contracts read**: `GuardianRegistry` (events, `getReviewState`, `outcomeOf`, `reviewWindow`,
  `voteOnProposal`), `StakedWood` (`getPastVotes`, `getPastTotalVotes`), `ExposureLedger`
  (coverage), `SyndicateGovernor` (proposal calldata).
- **Secrets**: a guardian private key and the Tenderly admin RPC both become Railway service
  variables. The admin RPC is already classified as a secret (`TENDERLY_ROBINHOOD_RPC_URL`) and must
  stay uncommitted.
