## Why

The guardian daemon does not review proposals. It answers a narrower question — *did anything
revert, and are the target addresses familiar* — and reports that as a verdict. Six defects in
`sherwood-guardian` establish this, each verified in source rather than inferred:

1. **The simulation bypasses the protocol.** `foundry/test/SimulateProposal.t.sol` does
   `vm.startPrank(vault)` and issues a raw `.call()` against each target. The governor is never
   invoked, so the harness tests the *calldata*, not the *proposal*. It false-passes calls the
   governor would reject (target gating, `BatchExecutorLib`, tier and sandbox checks) and
   false-fails calls that are only valid inside the governor's execution context — the latter
   surfacing as `SIMULATION_FAILED`, which is a Block.

2. **Execute and settle are replayed in one block.** The harness concatenates `getExecuteCalls` with
   `getSettlementCalls` and runs them back to back with no `vm.warp`. The settle leg is therefore
   simulated at `t = 0`, though it will run `strategyDuration` later.

3. **The one economic measurement is discarded.** `SimRun.vaultAssetBefore` / `vaultAssetAfter` are
   emitted by the harness and parsed in `src/simulator.ts`, then never passed to `analyzeRisk` —
   `RiskContext` has no field to receive them. No risk code exists for "the vault ended up poorer".

4. **Target sanctioning is read as action sanctioning.** `analyzeRisk` branches only on `transfer`,
   `transferFrom` and `approve`. `exactInputSingle` is decoded and then ignored, so a swap on a
   sanctioned router with `recipient` set to an attacker and `amountOutMinimum` set to zero decodes
   cleanly, raises nothing, and reaches `APPROVE`. `call.value` is never examined at all.

5. **`UNDECODED_CALLDATA` cannot ever be the flag that blocks.** It fires only under
   `if (!targetKnown)`, a branch that has already emitted a critical `UNKNOWN_TARGET`. Unrecognised
   calldata sent to a *known* target raises nothing.

6. **No model has ever adjudicated anything.** `src/index.ts` calls `decide({risks, coverage,
   simulationOk, now, voteEnd, reviewEnd})` without a `model` field, so every warning-band proposal
   returns `UNRESOLVED_NO_MODEL` and abstains. The escalation tier specified by
   `autonomous-guardian-agent` is unreachable code.

Defects 4 and 5 are one structural problem. An allowlist-of-targets defence needs a complete ABI
catalogue plus a per-function argument policy for every venue the protocol will ever touch, and it
fails open on everything not yet written. It cannot be completed.

## What Changes

Invert the question the reviewer asks: from *do I recognise this call* to **is the vault whole when
it is over**. That question needs no decoder.

- Replace the pranked raw-call harness with a **lifecycle harness** that drives the real
  entrypoints on a fork — `openReview`, `resolveReview`, `executeProposal`, then `settleProposal`
  after advancing the clock by `strategyDuration`. The pattern already exists in this repo at
  `test/governor/ProposalLifecycle.t.sol`.
- Advance **both** `block.timestamp` and `block.number` between legs. Timestamp-based accrual
  (Morpho Blue) follows a warp; block-number accrual (Compound-style markets) does not, and a warp
  alone under-accrues them.
- **Re-stamp oracle freshness without changing prices.** A fork's feed rounds are frozen at the fork
  block, so any warp ages them past `maxAge` and `PortfolioStrategy.sol:1532` reverts `StalePrice()`
  on honest proposals. Mock `latestRoundData` to return the same answer at the current timestamp.
- Decide on **outcome invariants** measured after settlement — capital round-trip, residual
  allowances, residual non-asset balances, native balance, decodable beneficiaries — rather than on
  target recognition. In a frozen-price fork, value lost across the round trip is structural, so a
  tight bound is defensible in a way a live-chain bound never is.
- Run an **unwarped control** at fork state alongside the warped run, and treat disagreement between
  the two as a warning band rather than a clean pass. This is what stops oracle re-stamping from
  silently concealing an attack that depends on stale prices.
- **Wire the model** into `decide` so the warning band is adjudicated instead of universally
  abstained. Its verdict stays narrowed to Block or Abstain; Approve remains unreachable from any
  non-deterministic component.

Not in scope: adversarial price-movement probes (replaying under moved markets, hostile ordering);
challenge filing; TokenCourt voting; running more than one guardian, which is `guardian-fleet`.

## Capabilities

### Modified Capabilities

- `guardian-agent`: gains requirements for how a proposal is simulated (real entrypoints, advanced
  clock and height, re-stamped oracles) and how a verdict is reached (outcome invariants, the
  control run, the adjudicated warning band). The posture gate, the coverage ceiling, and the rule
  that Approve is unreachable from a model are unchanged and continue to hold.

## Impact

- **`sherwood-guardian` repo**: `foundry/test/SimulateProposal.t.sol` (rewritten around the real
  entrypoints), `src/simulator.ts` (parse the invariant measurements; stop hardcoding `gasUsed: 0`
  and `returnData: "0x"`), `src/risk.ts` (`RiskContext` gains the measurements; new outcome-invariant
  risk codes), `src/judge.ts` (accept the control-run disagreement band), `src/index.ts` (pass a
  `model`), `src/types.ts`.
- **This repo**: no Solidity changes. The guardian is a consumer of the deployed contracts.
- **Contracts read or driven**: `SyndicateGovernor` (`executeProposal`, `settleProposal`,
  `getExecuteCalls`, `getSettlementCalls`, `getCapitalSnapshot`), `GuardianRegistry` (`openReview`,
  `resolveReview`), `SyndicateVault` (`asset`, `totalAssets`).
- **Depends on** `autonomous-guardian-agent`, which creates the `guardian-agent` capability. That
  change's `tasks.md` is stale — groups 2 through 5 are implemented in `sherwood-guardian` but
  unticked — and should be reconciled before either change is archived.
- **New image dependency**: driving `executeProposal` and `settleProposal` needs the protocol's ABIs.
  Hand-written interfaces are what produced the `IVerifierProxy` failure, where a wrong shape
  presented as empty returndata and was indistinguishable from a local bug.
