# LighterPerpStrategy — spec & integration guide

A perpetuals strategy that runs a **contract-owned Lighter (zkLighter) margin account**.
USDG is pulled from the vault into an account owned by the strategy contract; a proposer-
registered **agent L2 trading key** drives trades off-chain through Lighter's API, while
every custody action (cancel, close, withdraw) stays on-chain and authed to the account
owner — the strategy itself.

This document serves two audiences:

- **Auditors** — architecture, trust model, storage, authorization, the three-step settle,
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
   rotate the key) at any time between execute and settle.
4. Unwinds via a **three-step settle**: `initiateReturn()` closes positions,
   `queueWithdraw(ticks)` queues the (async, slow) USDG drain once the closes have
   filled, and a later `_settle` claims the matured balance and returns it to the vault.

It is **Lane-B only** — `positions()` is empty (inherited from `BaseStrategy`), so the
vault never prices an in-flight Lighter position; deposits and redeems settle at the frozen
per-proposal queue price.

## Trust model

| Concern | Design |
|---|---|
| **Custody boundary (D1)** | The Lighter account is owned by the **strategy contract**. Every mutating venue call is authed by `msg.sender` = the account owner. Funds can only leave the account to the account owner (this contract), and this contract only ever pushes USDG to `vault()`. |
| **Agent key is trade-only** | `changePubKey(acct, apiKeyIndex, pubKey)` registers an L2 key that can place/cancel orders through the API. It **cannot** withdraw — `withdraw` / `withdrawPendingBalance` are venue-authed to the account owner, never the API key. A compromised agent key can churn/lose the position but cannot exfiltrate principal. |
| **On-chain kill switch** | The proposer can `CANCEL_ALL`, `CLOSE_MARKET` or `ROTATE_KEY` at any time via `updateParams`, `initiateReturn()` force-closes every configured market both directions, and `queueWithdraw(ticks)` drains the account — all without the agent's cooperation. |
| **Value is never self-reported** | `positions()` returns empty; the venue exposes no on-chain mark the PriceRouter can trust for an in-flight perp. The vault reads float only while the proposal is open; realized PnL is the USDG that actually round-trips back at settle. |
| **Residual trust: `markets` ≠ the agent's reach** | The registered L2 key can trade **any** Lighter market — the venue enforces no per-key whitelist. `markets` is only the list `initiateReturn()` auto-closes, so a position the agent opens outside it is **not** closed by the automatic unwind and its margin stays locked. See "Residual trust" below. |
| **Residual trust: the settle gate is a *liveness* check, not a completeness check** | `_settle`'s guard compares what came back against `queuedTicks` — the amount the **proposer chose**. It proves "everything I *asked* for arrived", which is enough to stop a phantom-loss settle a depositor could sandwich, but it does **not** prove the venue account is empty: `queueWithdraw(1)` plus one tick maturing satisfies it with the rest of the margin still at Lighter. It cannot be made complete on-chain — position and margin state live with the off-chain sequencer and `IZkLighter` exposes no accessor for either, which is the same reason `positions()` is empty. **Completeness is an off-chain guarantee**: the CLI's `queue-withdraw --all` reads the true L2 balance from the Lighter API and hard-aborts on any nonzero position size. It sits in the same trust bucket as the agent key — a proposer who ignores the CLI can stamp the Lane-B redeem price at a deflated NAV, which is a transfer from exiting LPs to remaining LPs (the residue is still recoverable via `queueWithdraw` + `recoverResiduals`, but it lands *after* the stamp). See "The settle guard cannot brick the vault" below. |

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
initiateReturn()         cancel all → both-side market-close every market →
  (proposer anytime;     record returnsInitiatedAt. Queues NOTHING.
   anyone once
   strategyDuration
   has elapsed)
        │
        ▼
  ⏳ closes fill          the closing trades' PnL only exists now — this is why
                          the drain amount cannot be chosen a step earlier
        │
        ▼
queueWithdraw(ticks)     queue withdraw(ticks) → queuedTicks += ticks
  (proposer OR           [ticks = observed L2 balance, read off-chain AFTER
   vault owner)           the closes filled]. Repeatable, and callable in the
                          Settled state so an under-withdraw is correctable.
        │
        ▼
  ⏳ async maturity       Lighter's sequencer matures the withdrawal into
   (minutes → days)       getPendingBalance() — NOT same block
        │
        ▼
settle()                 requires returnsInitiatedAt != 0, a strictly later
  (onlyVault)            block, and that everything queued has arrived →
                        claim pending → push all USDG to the vault →
                        governor stamps the Lane-B price
        │
        ▼
recoverResiduals() / sweepToVault()   recovery of late-maturing withdrawals or
  (permissionless, any state)         third-party-claimed dust
```

## Configuration (init data)

`initialize(vault, proposer, data)` where
`data = abi.encode(bytes apiKeyPubKey, uint8 apiKeyIndex, uint16[] markets, uint256 depositAmount)`.

| Field | Validation | Meaning |
|---|---|---|
| `apiKeyPubKey` | length **exactly 40** (`InvalidPubKey`) | Goldilocks-canonical L2 trading key |
| `apiKeyIndex` | `2..254` (`InvalidApiKeyIndex`) | API key slot (0/1 reserved by the web app, 255 out of range) |
| `markets` | nonempty (`NoMarkets`), at most **16** (`TooManyMarkets`), each `≤ 254` (`InvalidMarket`), no duplicates (`DuplicateMarket`) | perp markets `initiateReturn()` auto-closes. **Not** a venue-enforced trading whitelist — see "Residual trust" |
| `depositAmount` | `≤ type(uint64).max` (`DepositTooLarge`) | fixed USDG amount, or **`0` = dynamic-all** (pull the vault's full USDG balance at execute) |

`MAX_MARKETS = 16` and the duplicate rejection exist because `initiateReturn()` makes
**2 venue calls per market in one transaction**. An unbounded or padded list could push
that past the block gas limit, which would make `returnsInitiatedAt` unreachable and
therefore `_settle` permanently unreachable — locking vault redemptions.

`depositAmount` is bounded by `type(uint64).max` (checked at init **and** for the
dynamic-all path at execute) because `IZkLighter.withdraw` takes `uint64` ticks: a larger
deposit could never be drained in a single request.

The **template** constructor pins `block.chainid` to `4663` (Robinhood mainnet) or
`9994663` (the fork), reverting `UnsupportedChain` otherwise — the venue and asset
addresses below are `constant`, so a template deployed on any other chain would point at
whatever code happens to live at those addresses. ERC-1167 clones skip constructors, so
this guards the template deploy only, which is exactly the right place.

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
| ~~`WITHDRAW`~~ | ~~4~~ | — | **RETIRED.** Superseded by the top-level `queueWithdraw(ticks)`, which must also work in the `Settled` state and therefore cannot route through `updateParams` (Executed-only). Action `4` now reverts `InvalidAction`; `1`/`2`/`3`/`5` keep their meaning |
| `REGISTER_KEY` | 5 | `""` | (re)register the stored key — reverts `AccountNotRegistered` before the first deposit |

`baseAmount = 0` on a close order closes the **full** position on whichever side opposes it.
Any unrecognized action reverts `InvalidAction`.

`CLOSE_MARKET` deliberately does **not** validate `market` against the configured `markets`
list. That is not an oversight: the agent key can trade any Lighter market, so this is the
operator's only remedy for a position opened outside the list (see "Residual trust").
Impact is bounded — `baseAmount = 0` can only *close* a position, never open one.

## Roles & authorization matrix

`proposer` = the agent that cloned/initialized the strategy (`BaseStrategy._proposer`).

| Function | vault | proposer | vault owner | anyone | State gate |
|---|:---:|:---:|:---:|:---:|---|
| `execute()` / `settle()` | ✅ | | | | `onlyVault` + state |
| `registerAgentKey()` | | ✅ | | | `onlyProposer`; account must exist |
| `updateParams(...)` | | ✅ | | | `onlyProposer`, `Executed` |
| `initiateReturn()` | | ✅ (anytime) | | ✅ (once `strategyDuration` has elapsed) | `Executed` |
| `queueWithdraw(ticks)` | | ✅ | ✅ | | `Executed` **or** `Settled` |
| `acknowledgeShortfall()` | | ✅ | ✅ | | `returnsInitiatedAt != 0` **and** `queuedTicks != 0` **and** a shortfall is currently observable |
| `recoverResiduals()` | | | | ✅ | any |
| `sweepToVault()` | | | | ✅ | any |

The permissionless paths are safe because funds only ever flow to `vault()`: `_settle`'s
claim+push and `recoverResiduals`/`sweepToVault` all push USDG to the vault, and none
accept a caller-supplied destination.

Five auth details are load-bearing:

- **`queueWithdraw` is NOT permissionless**, even after `strategyDuration`. The amount is
  un-correctable once the request is queued, so letting an anonymous caller choose it
  would let them book the entire principal as an LP loss for the price of two
  transactions. Only the drain *trigger* (`initiateReturn`) is permissionless; the drain
  *amount* never is.
- **`initiateReturn()`'s permissionless branch validates the proposal identity, not just
  the clock.** `getActiveProposal()` returns `0` when nothing is active and
  `getProposal(0)` returns a **zeroed struct rather than reverting**, so a bare
  `block.timestamp < p.executedAt + p.strategyDuration` check is fail-**open** for
  everyone. That state is reachable: every emergency-settle path clears
  `_activeProposal` while the strategy may still be `Executed`. The gate therefore
  rejects `pid == 0` and `p.strategy != address(this)` first.
- **The permissionless branch may only *kick off* the unwind.** The proposer can
  re-invoke `initiateReturn()` freely (e.g. the agent re-opened after the first close),
  but a repeat from an anonymous caller reverts `AlreadyInitiated` so a griefer cannot
  spam venue priority requests block after block. `returnsInitiatedAt` latches on the
  first call only — re-latching would reset the async-maturity clock and hold `_settle`
  in `SettleTooSoon` indefinitely.
- **`acknowledgeShortfall()` is state-gated, not a free waiver.** It waives the two
  settle guards that stand between `settle()` and booking the principal as a loss, so an
  ungated version was a one-call bypass of both: arm it the moment the strategy went
  `Executed` (before any close, before any drain was requested) and `settle()` booked
  100% of the principal as a loss with the funds still at the venue. It now requires an
  *initiated* return, a *nonzero* `queuedTicks`, and a shortfall that is **actually
  observable right now** (`returnedAssets + pending + bal < queuedTicks`) — you can only
  acknowledge a shortfall against something you actually asked for and did not get. Kept
  on the proposer as well as the vault owner deliberately: post-gate the waiver grants
  the proposer nothing they do not already hold via the denominator (see "the settle
  gate is a liveness check" below), and the proposer is the party that observes the
  under-fill operationally, so excluding them would cost liveness for no security.
- **After an emergency settle, the permissionless `initiateReturn()` branch is closed.**
  Rejecting `pid == 0` (the M1 fix) means that once `_activeProposal` is cleared the only
  remaining unwind drivers are the **proposer** and the **vault owner** (via
  `queueWithdraw`), with `recoverResiduals()`/`sweepToVault()` still open to anyone. This
  is deliberate, not a gap: the emergency-settle path is itself vault-owner-driven, so
  the owner is by construction present and is the correct unwind driver; leaving the
  branch open in that state is precisely the fail-open M1 exploits.

## Three-step settle (G-H1 + the close/withdraw split)

Lighter withdrawals are **async priority requests**. A `withdraw` only becomes claimable
once the off-chain sequencer's batch executes — proven to take **minutes to days**, never the
same block. Settling naively (drain + push in one call) would push ~0 and book a **phantom
total loss** that a depositor could sandwich (deposit at the deflated NAV, redeem the windfall
once the late arrival is swept).

**Why close and withdraw are separate steps.** Both legs used to live in one
`initiateReturn(ticks)` call, which meant `ticks` was read off-chain *before* the closing
trades executed — so it structurally could not include those trades' PnL. Under-stating
stranded the remainder permanently: `_settle` succeeded on any pending balance, flipped the
state to `Settled`, and `updateParams` (the only route to `ZK_LIGHTER.withdraw`) is gated on
`Executed`. `recoverResiduals()` can only *claim* an already-queued pending balance, never
*queue* a new withdrawal. The two legs are therefore split, and the withdraw leg is
reachable **after** settlement.

**Step 1 — `initiateReturn()`**:
- `cancelAllOrders`, then for **every** configured market emit **both** a market SELL-close
  (`price = 1`, `isAsk = 1`) and a market BUY-close (`price = 2^32-1`, `isAsk = 0`). The
  contract can't read a position's sign on-chain, so it closes both directions — the side
  opposing the open position fills, the other no-ops against a flat/absent position.
- Queues **nothing**. Records `returnsInitiatedAt = block.number` on the first call.

> **MEV surface.** Those price bounds (`1` for a SELL, `2^32-1` for a BUY) are the widest
> legal values — i.e. the unwind carries **zero slippage protection**. This is deliberate:
> an unwind that silently no-fills is strictly worse than a bad fill, because the margin
> then never leaves the venue and the whole settlement stalls. The cost is that a searcher
> who can see the pending priority request may fill it at a punitive price. If tighter
> bounds are wanted for a given position, use `CLOSE_MARKET` (which takes an explicit
> `price`) *before* `initiateReturn()`; the both-side sweep then no-ops on a flat book.

**Step 2 — `queueWithdraw(uint64 ticks)`**, proposer or vault owner:
- `withdraw(acct, 3, Perps, ticks)`, accumulating into `queuedTicks`. `ticks` is the
  **observed L2 balance** read off-chain from the API *after* the closes filled (the
  contract can't read its own L2 balance). A too-large value reverts venue-side.
- Repeatable, and callable in **both** `Executed` and `Settled`, so an under-withdraw is
  always correctable — including after settlement.

**Step 3 — `_settle()`**, governor-called:
- Reverts `ReturnsNotInitiated` if step 1 never ran.
- Reverts `SettleTooSoon` unless `block.number > returnsInitiatedAt` (async maturity guard).
- Reverts `NothingQueued` if `queuedTicks == 0` — no drain was ever requested, so settling
  would book the whole principal as a loss while it still sits on the venue.
- Reverts `WithdrawalInFlight(queued, accounted)` if
  `returnedAssets + getPendingBalance() + USDG.balanceOf(this) < queuedTicks` — what was
  asked for has not fully arrived. This replaces the old
  `pending == 0 && bal == 0` check, which **anyone could satisfy by donating 1 wei of USDG
  to the clone**. `returnedAssets` (cumulative pushed-to-vault) keeps the sum monotone, so
  a permissionless `sweepToVault()` immediately before settle moves value to the vault
  without ever bricking settlement.
- Otherwise: claim the matured pending balance (skipped if a third party already claimed it
  here — `withdrawPendingBalance` is permissionless), then push the **entire** USDG balance
  to the vault.

### What the settle gate does and does not prove

Stated plainly, because the distinction is load-bearing and it is easy to read the guard as
stronger than it is:

- **It is a liveness / anti-phantom-loss check.** It proves *"everything I asked for has
  come back"*. That is exactly enough to stop the attack it was added for — settling into a
  0-balance vault and booking a phantom total loss that a depositor can sandwich.
- **It is NOT a completeness check.** The denominator is `queuedTicks`, which the proposer
  chooses. `queueWithdraw(1)` followed by 1 tick maturing satisfies the guard with **no
  waiver at all**: the vault receives 0.000001 USDG and the rest of the margin is still at
  the venue when the Lane-B price is stamped.
- **It cannot be made complete on-chain.** The account's true balance and open positions are
  off-chain sequencer state; `IZkLighter` exposes `getPendingBalance` (matured withdrawals
  only) and nothing else. There is no value the contract could compare against.
- **Completeness is enforced off-chain**, by the CLI: `queue-withdraw --all` reads the true
  L2 balance from the Lighter API and hard-aborts if any market still has a nonzero position
  size. That is an operational guarantee, not a contract one, and it belongs in the trust
  model next to the agent key — see the "settle gate is a liveness check" row above.
- **The residual risk is a NAV *transfer*, not a loss.** A proposer who under-queues stamps
  the per-proposal redeem price low; the residue is still fully recoverable via
  `queueWithdraw` + `recoverResiduals`, but it lands after the stamp, so the value moves
  from exiting LPs to remaining LPs. The vault owner's `emergencySettleWithCalls` path is
  the backstop if the proposer will not complete the drain.

### The settle guard cannot brick the vault

The contract can never *know* the account is empty — it can only verify that what it
**asked** for has come back. When the venue under-fills (partial batch, forced liquidation,
a write-off), `accounted` can never reach `queuedTicks` and the guard would hold `_settle`
shut. Three independent releases exist, in increasing order of cost:

1. **`acknowledgeShortfall()`** — proposer *or* vault owner asserts the shortfall is real.
   It only relaxes a timing gate: it cannot redirect funds, and anything that matures later
   is still recoverable via `queueWithdraw` + `recoverResiduals` **after** settle. This is
   the normal path.

   It is **state-gated**, and the gate matters: the waiver skips both `NothingQueued` and
   `WithdrawalInFlight`, so without preconditions it was a one-call bypass of the entire
   settle guard from the moment the strategy went `Executed`. Arming now requires all three
   of:
   - `returnsInitiatedAt != 0` (`ReturnsNotInitiated`) — the positions were actually closed;
   - `queuedTicks != 0` (`NothingQueued`) — a drain was actually requested, so there is a
     denominator to fall short of;
   - `returnedAssets + pending + bal < queuedTicks` (`NoShortfall(queued, accounted)`) — the
     shortfall is observable *now*. If `accounted` ever reaches `queuedTicks`, `_settle`
     passes unaided and the waiver is not needed; `returnedAssets` is monotone so
     `accounted` only grows, and this check can never lock out a genuine under-fill.
     Arming while `accounted == 0` (nothing matured yet) stays legal — that is the normal
     case.

   Note what the gate does **not** claim: it does not stop a proposer from settling at a
   deflated NAV, because `queueWithdraw(1)` already does that without any waiver (see "What
   the settle gate does and does not prove"). What it stops is doing so *instantly*, against
   an unwind that was never started and a drain that was never requested. Given that, the
   proposer is kept on the function: excluding them would remove no lever they do not
   already have, and would cost the liveness of the escape hatch in exactly the case it
   exists for, since the proposer is the party that observes the under-fill.
2. **`SyndicateGovernor.unstick(pid)`** — vault owner runs the pre-committed settlement
   calls. (Only helps if those calls don't include a reverting `strategy.settle()`.)
3. **`emergencySettleWithCalls` → `finalizeEmergencySettle`** — the vault owner supplies
   arbitrary unwind calls; `_finishSettlementHook` completes the proposal in the *governor*
   whether or not `strategy.settle()` was ever called. This is the structural guarantee: a
   reverting `_settle` can never permanently lock vault redemptions.

Because (3) resolves a proposal without touching the strategy, `recoverResiduals()` and
`sweepToVault()` are **not** gated on `settled` — gating them there would strand every
emergency-settled position. Both are permissionless with a fixed destination (the vault),
so racing the unwind is harmless.

### Residual trust: `markets` is not a trading whitelist

The registered L2 key can trade **any** Lighter market. The venue enforces no per-key market
restriction, and the contract has no way to impose one. `markets` is only the list that
`initiateReturn()` automatically closes.

**Consequence:** if the agent opens a position in a market outside `markets`, the automatic
unwind never closes it. Its margin stays locked on the venue, so the post-close L2 balance
is lower than expected and `queueWithdraw` under-fills — the loss shows up as a settlement
shortfall, not as a revert.

**Operator remedy:** `CLOSE_MARKET` (action `2`) on the unlisted market — this is exactly
why that action does not validate against `markets` — then `queueWithdraw(ticks)` for the
freed margin.

**Ordering constraint:** `CLOSE_MARKET` routes through `updateParams`, which is
`Executed`-only. `queueWithdraw` survives into `Settled`, but *closing* does not. Discover
and close stray positions **before** settlement; monitoring the account's open positions
off-chain (they are not readable on-chain) is an operational requirement, not an optional
extra.

## The slow-secure-withdraw reality & the LP-lock window

Because the withdrawal leg is asynchronous and slow, the proposal's Lane-B redeem queue does
**not** settle the instant the unwind starts. LPs who requested a redeem for this
proposal are paid at the frozen per-proposal price only **after** `_settle` returns the USDG —
which cannot happen until the sequencer matures the withdrawal (minutes to days). Integrators
and depositors must expect this **lock window**: an in-flight Lighter proposal ties up
redeems until maturity + settle, and there is no instant (Lane A) exit for this strategy.

Late-maturing tranches (a `withdraw` that matured after settle, or a partial fill) are
recovered post-settle:

- **`queueWithdraw(ticks)`** — proposer/owner queues the residue. Works in the `Settled`
  state; this is what makes an under-withdraw recoverable rather than terminal.
- **`recoverResiduals()`** — claims any newly matured pending balance and pushes it to the
  vault. Repeatable.
- **`sweepToVault()`** — pushes any USDG the contract already holds (e.g. a balance a third
  party claimed here) to the vault. No-op on zero balance.

The last two are **ungated** (any state, any caller) — see "The settle guard cannot brick
the vault". Note that value arriving *after* settlement accrues to whoever holds shares at
that moment, not to the LPs who redeemed at the frozen settle price: recovering residue is
strictly better than stranding it, but it is not neutral. Queue the true balance before
settling whenever possible.

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
`OrdersCancelled(accountIndex)`, `MarketClosed(market, isAsk)`,
`WithdrawQueued(ticks, cumulativeTicks)`, `ReturnsInitiated(address indexed caller)`,
`ShortfallAcknowledged(address indexed caller, uint256 queuedTicks, uint256 accounted)`
(the two amounts make the assertion auditable from logs), `Settled()`, `FundsSwept(amount)`.

**Errors:** `InvalidPubKey`, `InvalidApiKeyIndex`, `NoMarkets`, `InvalidMarket`,
`DuplicateMarket`, `TooManyMarkets`, `DepositTooSmall`, `DepositTooLarge`,
`AccountNotRegistered`, `InvalidAction`, `NotAuthorized`, `ReturnsNotInitiated`,
`AlreadyInitiated`, `SettleTooSoon`, `ZeroTicks`, `NothingQueued`,
`WithdrawalInFlight(queued, accounted)`, `NoShortfall(queued, accounted)`, `UnsupportedChain`
(plus `BaseStrategy`'s `NotProposer` / `NotVault` / `NotExecuted` / `AlreadyExecuted` /
`AlreadyInitialized` / `ZeroAddress`).

`AccountNotRegistered` is raised by a single shared `_acct()` helper that every
venue-calling path goes through — including `_execute`, which fails the whole deposit
rather than custodying capital in an account this contract cannot address. Account index
`0` is a *different* account, not "no account", so no path may pass it through.

## State reads (frontend data needs)

| Read | Source |
|---|---|
| Lighter account index (0 until first deposit) | `strategy.accountIndex()` |
| USDG ticks matured & awaiting claim | `strategy.pendingBalance()` |
| Configured markets | `strategy.markets(i)` |
| Stored agent key / key slot | `strategy.apiKeyPubKey()` / `strategy.apiKeyIndex()` |
| Unwind progress | `strategy.returnsInitiatedAt()` (block; 0 = not initiated), `strategy.settled()` |
| Ticks requested from the venue (cumulative) | `strategy.queuedTicks()` |
| USDG delivered to the vault by this clone (cumulative — settle push **and** every sweep) | `strategy.returnedAssets()` |
| Shortfall waived by proposer/owner | `strategy.shortfallAcknowledged()` |

`returnedAssets` replaces the old `cumulativeSwept`, which counted only `_sweep()` and
silently omitted `_settle`'s push — the name over-promised. `returnedAssets` counts every
push, which is also what makes the settle guard monotone.

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
vault/proposer lifecycle with the async settle.

The **full strategy lifecycle** was then proven on the Robinhood-mainnet fork (chain 9994663)
against real deployed Sherwood core + real ZkLighter: propose → vote → execute (deposited into
ZkLighter, registered real account **843**) → `registerAgentKey` → `initiateReturn` → settle
(USDG round-tripped to the vault, ~0 PnL, proposal Settled). That run predates the
close/withdraw split, so it exercised the old single-call `initiateReturn(ticks)`; the
withdraw leg is now the separate `queueWithdraw(ticks)` step and the bench in
[`lighter-fork-testing.md`](./lighter-fork-testing.md) §5 has been updated to match.
**Re-running §5 against the current API is still outstanding.**
