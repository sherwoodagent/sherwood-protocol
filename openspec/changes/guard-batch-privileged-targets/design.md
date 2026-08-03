## Context

See proposal.md — Why. The vulnerable code is `SyndicateVault._guardBatchCalls` (`src/SyndicateVault.sol:550-577`). Current shape:

```solidity
function _guardBatchCalls(BatchExecutorLib.Call[] calldata calls) private view {
    (bool ok, bytes memory ret) = msg.sender.staticcall(abi.encodeCall(ISyndicateGovernor.tierRegistry, ()));
    if (!ok || ret.length != 32) return;               // (A) degrade-open
    address registry = abi.decode(ret, (address));
    if (registry == address(0)) return;                // (B) degrade-open
    for (uint256 i = 0; i < calls.length; i++) {
        // selector switch: approve / increaseAllowance / transfer / transferFrom
        // -> recipient must be vault or an allowlisted adapter, else DisallowedTransferTarget
    }
}
```

Two facts fix the placement of the new check:

1. **The loop is gated behind two degrade-open early returns (A, B).** If the target check lived inside or after them, a registry-less governor (a real, supported configuration — see the "UNSET REGISTRY" natspec at `src/SyndicateVault.sol:545-549`) would skip it and the queue path would stay open. So the target check MUST sit above line A.
2. **`_guardBatchCalls` is the single chokepoint for all four batch paths.** It runs inside `executeGovernorBatch` (`src/SyndicateVault.sol:473`), which is the only route the governor (`executeProposal`/`settleProposal`) and `GovernorEmergency` (`unstick`/`finalizeEmergencySettle`) use to run batches. One guard covers execute, settlement, and both emergency paths — no per-entrypoint duplication.

Reachability was re-verified against this worktree:
- `VaultWithdrawalQueue.queueRedeem/queueDeposit/stampSettlement` are `onlyVault` (`src/queue/VaultWithdrawalQueue.sol:82-92,105,136`); a `delegatecall` batch presents `msg.sender == vault` and clears the gate.
- The net-outflow meter (`src/SyndicateVault.sol:508-509`) reads `balanceBefore - balanceAfter` of the vault's own `asset()`; `queueRedeem` moves none in-tx (value leaves later via `queue.claim`), so `netOutflow == 0`.
- Coverage: `TierRegistry.tierOf` returns `(2, 10_000)` for an uncertified `(target, selector)` (`src/TierRegistry.sol:93-98`), and `_resolveTierAndCoverage` computes `coverage = maxCapital * sumBps / 10_000` (`src/SyndicateGovernor.sol:1020`), so `maxCapital = 1` → `coverage = 1` wei — trivially cleared.

## Goals / Non-Goals

**Goals:**
- Close every governor-batch path (execute, settlement, both emergency) into the withdrawal queue's `onlyVault` entrypoints and into any vault self-call, unconditionally.
- Keep the fix minimal and localized to `_guardBatchCalls` — no changes to `BatchExecutorLib`, the governor, or the queue.

**Non-Goals:**
- Not a full target allowlist. Legitimate batches call many external targets (strategy adapters, tokens, protocols); enumerating them is the TierRegistry's job. This change only denylists the two privileged self-addresses.
- Not touching the strategy adapters' own `onlyVault` functions (`BaseStrategy.execute/settle/withdrawTo`). Those are the intended batch surface, are allowlisted adapters, and expose no exfiltration beyond what the outflow meter + selector guard already bound (execute pulls via a guarded approval; withdrawTo/settle are inflows).

## Decisions

**1. Place the target check at the very top of `_guardBatchCalls`, above the `tierRegistry` staticcall.**
The loop over `calls` is added/duplicated as a small pre-pass, OR the single existing loop is entered before the registry lookup with the target check first and the selector switch still gated on a resolved registry. Either is acceptable; the invariant the spec fixes is: the target check executes for every call regardless of registry state. Rationale: the registry-less degrade-open path (A/B) is deliberate for the selector guard (default is tier-2 pricing anyway) but MUST NOT weaken a hard target denylist — a queue steal is not "priced," it is unconditional theft.

_Alternative considered_: gate the target check inside `executeGovernorBatch` before calling `_guardBatchCalls`. Rejected — `_guardBatchCalls` is already the guard home and its natspec documents the batch-guard contract; splitting the two halves of the guard across two functions invites a future edit to re-open one path.

**2. New error `DisallowedBatchTarget(address target)`.**
The existing `DisallowedTransferTarget(address target, bytes4 selector, address recipient)` (`src/SyndicateVault.sol:574`) is the selector-guard error with a 3-arg signature; Solidity does not allow same-name error overloads, and reusing it would force meaningless `selector`/`recipient` fields. A dedicated 1-arg error also makes the two failure modes distinguishable in tests and off-chain tooling.

_Alternative considered_: reuse `DisallowedTransferTarget` with zeroed extra args. Rejected — muddies the semantics and the ABI.

**3. Compare against `address(this)` and `_withdrawalQueue`.**
`address(this)` is the vault (the guard runs in vault context, not via delegatecall). `_withdrawalQueue` is the bound queue storage slot (`src/SyndicateVault.sol:146`). Both are read directly; no external call needed.

## Risks / Trade-offs

- **[Vault self-call is defense-in-depth today, not a live hole]** → Blocking `address(this)` closes an entire class rather than a currently-exploitable call. Verified: the vault's `settleRedeem`/`settleDeposit` gate on `msg.sender == _withdrawalQueue` (not the vault), so a self-call cannot reach them; the ERC-4626 `deposit`/`mint`/`withdraw`/`redeem` paths are blocked during a batch because `_activeProposal` stays set through the settlement batch (`SyndicateGovernor._finishSettlement` clears it only after `executeGovernorBatch` returns — `src/SyndicateGovernor.sol:457-460,1177`), so `redemptionsLocked()` is true. The denylist removes reliance on that lock invariant holding forever (e.g. a future self-mint would otherwise be catastrophic). Mitigation is the guard itself; no downside since no honest batch self-targets.
- **[False sense of completeness for exotic assets]** → Unchanged by this fix and explicitly out of scope: ERC-721/1155 approvals still rely on tier-2 pricing (see the existing "RESIDUAL" natspec). This change does not regress that; it only adds the target denylist.
- **[Gas]** → One extra address comparison per call. Negligible.

## Migration Plan

Single-contract logic change to `SyndicateVault`. Deploys via the normal UUPS upgrade path (factory-authorized). No storage layout change (no new state; the error selector is bytecode-only). Rollback is a re-upgrade to the prior impl. No coordination with the governor or queue needed.
