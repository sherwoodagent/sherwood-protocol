## Context

`sherwood-guardian` reaches a verdict from two signals: whether a replay of the proposal's calldata
reverted, and whether every call target appears in the deploy ceremony's address book. Both signals
are cheap and neither answers the question a guardian is paid to answer — whether the vault is worse
off after the proposal runs.

The daemon's surrounding structure is sound and is not revisited here: the posture gate runs before
any RPC client exists, chain identity comes from the RPC rather than configuration, every coverage
read fails closed to Abstain, and Approve is unreachable from a model. This change alters what
evidence the verdict is computed from, not who is allowed to sign.

## Goals / Non-Goals

**Goals**

- Simulate the proposal as the protocol will actually run it, through the governor's own entrypoints.
- Decide on measured outcomes rather than on recognition of call targets.
- Keep every existing safety property: Approve deterministic, unavailable inputs abstaining, the
  posture gate unchanged.

**Non-Goals**

- Adversarial market simulation (moved prices, hostile ordering). That is a larger build and is
  deferred.
- Completing the ABI decoder catalogue. This change deliberately reduces how much the verdict
  depends on decoding.
- Anything about running more than one guardian.

## Decisions

### Decision 1 — Drive the real entrypoints, not pranked raw calls

The harness executes `openReview` → `resolveReview` → `executeProposal` → `settleProposal` against a
fork, warping between them, exactly as `test/governor/ProposalLifecycle.t.sol` already does in this
repo.

*Why not keep the pranked replay:* `vm.startPrank(vault)` plus `target.call(...)` skips every
protocol-level guard. A call the governor would reject succeeds under the prank, and a call that is
only valid inside the governor's execution context reverts standalone and is reported as a critical
`SIMULATION_FAILED`. The existing harness is wrong in both directions, and the direction that
matters is the false pass.

A property falls out of the change: driving the real path answers *would this proposal even
execute*, which the pranked replay cannot express at all. Casting the fleet's own votes inside the
fork additionally turns "would we actually block this" from arithmetic into a measurement.

### Decision 2 — Advance timestamp and height together

`vm.warp` alone is insufficient. Morpho Blue accrues from `block.timestamp` and follows a warp
correctly; Compound-style markets accrue from `accrualBlockNumber` and do not move at all. A warp
without a matching `vm.roll` under-accrues every block-number market, which makes a leveraged settle
look better than it will be — an error in the permissive direction.

Height is derived from a per-chain blocks-per-second constant. Robinhood is an Arbitrum Orbit chain
at roughly 0.25 s blocks, so a 48-hour strategy is on the order of 700k blocks.

*Risk accepted:* the constant is an approximation and will drift from real block production. It is
recorded as an explicit per-chain configuration value rather than a literal, so a wrong figure is
visible and correctable instead of buried in the harness.

### Decision 3 — Re-stamp oracle freshness, preserve oracle prices

After a warp, a fork's Chainlink rounds still carry their fork-block `updatedAt`. Every consumer
that ages that value against `block.timestamp` then fails:
`src/strategies/PortfolioStrategy.sol:1532` reverts `StalePrice()` outright, `PortfolioStrategy.sol:1365`
degrades silently to `(0, false)`, and `ExposureLedger.sol:564,895` and
`pricing/WoodTwapOracle.sol:519` perform the same arithmetic.

Left unhandled this produces the failure mode the guardian README already names: *a guardian that
blocks everything looks exactly like one that is working*. Every honest proposal with a
time-dependent settle leg would revert, land in `SIMULATION_FAILED`, and be voted Block.

The fix is to `vm.mockCall` each consulted feed so `latestRoundData` returns **the same answer with
`updatedAt` equal to the current block timestamp**. Freshness is an artefact of the fork being a
snapshot; the price being frozen is the property the review actually wants.

*Why frozen prices are wanted:* in a fork nothing trades, so price does not move. Any value the vault
loses across a warped execute-and-settle round trip is therefore structural — fees, proposer-set
slippage, or leakage — never market risk. On the live chain, separating a bad trade from a theft
needs a market model. In the counterfactual it does not, and that licenses a tight bound on
Invariant 1 where a live-chain check could only afford a loose one.

*Risk accepted, and mitigated:* re-stamping conceals any attack whose harm depends on a stale or
manipulated feed. Decision 5 is the mitigation.

### Decision 4 — Outcome invariants, checked after settlement

| Id | Invariant | Adversary it catches |
|----|-----------|----------------------|
| I1 | `totalAssets() >= capitalSnapshot * (1 - maxDrawdownBps)` | drains, extractive slippage, fee siphons |
| I2 | no residual allowance to any spender | approve-now-drain-later, the standing withdrawal right |
| I3 | no residual non-asset token balance | a strategy that never returns to cash |
| I4 | native balance conserved | value sent to a sanctioned target and never returned |
| I5 | every decodable recipient or beneficiary is the vault | `exactInputSingle(recipient: attacker)` |

I1 through I4 need no ABI knowledge — they are balance and allowance reads. That is the point:
every one of the decoder gaps in the proposal's defect list is a gap the invariant check does not
consult. I2 is the highest value for the lowest cost, because a proposal that approves a sanctioned
router and leaves the allowance live has handed a standing withdrawal right to whoever controls that
router later, and today that reads as `CLEAN`.

The decoder is retained, demoted from decider to explainer. A report needs to say *why* something
failed; it no longer needs to be complete for the verdict to be sound.

*Open:* `maxDrawdownBps` cannot be chosen from first principles. Round-trip cost is nonzero even for
an honest strategy — swap fees and tick crossings are real — so the bound must be measured against
real proposals on the vnet before it becomes a gate. Until measured it ships as a warning, not a
critical.

### Decision 5 — Two runs, and disagreement is a warning

Every proposal is simulated twice: once warped with re-stamped feeds (does it round-trip?), once
unwarped at fork state with no mocking (does the execute leg work right now?). Agreement is the
expected case. Disagreement means the verdict depends on something the re-stamping touched, which is
exactly the band where an oracle-dependent attack would hide, so it escalates to the warning band
rather than passing clean.

*Why not skip the control run:* without it, Decision 3 is an unbounded weakening — the reviewer
would assert freshness onto every feed and have no way to notice that the assertion mattered.

### Decision 6 — Wire the model into the warning band

`decide` already implements the escalation tier and constrains its output to Block or Abstain.
`index.ts` simply never passes a `model`, so the tier is unreachable and every warning-band proposal
abstains. Passing one activates specified behaviour; it does not widen the model's authority.

The injection argument in `judge.ts` continues to hold unchanged: proposal calldata, token names and
metadata URIs are attacker-controlled strings that reach the model's context, so the model sits
inside the injection surface and may only ever move a verdict toward safety. A successful injection
costs liveness, never stake.

## Risks / Trade-offs

- **Oracle re-stamping is a deliberate weakening.** Mitigated by Decision 5, not eliminated.
- **The blocks-per-second constant is an estimate.** Wrong in the permissive direction if too low.
- **Vendoring the protocol's ABIs grows the image.** The alternative — hand-written interfaces — is
  what produced the `IVerifierProxy` incident, where a wrong interface shape presented as empty
  returndata and read as a local bug. Compile-time coupling makes a divergence fail to build rather
  than fail silently.
- **The lifecycle run is slower than the raw replay.** Acceptable: reviews run on windows measured in
  hours, and `guardian-fleet` shares one simulation across all guardians rather than paying per
  guardian.
- **`maxDrawdownBps` starts unmeasured.** Shipping it as a critical gate before measurement would
  block honest proposals, so it starts as a warning and is promoted once the vnet data exists.

## Migration Plan

1. Build the lifecycle harness alongside the existing one; run both and diff verdicts on real vnet
   proposals.
2. Ship the invariants as warnings only. Collect the round-trip cost distribution.
3. Promote I2 through I5 to critical once each has fired zero false positives across the collected
   set. Promote I1 only after `maxDrawdownBps` is measured.
4. Retire the pranked harness.

## Open Questions

- Which feeds get re-stamped: only those the strategy declares, or every feed reached during the
  run? Blanket re-stamping is simpler and strictly more permissive, which is the wrong direction.
- Does `settleProposal` succeed under a warp for the strategies currently deployed, or does the warp
  itself break assumptions beyond oracle freshness? Task 1.1 answers this before anything is built.
- Should the fleet's own votes be cast inside the fork to measure the block outcome, or is that
  scope for `guardian-fleet`?
