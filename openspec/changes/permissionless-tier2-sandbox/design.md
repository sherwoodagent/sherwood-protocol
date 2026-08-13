## Context

See proposal.md — Why. The design-relevant constraints:

- `SyndicateVault._guardBatchCalls` PART 2a admits only `asset()` and `isAdapterAllowed(target)` callees, and PART 2b requires the spender/recipient of value-moving selectors to be allowlisted. Both are owner-curated, so **anything routed through a governor batch inherits an owner gate**. The sandbox must therefore not be a batch callee.
- Every existing "list something" path bottoms out in an owner: `TierRegistry.setAdapterAllowed` / `setClassAllowed` / `certify` are `onlyOwner`, and so is `StrategyFactory.setTemplateApproval`. A `BaseStrategy` template would only move the ceremony from per-venue to per-template, not remove it.
- `collectResidue` reaches a strategy by a **direct** low-level call from the vault, not through a batch. This is what lets residue recovery work without any registry standing.
- `SyndicateVault.registerAgent` is `onlyOwner`; proposing already requires `isAgent`. The proposer gate is pre-existing and deliberately unchanged (see proposal.md — Capabilities).
- No vault proxy is live, so storage layout may be changed with a golden regeneration rather than a migration.
- The propose-time tier-2 ceiling (`Tier2CallCapExceedsCeiling`) lives in the unarchived `per-call-capital-declarations` change, so this design must not depend on it.

## Goals / Non-Goals

**Goals:**
- Arbitrary proposer-chosen targets with **zero owner transactions** — not per-venue, not per-template, not once.
- A max-loss ceiling that is structural (funded capital) rather than measured (metered outflow), so full-notional tier-2 coverage is an honest price.
- Zero modification and zero new exemption in `_guardBatchCalls`.
- Land independently of `per-call-capital-declarations`.

**Non-Goals:**
- Changing who may propose. Sandbox proposals stay agent-gated; permissionless proposing is a separate question with its own spam and review-load design.
- Native-ETH `value` in sandbox calls. Adds a transfer channel with no metering story for v1.
- Making a bounded tier reachable for proposer-supplied calldata. A sandbox payload forces tier 2 permanently.
- Replacing the adapter allowlist for strategies that bind counterparties in their own reviewed code.

## Decisions

### D1. The sandbox is minted by the vault from an immutable implementation, not listed in any registry

**Chosen**: `SyndicateVault` carries `address public immutable sandboxImplementation`, set in the implementation constructor, and clones it per proposal via CREATE2 salted on the proposal id.

*Why*: this is the only shape with no owner in the loop. Every alternative that makes the sandbox a *third party* — an adapter address, a certified class, a factory template — requires someone to attest it, and every attestation path in this codebase is `onlyOwner`. Making it protocol code sidesteps the question: the vault is not consenting to an external contract, it is running its own.

*Alternative rejected*: `ArbitraryCallStrategy` as a `BaseStrategy` template (the previous draft). It reuses more existing machinery, but `StrategyFactory.setTemplateApproval` and `TierRegistry.setClassAllowed` are both `onlyOwner`, so it keeps a one-time owner ceremony — which is the thing being removed.

*Cost accepted*: replacing the sandbox implementation is a vault upgrade rather than a config change. That is the correct weight for "the code that runs arbitrary calldata against LP capital," and it is not a gate on any proposal or venue.

### D2. Fund by direct transfer from a governor-only vault entry point

**Chosen**: `SyndicateVault.runSandbox(...)`, `onlyGovernor` and `nonReentrant`, transfers the funding to the freshly minted sandbox and calls into it. The transfer never passes through `_guardBatchCalls`.

*Why*: an approve-and-pull shape leaves a vault allowance whose size proposer calldata could choose, which is the "authorization is invisible to the meter" failure this whole change exists to avoid, reproduced at the funding step. A direct transfer leaves no allowance to reason about. Routing it outside the batch is what removes the allowlist requirement on the sandbox address itself; the authorization is `onlyGovernor`, the same posture `settleRedeem` takes toward the queue.

*Alternative rejected*: carve a structural exemption into PART 2a for "addresses the vault just minted." It works, but it puts a second exemption next to `asset()` in the most-audited guard in the codebase, and every future reader has to re-derive why it is safe. Not touching the guard at all is worth more than the code it saves.

### D3. The funding ceiling is enforced at execute time against live state

**Chosen**: the vault reads `tier2CallCapBps()` and `totalAssets()` in the executing transaction and reverts if the funding exceeds the ceiling.

*Why*: it makes the bound independent of `per-call-capital-declarations`, and it binds a ceiling *tightened after propose*, which a propose-time-only check cannot.

*Note, stated because it is load-bearing*: `tier2CallCapBps()` defaults to `10_000` (100% of TVL — inert). With the default in place this check passes for any amount. The ceiling is only real once governance sets it, which the migration plan makes a deployment precondition. The code cannot assert this for itself.

### D4. The privileged-address denylist is resolved at execute time and fails closed

**Chosen**: before dispatch, resolve vault, withdrawal queue, governor, tier registry, exposure ledger, WOOD and sWOOD, and revert if any stored call names one. Refusal reverts the whole execution rather than skipping the call.

*Why*: the addresses can be re-pointed, so they must be read live. Skipping instead of reverting would execute a *subset* of the calls guardians reviewed, which is a different proposal than the one that was approved.

*Why a denylist at all*, given the funded cap already bounds loss: the concern is accounting, not theft. A sandbox holding vault capital could otherwise deposit it back to mint shares while deposits are locked for the open proposal, or touch the queue's stamp and reserve counters — corrupting figures other guards assume only the vault moves.

### D5. The payload lives on the proposal, immutable, readable through review

**Chosen**: the call set, funding amount and declared token set are stored by `propose` and exposed by a public view; no setter exists.

*Why*: the guardian coverage quorum **is** the review that replaces the owner's allowlist decision. That substitution only holds if reviewers can see exactly what will run and it cannot change afterwards. A payload supplied at execute time would be approved unseen, and a mutable one would let a proposal be covered against one payload and executed against another.

### D6. Residue reporting is honest about what it cannot value, bounded by a declared token set

**Chosen**: the sandbox implements the delivery interface. `undeliveredValue()` reports the vault-asset balance; `hasUnvaluedResidue()` is true when any *declared* non-asset token has a non-zero balance; `sweep()` pushes the asset balance back.

*Why the declared set*: a contract cannot enumerate "every ERC20 I hold," so without a declaration `hasUnvaluedResidue` could only be a constant. Declaring makes the report checkable and makes under-declaration the proposer's own loss — an undeclared leftover is stranded in the sandbox and never counted as vault value, which is the safe direction.

*Trade-off accepted*: a sandbox ending with dust of a declared reward token locks deposits until cleared. Mitigated by `collectResidue` being permissionless and untaxed, so the depositor being refused can clear it themselves.

## Risks / Trade-offs

- **The ceiling defaults to inert.** `tier2CallCapBps() == 10_000` means a deployment shipping the sandbox without seeding it has unbounded sandbox funding — strictly worse than today. → The deploy script seeds it in the same script that wires the sandbox implementation, so the two cannot be separated; a test asserts the deployed value is below `10_000`.
- **The owner gate moved rather than vanished, one level up.** Targets are now permissionless, but `registerAgent` is still `onlyOwner`, so proposers are curated. → Deliberate and specced (see the proposer-gate requirement); flagged here so nobody reads "permissionless targets" as "permissionless protocol."
- **Coverage is only as honest as the funding is complete.** The ceiling equals max loss only if the sandbox cannot acquire vault capital by any other route. → D2 removes the allowance route, D4 removes the mint-shares route, and one-shot execution prevents a second funding. Any future path that lets a sandbox pull from the vault breaks the central claim and must be treated as a spec violation, not an optimization.
- **A new asset-moving vault entry point outside the batch guard.** `runSandbox` is the second function that moves vault assets without passing `_guardBatchCalls`. → `onlyGovernor` + `nonReentrant` + pause-gated + metered against effective capital; reachable only through a proposal that cleared the vote, the review period and the coverage quorum.
- **Arbitrary calls can grief the proposal, not the vault.** A sandbox can be sandwiched, front-run, or handed worthless tokens. Loss is bounded by the funded amount and priced by coverage. → Accepted: this is what tier 2 at full notional means, and the guardian quorum is the review layer.
- **One sandbox per proposal** pushes proposers toward larger single call sets, which are harder to review than several small ones. → Accepted for v1; the payload is fully readable on-chain before approval.

## Migration Plan

1. Deploy `CallSandbox`.
2. Deploy the vault implementation with the sandbox address as a constructor immutable.
3. **Seed `tier2CallCapBps` to a real value** in the same script — the sandbox is unbounded until this lands.
4. Verify `quorumTierThreshold == 0` so the guardian quorum stays mandatory.
5. Regenerate the vault and governor layout goldens.

**No registry ceremony exists to perform.** There is no `setAdapterAllowed`, `setClassAllowed`, `certify` or `setTemplateApproval` step, by design.

**Rollback**: deploying a vault implementation whose sandbox immutable is `address(0)` disables the path; the entry point reverts and every other capability is unaffected. In-flight sandboxes still return capital through `collectResidue`, which needs neither the batch nor any registry standing.
