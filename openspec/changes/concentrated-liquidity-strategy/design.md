## Context

See `proposal.md` — Why, for motivation and the measured venue data. Requirements are in `specs/concentrated-liquidity-strategy/spec.md`.

Design-relevant constraints from the existing codebase:

- `BaseStrategy` already owns the lifecycle, the clone-ratchet guard (`NotActiveProposalStrategy`), and the vault push/pull helpers. This template supplies only `_initialize`, `_execute`, `_settle`, `_updateParams`.
- `MorphoSupplyStrategy` is the closest precedent and establishes two patterns this design reuses verbatim: init-time validation in adversary order, and deliverable-maximum settlement with a permissionless post-settlement `sweep()`.
- `PortfolioStrategy` establishes the repo's oracle-read discipline: raw `staticcall` + explicit `ret.length` check + `abi.decode`, with the failure branch a stated decision rather than an accident (`_tryPushFeedPrice`).
- Morpho Blue is already vendored under `src/vendor/morpho/`. A Uniswap V3 position manager is not vendored; `UniswapSwapAdapter` covers swaps only.

## Goals / Non-Goals

**Goals:**
- A template whose on-chain guards bound the damage from wrong off-chain parameters, without trying to reproduce the off-chain analysis on-chain.
- Settlement that cannot be vetoed by a third party.
- Reuse of the two `MorphoSupplyStrategy` patterns rather than new invention.

**Non-Goals:**
- Computing volatility, trailing medians, or venue-decay signals on-chain.
- Discretionary reranging — a rerange re-centers on a formula, and no caller chooses the resulting range (see Decision 4).
- Pricing an open position for mid-proposal NAV — the vault sees this clone the way it sees `MorphoSupplyStrategy`: custody in, vault asset out.
- Uniswap V4 support in this change.

## Decisions

### Decision 1: The agent chooses parameters; the contract bounds them

The strategy's economics depend on realized volatility, trailing fee/TVL, and venue decay — none computable on-chain. The agent computes the band, size, and target LTV off-chain and passes them as init data; the contract enforces only invariants it can evaluate from live venue state: pool/market existence and token match, borrow ≤ lendable liquidity, LTV ≤ LLTV − buffer, notional ≤ pool-share cap, tick alignment, and a spot-vs-TWAP bound at execute.

*Alternative considered:* derive the band on-chain from a TWAP-based volatility estimate. Rejected — a volatility figure computed from the same pool the position trades in is manipulable by the party the guard exists to stop, and it would put a log-math dependency in a security path to replace a number the agent already has.

The division is honest about what each side can know. It also means a bad-but-in-bounds proposal is possible; that is what voter and guardian review are for.

### Decision 2: Tick range is passed as absolute ticks, not a percentage

Init data carries `tickLower`/`tickUpper` as `int24`. The contract validates ordering, non-emptiness, and tick-spacing alignment, but does not convert a percentage band into ticks.

*Alternative considered:* accept `bandBps` and convert on-chain. Rejected — the conversion needs `TickMath`-grade log/exp, which costs bytecode and precision in a path where the caller (the agent) has already done the arithmetic exactly. Ticks are the venue's native unit; accepting them removes a lossy translation rather than adding one.

### Decision 3: Collateral is the vault asset or a configured wrapper of it — never the volatile leg

The borrow leg posts a stable asset as collateral and borrows the vault asset. Measured: stable-wrapper markets carry $1.19M–$20.15M lendable at 91.5% LLTV, while every tokenized-equity market on the chain holds $0–$1.6k. Posting the volatile leg is unexecutable at any size the vault cares about.

*Alternative considered:* collateralize the tokenized equity and borrow the stable — the shape the source strategy brief assumed. Rejected on measured liquidity, and it would also give the position a second liquidation surface correlated with the LP's own divergence loss.

### Decision 4: Rerange is permissionless and fully determined — the policy is approved, not each range

The strategy brief this template comes from has a `rerange_rule`, and a CL position that cannot rerange is a position that stops earning the moment price leaves its band. The template supports reranging, but resolves the "who approves the new range" problem by removing the discretion rather than by granting it.

What voters and guardians approve is the **rerange policy**, fixed at initialization and immutable thereafter: a half-width in ticks, a trigger fraction of the band, a minimum interval, a maximum rerange count, and a slippage floor. What a rerange call then does is fully determined by that policy plus live chain state — the new range is the approved half-width centered on the current TWAP tick, snapped to tick spacing. No caller, including the proposer, picks the new range.

Because there is no discretion left, `rerange()` is permissionless. Anyone may call it, and the only thing they can influence is *when* — which is already bounded by the trigger condition and the minimum interval.

*Alternative considered — proposer-controlled rerange:* let the proposer nominate the new range through `updateParams`. Rejected: that is precisely the hazard the narrow-tunables requirement exists to prevent. A proposer who can re-center an approved position at will can walk it anywhere over the strategy period, one "rerange" at a time, and the review that approved the original range never covered any of the destinations.

*Alternative considered — rerange only via a new proposal:* settle and re-propose. Rejected as the default: it costs a full governance cycle per rerange, which makes any band tight enough to be worth running uneconomic. It remains available — a proposer who wants a genuinely different band still proposes one.

*Trade-off accepted:* a deterministic re-center is not always the *best* range, only a defensible one. A caller can also time reranges adversarially within the allowed window (calling right after an unfavorable tick move rather than a favorable one). The minimum interval, the trigger fraction, the rerange cap, and the slippage floor bound how much that timing is worth; they do not eliminate it. The rerange cap in particular is what stops a griefer from grinding the position's value away through repeated in-bounds reranges, each paying swap cost.

### Decision 4a: Reranges are counted and capped, and the cap is part of the approved policy

Each rerange burns and re-mints liquidity, paying swap cost and realizing divergence loss. Left uncapped, a permissionless rerange is a griefing surface: an adversary calls it at every permitted opportunity, bleeding the position through cost rather than through any single bad trade.

The clone therefore counts reranges and refuses past the approved maximum, after which the position simply runs to settlement in its last range. Combined with the minimum interval, the worst case is bounded before the proposal is ever voted on: `maxReranges × (swap cost + slippage floor)` is a number a voter can read off the proposal.

### Decision 5: The TWAP guard fails closed; the settlement path does not

Two oracle-ish reads with deliberately opposite failure behavior, per the repo's existing rule that a fail-open branch must be a stated decision:

- **Execute-time TWAP** — fail closed. It *is* the security boundary against minting into a manipulated tick, and its failure is recoverable (redeploy the clone, propose again). This mirrors `BaseStrategy.execute`'s posture, not `PortfolioStrategy._tryPushFeedPrice`'s.
- **Settle-time deliverability** — degrade. Reverting on shortfall hands a borrower a veto over vault-wide settlement (the `MorphoSupplyStrategy._settle` argument, applied unchanged).

### Decision 5a: Clones sit at tier 2, and `rerange()` is a third allowlist-gated selector

Tiers are keyed by `(target, selector)`, and every proposal produces a clone at a fresh address, so clones are uncertified and read as tier 2 (`TIER_ARBITRARY`, full notional) — the same position as existing `MorphoSupplyStrategy` and `PortfolioStrategy` clones, and admissible per the tier-policy spec's explicit "no on-chain tier ceiling". Certifying at tier 0/1 is not pursued: certification is owner-only and bonded and keys on address, so it would mean one certification per clone per proposal. Clones of one template share a codehash, but tiering does not key on codehash, so there is nothing to amortize.

The consequence to plan around is coverage, not permission: at tier 2 guardian coverage is priced at full notional, so these proposals consume maximum coverage capacity per dollar deployed.

The actually binding gate is the allowlist. `SyndicateVault._guardBatchCalls` rejects any batch target that is not an allowlisted adapter (`asset()` is the sole exemption) and checks the spender of the `approve` that funds the pull, so each clone needs an owner `setAdapterAllowed(clone, true)` before its batch can run. `rerange()` adds a third batch-reachable selector on the clone; it does not change the allowlist requirement, but it does mean the clone must stay allowlisted for the whole strategy period rather than only across execute and settle.

*Note on permissionlessness:* `rerange()` being permissionless means callable by anyone **directly**, not only through a governor batch. It moves no vault funds — it burns and re-mints the clone's own position — so it is not subject to the batch guard when called directly, which is what keeps it usable by a keeper.

### Decision 6: Vendor minimal Uniswap interfaces rather than importing v3-periphery

Add `src/vendor/uniswap/` with only the functions used, following the `src/vendor/morpho/` precedent and registering them in `lib/VENDOR-MANIFEST.json`.

*Alternative considered:* import `@uniswap/v3-periphery`. Rejected — it pins older solc pragmas and pulls a large dependency surface for four function signatures, and this repo already has a vendoring convention for exactly this case.

## Risks / Trade-offs

- **The position manager on chain 4663 is unverified.** → The deploy script asserts the address holds code before deploying or approving the template, and the `deployment-docs` delta pins that as a scenario. Address discovery is a deploy-time input, not a code assumption.
- **Adding new cross-contract calls breaks every test stand-in lacking the selector, and a typed call makes the break undecodable.** This has bitten this repo repeatedly. → Before adding each external call, grep `test/` for existing stand-ins and patch them in the same commit; use raw `staticcall` + `ret.length` + `abi.decode` for reads, with the failure branch stated per Decision 5.
- **Thin pools mean the exit is the dominant flow.** → Pool-share cap at init plus deliverable-maximum settlement. The cap does not remove the risk, it bounds it; a position at the cap in a decaying pool still exits badly.
- **Collateral can be liquidated mid-proposal** if the vault asset moves against the collateral wrapper. → The LLTV buffer at init is the only on-chain control; reranging re-centers the LP band but never touches the borrow, so it does not relieve LTV. The buffer must be sized against the proposal-duration ceiling, not against a day.
- **Permissionless rerange is a griefing surface** — repeated in-bounds reranges bleed the position through swap cost. → Minimum interval, trigger fraction, and a hard rerange cap, all fixed at init (Decision 4a); worst case is `maxReranges × (swap cost + slippage floor)`, readable before the vote.
- **Rerange timing can be chosen adversarially** inside the permitted window. → Bounded, not eliminated, by the same three parameters plus the slippage floor. Accepted explicitly rather than papered over.
- **Divergence loss books as a proposal loss.** Intended, and consistent with how an incomplete settlement is treated: the proposer wears the mark.
- **Two external protocols in one settlement path** raises the chance of a partial unwind relative to `MorphoSupplyStrategy`. → The sweep is correspondingly more load-bearing and needs tests for each partial-failure combination, not just the aggregate.

## Migration Plan

Additive — no existing clones, templates, or batches change. Deploy order: vendor interfaces → template → `setTemplateApproval(template, true)`. Rollback is `setTemplateApproval(template, false)`, which blocks new factory clones while leaving existing clones able to settle and sweep (the factory gates cloning, not the clone's own lifecycle). If the template is ever class-certified in `TierRegistry`, that lever alone leaves the funds axis open — a bare `Clones.clone` of the template bound to the vault stays class-admitted — so rollback must also run `demoteClass` / `setClassAllowed(template, false)` per the sequenced procedure in `docs/adapter-onboarding-checklist.md` (SHE-209 / PR #284).

## Open Questions

- Which position-manager address to wire on Robinhood Chain mainnet. Deferrable: it is a deploy-time input guarded by the code-presence assertion, and it changes neither the specs, the approach, nor the task breakdown.
- Whether the pool-share cap and LLTV buffer should be template constants or owner-settable via `ProtocolConfig`. Deferrable to implementation: both are init-time validations either way, and the choice does not alter the requirements.
