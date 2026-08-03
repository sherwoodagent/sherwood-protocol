# Bind strategy-clone execution to its owning proposal (issue #150)

## Why

**An unrelated earlier proposal's batch can permanently brick a later proposal by flipping a pre-deployed strategy clone's one-shot `Executed` ratchet.** Confirmed live by PoC on current main (issue #150 comments, 2026-08-03, run after #118/PR #164 landed): deploy a clone via `StrategyFactory` for a would-be future proposal, drive an unrelated proposal whose `executeCalls` contain `clone.execute()` through `propose → executeProposal`, and the clone's ratchet flips `Pending → Executed`. The later proposal that declares that clone as its strategy then reverts `AlreadyExecuted()` at execution — bricked before it was even voted on, by a batch that had nothing to do with it.

The mechanism is an authorization gap, not a missing guard misfire:

- `BaseStrategy.execute()` (src/strategies/BaseStrategy.sol:86-90) is guarded `onlyVault` (:67-70) — a **caller-identity** check.
- But governor batches run through `SyndicateVault.executeGovernorBatch` via delegatecall into `BatchExecutorLib` (src/SyndicateVault.sol:495-544, delegatecall at :504-505), so **every batch sub-call carries `msg.sender == vault`** — for every proposal of that vault, not just the one the clone was deployed for. `onlyVault` cannot distinguish them; the clone has no notion of *which proposal* is driving the vault.
- Clones are pre-deployed **before** their proposal exists by design (src/StrategyFactory.sol:30-36: "Strategies must always be pre-deployed … BEFORE proposal execution"), so a window in which an unrelated proposal can reach a not-yet-owned clone always exists.

**#118's fix does not and cannot cover this — verified against the landed code.** `_rejectPrivilegedTargets` (src/SyndicateGovernor.sol:1055-1084) consumes the vault's privileged-target predicate, whose scope is *exactly two addresses* — the vault and its bound withdrawal queue. The vault's own guard documentation is explicit that strategy clones are exempt on purpose (src/SyndicateVault.sol:583-587: "Strategy adapters' own `onlyVault` entrypoints (`BaseStrategy.execute/settle`) are the LEGITIMATE batch surface and stay open"). A clone address passes `propose`, passes `_guardBatchCalls`, and the batch runs. The post-landing check that `propose-time-target-validation`'s design.md required ("Does item 1 subsume #150?") was performed and recorded on the issue: **no**.

**Severity, restated honestly:** griefing, not theft. No fund loss (the ratchet controls lifecycle state, not custody); insider-gated (`propose` requires `vault.isAgent(msg.sender)`, src/SyndicateGovernor.sol:229); remedy is redeploy-and-repropose, so the cost is a proposal cycle. Issue #150 was filed deferred because both fix options it costed — a clone registry on `StrategyFactory`, or threading a `proposalId` through `initialize` and every subclass — were wide changes for a bounded grief. This change is the dedicated design pass the issue's 2026-08-03 comment asked for, and it found a third mechanism that is materially cheaper than either costed option: the binding the clone needs already exists on-chain, in views that already ship (`getActiveProposal()`, `strategyOf(pid)`, `vault.governor()`). The fix is ~10 lines in one contract, no new storage, no interface changes, no registry. At that price the defer calculus inverts, and the gap is worth closing before any clone exists on the target chain (none do — see design.md Decision 4).

## What Changes

- **`BaseStrategy.execute()` gains a proposal-binding check** (the only code change): before flipping the ratchet, the clone resolves `vault() → governor()` and requires that the governor's currently-active proposal declares *this clone* as its strategy — `IProposalStatus(gov).strategyOf(IProposalStatus(gov).getActiveProposal()) == address(this)` — reverting a new `NotActiveProposalStrategy()` otherwise. During a legitimate execution this always holds: `executeProposal` sets `_activeProposal = proposalId` (src/SyndicateGovernor.sol:378) before running the batch (:451), and `p.strategy` was pinned at propose (:276). An unrelated proposal's batch fails the check because *its* `p.strategy` is not this clone.
- **Fail-closed, deliberately** — the opposite posture from #118's propose-time check, argued in design.md Decision 2: this check IS the enforcement, not an early copy of a later authoritative guard, so degrade-open would equal no fix. Typed external calls; any unresolvable hop reverts `execute()`. A clone that cannot verify its wiring must not deploy capital, and a refused execute is recoverable (fix wiring / redeploy) where a flipped ratchet is permanent.
- **`settle()` is deliberately NOT guarded.** Transitive protection: reaching `settle()` requires `_state == Executed`, which post-fix only the owning proposal's batch can set; while that proposal is open, the single-open-proposal invariant means no other proposal's batch can run. And an unguarded `settle()` is load-bearing for recovery: an orphaned clone (owning proposal settled via owner-supplied emergency calls that bypassed it) can still be swept back to the vault by a later proposal's batch. Guarding settle would strand those funds. Full argument in design.md.
- **No changes to `SyndicateGovernor`, `SyndicateVault`, `StrategyFactory`, or any interface.** The check consumes the existing `IProposalStatus` seam (src/interfaces/IProposalStatus.sol:21-33 — the vault's own narrow view of the governor, already used for exactly this walk at src/SyndicateVault.sol:1017-1021) plus a one-member local interface for `vault.governor()`, mirroring `VeniceInferenceStrategy`'s `ITierBindingPath` precedent (src/strategies/VeniceInferenceStrategy.sol:43).
- **Tests**: PoC-shaped lifecycle test (the exact #150 scenario, now asserting `NotActiveProposalStrategy` and the later proposal executing cleanly); unit tests for the binding check including fail-closed behavior; a sweep of existing harnesses that call `execute()` under a pranked vault without governor wiring (`MockStrategy` consumers) — see design.md "Test impact".
- **Templates redeploy, no migration**: the fix ships in `BaseStrategy`, so it reaches chains via new template deploys + `setTemplateApproval`. No deployed clone needs (or could take) a retrofit — ERC-1167 clones are immutable, and no clone exists on Robinhood 4663 (design.md Decision 4).

## Capabilities

### New Capabilities

- `strategy-lifecycle`: the `BaseStrategy` clone lifecycle state machine (`Pending → Executed → Settled` one-shot ratchet) and its authorization: execution bound to the clone's owning proposal, settlement transitively protected and deliberately open for orphan recovery. `BaseStrategy` predates the openspec tree; the delta specs only what this change introduces plus the ratchet invariant it defends, not a retrofit of the whole contract.

### Modified Capabilities

None. `syndicate-governor` and `syndicate-vault` behavior is untouched — the propose-time denylist keeps its two-address scope on purpose (its spec already states the scope), and the fix lives entirely on the strategy side.

## Impact

- `src/strategies/BaseStrategy.sol` — the binding check in `execute()`, new error, one local interface, natspec stating the adversary. No storage change: the binding is derived at call time, zero new state variables, so subclass storage (`PortfolioStrategy`, `VeniceInferenceStrategy`) is unaffected.
- Storage-layout goldens: **not applicable and no action** — `script/check-layout-goldens.sh` guards the five proxy-upgraded contracts (governor, factory, registry, StakedWood, vault); strategy clones are immutable ERC-1167 proxies with no upgrade path, hence no frozen-layout convention (design.md Decision 3).
- Subclasses: none touched — `execute()` is non-virtual in `BaseStrategy`; subclasses implement `_execute()` only.
- Bytecode/gas: three external view calls on a one-shot cold path; template size nowhere near any limit. Irrelevant.
- Tests: the real blast radius. `MockStrategy is BaseStrategy` (test/mocks/MockStrategy.sol:22) is used across suites; any harness that calls `execute()` via `vm.prank(vault)` against a vault lacking a `governor()` view (or a governor lacking the two views) now reverts. Each such site gets wired with the existing `MockProposalStatus` or asserts the new revert deliberately (tasks 3.x).

## Sequencing

No pending change edits `BaseStrategy.execute()`. The two changes whose tasks name `BaseStrategy` (`retire-lane-a`, `remove-self-managed-fees`) are already reflected in current main (no `Position` import, no `selfManagesFees` — both gone at 00a264a); this change rebases trivially if their archival lands first. No file overlap with off-limits #35 (`ExposureLedger`/`StakedWood`), #45 (`TierRegistry`), or #115 (vault batch guard selectors). Line references throughout are against `origin/main` @ `00a264a`.
