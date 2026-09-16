# guardian-agent Specification

## Purpose

Defines the observable behaviour of the autonomous guardian daemon: which reviews it acts on, how it
reaches a verdict, what it is permitted to sign on which chain, and how it degrades when any of its
inputs fail. The capability exists so the guardian review path can be exercised end-to-end against a
live deployment without a human in the signing loop.

Verdicts are reached by simulating the proposal through the governor's own entrypoints and measuring
what the vault looks like after settlement, rather than by recognising target addresses — so a gap in
the decoder's ABI catalogue is not a gap in the review. Approve is reachable only through
deterministic evaluation and only within underwriting capacity; every unavailable input fails toward
not-approving.

## Requirements
### Requirement: Proposals are simulated through the governor's own entrypoints

The agent SHALL simulate a proposal by driving the protocol's real entrypoints on a fork —
`openReview`, `resolveReview`, `executeProposal`, and `settleProposal` — and SHALL NOT reach a
verdict from calldata replayed directly against call targets under an impersonated vault.

The adversary is a proposal whose calls the governor would reject. Impersonating the vault and
calling each target directly skips target gating, batch-executor checks, and tier and sandbox
constraints, so such a proposal simulates cleanly and reaches Approve. The same substitution fails in
the other direction — a call valid only inside the governor's execution context reverts standalone
and is reported as a critical simulation failure — which blocks honest proposals.

#### Scenario: A call the governor would reject

- **WHEN** a proposal contains a call that `executeProposal` would refuse
- **THEN** the simulation reports the refusal and the agent votes Block

#### Scenario: A call valid only through the governor

- **WHEN** a proposal contains a call that reverts in isolation but succeeds within the governor's
  execution context
- **THEN** the simulation succeeds and the call is not reported as a failure

#### Scenario: The proposal cannot be executed at all

- **WHEN** `executeProposal` reverts on the fork for a proposal whose review is otherwise clean
- **THEN** the agent votes Block and records the execution failure as the cause

### Requirement: The simulated lifecycle advances both clock and block height

Between the execution leg and the settlement leg the agent SHALL advance the fork's
`block.timestamp` by the proposal's `strategyDuration` and SHALL advance `block.number` by the
height implied by a per-chain blocks-per-second constant recorded in configuration.

The adversary is a leveraged settlement that looks solvent because interest never accrued.
Timestamp-based markets accrue correctly under a warp alone; markets that accrue from block height
do not move at all, and the resulting under-accrual errs toward Approve.

#### Scenario: Settlement is simulated at the strategy's horizon

- **WHEN** a proposal declares a strategy duration
- **THEN** the settlement leg is simulated at the fork's start time plus that duration, not in the
  same block as execution

#### Scenario: Block-height accrual is exercised

- **WHEN** a proposal's settlement depends on a market that accrues from block height
- **THEN** the simulation advances block height alongside the timestamp so that accrual occurs

#### Scenario: The blocks-per-second constant is absent

- **WHEN** no blocks-per-second constant is configured for the connected chain
- **THEN** the agent refuses to start rather than simulating with an assumed default

### Requirement: Oracle freshness is restamped without altering reported prices

Before the settlement leg the agent SHALL cause each consulted price feed to report its existing
answer stamped at the current block timestamp, and SHALL NOT alter the answer itself.

The adversary here is the agent's own simulation, not an attacker. A fork's feed rounds are frozen at
the fork block, so advancing the clock ages every feed past its consumer's maximum age; consumers
then revert or degrade to an unavailable price. Every honest proposal with a time-dependent
settlement would fail simulation and be voted Block, and a fleet that blocks everything is
indistinguishable from one that is working.

Prices are held constant deliberately. In a fork nothing trades, so any value lost across the round
trip is structural rather than market movement, which is what makes a tight capital bound defensible.

#### Scenario: A warped settlement reaches a staleness-checking consumer

- **WHEN** the settlement leg calls a contract that rejects prices older than a maximum age
- **THEN** the feed reports the fork's price at the current timestamp and the call is not rejected
  for staleness

#### Scenario: Prices are not modified

- **WHEN** feed freshness is restamped
- **THEN** the reported answer equals the answer the fork returned before restamping

### Requirement: A verdict is decided by measured outcomes, not by target recognition

After the settlement leg the agent SHALL evaluate the vault's measured end state and SHALL treat
presence in the sanctioned address book as insufficient grounds to approve. The evaluated outcomes
SHALL include the capital round trip against the proposal's capital snapshot, residual token
allowances granted during the proposal, residual non-asset token balances, the native balance, and
whether every decodable recipient or beneficiary is the vault.

The adversary is a proposal built entirely from sanctioned targets. A swap on an allowlisted router
that names an attacker as recipient, or sets a zero minimum output, decodes without error and raises
no target-based flag. An allowlist of targets sanctions addresses; it cannot sanction actions, and
completing it would require a per-function argument policy for every venue the protocol will ever
touch.

An allowance left outstanding after settlement is a standing withdrawal right against the vault and
SHALL be treated as a finding in its own right, independent of whether the spender is sanctioned.

#### Scenario: A drain routed through a sanctioned target

- **WHEN** a proposal's calls all target sanctioned addresses but the vault's capital after
  settlement falls below its snapshot by more than the configured drawdown bound
- **THEN** the agent reports the shortfall and does not vote Approve

#### Scenario: An allowance survives settlement

- **WHEN** any non-zero allowance granted during the proposal remains outstanding after the
  settlement leg
- **THEN** the agent reports it and does not vote Approve, whether or not the spender is sanctioned

#### Scenario: A beneficiary other than the vault

- **WHEN** a decodable call names a recipient or beneficiary that is not the vault
- **THEN** the agent reports it and does not vote Approve

#### Scenario: An honest round trip

- **WHEN** the vault returns to cash, holds no residual allowances or non-asset balances, and its
  capital is within the configured drawdown bound
- **THEN** the outcome evaluation raises no finding and the deterministic gate may proceed to Approve

### Requirement: Every proposal is simulated twice and disagreement is escalated

The agent SHALL simulate each proposal both with the clock advanced and feed freshness restamped,
and unmodified at fork state, and SHALL escalate any proposal whose two runs disagree to the
unresolved band rather than treating it as clean.

The adversary is an attack whose harm depends on a stale or manipulated price. Restamping freshness
asserts that every feed is current, so on its own it would conceal exactly that class of proposal.
The control run is what makes the assertion detectable: a proposal whose verdict depends on
restamping is one whose verdict depends on price freshness.

#### Scenario: The two runs disagree

- **WHEN** the warped run and the control run reach different outcomes for the same proposal
- **THEN** the proposal enters the unresolved band and is not approved on the strength of the warped
  run alone

#### Scenario: The control run cannot complete

- **WHEN** the control run fails to produce a result
- **THEN** the agent abstains rather than approving on the warped run alone

### Requirement: The unresolved band is adjudicated rather than universally abstained

The agent SHALL supply an adjudicating model to the verdict gate so that proposals left unresolved by
deterministic evaluation receive a decision. The model's verdict SHALL remain constrained to Block or
Abstain, and Approve SHALL remain unreachable from any non-deterministic component.

The adversary is prompt injection carried in proposal calldata, token names, or metadata URIs — all
attacker-controlled strings that reach the model's context. Confining the model to the safe half of
the decision means a successful injection costs liveness and never stake. An unconfigured model is
not a safe default but a silent one: it abstains on every warning-band proposal, which is a review
that never happens.

#### Scenario: A warning-band proposal is adjudicated

- **WHEN** deterministic evaluation raises warnings but nothing critical
- **THEN** the model is consulted and its narrowed verdict is recorded as the outcome

#### Scenario: The model is unavailable

- **WHEN** the model errors, times out, or is rate-limited
- **THEN** the agent abstains and records the failure, and does not fall through to Approve

#### Scenario: The model returns an approval

- **WHEN** the model's response resolves to Approve
- **THEN** the response is recorded, the verdict is treated as Abstain, and no Approve vote is cast

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

