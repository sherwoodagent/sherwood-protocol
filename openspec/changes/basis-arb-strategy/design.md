# Design: BasisArbStrategy

## Shape

A `BaseStrategy` subclass, conforming to the existing template lifecycle
(`initialize` → `_execute` → pokes during the window → `_settle` → `sweep`).
The vault and governor need zero changes — the whole point of choosing the
template path over a protocol change.

```
                      one proposal = one trading WINDOW
 vault ── asset ──► BasisArbStrategy clone ──────────────────────────┐
                    │ _execute(): custody only, no trade             │
                    │                                                │
                    │ pokeArb(dir, minOut)  [permissionless]         │
                    │   1. read 4 pool prices, same block            │
                    │   2. basisBps = gap(routeA, routeB)            │
                    │   3. require basisBps >= minBasisBps           │
                    │   4. swap cheap route in, rich route out,      │
                    │      one tx, require out >= in + minProfit     │
                    │                                                │
                    │ _settle(): push all asset home                 │
                    │ sweep(): residue path (leg tokens stranded     │
                    │          by a partial failure)                 │
                    └────────────────────────────────────────────────┘
```

## Decisions

### D1. Inventory triangle, not flash-atomic legs against each other

Each poke: `asset → route-in → intermediate(s) → route-out → asset`, all in
one transaction, ending flat. The clone never holds a non-asset token across
transactions in normal operation. Consequences:

- `hasUndeliveredValue()` is `asset balance > dust` — trivially honest.
- A leg that fails mid-poke reverts the whole poke (no partial inventory).
- The only way non-asset tokens strand on the clone is a token that lies
  about transfers — which is what `sweep()` and the vault's residue
  machinery already exist for.

### D2. Legs are init parameters, generic over (v3 pool | v4 poolId)

```solidity
struct Leg {
    uint8   kind;        // 0 = uniswap v3 pool, 1 = v4 poolId via PoolManager
    address pool;        // v3 pool address (kind 0)
    bytes32 poolId;      // v4 pool id     (kind 1)
    bool    zeroForOne;  // trade direction along this leg, route-A orientation
}
```

`init` takes `Leg[] routeA, Leg[] routeB` (each 1–2 legs), the shared
endpoints (vault asset in/out), `minBasisBps`, `maxTradeNotional`,
`maxLegs = 2` hard cap. Pair-agnostic by construction — the AI/NVDA numbers
live in the proposal that instantiates a clone, never in the template. This
is what lets the same template serve the next Bankr listing if AI/NVDA fails
the economics gate.

Init MUST verify the two routes share endpoints (`asset → X → asset`) and
that every v3 leg's `token0/token1` and every v4 leg's currencies actually
chain — mis-wired legs fail at init, not at execute (repo convention: fail
closed at the cheapest moment).

### D3. Price reads

- v3 legs: `slot0()` direct.
- v4 legs: `PoolManager.extsload(keccak256(poolId . uint256(6)))`, low 160
  bits = sqrtPriceX96. **Validated live 2026-08-31**: bankr AI/NVDA read
  0.000603 NVDA/AI against $0.133/$220 spot — self-consistent. `lpFee` is
  bits 208–231 (pips); read it live because the Bankr hook sets it
  dynamically (70bps observed), and `minBasisBps` must be checked against
  the LIVE fee sum, not an init-time constant:

  `require(basisBps >= minBasisBps && basisBps > liveFeeSumBps + marginBps)`

  A hook that hikes its fee mid-window otherwise turns a profitable-looking
  poke into a guaranteed-loss fill.

### D4. Swap execution

- v3 legs: pool `swap()` directly with a callback, or the canonical
  SwapRouter — decide at implementation by what the guardian book already
  knows (the fleet has `UNISWAP_SWAP_ADAPTER`/router entries; direct pool
  swaps would add 3 unknown targets per proposal).
- v4 leg: `PoolManager.unlock` + `swap` in the callback (canonical v4
  integration), settle deltas with `take`/`settle`.
- Slippage: caller passes `minOut`; the contract additionally enforces
  `out >= in + (in * minProfitBps / 10_000)` — the poke may not close at a
  loss even if the caller is hostile or careless. This is the same
  caller-cannot-hurt-the-vault stance as `rerange()`'s policy guards.

### D5. `pokeArb` trigger is verified on chain, not trusted

Direction is an argument (`dir`: A-cheap vs B-cheap) but the contract
recomputes the basis itself and reverts on `BasisTooThin` /
`WrongDirection`. Anyone may poke; a poke that would not profit reverts.
Manipulation analysis: an attacker who moves a pool to fake a basis must
move it against the pool's own arbitrageurs, and the poke's profit check
means the worst outcome for the vault is a revert or a profitable fill.
The residual risk is the attacker sandwiching the poke's own legs — bounded
by `minOut` + `minProfitBps`, identical in kind to every swap the protocol
already executes.

### D6. Open spike before implementation freezes: the Bankr hook

A v4 hook can discriminate callers (beforeSwap sees the sender), skim, or
revert non-router flow. **Task 0 is a fork-test that swaps through the
bankr pool from a contract caller.** If the hook blocks contract callers,
route A's bankr leg must go through the Universal Router instead of direct
`PoolManager` calls — or the strategy is dead regardless of economics.
This is the one remaining kill-risk and it costs one fork test to resolve.

### D7. Economics ship-gate lives in the proposal, not the code

The template merges on its own correctness. Proposing a live clone is gated
on the sampler distribution (see proposal.md). Rationale: the code is
pair-agnostic infrastructure; the AI/NVDA go/no-go is a deployment decision
that data settles, and Bankr keeps listing new meme/RWA pairs.

## Guardian-side work (separate repo, sherwood-guardian)

- chains book: add v4 PoolManager `0x8366a39c…` and Universal Router
  `0x88767899…` as known targets.
- risk.ts: the batch path flags undecoded calldata at known targets as
  warning (existing behavior) — acceptable for v1; a v4-swap decoder is a
  follow-up, not a blocker.

## Testing

- Unit: init endpoint-chaining validation (mis-wired legs revert), basis
  math against fixed sqrtPriceX96 fixtures (including the live-validated
  bankr word `0x…064b92ec50…`), fee-floor guard, minProfit enforcement,
  poke reverts on thin basis.
- Fork (pinned block, per repo rule): the D6 hook spike; one full poke
  round-trip on the real four pools; settle delivers asset.
- Mutation checks on every new guard (repo discipline): drop the fee-sum
  check, invert a leg orientation, remove minProfit — each must fail a test.
- Lifecycle: `LifecycleSimulation` harness run with this template in a
  sandboxless proposal, as with pid 22's flow.
