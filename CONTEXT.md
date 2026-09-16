# Sherwood Protocol

Agent-managed investment funds (syndicates): depositors pool capital into an ERC-4626
vault, a registered agent proposes strategies, shareholders vote under optimistic
governance, and staked-WOOD guardians review calldata before execution.

## Language

### Proposal lifecycle

**Proposal lifecycle**:
The full arc of a strategy proposal — propose → vote → guardian review → execute → settle. Owned by one module; there is exactly one authoritative state per proposal.
_Avoid_: proposal state machine, proposal flow

**Proposal state**:
The single resolved position of a proposal in its lifecycle (Draft, Pending, GuardianReview, Approved, Rejected, Expired, Executed, Settled). Read via `stateOf(pid)`, which is a true view — it never lags behind determinable reality.
_Avoid_: proposal status

**Review outcome**:
The guardian review's verdict on a proposal — cleared, blocked, or cohort-too-small. Deterministic from registry storage once the review window ends; readable before the economic commit happens.
_Avoid_: review resolution, review result

**Economic commit**:
The irreversible side effect of a blocked review — slashing approvers (blocker attribution is derived off-chain from the vote events). Idempotent and permissionless; distinct from merely reading the review outcome.
_Avoid_: resolution, settlement (that word belongs to proposals)

**Review registration**:
The governor pushing a proposal's review-window facts (vote end, review end, vault) to the guardian registry at propose time. Facts flow governor → registry once; the registry never calls back.

### Governance actors

**Syndicate**:
One agent-managed fund: a vault, its per-vault governor, and its withdrawal queue.
_Avoid_: fund, pool

**Agent**:
A registered strategy proposer for a vault.
_Avoid_: manager, operator

**Guardian**:
A staked-WOOD reviewer who votes to clear or block proposals during guardian review.
_Avoid_: reviewer, validator

### Liquidity lanes

**Lane A**:
Instant withdrawal liquidity priced by the price router over per-kind pricing adapters. Fail-closed: anything unpriceable falls to Lane B.

**Lane B**:
Async withdrawal liquidity through the per-vault withdrawal queue; requests settle at one frozen price per proposal.
