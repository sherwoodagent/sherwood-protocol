## Purpose

Defines the observable behaviour of the autonomous guardian daemon: which reviews it acts on, how it
reaches a verdict, what it is permitted to sign on which chain, and how it degrades when any of its
inputs fail. The capability exists so the guardian review path can be exercised end-to-end against a
live deployment without a human in the signing loop.

## ADDED Requirements

### Requirement: Signing authority is gated by mode and chain

The agent SHALL expose exactly three postures — `observe` (simulate and report, sign nothing),
`defend` (additionally sign `openReview`, `resolveReview`, and Block votes), and `autonomous`
(additionally sign Approve votes) — and SHALL default to `observe`.

`autonomous` SHALL refuse to arm unless the connected chain id is the Robinhood Tenderly vnet fork
(9994663). The adversary is a misconfigured deploy: an operator copying the fork's service
variables onto a mainnet RPC would otherwise hand an unattended process the one action that can
burn staked WOOD. Chain identity is read from the RPC at start-up, never from configuration.

#### Scenario: Autonomous mode on a non-fork chain
- **WHEN** the agent starts in `autonomous` mode and the RPC reports chain id 4663 or 8453
- **THEN** it refuses to start, exits non-zero, and casts no transaction

#### Scenario: Default posture signs nothing
- **WHEN** the agent starts with no mode configured
- **THEN** it runs in `observe`, produces reports, and issues no `eth_sendRawTransaction`

### Requirement: Approve is reachable only through deterministic evaluation

An Approve vote SHALL be produced only by deterministic evaluation of the fork replay and its risk
codes. A language model MAY be consulted for proposals that the deterministic layer leaves
unresolved, and its verdict SHALL be constrained to Block or Abstain.

The adversary is both prompt injection carried in proposal calldata or token metadata, and ordinary
model error. Approve is the only guardian action that books coverage and exposes stake to slashing,
so no non-deterministic component may reach it.

#### Scenario: Model returns an approval
- **WHEN** the language model's response resolves to Approve for an unresolved proposal
- **THEN** the agent records the response, treats the verdict as Abstain, and does not vote Approve

#### Scenario: Critical risk short-circuits
- **WHEN** the deterministic layer emits any critical risk code
- **THEN** the agent votes Block without consulting the language model

#### Scenario: Simulation cannot complete
- **WHEN** the fork replay fails, reverts, or exceeds its time budget
- **THEN** the verdict is Block — a proposal that cannot be simulated cannot be approved

### Requirement: Approval is bounded by underwriting capacity

Before voting Approve the agent SHALL read the proposal's required coverage and its own free staked
weight, and SHALL abstain when required coverage exceeds either that free weight or a configured
per-proposal ceiling.

The adversary is a proposal sized specifically to consume the agent's entire free stake, so that one
adverse review liquidates its whole position rather than a bounded fraction.

#### Scenario: Coverage exceeds free stake
- **WHEN** required coverage for a proposal exceeds the agent's unencumbered staked weight
- **THEN** the agent abstains and records the shortfall, rather than voting Approve

#### Scenario: Coverage exceeds the configured ceiling
- **WHEN** required coverage is affordable but above the configured per-proposal ceiling
- **THEN** the agent abstains

### Requirement: Reviews are discovered from registry events, not configuration

The agent SHALL discover the governor for each proposal from the registry's review-registration
event, which carries the governor address, and SHALL NOT require a governor to be configured.

Governors are minted per vault by the factory, so any single configured governor address is wrong by
construction on a multi-vault deployment.

#### Scenario: Second vault's proposal
- **WHEN** a review opens on a governor the agent has never seen
- **THEN** the agent resolves that governor from the registration event and evaluates the proposal

#### Scenario: Review-opened carries no governor
- **WHEN** the agent observes a review-opened event, which identifies only the proposal
- **THEN** it joins that proposal to its governor using the earlier registration event

### Requirement: The sanctioned-target set derives from the deployed address book

The agent SHALL treat a call target as known only if it appears in the committed address book for the
connected chain id, and SHALL classify every other target as unknown.

This makes "unknown target" mean precisely "not an address the deploy ceremony sanctioned", and it
keeps the agent correct across vnet re-mints, because external addresses in that book survive
redeploys while core addresses are patched in place.

#### Scenario: Target outside the address book
- **WHEN** a proposal calls an address absent from the connected chain's address book
- **THEN** the call is flagged as an unknown target and the proposal is blocked

#### Scenario: Unsupported chain
- **WHEN** the agent connects to a chain with no committed address book
- **THEN** it refuses to start rather than evaluating with an empty sanctioned set

### Requirement: Timing decisions read chain time

Every deadline decision — whether a review is open, whether the late-vote lockout has begun, whether
the window has closed — SHALL be computed from the chain's block timestamp and the window recorded
on-chain, never from the agent's local clock.

The fork's clock is advanced deliberately in large steps during simulation, so a local clock diverges
from chain time by days within a single run.

#### Scenario: Chain time jumps forward
- **WHEN** the fork's timestamp advances past the review end between two polls
- **THEN** the agent abstains and records the window as closed, rather than submitting a vote that reverts

#### Scenario: Late-vote lockout reached
- **WHEN** chain time enters the final tenth of the review window
- **THEN** the agent does not attempt to vote or change its vote

### Requirement: On-chain review state overrides local state

Before signing any vote the agent SHALL read the review's on-chain state and SHALL NOT vote when the
chain already records a vote from its address for that proposal.

The adversary here is the agent's own restart: local progress state can be lost, rolled back, or
restored from a stale volume, and a duplicate vote wastes gas at best and misrepresents intent at worst.

#### Scenario: Restart with lost local state
- **WHEN** the agent restarts with an empty state directory and re-observes a review it already voted on
- **THEN** it reads its existing vote from the chain and does not vote again

#### Scenario: Review already resolved
- **WHEN** a review has been resolved before the agent reaches it
- **THEN** the agent records the outcome and casts no vote

### Requirement: A block that cannot reach quorum is reported, not cast

When the agent determines a proposal should be blocked, it SHALL compute whether the achievable
block weight at review-open can reach the snapshotted block quorum, and when it cannot, SHALL record
that the quorum is unreachable rather than reporting a successful defence.

The quorum denominator is raw staked weight while the numerator is age-weighted, so a sufficiently
young cohort cannot block regardless of participation. Silently casting a doomed vote would present
an undefended protocol as a defended one.

#### Scenario: Cohort too young to block
- **WHEN** the agent decides to block and the cohort's age-weighted ceiling is below the block quorum
- **THEN** it records the quorum as unreachable, and its report distinguishes this from a cleared review

### Requirement: The guardian agent is independent of the proposing agent

The guardian agent SHALL run as its own process with its own signing key, and SHALL NOT share a
process, key, or key-derivation path with any agent that proposes strategies to the same vault.

A reviewer that shares a trust domain with the proposer provides no assurance: the same compromise
that produces a malicious proposal also produces its approval.

#### Scenario: Shared key detected
- **WHEN** the agent's signing address equals a registered agent address on a vault it reviews
- **THEN** it refuses to start

### Requirement: Every unavailable input fails toward not-approving

When any input the verdict depends on is unavailable — the RPC, the simulator, the coverage read, or
the model — the agent SHALL resolve to Block or Abstain, and SHALL NOT resolve to Approve.

#### Scenario: Coverage read unavailable
- **WHEN** the required-coverage read reverts or returns no data
- **THEN** the agent abstains

#### Scenario: Model unavailable
- **WHEN** the language model is unreachable or times out for an unresolved proposal
- **THEN** the agent abstains

#### Scenario: RPC endpoint gone
- **WHEN** the configured RPC returns not-found, as an expired vnet does
- **THEN** the agent reports the endpoint as gone and retries, without exiting or casting votes
