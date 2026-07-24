# ProposalLifecycle Deepening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the proposal state machine into one owning module (`ProposalLifecycle`) with a true-view `stateOf(pid)` seam, kill the registry call-back and all three duplicate proposal-struct projections.

**Architecture:** The governor pushes review-window facts to the registry at propose time (`registerReview`); the registry stores them and never calls back (`IGovernorMinimal`/`getProposalView`/`ProposalViewLite` deleted). The registry gains `outcomeOf` — a deterministic view of the review verdict sharing one internal predicate with `resolveReview` (the economic commit). A new abstract `ProposalLifecycle` base owns proposal-state storage, `stateOf` (true view — reports Approved/Rejected immediately after `reviewEnd`), and `_transition`/`_commitState` (the ONLY writers of `proposal.state`). The vault reads `strategyOf(pid)` (scalar) instead of the full `StrategyProposal`.

**Frame:** Fresh-deploy (Robinhood stack). Storage layouts, ABIs, and struct shapes are free to change. Base (8453) legacy deployment untouched. Emergency-review registry seam keeps its current shape (scope fence); emergency paths only reroute state writes.

**Tech Stack:** Solidity 0.8.28, Foundry (`forge test`), via_ir. Run all commands from repo root.

**Vocabulary:** see `CONTEXT.md` — proposal lifecycle, proposal state, review outcome, economic commit, review registration.

---

## Behavioral delta (the one intentional spec change)

Today the view path reports `GuardianReview` after `reviewEnd` until a mutating tx pokes `resolveReview`. After this plan, `stateOf` reports `Approved`/`Rejected`/`Expired` immediately once determinable. Tests asserting the lazy behavior are updated **individually** in Task 10 — each such diff is the spec change, reviewed one by one, never bulk-fixed.

## Invariant preserved exactly

`resolveReview` (economic commit / slash) is fired from mutating governor paths ONLY when the proposal actually passed the vote and traversed guardian review — a veto-rejected proposal never triggers it (matches today's `_resolveState`, which only calls `resolveReview` when the view resolved to `GuardianReview`).

## File structure

| File | Action | Responsibility after |
|---|---|---|
| `src/ProposalLifecycle.sol` | **Create** | Abstract base: proposal-state storage, `stateOf`, `_computeState`, `_commitState`, `_transition`, `_decOpen`, `openProposalCount`, `whenNoActiveProposal` |
| `src/GuardianRegistry.sol` | Modify | + `vaultOf`, `registerReview`, `outcomeOf`, `_isBlocked`; − `IGovernorMinimal`, all `getProposalView` call-backs |
| `src/SyndicateGovernor.sol` | Modify | Propose/vote/execute/settle only; − twin resolvers, `getProposalView`, `ProposalViewLite`; + `registerReview` pushes, `strategyOf` |
| `src/GovernorParameters.sol` | Modify | Extends `ProposalLifecycle`; − abstract `openProposalCount`, − `whenNoActiveProposal` (moved to base) |
| `src/GovernorEmergency.sol` | Modify | Extends `ProposalLifecycle`; − `_getProposal`/`_getRegistry` virtual accessors; state writes via base |
| `src/SyndicateFactory.sol` | Modify | `addGovernor(gov, vault)` |
| `src/interfaces/IGuardianRegistry.sol` | Modify | + `registerReview`, `outcomeOf`, `ReviewOutcome`; `addGovernor(address,address)` |
| `src/interfaces/IProposalStatus.sol` | Modify | `getProposal` → `strategyOf` |
| `src/SyndicateVault.sol` | Modify | `_activeStrategy` uses `strategyOf`; try/catch + `ISyndicateGovernor` struct import dropped |
| `test/GuardianRegistryOutcome.t.sol` | **Create** | `outcomeOf` unit + fuzz agreement with `resolveReview` |
| `test/governor/ProposalLifecycle.t.sol` | **Create** | Lifecycle harness suite through `stateOf` |
| `test/mocks/MockGovernorMinimal.sol` | Modify | Drop `getProposalView`; registry tests push windows via `registerReview` |
| existing suites | Modify | Regression net; mechanical ABI adaptation + individually-reviewed lazy-view deltas |

---

### Task 0: Branch

- [ ] **Step 1: Create feature branch off main**

```bash
git checkout main && git pull && git checkout -b refactor/proposal-lifecycle
```

---

### Task 1: Registry — review registration storage + `registerReview` + `addGovernor(gov, vault)`

**Files:**
- Modify: `src/GuardianRegistry.sol` (Review struct ~line 71; `addGovernor` ~line 247)
- Modify: `src/interfaces/IGuardianRegistry.sol`
- Modify: `src/SyndicateFactory.sol:331`
- Test: `test/GuardianRegistryRegisterReview.t.sol` (create)

- [ ] **Step 1: Write the failing tests**

Create `test/GuardianRegistryRegisterReview.t.sol`. Copy the deploy/setup pattern from the top of `test/GuardianRegistry.t.sol` (registry + sWOOD + mock governor wiring through the test factory address), then:

```solidity
function test_registerReview_storesWindow() public {
    vm.prank(address(mockGov)); // mockGov added via addGovernor in setUp
    registry.registerReview(1, block.timestamp + 1 days, block.timestamp + 2 days);
    (uint64 ve, uint64 re) = registry.reviewWindow(address(mockGov), 1);
    assertEq(ve, block.timestamp + 1 days);
    assertEq(re, block.timestamp + 2 days);
}

function test_registerReview_revertsForNonGovernor() public {
    vm.prank(address(0xBEEF));
    vm.expectRevert(IGuardianRegistry.UnauthorizedGovernor.selector);
    registry.registerReview(1, block.timestamp + 1, block.timestamp + 2);
}

function test_registerReview_revertsOnReRegister() public {
    vm.startPrank(address(mockGov));
    registry.registerReview(1, block.timestamp + 1, block.timestamp + 2);
    vm.expectRevert(IGuardianRegistry.ReviewAlreadyRegistered.selector);
    registry.registerReview(1, block.timestamp + 5, block.timestamp + 6);
    vm.stopPrank();
}

function test_registerReview_revertsOnInvalidWindow() public {
    vm.prank(address(mockGov));
    vm.expectRevert(IGuardianRegistry.InvalidReviewWindow.selector);
    registry.registerReview(1, block.timestamp + 2, block.timestamp + 1); // reviewEnd < voteEnd
}

function test_addGovernor_recordsVault() public {
    address gov2 = address(0xCAFE);
    address vault2 = address(0xFA11);
    vm.prank(factoryAddr);
    registry.addGovernor(gov2, vault2);
    assertEq(registry.vaultOf(gov2), vault2);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/GuardianRegistryRegisterReview.t.sol -vv`
Expected: FAIL — `registerReview`/`reviewWindow`/`vaultOf` undeclared, `addGovernor` arity mismatch.

- [ ] **Step 3: Implement registry storage + functions**

In `src/GuardianRegistry.sol`, append to the `Review` struct (packs after `blockQuorumBpsAtOpen`):

```solidity
        /// @dev Review registration (pushed by the governor at propose time;
        ///      replaces the deleted IGovernorMinimal.getProposalView call-back).
        uint64 voteEnd;
        uint64 reviewEnd;
```

Add a `vaultOf` mapping next to `_authorizedGovernors`:

```solidity
    /// @notice Vault served by each authorized governor (1:1, factory-wired at
    ///         `addGovernor`). Replaces the getProposalView().vault call-back:
    ///         vault identity comes from factory wiring, so a compromised
    ///         governor cannot misdirect `slashOwnerBond`.
    mapping(address => address) public vaultOf;
```

Replace `addGovernor`:

```solidity
    /// @notice Register an additional governor and the vault it serves.
    ///         Factory-only — called immediately after a new per-vault
    ///         governor is deployed.
    function addGovernor(address gov, address vault) external {
        if (msg.sender != factory) revert UnauthorizedGovernor();
        if (gov == address(0) || vault == address(0)) revert ZeroAddress();
        _authorizedGovernors.add(gov);
        vaultOf[gov] = vault;
        emit GovernorAdded(gov);
    }
```

Add `registerReview` + `reviewWindow` view (place after `addGovernor`):

```solidity
    /// @notice Review registration: the governor pushes the proposal's review
    ///         window at propose time. onlyGovernor (msg.sender IS the
    ///         governor); one-shot per proposal.
    function registerReview(uint256 proposalId, uint256 voteEnd, uint256 reviewEnd) external onlyGovernor {
        if (voteEnd == 0 || reviewEnd < voteEnd) revert InvalidReviewWindow();
        Review storage r = _reviews[_reviewKey(msg.sender, proposalId)];
        if (r.voteEnd != 0) revert ReviewAlreadyRegistered();
        r.voteEnd = uint64(voteEnd);
        r.reviewEnd = uint64(reviewEnd);
        emit ReviewRegistered(msg.sender, proposalId, uint64(voteEnd), uint64(reviewEnd));
    }

    /// @notice Registered review window for (governor, proposalId). (0,0) = unregistered.
    function reviewWindow(address governor, uint256 proposalId) external view returns (uint64 voteEnd, uint64 reviewEnd) {
        Review storage r = _reviews[_reviewKey(governor, proposalId)];
        return (r.voteEnd, r.reviewEnd);
    }
```

(`onlyGovernor` modifier already exists — it gates `cancelReview` at line 551.)

In `src/interfaces/IGuardianRegistry.sol`: change `addGovernor(address governor)` to `addGovernor(address governor, address vault)`; declare `registerReview`, `reviewWindow`, `vaultOf`; add errors `InvalidReviewWindow()`, `ReviewAlreadyRegistered()` and event `ReviewRegistered(address indexed governor, uint256 indexed proposalId, uint64 voteEnd, uint64 reviewEnd)` (follow the file's existing declaration style).

In `src/SyndicateFactory.sol:331`:

```solidity
        IGuardianRegistry(guardianRegistry).addGovernor(govProxy, address(vault));
```

(use the local vault variable name in scope at that call site — read lines 300–335 before editing.)

- [ ] **Step 4: Run tests**

Run: `forge test --match-path test/GuardianRegistryRegisterReview.t.sol -vv`
Expected: PASS. `forge build` clean (factory + interface consumers compile).

- [ ] **Step 5: Commit**

```bash
git add src/GuardianRegistry.sol src/interfaces/IGuardianRegistry.sol src/SyndicateFactory.sol test/GuardianRegistryRegisterReview.t.sol
git commit -m "feat(registry): review registration push + vaultOf factory wiring"
```

---

### Task 2: Registry — replace every `getProposalView` call-back with stored state; delete `IGovernorMinimal`

**Files:**
- Modify: `src/GuardianRegistry.sol:14–30` (delete interface), `:338–339,348,369` (voteOnProposal), `:558` (cancelReview), `:588` (openReview), `:631–632` (resolveReview), `:775` (_resolveEmergency), `:117,249` (comments)
- Modify: `test/mocks/MockGovernorMinimal.sol`, `test/helpers/RegistryTestHarness.sol`

- [ ] **Step 1: Rewire the five call sites**

`voteOnProposal` (delete line 338, use stored fields):

```solidity
        // was: IGovernorMinimal.ProposalView memory p = IGovernorMinimal(governor).getProposalView(proposalId);
        if (r.voteEnd == 0 || block.timestamp < r.voteEnd || block.timestamp >= r.reviewEnd) revert ReviewNotOpen();
```

and in both lockout blocks replace `p.reviewEnd`/`p.voteEnd` with `r.reviewEnd`/`r.voteEnd`:

```solidity
            uint256 reviewWindow_ = uint256(r.reviewEnd) - uint256(r.voteEnd);
            uint256 lockoutStart = uint256(r.reviewEnd) - (reviewWindow_ * LATE_VOTE_LOCKOUT_BPS) / BPS_DENOMINATOR;
```

`cancelReview` line 558:

```solidity
        // was: uint256 ve = IGovernorMinimal(msg.sender).getProposalView(proposalId).reviewEnd;
        uint256 ve = r.reviewEnd;
```

`openReview` line 588:

```solidity
        // was: uint256 ve = IGovernorMinimal(governor).getProposalView(proposalId).voteEnd;
        uint256 ve = r.voteEnd;
```

`resolveReview` lines 631–632:

```solidity
        // was: IGovernorMinimal.ProposalView memory p = ...; if (p.reviewEnd == 0 || ...)
        bytes32 key = _reviewKey(governor, proposalId);
        Review storage r = _reviews[key];
        if (r.reviewEnd == 0 || block.timestamp < r.reviewEnd) revert ReviewNotReadyForResolve();
```

(the `key`/`r` declarations move up; delete the duplicates below.)

`_resolveEmergency` line 775:

```solidity
            // was: address vault = IGovernorMinimal(er.governor).getProposalView(proposalId).vault;
            address vault = vaultOf[er.governor];
```

Delete the `IGovernorMinimal` interface block (lines 14–30) and update the two comments referencing it (`:117`, `:249`).

- [ ] **Step 2: Adapt registry test mocks**

In `test/mocks/MockGovernorMinimal.sol`: delete `getProposalView` and its `ProposalView` plumbing (keep `getActiveProposal`/`openProposalCount` — StakedWood still consumes those through its own stub). In `test/helpers/RegistryTestHarness.sol` and each registry test that previously relied on the mock's `setProposal(...)` to make windows visible, add the explicit push after proposal setup:

```solidity
        vm.prank(address(mockGov));
        registry.registerReview(pid, voteEnd, reviewEnd);
```

Where the mock's `setProposalWithVault(..., vault)` fed the emergency slash path, the vault now comes from registration: ensure `addGovernor(address(mockGov), vaultAddr)` in the harness setUp carries the vault the test expects to be slashed.

- [ ] **Step 3: Run the registry suites**

Run: `forge test --match-path "test/GuardianRegistry*.t.sol" --match-path "test/StakedWood*.t.sol" --match-path "test/invariants/GuardianInvariants.t.sol" --match-path "test/invariants/InvariantNoProposalBleed.t.sol" -vv`
Expected: PASS after adaptation. Any assertion change beyond mechanical push-wiring: stop and review individually.

- [ ] **Step 4: Commit**

```bash
git add src/GuardianRegistry.sol test/
git commit -m "refactor(registry): read review windows from registration, drop IGovernorMinimal call-back"
```

---

### Task 3: Registry — `outcomeOf` view + shared `_isBlocked` predicate

**Files:**
- Modify: `src/GuardianRegistry.sol` (`resolveReview` ~line 629, `cancelReview` ~line 566, views ~line 900)
- Modify: `src/interfaces/IGuardianRegistry.sol`
- Test: `test/GuardianRegistryOutcome.t.sol` (create)

- [ ] **Step 1: Write the failing tests**

Create `test/GuardianRegistryOutcome.t.sol` (same setup pattern as Task 1's test file):

```solidity
function test_outcomeOf_unresolvedBeforeReviewEnd() public {
    _register(1, T_VOTE_END, T_REVIEW_END);
    vm.warp(T_REVIEW_END - 1);
    assertEq(uint8(registry.outcomeOf(address(mockGov), 1)), uint8(IGuardianRegistry.ReviewOutcome.Unresolved));
}

function test_outcomeOf_clearedWhenNeverOpened() public {
    _register(1, T_VOTE_END, T_REVIEW_END);
    vm.warp(T_REVIEW_END);
    assertEq(uint8(registry.outcomeOf(address(mockGov), 1)), uint8(IGuardianRegistry.ReviewOutcome.Cleared));
}

function test_outcomeOf_blockedAtQuorum() public {
    // open review, stake guardians, cast block votes to quorum (reuse the
    // voting helpers from test/GuardianRegistry.t.sol), then:
    vm.warp(T_REVIEW_END);
    assertEq(uint8(registry.outcomeOf(address(mockGov), 1)), uint8(IGuardianRegistry.ReviewOutcome.Blocked));
}

function test_outcomeOf_cohortTooSmallIsCleared() public {
    // open review with combined stake below MIN_COHORT_STAKE_AT_OPEN, then:
    vm.warp(T_REVIEW_END);
    assertEq(uint8(registry.outcomeOf(address(mockGov), 1)), uint8(IGuardianRegistry.ReviewOutcome.Cleared));
}

/// The anti-twin-drift invariant: for any voting configuration past reviewEnd,
/// the view and the economic commit agree.
function testFuzz_outcomeOf_agreesWithResolveReview(uint96 approveStake, uint96 blockStake, bool open) public {
    // bound stakes, optionally open review + cast votes (reuse harness helpers),
    // warp past reviewEnd, then:
    IGuardianRegistry.ReviewOutcome viewOutcome = registry.outcomeOf(address(mockGov), 1);
    bool committedBlocked = registry.resolveReview(address(mockGov), 1);
    assertEq(viewOutcome == IGuardianRegistry.ReviewOutcome.Blocked, committedBlocked);
    // and post-commit the view reports the cached resolution:
    assertEq(uint8(registry.outcomeOf(address(mockGov), 1)), uint8(viewOutcome));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/GuardianRegistryOutcome.t.sol -vv`
Expected: FAIL — `outcomeOf`/`ReviewOutcome` undeclared.

- [ ] **Step 3: Implement**

In `src/interfaces/IGuardianRegistry.sol`:

```solidity
    /// @notice Review outcome: the guardian review's verdict on a proposal.
    ///         Deterministic from registry storage once the review window ends.
    ///         Unresolved only before `reviewEnd` (or when unregistered);
    ///         cohort-too-small and never-opened reviews are Cleared.
    enum ReviewOutcome {
        Unresolved,
        Cleared,
        Blocked
    }

    function outcomeOf(address governor, uint256 proposalId) external view returns (ReviewOutcome);
```

In `src/GuardianRegistry.sol` — extract the predicate (single source shared by view and commit):

```solidity
    /// @dev Single block-quorum predicate shared by `outcomeOf` (view) and
    ///      `resolveReview` (economic commit) so the two can never drift.
    function _isBlocked(Review storage r) private view returns (bool) {
        uint256 denom = uint256(r.totalStakeAtOpen) + uint256(r.totalDelegatedAtOpen);
        return uint256(r.blockStakeWeight) * 10_000 >= uint256(r.blockQuorumBpsAtOpen) * denom;
    }

    /// @inheritdoc IGuardianRegistry
    function outcomeOf(address governor, uint256 proposalId) external view returns (ReviewOutcome) {
        Review storage r = _reviews[_reviewKey(governor, proposalId)];
        if (r.resolved) return r.blocked ? ReviewOutcome.Blocked : ReviewOutcome.Cleared;
        if (r.reviewEnd == 0 || block.timestamp < r.reviewEnd) return ReviewOutcome.Unresolved;
        if (!r.opened || r.cohortTooSmall) return ReviewOutcome.Cleared;
        return _isBlocked(r) ? ReviewOutcome.Blocked : ReviewOutcome.Cleared;
    }
```

In `resolveReview` replace the inline quorum math (lines 650–651) with:

```solidity
        bool blocked_ = _isBlocked(r);
```

In `cancelReview` replace the duplicated quorum math (lines 566–568) with `if (_isBlocked(r)) revert ReviewNotOpen();` inside the existing `!r.cohortTooSmall` guard.

- [ ] **Step 4: Run tests**

Run: `forge test --match-path "test/GuardianRegistry*.t.sol" -vv`
Expected: PASS, including the fuzz agreement test.

- [ ] **Step 5: Commit**

```bash
git add src/GuardianRegistry.sol src/interfaces/IGuardianRegistry.sol test/GuardianRegistryOutcome.t.sol
git commit -m "feat(registry): outcomeOf review-outcome view sharing one predicate with resolveReview"
```

---

### Task 4: Create `src/ProposalLifecycle.sol` (the deep module)

**Files:**
- Create: `src/ProposalLifecycle.sol`
- (Consumers rewired in Tasks 5–7; this task only compiles the base.)

- [ ] **Step 1: Write the contract**

Storage moved here from `SyndicateGovernor` (fresh-deploy frame — layout shift is intentional): `_guardianRegistry`, `_proposals`, `_openProposalCount`, `_lastSettledAt`, `collaborationDeadline`. Copy each declaration verbatim from `SyndicateGovernor.sol` (grep the exact lines before deleting them there in Task 6).

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title ProposalLifecycle
/// @notice Abstract base owning the proposal lifecycle: the full arc
///         propose → vote → guardian review → execute → settle. There is
///         exactly one authoritative state per proposal, read via `stateOf`
///         (a true view — it never lags behind determinable reality) and
///         written ONLY by `_transition` / `_commitState`.
/// @dev    Single-writer invariant: `p.state =` appears nowhere outside
///         `_transition`. Greppable: `grep -rn "\.state =" src/` must hit
///         only this file.
abstract contract ProposalLifecycle is ISyndicateGovernor {
    // ── Storage (moved from SyndicateGovernor; fresh-deploy frame) ──

    /// @notice Guardian registry handle (review registration + outcome reads).
    address internal _guardianRegistry;

    /// @dev Canonical proposal records.
    mapping(uint256 => StrategyProposal) internal _proposals;

    /// @notice Count of non-terminal proposals bound to the vault.
    uint256 internal _openProposalCount;

    /// @dev Settle-cooldown stamp — bumped at every open-count decrement.
    uint256 internal _lastSettledAt;

    /// @notice Draft collaboration deadline per proposal.
    mapping(uint256 => uint256) public collaborationDeadline;

    /// @dev Upgrade-hygiene gap for this layer.
    uint256[10] private __lifecycleGap;

    // ── Gate (moved from GovernorParameters) ──

    modifier whenNoActiveProposal() {
        if (_openProposalCount > 0) revert ParamsFrozenDuringProposal();
        _;
    }

    // ── The seam ──

    /// @notice True-view proposal state. Reports Approved/Rejected/Expired
    ///         immediately after `reviewEnd` — callers never need to "poke"
    ///         a lazy resolver to learn a proposal's fate.
    function stateOf(uint256 proposalId) public view returns (ProposalState) {
        (ProposalState s,) = _computeState(_proposals[proposalId]);
        return s;
    }

    /// @inheritdoc ISyndicateGovernor
    function openProposalCount() public view virtual returns (uint256) {
        return _openProposalCount;
    }

    // ── State computation (the ONE resolver; no twins) ──

    /// @dev Computes the resolved state without writing storage.
    /// @return resolved         The authoritative current state.
    /// @return reviewConcluded  True iff the proposal passed the vote and its
    ///                          guardian review window has elapsed — the
    ///                          condition under which `_commitState` fires the
    ///                          registry's economic commit. False for
    ///                          veto-rejections at voteEnd (they never
    ///                          traversed review; matches the pre-refactor
    ///                          `_resolveState`, which only called
    ///                          `resolveReview` when the view resolved to
    ///                          GuardianReview).
    function _computeState(StrategyProposal storage p)
        internal
        view
        returns (ProposalState resolved, bool reviewConcluded)
    {
        ProposalState stored = p.state;

        if (stored == ProposalState.Draft) {
            return (
                block.timestamp > collaborationDeadline[p.id] ? ProposalState.Expired : ProposalState.Draft, false
            );
        }

        if (stored == ProposalState.Pending) {
            if (block.timestamp <= p.voteEnd) return (ProposalState.Pending, false);

            // Optimistic: approved unless AGAINST reaches the veto threshold.
            // G-H4: skip when pastTotalSupply == 0 (threshold collapses to 0).
            // G-H6: threshold snapshotted at Draft → Pending, not live params.
            uint256 pastTotalSupply = IVotes(p.vault).getPastTotalSupply(p.snapshotTimestamp);
            if (pastTotalSupply > 0) {
                uint256 vetoThreshold = (pastTotalSupply * p.vetoThresholdBps) / 10_000;
                if (p.votesAgainst >= vetoThreshold) return (ProposalState.Rejected, false);
            }
            return _afterVote(p);
        }

        if (stored == ProposalState.GuardianReview) return _afterVote(p);

        if (stored == ProposalState.Approved) {
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, false);
        }

        return (stored, false);
    }

    /// @dev Maps a vote-passed proposal through the guardian-review outcome.
    ///      True view: reads the registry's deterministic `outcomeOf` instead
    ///      of waiting for a mutating resolve.
    function _afterVote(StrategyProposal storage p) private view returns (ProposalState, bool) {
        if (block.timestamp <= p.reviewEnd) return (ProposalState.GuardianReview, false);

        IGuardianRegistry.ReviewOutcome outcome =
            IGuardianRegistry(_guardianRegistry).outcomeOf(address(this), p.id);
        if (outcome == IGuardianRegistry.ReviewOutcome.Blocked) return (ProposalState.Rejected, true);
        if (outcome == IGuardianRegistry.ReviewOutcome.Cleared) {
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, true);
        }
        // Unresolved past reviewEnd should be unreachable for a registered
        // review; stay in GuardianReview defensively (fail-closed).
        return (ProposalState.GuardianReview, false);
    }

    // ── State writes (single writer) ──

    /// @dev THE only assignment of `p.state`. Direct transitions (cancel,
    ///      veto, Draft → Pending, execute, settle) call this; lazy
    ///      resolution goes through `_commitState`.
    function _transition(StrategyProposal storage p, ProposalState to) internal {
        p.state = to;
    }

    /// @dev Resolve-and-persist: compute the authoritative state, commit the
    ///      registry's economic commit when the review concluded, persist the
    ///      transition, and keep open-count bookkeeping. Replaces the old
    ///      mutating/view twin pair.
    function _commitState(StrategyProposal storage p) internal returns (ProposalState resolved) {
        ProposalState stored = p.state;
        bool reviewConcluded;
        (resolved, reviewConcluded) = _computeState(p);

        if (reviewConcluded && stored != resolved) {
            // Economic commit — idempotent on the registry (slash +
            // attribution happen at most once); shares `_isBlocked` with
            // `outcomeOf`, so it cannot disagree with the view we just read.
            bool blocked = IGuardianRegistry(_guardianRegistry).resolveReview(address(this), p.id);
            emit GuardianReviewResolved(p.id, blocked);
        }

        if (resolved != stored) {
            _transition(p, resolved);
            // Sherlock #8: Draft binds the vault — both Draft and non-Draft
            // terminal transitions decrement.
            if (resolved == ProposalState.Rejected || resolved == ProposalState.Expired) {
                _decOpen();
                if (stored == ProposalState.Draft) emit CollaborationDeadlineExpired(p.id);
            }
        }
    }

    /// @dev Decrement the open-proposal counter AND stamp the settle cooldown
    ///      (PR #359 review #1: single chokepoint so the lazy terminal path
    ///      can't dodge the cooldown).
    function _decOpen() internal {
        --_openProposalCount;
        _lastSettledAt = block.timestamp;
    }
}
```

- [ ] **Step 2: Compile**

Run: `forge build`
Expected: compiles (events `GuardianReviewResolved` / `CollaborationDeadlineExpired` and error `ParamsFrozenDuringProposal` already live in `ISyndicateGovernor` — verify with `grep -n "GuardianReviewResolved\|CollaborationDeadlineExpired\|ParamsFrozenDuringProposal" src/interfaces/ISyndicateGovernor.sol`; if any is declared in `SyndicateGovernor.sol` instead, move the declaration to the interface now).

- [ ] **Step 3: Commit**

```bash
git add src/ProposalLifecycle.sol
git commit -m "feat: ProposalLifecycle abstract base — true-view stateOf, single-writer transitions"
```

---

### Task 5: GovernorParameters extends ProposalLifecycle

**Files:**
- Modify: `src/GovernorParameters.sol:24` (inheritance), `:150–153` (delete modifier), `:284` (delete abstract)

- [ ] **Step 1: Rewire**

```solidity
import {ProposalLifecycle} from "./ProposalLifecycle.sol";

abstract contract GovernorParameters is ProposalLifecycle {
```

Delete the `whenNoActiveProposal` modifier (lines 150–153 — now inherited) and the abstract `function openProposalCount() public view virtual returns (uint256);` (line 284 — now concrete in the base). Setters keep compiling unchanged against the inherited modifier.

- [ ] **Step 2: Compile**

Run: `forge build` — SyndicateGovernor will NOT compile yet (duplicate storage until Task 6). Proceed directly to Task 6 and commit Tasks 5+6 together.

---

### Task 6: SyndicateGovernor — twins die; pushes at propose; `strategyOf`

**Files:**
- Modify: `src/SyndicateGovernor.sol` (storage block ~line 112; `propose` ~235; `_initPendingProposal` ~755; `approveCollaboration` ~586; twins 958–1047; `getProposalView`/`ProposalViewLite` 731–747; all `_resolveState`/direct `p.state =` call sites; `_decOpen` 524–527; `openProposalCount` 530–532)

- [ ] **Step 1: Remove migrated storage + duplicates**

Delete from `SyndicateGovernor`: `_openProposalCount` (line 112), `_guardianRegistry`, `_proposals`, `_lastSettledAt`, `collaborationDeadline` declarations (grep each first: `grep -n "_guardianRegistry;\|_proposals;\|_lastSettledAt;\|collaborationDeadline;" src/SyndicateGovernor.sol`), `_decOpen()` (524–527), and `openProposalCount()` (530–532; base provides it — if the `override(GovernorParameters, ISyndicateGovernor)` specifier is still required by the compiler, keep a thin `override` returning `_openProposalCount`).

- [ ] **Step 2: Delete the twins and the projection**

Delete `_resolveState` (958–986), `_resolveStateView` (988–1030), `_resolveAfterVote` (1032–1047), `getProposalView` + `ProposalViewLite` (731–747).

- [ ] **Step 3: Reroute every call site**

Mechanical substitutions — enumerate with `grep -n "_resolveState\|proposal.state =\|p.state =" src/SyndicateGovernor.sol` and apply:

| Site | Old | New |
|---|---|---|
| `cancelProposal:467` | `_resolveState(proposal)` | `_commitState(proposal)` |
| `cancelProposal:496` | `proposal.state = ProposalState.Cancelled;` | `_transition(proposal, ProposalState.Cancelled);` |
| `emergencyCancel:507,514` | same pair | same pair |
| `vetoProposal:540,541` | same pair | same pair |
| `approveCollaboration:553,580` | `_resolveState` → `_commitState`; direct write → `_transition(proposal, ProposalState.Pending);` |
| `rejectCollaboration:601,607` | same pair | same pair |
| `resolveProposalState:634` | `_resolveState(proposal)` | `_commitState(proposal)` |
| `propose:315` (Draft) | `p.state = ProposalState.Draft;` | `_transition(p, ProposalState.Draft);` |
| `_initPendingProposal:761` | `p.state = ProposalState.Pending;` | `_transition(p, ProposalState.Pending);` |
| execute path (grep `ProposalState.Executed`) | direct write | `_transition(...)` |
| `_finishSettlement` (grep `ProposalState.Settled`) | direct write | `_transition(...)` |
| `getProposalState` public view (grep it) | `_resolveStateView` | `stateOf(proposalId)` |
| every other internal `_resolveStateView(...)` read | | `stateOf(p.id)` or `(ProposalState s,) = _computeState(p)` |

After this: `grep -rn "\.state =" src/ --include="*.sol"` must return ONLY `src/ProposalLifecycle.sol` (the single-writer invariant, now greppable).

- [ ] **Step 4: Push review registration at both Pending transitions**

In `_initPendingProposal` (after `p.reviewEnd` is set, line 759):

```solidity
        // Review registration: push the window to the registry (it never
        // calls back — IGovernorMinimal is gone).
        IGuardianRegistry(_guardianRegistry).registerReview(p.id, p.voteEnd, p.reviewEnd);
```

In `approveCollaboration`'s Draft → Pending block (after `proposal.executeBy` is set, line 588):

```solidity
            IGuardianRegistry(_guardianRegistry).registerReview(proposalId, proposal.voteEnd, proposal.reviewEnd);
```

- [ ] **Step 5: Add `strategyOf`**

Next to the remaining views:

```solidity
    /// @notice Strategy adapter of a proposal (address(0) = none / opted out
    ///         of live NAV). Scalar seam for the vault — replaces the vault's
    ///         full-struct `getProposal` read and its shape-drift try/catch.
    function strategyOf(uint256 proposalId) external view returns (address) {
        return _proposals[proposalId].strategy;
    }
```

- [ ] **Step 6: Compile**

Run: `forge build`
Expected: clean. Then run the focused suites: `forge test --match-path "test/governor/*.t.sol" --match-path test/SyndicateGovernor.t.sol -vv` — failures at this point are either (a) mechanical ABI/mock wiring (fix inline) or (b) lazy-view assertions — leave (b) for Task 10, mark each with a TODO comment.

- [ ] **Step 7: Commit (Tasks 5+6 together)**

```bash
git add src/GovernorParameters.sol src/SyndicateGovernor.sol
git commit -m "refactor(governor): fold state machine into ProposalLifecycle; true-view stateOf; registerReview pushes"
```

---

### Task 7: GovernorEmergency extends ProposalLifecycle

**Files:**
- Modify: `src/GovernorEmergency.sol:24–35` (inheritance + accessors), `:57,75,90,102` (state reads)
- Modify: `src/SyndicateGovernor.sol` (delete the `_getProposal`/`_getRegistry` overrides)

- [ ] **Step 1: Rewire**

```solidity
import {ProposalLifecycle} from "./ProposalLifecycle.sol";

abstract contract GovernorEmergency is ProposalLifecycle {
```

Delete the virtual accessors `_getProposal` and `_getRegistry` (lines 27–29) — the base provides `_proposals` and `_guardianRegistry` directly. Keep `_getSettlementCalls`, `_emergencyReentrancyEnter/Leave`, `_finishSettlementHook` virtuals (still owned by SyndicateGovernor). Replace each `StrategyProposal storage p = _getProposal(proposalId);` with `StrategyProposal storage p = _proposals[proposalId];` and each `IGuardianRegistry reg = _getRegistry();` with `IGuardianRegistry reg = IGuardianRegistry(_guardianRegistry);`. Delete the corresponding `override` implementations in `SyndicateGovernor` (grep `_getProposal\|_getRegistry` there).

The four `if (p.state != ProposalState.Executed)` checks stay as direct reads — Executed is not a time-lazy state (it only leaves via settle, a mutating path), so the stored field IS the authoritative state here; a `stateOf` call would cost an external registry read for nothing.

- [ ] **Step 2: Compile + run emergency suite**

Run: `forge build && forge test --match-path test/governor/GovernorEmergency.t.sol -vv`
Expected: PASS (mechanical adaptation only — this path is freshly hardened; any behavioral diff here is a bug in the refactor, not a test to update).

- [ ] **Step 3: Commit**

```bash
git add src/GovernorEmergency.sol src/SyndicateGovernor.sol
git commit -m "refactor(emergency): consume ProposalLifecycle base directly"
```

---

### Task 8: Vault reads `strategyOf`; `IProposalStatus` narrows

**Files:**
- Modify: `src/interfaces/IProposalStatus.sol:33–34`
- Modify: `src/SyndicateVault.sol:582–594` (`_activeStrategy`), `:7` (import)

- [ ] **Step 1: Narrow the interface**

In `IProposalStatus.sol`, replace `getProposal` (lines 33–34) with:

```solidity
    /// @notice Strategy adapter of a proposal (address(0) = none). A scalar —
    ///         cannot drift in shape, so the vault needs no try/catch.
    function strategyOf(uint256 proposalId) external view returns (address);
```

Delete the `ISyndicateGovernor` import from `IProposalStatus.sol` if `getProposal` was its only use (grep the file).

- [ ] **Step 2: Simplify `_activeStrategy`**

```solidity
    /// @dev Reads the active proposal's strategy through the governor.
    ///      Returns `address(0)` when no proposal is active OR when the active
    ///      proposal opted out of live NAV (proposer passed `strategy=0`).
    function _activeStrategy() internal view returns (address) {
        address gov = _getGovernor();
        if (gov == address(0)) return address(0);
        uint256 pid = IProposalStatus(gov).getActiveProposal();
        if (pid == 0) return address(0);
        return IProposalStatus(gov).strategyOf(pid);
    }
```

Remove the now-unused `ISyndicateGovernor` import from `SyndicateVault.sol` if nothing else references it (`grep -n "ISyndicateGovernor" src/SyndicateVault.sol`).

- [ ] **Step 3: Run vault suites**

Run: `forge test --match-path test/SyndicateVault.t.sol --match-path "test/invariants/*.t.sol" -vv`
Expected: PASS. Confirm no accidental size regression: `forge build --sizes | grep SyndicateVault`.

- [ ] **Step 4: Commit**

```bash
git add src/interfaces/IProposalStatus.sol src/SyndicateVault.sol
git commit -m "refactor(vault): scalar strategyOf read replaces full-struct getProposal + try/catch"
```

---

### Task 9: New lifecycle harness suite

**Files:**
- Create: `test/governor/ProposalLifecycle.t.sol`

- [ ] **Step 1: Write the suite**

Reuse the governor test scaffolding from `test/governor/GuardianReviewLifecycle.t.sol` (factory-deployed vault + governor + registry + sWOOD, `GovEnvelope.permissive()` hoisted to a state variable per the PR #13 pattern). Cover, all through `stateOf` / public entrypoints only (no `vm.store` on lifecycle state):

```solidity
// 1. Pending during vote window.
function test_stateOf_pendingDuringVote() public { ... assertEq(stateOf, Pending); }

// 2. Veto: AGAINST >= snapshot threshold at voteEnd -> Rejected, and
//    resolveProposalState commits WITHOUT calling registry.resolveReview
//    (assert no ReviewResolved event; approvers of a vetoed proposal are
//    not slashed by the lifecycle).
function test_stateOf_vetoRejectsWithoutEconomicCommit() public { ... }

// 3. TRUE-VIEW CORE: warp past reviewEnd with no block quorum ->
//    stateOf == Approved IMMEDIATELY, before any poke.
function test_stateOf_trueViewApprovedAfterReviewEnd() public { ... }

// 4. TRUE-VIEW CORE: block quorum reached, warp past reviewEnd ->
//    stateOf == Rejected immediately; then resolveProposalState commits,
//    emits GuardianReviewResolved(pid, true), slashes approvers exactly once,
//    and stateOf still == Rejected (view/commit agreement end-to-end).
function test_stateOf_trueViewRejectedThenCommitAgrees() public { ... }

// 5. Approved past executeBy -> Expired; open count released via
//    resolveProposalState (no VaultHasOpenProposal on next propose).
function test_stateOf_expiryReleasesVault() public { ... }

// 6. Draft past collaborationDeadline -> Expired (view), commit emits
//    CollaborationDeadlineExpired + decrements open count.
function test_stateOf_draftExpiry() public { ... }

// 7. registerReview wiring: propose() registers the window — read
//    registry.reviewWindow(governor, pid) and assert it equals
//    (p.voteEnd, p.reviewEnd); collaborative Draft registers at the
//    Draft -> Pending transition, not at propose.
function test_registerReview_pushedAtPendingTransition() public { ... }
```

Fill each `...` with the concrete deposit/propose/vote/warp choreography copied from the nearest existing lifecycle test (deposit in the same block as propose where the PR #13 refactor requires it).

- [ ] **Step 2: Run**

Run: `forge test --match-path test/governor/ProposalLifecycle.t.sol -vv`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/governor/ProposalLifecycle.t.sol
git commit -m "test: ProposalLifecycle harness — true-view stateOf through the seam"
```

---

### Task 10: Lazy-view test deltas — individually reviewed

**Files:**
- Modify: only test files whose assertions encode the OLD lazy behavior (view == GuardianReview after reviewEnd until poked).

- [ ] **Step 1: Enumerate the deltas**

Run: `forge test 2>&1 | grep -B2 "FAIL"` on the full suite. For each failure, classify:
- **Mechanical** (ABI change, mock wiring, `addGovernor` arity): fix inline.
- **Spec delta** (asserts `GuardianReview` where `stateOf` now reports the resolved state, or asserts a poke was required): update the assertion to the new behavior and add a one-line comment `// true-view: resolved immediately after reviewEnd (2026-07-24 lifecycle deepening)`.

- [ ] **Step 2: Review each spec delta individually**

List every spec-delta diff in the PR description. Do not bulk-sed assertions. Expected concentration: `test/governor/GuardianReviewLifecycle.t.sol`, `test/SyndicateGovernor.t.sol`, `test/invariants/InvariantNoProposalBleed.t.sol`.

If `test/governor/GovernorLayoutPins.t.sol` pins governor storage slots, regenerate its golden values here (the base-contract move shifts the layout by design — fresh-deploy frame) and explain the diff in the PR.

- [ ] **Step 3: Full suite green**

Run: `forge test`
Expected: PASS (fork tests excluded if RPC env unset — same as baseline).

- [ ] **Step 4: Commit**

```bash
git add test/
git commit -m "test: adapt suites to true-view stateOf (spec deltas reviewed individually)"
```

---

### Task 11: Docs, fmt, wrap-up

- [ ] **Step 1: Update README contract table**

`README.md`: add one row for `src/ProposalLifecycle.sol` (abstract lifecycle base, single-writer state machine, true-view `stateOf`); adjust the `SyndicateGovernor` / `GovernorParameters` / `GuardianRegistry` descriptions (registry line: review registration replaces the governor call-back).

- [ ] **Step 2: forge fmt with a CI-matching forge**

Run: `forge fmt && forge fmt --check`
(Guardrail: fmt rules differ across forge versions — check `.github/workflows/` for a pinned version before trusting local fmt.)

- [ ] **Step 3: Final gates**

```bash
forge build --sizes | grep -Ei "governor|registry|vault"   # note new sizes; Robinhood limit 98304
forge test
grep -rn "\.state =" src/ --include="*.sol"                # must hit ONLY ProposalLifecycle.sol
grep -rn "getProposalView\|IGovernorMinimal\|ProposalViewLite" src/  # must be empty
```

- [ ] **Step 4: Commit + push + PR**

```bash
git add README.md
git commit -m "docs: proposal lifecycle module in contract table"
git push -u origin refactor/proposal-lifecycle
```

Open the PR with: the behavioral delta called out at the top, the list of individually-reviewed lazy-view assertion changes, and the two grep gates from Step 3 quoted as evidence.

---

## Self-review notes

- **Spec coverage:** Q1 frame → header; Q2 push → Tasks 1, 2, 6; Q2-amendment (vaultOf) → Tasks 1, 2; Q3 outcomeOf/true view → Tasks 3, 4; Q4 base module → Tasks 4, 5, 6, 7; Q5 strategyOf → Tasks 6, 8; Q6 fence → Task 7; Q7 tests → Tasks 9, 10; Q8 single PR → Task 11; Q9 naming → file/vocabulary throughout.
- **Type consistency:** `ReviewOutcome {Unresolved, Cleared, Blocked}` (Task 3) is what `_afterVote` consumes (Task 4). `registerReview(uint256,uint256,uint256)` (Task 1) matches both push sites (Task 6). `strategyOf(uint256) → address` consistent across Tasks 6 and 8. `addGovernor(address,address)` consistent across Tasks 1, 2 (mocks) and the factory.
- **Known risk:** moving `_proposals`/`_openProposalCount` into the base shifts the governor storage layout — safe ONLY under the fresh-deploy frame; do not cherry-pick onto the Base (8453) beacon. Layout-pin tests regenerate in Task 10.
