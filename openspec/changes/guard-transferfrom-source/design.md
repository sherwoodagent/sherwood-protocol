## Context

See proposal.md — Why. The vulnerable code is `SyndicateVault._guardBatchCalls` (`src/SyndicateVault.sol:589-670` on current `main`, commit `c4f9ef4`). Current shape after #93's fix (PR #111):

```solidity
function _guardBatchCalls(BatchExecutorLib.Call[] calldata calls) private view {
    // ── PART 1 (unconditional): privileged-target denylist ──
    address q = _withdrawalQueue;
    for (uint256 i = 0; i < calls.length; i++) {
        address target = calls[i].target;
        if (target == address(this) || (q != address(0) && target == q)) {
            revert DisallowedBatchTarget(target);
        }
    }
    // ── registry resolution: two degrade-open early returns ──
    (bool ok, bytes memory ret) = msg.sender.staticcall(abi.encodeCall(ISyndicateGovernor.tierRegistry, ()));
    if (!ok || ret.length != 32) return;               // (A)
    address registry = abi.decode(ret, (address));
    if (registry == address(0)) return;                // (B)
    // ── PART 2 (registry-gated): value-moving selector switch ──
    for (uint256 i = 0; i < calls.length; i++) {
        // approve/increaseAllowance/transfer → recipient = data[4:36]
        // transferFrom → recipient = data[36:68]   // `from` at data[4:36] NEVER READ
        // recipient == address(this) → continue
        // else require isAdapterAllowed(recipient), else DisallowedTransferTarget
    }
}
```

Facts fixed by re-verification against this worktree:

1. **No honest batch encodes a raw `transferFrom` — with any source.** Capital deploy is `approve(adapter, amt)` (Part 2-guarded) followed by a call to the adapter's own entrypoint; the *adapter* executes `safeTransferFrom(vault → adapter)` in its own code (`BaseStrategy._pullFromVault`, `src/strategies/BaseStrategy.sol:161`; `UniswapSwapAdapter.sol:199`, `SynthraSwapAdapter.sol:85`, `SynthraDirectAdapter.sol:71` all pull from `msg.sender`), so the guard never sees that calldata. Returns are pushes (`_pushToVault` / `withdrawTo` / `_settle`). No adapter or strategy ever grants the vault an allowance, so `transferFrom(adapter, vault, …)` cannot even succeed today.
2. **The Part-1 loop is the right home for an unconditional check.** #93 established the pattern and its rationale ("not pricing a call, refusing a capability") — the natspec at `src/SyndicateVault.sol:622-627` documents that the degrade-open returns are a Part-2-only posture.
3. **`_guardBatchCalls` is private with a single caller**, `executeGovernorBatch` (`src/SyndicateVault.sol:473`), which is the sole batch route for `executeProposal`/`settleProposal` and both `GovernorEmergency` paths. One edit covers all four.
4. **Test surface**: `test/vault/SelectorGuard.t.sol` is the only test file that routes `transferFrom` through a batch; `test_transferFromIntoVaultPasses` (lines 144-153) asserts the hole as intended behaviour. `test/audit-fixes/Vault_batchQueueTargets.t.sol:98-102` grants the vault a `type(uint256).max` victim allowance (deposit realism) but never batches a `transferFrom`, so it needs no change.

## Goals / Non-Goals

**Goals:**

- Close the LP-allowance confiscation primitive on every batch path, for every governor configuration — including registry-less ones.
- Keep the fix localized to `_guardBatchCalls` + one new interface error; preserve the existing destination guard and its degrade-open posture untouched.

**Non-Goals:**

- Not building a "permitted sources" registry affordance. There is no honest pull-from-third-party pattern to serve (fact 1); if one ever materializes it must arrive as an explicit spec change, not a pre-opened hole.
- Not touching #19 (fail-closed on unset registry) or #18 (exotic-asset selectors) — same function, deliberately separate changes per issue #115's sequencing.
- Not guarding allowances the vault *holds on others' tokens* beyond ERC-20 `transferFrom` — ERC-721/1155 remain the documented RESIDUAL.

## Decisions

**1. `from` must equal `address(this)` — reject everything else, including allowlisted adapters.**

The audit's suggested diff permitted `from == vault || isAdapterAllowed(from)`. Rejected the second disjunct:

- `isAdapterAllowed` is defined as destination consent — "may *receive* approvals/transfers of vault funds" (`src/TierRegistry.sol:305-318`). An entry there is set by the TierRegistry owner to authorize *sending to* an address; it is not, and was never consented as, "this address's allowances to the vault may be spent by a batch". Overloading it converts every allowlisted address that ever holds a vault allowance (an adapter operated by a party that also LPs, a fee recipient, a future EOA entry) into a confiscatable wallet.
- The affordance it would preserve — "pull funds back from an allowlisted adapter" — has no consumer: adapters return funds by push and hold no vault-facing allowances (fact 1). The issue's open question ("confirm that is the only honest source pattern") resolves to: there is no honest non-vault source pattern at all.
- Fail-closed beats fail-flexible for a theft primitive. Extending to a narrow source allowlist later is a compatible spec change; retracting a shipped affordance is not.

**2. Enforce in the Part-1 (unconditional) pass, not the registry-gated loop.**

The check needs no registry data (`from == address(this)` is structural), and the adversary steals third-party funds that no tier prices — the exact argument that made #93's target denylist unconditional. The audit's diff, placed inside Part 2, would leave registry-less vaults (a real, supported configuration per the UNSET REGISTRY natspec) exposed to the same confiscation. Concretely: in the existing Part-1 loop, after the target check, decode `sel = bytes4(data[0:4])` when `data.length >= 4`; if `sel == _SEL_TRANSFER_FROM`, require `data.length >= 68` (else `MalformedCall`) and `address(uint160(uint256(bytes32(data[4:36])))) == address(this)` (else the new error). Part 2's `transferFrom` branch stays exactly as is (destination guard).

_Alternative considered_: keep the source check in Part 2 per the audit diff. Rejected — inherits the degrade-open exemption for a non-priced theft.

_Side effect accepted_: malformed `transferFrom` calldata (< 68 bytes) now reverts `MalformedCall` even with no registry wired, where it previously executed. Strictly conservative; a real token would revert on such calldata anyway, and a selector-colliding non-ERC20 function with < 68 byte args on some target loses batch access — acceptable, consistent with the existing "gated conservatively" posture for selector collisions, and pinned by a scenario.

**3. New error `DisallowedTransferFromSource(address target, address from)`.**

The audit diff reused `DisallowedTransferTarget(target, sel, recipient)` with `from` in the recipient slot. Rejected: the name asserts the *target/recipient* was disallowed, which is false here (the recipient may be the vault itself); tests and off-chain tooling need to distinguish "you may not send there" from "you may not pull from there". The `sel` field is dropped — it is pinned to `transferFrom` by construction. Declared in `ISyndicateVault` alongside the existing guard errors.

_Alternative considered_: reuse the 3-arg error. Rejected — muddies semantics; a fresh 2-arg error costs nothing.

**4. Keep `from == address(this)` permitted (rather than banning batch `transferFrom` outright).**

`transferFrom(vault, x, amt)` is semantically `transfer(x, amt)`: it spends `allowance[vault][vault]` (which only a batch's own guarded self-`approve` can create), moves only vault-owned balance, is metered by net-outflow, and `x` stays destination-guarded. Banning the selector entirely would be a second behavioral removal with no security gain, and would break the guard's design language ("gate addresses, don't ban selectors"). The issue's sub-question "does `from == address(this)` need the exemption at all" resolves to: keep it — it is harmless by the same argument that keeps `transfer` available, and removing it buys nothing.

**5. Replace — not merely delete — the asserted-safe test.**

`test_transferFromIntoVaultPasses` pinned "pull into the vault always passes" as intended behaviour. It becomes the positive confiscation regression (same fixture shape: third-party `sink` with a vault allowance, batch pulls, now expects `DisallowedTransferFromSource`), and its natspec records that the old assertion pinned issue #115's hole and why the behaviour was deliberately removed. The corresponding "Pull into the vault always passes" scenario is dropped from the main spec via the MODIFIED delta.

## Risks / Trade-offs

- **[A future strategy legitimately needs a batch-level pull from a non-vault source]** → No in-tree pattern exists (fact 1); the adapter-side pull idiom covers deploys and pushes cover returns. If one arrives, it lands as an explicit ADDED requirement with its own consent model — the guard's revert makes the gap loud, not silent.
- **[Selector collision: a non-ERC20 target function sharing `0x23b872dd` with a non-vault first arg]** → Now rejected unconditionally (previously only when a registry was wired). Same accepted posture as the existing MalformedCall/collision note in the guard natspec; no in-tree adapter exposes such a selector.
- **[Divergence between issue's suggested diff and this design]** → Deliberate and documented (Decisions 1-3); reviewers should evaluate against the spec delta, not the audit sketch. The issue's open question is answered in proposal.md and Decision 1.
- **[Gas]** → One selector compare per call plus, on the `transferFrom` path, one calldata word read and compare. Negligible.

## Migration Plan

Single-contract change behind the vault's existing UUPS upgrade path; no storage changes, no new external dependencies, no deploy-order impact. Rollback = revert the commit. Existing vaults pick the guard up on implementation upgrade; un-upgraded vaults retain the documented hole (tracked by issue #115 until fleet upgrade).

## Open Questions

None — the issue's open question (correct guard condition for `from`; whether the vault-self exemption stays) is resolved in Decisions 1 and 4.
