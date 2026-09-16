## Context

See `proposal.md` — Why. Requirements live in `specs/guardian-agent/spec.md`; this document covers
only how they are met.

Three pieces of existing state shape the approach:

- **`sherwood-guardian` V1** already carries the expensive half: an event watcher, a proposal fetcher,
  a Foundry fork-replay simulator (`foundry/test/SimulateProposal.t.sol`), a ~250-line risk analyzer,
  a report writer, a `/data` state volume, and a GHCR publish pipeline with cosign signing. It never
  signs, by design. Its `Dockerfile` carries unresolved `REPLACE_FOUNDRY_DIGEST` and
  `REPLACE_NODE_DIGEST` placeholders and therefore cannot build today.
- **The fork is live and deployed.** `chains/9994663.json` holds 50 keys — core Sherwood addresses,
  live WOOD, USDG, Uniswap v3+v4, and twelve Chainlink feeds. `SYNDICATE_GOVERNOR` is the zero
  address there, because governors are minted per vault.
- **`sherwood/hermes-plugin`** is the agent-operator runtime. It derives a sidecar wallet from the
  operator's Sherwood key and gates the operator's own proposals through `pre_tool_call` hooks.
- **`sherwood/spectator`** is the in-house precedent for a long-lived sidecar on Railway:
  `Dockerfile` builder, `/health` check, `restartPolicyType: ON_FAILURE`.

## Goals / Non-Goals

**Goals:**

- One process, one key, one job, deployable from the existing container pipeline.
- The approve path is pure, deterministic, and unit-testable without a chain.
- Chain-portable by configuration: moving to another deployment is an address-book entry plus a mode
  flag, not a code change.

**Non-Goals:**

- Multi-guardian coordination or vote signalling between agents.
- Any control-plane UI. Reports stay files on the volume plus structured logs.
- Reusing the operator agent's runtime, key, or process — see Decisions.

## Decisions

### Extend `sherwood-guardian` rather than build a guardian role in `hermes-plugin`

The Hermes plugin already owns a monitoring loop, a cron tick, XMTP transport, and risk hooks, so
folding the guardian in would reuse real infrastructure. It is still the wrong home. That plugin is
the proposer: its purpose is to originate strategies, and its hooks exist to gate its own proposals.
A guardian's function is to independently review those proposals and be slashed for approving a bad
one. One process and one derived key for both roles means the compromise that authors a malicious
proposal also signs its approval — the review becomes decorative. Independence is the product here,
so it is worth giving up the shared infrastructure.

*Alternatives considered:* a guardian role inside `hermes-plugin` (rejected, above); a scheduled
CI workflow (rejected — no persistent state, coarse latency, and a signing key in Actions secrets);
a serverless function (rejected — the Foundry fork replay wants a warm filesystem and a multi-second
budget).

### A rules gate that decides, and a model that can only object

The verdict pipeline runs deterministically first. Simulation failure or any critical risk code
yields Block with no model call. A clean proposal whose targets are all in the address book and whose
analysis raises no warnings yields Approve, again with no model call. Only the residual band —
plausible but unfamiliar — reaches the model, whose output is narrowed to Block or Abstain.

The reason for the narrowing is that Approve is not an opinion, it is an underwriting commitment: it
books coverage on the `ExposureLedger` and exposes the stake to a slash of 10–100%, burned. Proposal
calldata and token metadata are attacker-controlled strings that end up in the model's context, so
the model sits inside the injection surface. Constraining it to the safe half of the decision means a
successful injection can cost liveness but never stake, and it keeps the slashable path inside code
that unit tests can pin.

*Alternative considered:* letting the model approve with a confidence threshold. Rejected — a
threshold is a tunable on an adversarial input, and there is no calibration data to set it from.

### Governor discovery from `ReviewRegistered`, not configuration

`ReviewOpened(uint256 indexed proposalId, uint128 totalStakeAtOpen)` does not name a governor.
`ReviewRegistered(address indexed governor, uint256 indexed proposalId, uint64 voteEnd, uint64 reviewEnd)`
does, and the governor pushes it at propose time — strictly before the review can open. The watcher
therefore builds a proposal-to-governor map from registration events and joins on proposal id when a
review opens. This needs no factory enumeration and no vault discovery.

### The address book is the sanctioned-target set

`chains.ts` becomes a loader over `chains/<chainId>.json` instead of a hardcoded Base map. Beyond
removing the 8453 constraint, this sharpens what an unknown target means: not "absent from a list
someone maintained" but "not an address the deploy ceremony wrote down". It also survives vnet
re-mints, because `ScriptBase._writeAddresses` patches only core keys and leaves externals intact.

### Chain time everywhere, local time nowhere

Every window decision reads the block timestamp and the on-chain review window. The fork advances its
clock in deliberate multi-day steps via `evm_increaseTime`, which the deployment spec mandates in
preference to shortening the real parameters. Any cached wall-clock arithmetic would mis-fire the
late-vote lockout the first time the sim time-travels.

### The chain is the progress ledger; `/data` is a cache

The volume holds the last scanned block and past reports. It is never the authority on whether a vote
was cast — the agent reads review state on-chain before signing. A restored-from-stale-snapshot volume
is then a performance problem, not a correctness one.

### Posture as an explicit env gate, matching the repo's existing convention

`GUARDIAN_MODE` follows the pattern `deploy-vnet.sh` already sets with `SKIP_MULTISIG_HANDOFF` and
`ALLOW_FIXTURE_WOOD` — dangerous-on-mainnet behaviour switched on by an explicit variable that the
code refuses to honour on the wrong chain. Chain id is read from the RPC at start-up, so a copied
service configuration pointed at mainnet fails closed instead of arming.

## Risks / Trade-offs

- **A false Block costs liveness.** The agent can reject a legitimate proposal and, with enough
  weight, slash honest approvers. → Blocking is asymmetric-safe for the agent's own stake but not for
  others', so the agent starts in `defend` on a cohort it does not dominate, and its block rate is
  reviewed before `autonomous` is enabled.
- **The model is inside the injection surface.** Proposal calldata reaches its context. → Its output
  is structurally confined to Block/Abstain; a successful injection cannot reach Approve.
- **A deterministic Approve is still an Approve.** Bounding the model does not make the rules correct;
  a gap in the risk codes approves silently. → The per-proposal coverage ceiling caps the loss from
  any single such gap, and the address-book-derived target set makes novel destinations block by
  default rather than pass by default.
- **Fork parameters are mainnet-faithful, so a full review takes 24 hours.** → End-to-end runs
  traverse the window with `evm_increaseTime`, which is exactly why chain-time discipline is a
  requirement rather than a nicety.
- **The vnet expires.** → The agent treats a not-found RPC as a recoverable condition and keeps
  retrying; re-minting is an existing documented operator procedure.
- **A single agent cannot block on a young cohort.** The quorum denominator is raw stake and the
  numerator is age-weighted. → Reported as an unreachable quorum rather than a silent no-op, and the
  `deployment-docs` delta adds the maturation step to the sim procedure.

## Migration Plan

1. Pin the two base-image digests so the container builds at all.
2. Land the chain-agnostic loader and governor discovery, both observable in `observe` mode with no
   signing. Verify against the live fork.
3. Enable `defend`. First signed transactions are `openReview` and `resolveReview`, which are
   permissionless and risk nothing.
4. Enable `autonomous` on the fork only, with a low per-proposal coverage ceiling, and raise it as the
   deterministic layer earns confidence.

Rollback at any step is setting `GUARDIAN_MODE=observe` and redeploying; the agent stops signing
immediately and keeps reporting. No on-chain state needs unwinding, because an unstaked or
non-voting guardian is a valid resting state.

## Open Questions

- Whether the agent should also seed and maintain its own guardian stake, or whether staking stays a
  manual operator step. Deferred: it changes an operator runbook, not the verdict path or the specs.
- Which model tier to use for the judge band. Deferred: the interface is a function from risk report
  to Block/Abstain, so the choice is swappable without touching the pipeline.
