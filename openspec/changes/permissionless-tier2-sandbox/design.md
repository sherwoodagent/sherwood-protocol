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

*What it is NOT*: a boundary. It screens **stored targets only**, and a payload reaches any denied address anyway by naming a proposer-deployed forwarder that calls on to it — screening one hop cannot be made complete, and nothing should be built as though it were. What actually holds is upstream and indifferent to indirection: `runSandbox` is `nonReentrant`, so no route back into the vault survives while a run is in flight, and every function on the listed contracts is gated to its own privileged caller. The denylist catches the direct, obvious shape cheaply. Recorded here because an earlier version of this note read as though the list were load-bearing.

### D5. The payload lives on the proposal, immutable, readable through review

**Chosen**: the call set, funding amount and declared token set are stored by `propose` and exposed by a public view; no setter exists.

*Why*: the guardian coverage quorum **is** the review that replaces the owner's allowlist decision. That substitution only holds if reviewers can see exactly what will run and it cannot change afterwards. A payload supplied at execute time would be approved unseen, and a mutable one would let a proposal be covered against one payload and executed against another.

### D6. Residue reporting is honest about what it cannot value, bounded by a declared token set

**Chosen**: the sandbox implements the delivery interface. `undeliveredValue()` reports the vault-asset balance; `hasUnvaluedResidue()` is true when any *declared* non-asset token has a non-zero balance; `sweep()` pushes the asset balance back.

*Why the declared set*: a contract cannot enumerate "every ERC20 I hold," so without a declaration `hasUnvaluedResidue` could only be a constant. Declaring makes the report checkable and makes under-declaration the proposer's own loss — an undeclared leftover is stranded in the sandbox and never counted as vault value, which is the safe direction.

*Trade-off accepted*: a sandbox ending with dust of a declared reward token locks deposits until cleared. Mitigated by `collectResidue` being permissionless and untaxed, so the depositor being refused can clear it themselves.

### D7. Both declared-token loops divide the borrowed gas budget instead of trusting a per-entry ceiling

**Chosen**: each entry in `sweep()` and `hasUnvaluedResidue()` gets `gasleft() / (remaining + 1)`, capped by a fixed ceiling — the division binds, the ceiling only trims.

*Why*: both functions run on gas **borrowed from the vault** (150,000 for the residue probe, 1,500,000 for the collection sweep) over a **proposer-authored** list. A fixed per-entry ceiling does not bound a loop — n entries at the ceiling exceed whatever the caller lent — and the first version of this contract set that ceiling to the caller's *entire* budget. Two measured consequences, both reachable by any proposer whose payload clears review:

1. **A permanent deposit brick.** `SyndicateVault._refreshUnvalued` treats an unreadable probe as "keep the last known flag". Declare a real residue token first (latching the flag true), then a gas-burner, then anything at all; drain the first token and every later probe reverts out of gas. `depositsLocked()` stays true for the life of the vault — no permissionless exit, no owner override, and a clone cannot self-destruct into the codeless escape `collectResidue` offers. This is precisely the failure the abandonment mechanism was added to prevent, re-entered through gas rather than a reverting transfer.
2. **Funded capital stranded.** Sixteen gas-burning declared tokens consumed the whole 1,500,000 and reverted the sweep *including the asset leg that runs first*, so `collectResidue` recovered nothing. A manual `sweep()` with more gas still works, but it bypasses `_payCohortShare`, so the exiting cohort loses its share of what comes back.

*Why the trailing entry matters* (and why the regression test has one): EIP-150 hands a sub-call only 63/64 of what remains, so a burner in the **last** position still leaves its caller enough to return. Only an entry that starves an entry **behind** it makes the function unreadable. A test with the burner last passes against the broken code.

### D8. Abandonment requires the failure to persist, and is reversible

**Chosen**: a failed transfer records a timestamp; the token is abandoned only if it is still failing `ABANDON_DELAY` (2 days) later, and any successful transfer clears both marks.

*Why*: abandonment moves in the direction that **reopens deposits** on value the vault then stops counting, and `sweep()` is permissionless. Writing a token off on a single failure lets anyone pick the moment — a token that is merely paused, or under a temporary blacklist, gets permanently written off by a griefer while the sandbox still holds it, and the next depositor mints too cheaply against it. Requiring persistence is what distinguishes "unmovable" from "not moving right now"; clearing on success is what keeps the mark a belief rather than a verdict.

*Trade-off accepted*: a genuinely unmovable token holds the deposit lock for 2 days instead of clearing on the first sweep. Bounded and self-clearing, against a permanent brick on the other side — the same trade `depositsLocked` makes everywhere else. The delay is anchored to the **first observed failure**, not to the run: settlement is already `strategyDuration` past the run, so a run-anchored delay would be spent before anyone could realistically sweep.

*Why 2 days and not longer* (Ana, 2026-08-18): the delay trades deposit liveness against wrongly writing off live value, and 2 days is enough to separate a transient failure — a pause, a temporary blacklist — from a permanent one, without shutting the mint side for a week. A hostile token that always reverts is abandoned either way; the delay only ever protects a legitimate token caught mid-incident, and an incident still unresolved after 2 days is not the case this guard is sized for.

## Risks / Trade-offs

- **The ceiling is deliberately left inert.** `tier2CallCapBps() == 10_000` means NO tier-2-specific ceiling binds a payload. This was the plan of record — seed it in the same script, assert below `10_000` — and it was **reversed by an explicit decision (Ana, 2026-08-14): ship with no cap.** Two things also made the original mitigation unimplementable as written: the parameter is per-GOVERNOR and governors are minted at `createSyndicate`, so the core deploy script has no instance to seed; and it is `whenNoActiveProposal`, so it cannot be tightened mid-lifecycle either. → What actually bounds a payload: the proposal's declared `maxCapital` (funding is validated against it at propose and subtracted from the batch's capital at execute), the guardian coverage scaling (half the coverage funds half the payload; dust coverage funds nothing), and the vault's own net-outflow, queue-reserve and buffer checks inside `runSandbox`. A deployment wanting a tighter bound sets it per vault via `setTier2CallCapBps`. Recorded at the assertion site in `script/robinhood-mainnet/Deploy.s.sol` and in the deployment-docs spec.
- **The sandbox implementation can be missing entirely.** Found while wiring the ceremony: the factory never bound one, so every vault it created would have reverted `SandboxNotConfigured` — the feature was dead on any real deployment, invisible to tests because every fixture wired the vault by hand. → `SyndicateFactory.sandboxImpl` is pushed into each vault at `createSyndicate`, the deploy script binds it in the same broadcast that creates the factory and asserts the result, and `proposeWithSandbox` refuses at PROPOSE against a vault with no implementation — the vault's binding is set-once, so such a proposal could otherwise burn a full review period and lock a bond against an execution that can never succeed.
- **A declared token can be unmovable.** Found while writing the residue tests: `sweep()` returned only the vault asset, so any declared non-asset leftover pinned `hasUnvaluedResidue()` true with nothing able to move it — a permanent, unrecoverable deposit brick reachable by any registered agent. → `sweep()` now pushes declared tokens to the vault (asset first, fair-shared gas, best-effort), and a token that PROVES unsweepable — still failing a whole `ABANDON_DELAY` after the first failure — is abandoned so it stops counting. **Accepted cost:** an abandoned token is stranded in the sandbox with no recovery path — the same treatment an undeclared leftover already gets, and strictly better than a deposit lock nobody can clear.
- **The residue legs were themselves gas-griefable, and the griefing reproduced the very brick they existed to prevent.** Found in review, both confirmed by measurement before and after: a declared gas-burning token could make `hasUnvaluedResidue()` permanently unreadable (deposits shut forever, no exit), and a full hostile declared set could exhaust `collectResidue`'s sweep budget before the asset leg, stranding the funded capital. → See D7. The root cause was a per-entry gas ceiling copied from a single-call site into a loop, where it bounds nothing; both loops now divide the gas actually in hand.
- **Writing a token off was a one-call decision on a permissionless function.** A transiently failing token (paused, temporarily blacklisted) could be abandoned by anyone who called `sweep()` at the wrong moment, after which the vault stopped counting value it still held and mints were priced too cheaply. → See D8: abandonment now requires the failure to persist across a delay and is cleared by any later success.
- **The owner gate moved rather than vanished, one level up.** Targets are now permissionless, but `registerAgent` is still `onlyOwner`, so proposers are curated. → Deliberate and specced (see the proposer-gate requirement); flagged here so nobody reads "permissionless targets" as "permissionless protocol."
- **Coverage is only as honest as the funding is complete.** The ceiling equals max loss only if the sandbox cannot acquire vault capital by any other route. → D2 removes the allowance route, D4 removes the mint-shares route, and one-shot execution prevents a second funding. Any future path that lets a sandbox pull from the vault breaks the central claim and must be treated as a spec violation, not an optimization.
- **A new asset-moving vault entry point outside the batch guard.** `runSandbox` is the second function that moves vault assets without passing `_guardBatchCalls`. → `onlyGovernor` + `nonReentrant` + pause-gated + metered against effective capital; reachable only through a proposal that cleared the vote, the review period and the coverage quorum.
- **Arbitrary calls can grief the proposal, not the vault.** A sandbox can be sandwiched, front-run, or handed worthless tokens. Loss is bounded by the funded amount and priced by coverage. → Accepted: this is what tier 2 at full notional means, and the guardian quorum is the review layer.
- **One sandbox per proposal** pushes proposers toward larger single call sets, which are harder to review than several small ones. → Accepted for v1; the payload is fully readable on-chain before approval.

## Migration Plan

1. Deploy `CallSandbox` (CREATE3, before the factory).
2. Bind it with `factory.setSandboxImpl(...)` **in the same broadcast that creates the factory**, and assert the result. The vault's own binding is factory-only and set-once, so a factory that goes live unbound produces vaults that can never run a payload and can never be repaired.
3. Regenerate the vault, governor and factory layout goldens.

**Superseded from the original plan:** the sandbox is NOT a vault-implementation constructor immutable — the vault implementation is shared across per-vault proxies, so the address lives on the factory and is pushed into each vault at `createSyndicate`. And `tier2CallCapBps` is NOT seeded: it is per-governor (no instance exists at deploy time) and is being left at `10_000` by decision — see the first entry under Risks.

`quorumTierThreshold` defaults to `0` (quorum mandatory at every tier) and the core ceremony deploys no `ExposureLedger`, so there is nothing to assert at this phase; whichever ceremony deploys one asserts it before wiring.

**No registry ceremony exists to perform.** There is no `setAdapterAllowed`, `setClassAllowed`, `certify` or `setTemplateApproval` step, by design.

**Rollback**: leave `factory.sandboxImpl` unset (or clear it) — vaults created afterwards have no sandbox, `proposeWithSandbox` refuses at propose, and every other capability is unaffected. Vaults already bound keep theirs, since the vault-side setter is set-once by design; in-flight sandboxes still return capital through `collectResidue`, which needs neither the batch nor any registry standing.
