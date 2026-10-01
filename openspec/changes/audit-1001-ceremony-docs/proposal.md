# Audit 2026-10-01: ceremony wiring, ETH/USD bound, documentation corrections

## Why

The 2026-10-01 audit of `v1-deploy` found two ceremony defects and several statements in the docs
and specs that the code does not match.

- **V1-05.** A vault created between Mainnet run 1 and run 2 gets a governor with no exposure ledger
  and no bond escrow, run 2 never wires it, and the ceremony still reports green.
- **V1-06.** `ETH_USD_MAX_AGE` equalled the 4663 ETH/USD heartbeat (24h), so one late round halted
  WOOD pricing and with it propose, approve, execute and `ChallengeGame.file`.
- **V2-04.** The management-fee spec calls the base "deployed capital"; the code charges the whole
  fund's assets, stamped at execute, while a proposal is Executed.

## What Changes

- `DeployAll` run 1 closes syndicate creation (unpayable fee) and run 2 reopens it at the
  invite-only fee once the coverage layer is wired, so no vault can predate it. `_validateAll` pins
  the fee per stage; `verify-robinhood.sh` checks every live governor's wiring read-only.
- `ETH_USD_MAX_AGE` becomes 26h; the feed phase refuses a bound at or below the 24h heartbeat.
- Documentation only, no contract logic: lock retention for never-executed proposals (V1-08),
  sibling-challenge referral (V1-09), liquidity-holder check and feed recovery (V1-10), the
  `minSlashBps` qualifier on k = 1 containment (V1-11), the management-fee base (V2-04).

## Capabilities

### Modified Capabilities

- `deployment-docs`: creation closed between the two Mainnet runs; the ETH/USD bound exceeds the heartbeat.
- `management-fee`: the base is the whole fund while a proposal is Executed.

## Impact

`script/robinhood-mainnet/DeployAll.s.sol`, `RobinhoodParams.sol`, `script/DeployWoodPoolFeed.s.sol`,
`script/verify-robinhood.sh`, docs. No `src/` logic changes (one natspec comment).
