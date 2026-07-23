# LighterPerpStrategy — spec & integration guide

A perpetuals strategy that runs a **contract-owned Lighter (zkLighter) margin account**.
USDG is pulled from the vault into an account owned by the strategy contract; a proposer-
registered **agent L2 trading key** drives trades off-chain through Lighter's API, while
every custody action (cancel, close, withdraw) stays on-chain and authed to the account
owner — the strategy itself.

This document serves two audiences:

- **Auditors** — architecture, trust model, storage, authorization, the two-phase settle,
  and known risks.
- **Frontend / backend integrators** — the lifecycle, guardrail actions, state reads,
  events, and errors.

Source: `src/strategies/LighterPerpStrategy.sol`, extending `src/strategies/BaseStrategy.sol`
and using `src/lighter/IZkLighter.sol`. File references are relative to the repo root and
pinned to the code this document ships with — the code is authoritative where any external
description disagrees. Protocol-wide docs: https://docs.sherwood.sh/

## What it is

A single ERC-1167 clone per proposal. It:

1. Pulls USDG from the vault and `deposit`s it into a **strategy-owned** Lighter perp
   account (the first deposit registers the account synchronously in the same tx).
2. Registers a **trade-only** agent L2 key so an off-chain agent can trade the account via
   Lighter's API — the key can place/cancel orders but can **never** move funds out.
3. Lets the proposer run on-chain **guardrails** (cancel all, market-close a position,
   rotate the key, queue a withdrawal) at any time between execute and settle.
4. Unwinds via a **two-phase settle**: `initiateReturn` closes positions and queues the
   (async, slow) USDG withdrawal; a later `_settle` claims the matured balance and returns
   it to the vault.

It is **Lane-B only** — `positions()` is empty (inherited from `BaseStrategy`), so the
vault never prices an in-flight Lighter position; deposits and redeems settle at the frozen
per-proposal queue price.

## Trust model

| Concern | Design |
|---|---|
| **Custody boundary (D1)** | The Lighter account is owned by the **strategy contract**. Every mutating venue call is authed by `msg.sender` = the account owner. Funds can only leave the account to the account owner (this contract), and this contract only ever pushes USDG to `vault()`. |
| **Agent key is trade-only** | `changePubKey(acct, apiKeyIndex, pubKey)` registers an L2 key that can place/cancel orders through the API. It **cannot** withdraw — `withdraw` / `withdrawPendingBalance` are venue-authed to the account owner, never the API key. A compromised agent key can churn/lose the position but cannot exfiltrate principal. |
| **On-chain kill switch** | The proposer can `CANCEL_ALL`, `CLOSE_MARKET`, `WITHDRAW`, or `ROTATE_KEY` at any time via `updateParams`, and `initiateReturn` force-closes every configured market both directions and queues the drain — all without the agent's cooperation. |
| **Value is never self-reported** | `positions()` returns empty; the venue exposes no on-chain mark the PriceRouter can trust for an in-flight perp. The vault reads float only while the proposal is open; realized PnL is the USDG that actually round-trips back at settle. |

## Lifecycle

```
propose(strategy = LighterPerp clone)
        │
        ▼
execute()                pull USDG from vault → deposit into Lighter →
  (onlyVault)            account registered synchronously (accountIndex != 0)
        │
        ▼
registerAgentKey()       proposer registers the 40-byte trade-only L2 key
  (onlyProposer)         (idempotent; re-runnable for rotation)
        │
        ▼
  agent trades via Lighter API (off-chain)  ──  proposer trims risk on-chain
        │                                        via updateParams guardrails
        ▼
initiateReturn(ticks)    cancel all → both-side market-close every market →
  (proposer anytime;     queue withdraw(ticks) → record returnsInitiatedAt
   anyone after          [ticks = observed L2 balance, supplied off-chain]
   strategyDuration)
        │
        ▼
  ⏳ async maturity       Lighter's sequencer matures the withdrawal into
   (minutes → days)       getPendingBalance() — NOT same block
        │
        ▼
settle()                 requires returnsInitiatedAt != 0, a strictly later
  (onlyVault)            block, and funds present → claim pending → push all
                        USDG to the vault → governor stamps the Lane-B price
        │
        ▼
recoverResiduals() / sweepToVault()   post-settle recovery of late-maturing
  (permissionless)                    withdrawals or third-party-claimed dust
```

## Configuration (init data)

`initialize(vault, proposer, data)` where
`data = abi.encode(bytes apiKeyPubKey, uint8 apiKeyIndex, uint16[] markets, uint256 depositAmount)`.

| Field | Validation | Meaning |
|---|---|---|
| `apiKeyPubKey` | length **exactly 40** (`InvalidPubKey`) | Goldilocks-canonical L2 trading key |
| `apiKeyIndex` | `2..254` (`InvalidApiKeyIndex`) | API key slot (0/1 reserved by the web app, 255 out of range) |
| `markets` | nonempty (`NoMarkets`), each `≤ 254` (`InvalidMarket`) | perp markets this clone may trade / must close at unwind |
| `depositAmount` | — | fixed USDG amount, or **`0` = dynamic-all** (pull the vault's full USDG balance at execute) |

Venue addresses are `constant` (both chain 4663 mainnet and the 9994663 fork share them,
since the fork replays mainnet state):

- ZkLighter proxy `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d`
- USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6 dp), asset index `3`, route `Perps = 0`

`_execute` reverts `DepositTooSmall` below `MIN_DEPOSIT = 1e6` (1 USDG). USDG tick size is 1,
so any 6-dp amount is trivially a valid tick multiple.

## Guardrail actions (`updateParams`)

Proposer-only, `Executed` state only. Encoding: `abi.encode(uint8 action, bytes args)`.

| Action | Value | `args` | Effect |
|---|:---:|---|---|
| `CANCEL_ALL` | 1 | `""` | `cancelAllOrders(acct)` |
| `CLOSE_MARKET` | 2 | `(uint16 market, uint32 price, uint8 isAsk)` | `createOrder(acct, market, 0, price, isAsk, Market)` — single-side full-position close; side chosen off-chain (cheaper than the both-side close) |
| `ROTATE_KEY` | 3 | `(bytes newPubKey40)` | update the **stored** key, then `changePubKey` — reverts `InvalidPubKey` if not 40 bytes |
| `WITHDRAW` | 4 | `(uint64 ticks)` | `withdraw(acct, 3, Perps, ticks)` — queue an async withdrawal (1 USDG = 1e6 ticks) |
| `REGISTER_KEY` | 5 | `""` | (re)register the stored key — reverts `AccountNotRegistered` before the first deposit |

`baseAmount = 0` on a close order closes the **full** position on whichever side opposes it.
Any unrecognized action reverts `InvalidAction`.

## Roles & authorization matrix

`proposer` = the agent that cloned/initialized the strategy (`BaseStrategy._proposer`).

| Function | vault | proposer | anyone | State gate | Auth site |
|---|:---:|:---:|:---:|---|---|
| `execute()` / `settle()` | ✅ | | | `onlyVault` + state | `BaseStrategy.sol:88/95` |
| `registerAgentKey()` | | ✅ | | `onlyProposer`; account must exist | `LighterPerpStrategy.sol:137` |
| `updateParams(...)` | | ✅ | | `onlyProposer`, `Executed` | `BaseStrategy.sol:102`, `LighterPerpStrategy.sol:150` |
| `initiateReturn(ticks)` | | ✅ (anytime) | ✅ (after `strategyDuration`) | `Executed`; idempotent | `LighterPerpStrategy.sol:187` |
| `recoverResiduals()` | | | ✅ | `settled` only | `LighterPerpStrategy.sol:238` |
| `sweepToVault()` | | | ✅ | `settled` only | `LighterPerpStrategy.sol:248` |

The permissionless paths are safe because funds only ever flow to `vault()`:
`initiateReturn`'s drain, `_settle`'s claim+push, and `recoverResiduals`/`sweepToVault`
all push USDG to the vault; none accept a caller-supplied destination.

## Two-phase settle (G-H1)

Lighter withdrawals are **async priority requests**. A `withdraw` only becomes claimable
once the off-chain sequencer's batch executes — proven to take **minutes to days**, never the
same block. Settling naively (drain + push in one call) would push ~0 and book a **phantom
total loss** that a depositor could sandwich (deposit at the deflated NAV, redeem the windfall
once the late arrival is swept). This mirrors the fix on `HyperliquidPerpStrategy` /
`HyperliquidGridStrategy`.

**Phase 1 — `initiateReturn(uint64 ticks)`** (`LighterPerpStrategy.sol:187`):
- `cancelAllOrders`, then for **every** configured market emit **both** a market SELL-close
  (`price = 1`, `isAsk = 1`) and a market BUY-close (`price = 2^32-1`, `isAsk = 0`). The
  contract can't read a position's sign on-chain, so it closes both directions — the side
  opposing the open position fills, the other no-ops against a flat/absent position.
- `withdraw(ticks)` if `ticks > 0`. `ticks` is the **observed L2 balance** supplied off-chain
  from the API (the contract can't read its own L2 balance). A too-large value reverts
  venue-side; a too-small value leaves residue recoverable via the `WITHDRAW` guardrail +
  `recoverResiduals`.
- Records `returnsInitiatedAt = block.number`. Idempotent (a second call is a no-op).

**Phase 2 — `_settle()`** (`LighterPerpStrategy.sol:220`), governor-called:
- Reverts `ReturnsNotInitiated` if phase 1 never ran.
- Reverts `SettleTooSoon` unless `block.number > returnsInitiatedAt` (async maturity guard).
- Reverts `NothingToSettle` if **both** `getPendingBalance` and the strategy's USDG balance
  are zero — funds are still in flight; do not book a loss.
- Otherwise: claim the matured pending balance (skipped if a third party already claimed it
  here — `withdrawPendingBalance` is permissionless), then push the **entire** USDG balance
  to the vault.

## The slow-secure-withdraw reality & the LP-lock window

Because the withdrawal leg is asynchronous and slow, the proposal's Lane-B redeem queue does
**not** settle the instant `initiateReturn` is called. LPs who requested a redeem for this
proposal are paid at the frozen per-proposal price only **after** `_settle` returns the USDG —
which cannot happen until the sequencer matures the withdrawal (minutes to days). Integrators
and depositors must expect this **lock window**: an in-flight Lighter proposal ties up
redeems until maturity + settle, and there is no instant (Lane A) exit for this strategy.

Late-maturing tranches (a `withdraw` that matured after settle, or a partial fill) are
recovered permissionlessly post-settle:

- **`recoverResiduals()`** — claims any newly matured pending balance and pushes it to the
  vault. Repeatable.
- **`sweepToVault()`** — pushes any USDG the contract already holds (e.g. a balance a third
  party claimed here) to the vault. No-op on zero balance.

Both are gated to `settled == true` so they cannot race phase 1.

## Lane-B-only rationale

The strategy deliberately does **not** override `positions()` — it returns the `BaseStrategy`
default (empty array). Lighter exposes no on-chain, manipulation-resistant mark the PriceRouter
could trust for an in-flight perp (account value lives with the off-chain sequencer). Reporting
a self-computed value would violate the V2 live-NAV trust inversion ("the strategy reports
positions, the vault prices them"). So the vault reads **float only** while the proposal is
open, and deposits/redeems route through the async queue at the frozen settle price. It also
does not override `selfManagesFees` (default `false` — the governor distributes settle-fees)
or `availableLiquidity`/`withdrawTo` (inherit the inert no-on-demand-exit defaults).

## Events & errors

**Events:** `Deposited(amount, accountIndex)`, `AgentKeyRegistered(accountIndex, apiKeyIndex)`,
`OrdersCancelled(accountIndex)`, `MarketClosed(market, isAsk)`, `WithdrawQueued(ticks)`,
`ReturnsInitiated(ticks)`, `Settled()`, `FundsSwept(amount)`.

**Errors:** `InvalidPubKey`, `InvalidApiKeyIndex`, `NoMarkets`, `InvalidMarket`,
`DepositTooSmall`, `AccountNotRegistered`, `InvalidAction`, `NotAuthorized`,
`ReturnsNotInitiated`, `SettleTooSoon`, `NothingToSettle`, `NotSweepable`
(plus `BaseStrategy`'s `NotProposer` / `NotVault` / `NotExecuted` / `AlreadyExecuted` /
`AlreadyInitialized` / `ZeroAddress`).

## State reads (frontend data needs)

| Read | Source |
|---|---|
| Lighter account index (0 until first deposit) | `strategy.accountIndex()` |
| USDG ticks matured & awaiting claim | `strategy.pendingBalance()` |
| Configured markets | `strategy.markets(i)` |
| Stored agent key / key slot | `strategy.apiKeyPubKey()` / `strategy.apiKeyIndex()` |
| Unwind progress | `strategy.returnsInitiatedAt()` (block; 0 = not initiated), `strategy.settled()` |
| Cumulative post-settle recovery (off-chain accounting) | `strategy.cumulativeSwept()` |

## Fork testing

The contract/custody half runs against the **real** ZkLighter contract on the Tenderly
Robinhood-mainnet fork (chain 9994663) — see `docs/lighter-fork-testing.md`. The fork replays
mainnet state, so `deposit` (registers synchronously), `changePubKey`, `createOrder`,
`cancelAllOrders`, `withdraw`, and `withdrawPendingBalance` all execute for real; only the
off-chain sequencer's L2 effects (fills, PnL, withdrawal maturity) never arrive on their own.
Withdrawal maturity is simulated with a storage cheat (`tenderly_setStorageAt` on
`pendingAssetBalances`); the API/trade leg is exercised separately against the `rh-testnet`
Lighter domain. Full end-to-end bench (create fund → propose → execute/deposit →
registerAgentKey → guardrails → initiateReturn → simulate maturity → settle) is §5 of that doc.

## Canary provenance

The contract-owned-account lifecycle was proven **live on Robinhood mainnet (chain 4663)** by
the `LighterAccountOwner` canary harness (`test/harness/LighterAccountOwner.sol`), which ran the
full loop — deposit USDG → contract-owned account **623** → register agent key → trade → force-
close → withdraw USDG back to the contract. This strategy generalizes that canary into a
Sherwood strategy template: same custody boundary and on-chain kill switch, wrapped in the
vault/proposer lifecycle with the two-phase async settle.
