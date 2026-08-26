# guardian-agent Specification

## Purpose
TBD - created by archiving change guardian-review-depth. Update Purpose after archive.
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

