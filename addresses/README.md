# Contract Addresses

Deployed contract addresses organized by chain ID.

## Structure

Each `<chainId>.json` file contains:

- **protocol** — Core protocol contracts (factory, governor, vault implementation)
- **templates** — Strategy template contracts (used as ERC-1167 clone sources)
- **syndicates** — Active syndicates with vault addresses
- **deployer** — Deployer address used for protocol deployments

## Chains

| Chain | File | Network |
|-------|------|---------|
| 8453 | [8453.json](./8453.json) | Base Mainnet |
| 4663 | [4663.json](./4663.json) | Robinhood Chain |

`4663.json` additionally carries an `external` block for third-party venue
addresses (Morpho Blue, Uniswap V3) with a per-entry `verification` string
recording how the address was proven on-chain. Read the warning in that block
before wiring any Uniswap address: the canonical mainnet addresses hold
unrelated code on this chain, so a `code.length != 0` assertion does not
distinguish the real deployment from the wrong one.

## Usage

```typescript
import addresses from "./addresses/8453.json";

const factory = addresses.protocol.SyndicateFactory;
const wstethTemplate = addresses.templates.WstETHMoonwellStrategy;
```
