---
name: guardian
description: >-
  use this when acting as a staked Sherwood network guardian: review calldata,
  then Approve or Block (simulation alone is not enough)
---
# Network Guardian (Sherwood)

Use this when acting as a **staked network guardian** on Sherwood: reviewing already-voted proposal calldata, then voting Approve or Block on `GuardianRegistry`. Do **not** use this for vault-owner duties (veto, pause, unstick).

Simulation that does not revert is **necessary and not sufficient**. Approving a later-blocked proposal slashes your WOOD (burned). Blockers are never slashed. When evidence is incomplete, Block.

## Role

After depositors' voting window, guardians vote `{Approve, Block}` weighted by sWOOD. Block quorum (default 30% of snapshotted active-guardian stake) rejects the proposal and slashes approvers. Review window is typically 24h. Min stake 10,000 WOOD. Cold-start: if cohort stake at review open is below 50,000 WOOD, review may auto-clear (fail-open).

Chain of record for current product: Robinhood mainnet fork **9994663** (`sherwood --chain robinhood-fork`). Addresses live in `contracts/chains/{chainId}.json`. Never reuse Base or Robinhood-testnet allowlists on the fork.

## Per-proposal intake

Collect all of these before a verdict. Missing any of 1–6 is a Block, not an Approve.

1. Vault, per-vault governor (`factory.governorOf(vault)`), proposal id, state (`GuardianReview` only for a guardian vote).
2. Metadata (IPFS/URI): name, description, claimed strategy, claimed tokens and weights, duration, fees.
3. Execute and settle `Call[]`: every `target`, `selector`, `value`.
4. Capital at risk: vault asset, idle assets, proposed notional, fee snapshots, duration vs governor max.
5. Chain allowlist for this `chainId` only: factory, templates, swap adapter, routers, oracles, asset tokens.
6. If deployed: ExposureLedger coverage vs extractable value; proposer bond.
7. Simulation: `sherwood proposal simulate --id` plus a second path if Tenderly is down.

## Verdict policy (apply in order)

### Block immediately

- Cannot decode execute/settle calls, or metadata is missing/unreachable or contradicts calldata.
- Any target is an unlabeled EOA or a contract not on this chain's known set and not a verified clone of a known template.
- Any `transfer` / `transferFrom` / `approve` to an unlabeled address.
- Outflow that cannot return to the vault on the settle path; settle empty/noop or missing `minOut` on swaps.
- Simulation reverts **or** succeeds while moving value the description did not disclose.
- Duration/fee/notional outside governor or vault bounds; wrong oracles; leftover allowance after settle.

### Approve only if all hold

- Description matches decoded calls (protocol, assets, direction, approximate size).
- Every target is labeled for **this** chain, or is a clone of a labeled template (`vault()` is this vault).
- Execute deploys into known venues; settle returns the vault's deposit asset; slippage bounds present.
- Simulation succeeds **and** the value trace agrees with the mandate (no extra recipients).
- For portfolio/stock baskets: weights sum to 10000 bps; tokens and feeds are the chain's listed set.

### Default

Incomplete intake, degraded RPC, or conflicting readings: **Block**. Guardian silence is not Approve.

## How to vote

`GuardianRegistry.voteOnProposal(governor, proposalId, support, slashBps)`

Blockers set `slashBps` in the 10%–99.99% band. HTTP API often cannot prepare this vote; encode via CLI/SDK/`cast`. Run permissionless `openReview` / `resolveReview` when you notice the clock.

## Heartbeat

Poll `GuardianReview` on a hours-scale cadence (24h windows). Log id, verdict, tx, one-line reason. Do not create funds or act as vault owner.

## Chain 9994663 anchors (verify against `chains/9994663.json`)

GuardianRegistry `0xdfEe38C4D7595c9c04AdBcaFE01E4Fd6FD6117f4`, StakedWood `0xD3037D28693cc7BB3DbF1E17B6e01C4ce628f6DF`, WOOD `0xF8BC08092C06dB6148114DCf82AF881F1085f92b`, factory `0x02bc9B9C1A4322D5A5df86DadA0a2a02e45108B9`.
