## MODIFIED Requirements

### Requirement: Signing authority is gated by mode and chain

The agent SHALL expose exactly three postures — `observe` (simulate and report, sign nothing),
`defend` (additionally sign Block votes, and `openReview` / `resolveReview` when the agent runs alone; an agent run as a voting identity of a fleet leaves those two calls to the fleet's stakeless keeper role, per the guardian-fleet capability), and `autonomous`
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
