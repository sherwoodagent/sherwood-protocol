# Guardian Economic Security — Plan A: Execution-Side Safety

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the execution-side half of the v1 economic-security spec (`docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md` §3.1–§3.2): adapter tier registry with codehash-verified certification, per-proposal risk envelopes, and net-outflow metering in the vault.

**Architecture:** A new standalone `TierRegistry` maps `(target, selector) → {tier, extractableBoundBps, certifiedCodehash}` with lazy fail-safe demotion (a live `EXTCODEHASH` mismatch makes `tierOf` report tier 2 without any state write). `SyndicateGovernor.propose` gains a `RiskEnvelope` param, resolves the proposal's effective tier + required coverage at propose time, and re-checks the tier at execute (fail-safe revert on regression). `SyndicateVault.executeGovernorBatch` gains a `maxNetOutflow` cap enforced on its existing before/after balance metering.

**Tech Stack:** Solidity 0.8.28, Foundry (forge test/fmt), OpenZeppelin Ownable2Step. Repo conventions: custom errors, extensive natspec with finding-tags, tests in `test/*.t.sol`.

**Sequencing:** This is Plan A of three. Plan B (aggregate exposure cap in GuardianRegistry/StakedWood, consumes `requiredCoverage` stored here) and Plan C (challenge game + adjudication + submitter bond escrow) follow after A lands. A is independently shippable: it hard-bounds what any proposal can move, before any liability machinery exists.

**Storage caution:** `StrategyProposal` gains fields — append at the END of the struct only. Governors are beacon-upgraded; run the repo's storage-parity check after every struct change. If the parity check fails the layout, stop and surface — do not reorder existing fields.

---

### Task 1: TierRegistry — key derivation and default tier

**Files:**
- Create: `src/TierRegistry.sol`
- Create: `test/TierRegistry.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TierRegistry} from "src/TierRegistry.sol";

contract TierRegistryTest is Test {
    TierRegistry internal reg;
    address internal owner = makeAddr("owner");
    address internal target;

    function setUp() public {
        reg = new TierRegistry(owner);
        // any deployed contract works as a certification target; use the registry itself
        target = address(reg);
    }

    function test_unknownSelectorDefaultsToTier2FullNotional() public view {
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0xdeadbeef));
        assertEq(tier, 2);
        assertEq(boundBps, 10_000); // full notional
    }

    function test_keyIsDeterministic() public view {
        bytes32 k1 = reg.key(target, bytes4(0x12345678));
        bytes32 k2 = reg.key(target, bytes4(0x12345678));
        assertEq(k1, k2);
        assertTrue(k1 != reg.key(target, bytes4(0x12345679)));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract TierRegistryTest -vv`
Expected: compilation failure — `src/TierRegistry.sol` not found.

- [ ] **Step 3: Write minimal implementation**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title TierRegistry
 * @notice Adapter-selector tier certification for the guardian economic-security
 *         model (spec 2026-07-22 §3.2). Tier is a property of (target, selector),
 *         set at listing by governance, consumed at propose/execute time.
 *
 *         Tier 0: closed-loop — extractable bounded to `extractableBoundBps`.
 *         Tier 1: oracle-bounded discretion — extractable bounded likewise.
 *         Tier 2: arbitrary calldata — full notional. DEFAULT for any
 *                 uncertified (target, selector).
 *
 * @dev Fail-safe demotion is LAZY: `tierOf` verifies the target's live
 *      EXTCODEHASH against the certified hash on every read and reports tier 2
 *      on mismatch — no state write in the hot path, nothing to grief. `poke`
 *      persists the demotion and emits for indexers.
 */
contract TierRegistry is Ownable2Step {
    struct TierConfig {
        uint8 tier; // 0 or 1 when certified; entry absent => tier 2
        uint16 extractableBoundBps; // certified extractable bound, bps of notional
        bytes32 certifiedCodehash; // EXTCODEHASH of target at certification
    }

    uint8 public constant TIER_ARBITRARY = 2;
    uint16 public constant FULL_NOTIONAL_BPS = 10_000;

    mapping(bytes32 configKey => TierConfig) private _configs;

    constructor(address initialOwner) Ownable(initialOwner) {}

    function key(address target, bytes4 selector) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(target, selector));
    }

    /// @notice Effective tier for (target, selector). Uncertified, demoted, or
    ///         codehash-mismatched entries all report (2, 10_000).
    function tierOf(address target, bytes4 selector) public view returns (uint8 tier, uint16 boundBps) {
        TierConfig storage c = _configs[key(target, selector)];
        if (c.certifiedCodehash == bytes32(0) || target.codehash != c.certifiedCodehash) {
            return (TIER_ARBITRARY, FULL_NOTIONAL_BPS);
        }
        return (c.tier, c.extractableBoundBps);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract TierRegistryTest -vv`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add src/TierRegistry.sol test/TierRegistry.t.sol
git commit -m "feat: TierRegistry skeleton — default-deny tier 2, deterministic keys"
```

---

### Task 2: TierRegistry — certify, demote, codehash fail-safe

**Files:**
- Modify: `src/TierRegistry.sol`
- Modify: `test/TierRegistry.t.sol`

- [ ] **Step 1: Write the failing tests**

Append to `TierRegistryTest`:

```solidity
    function test_certifyThenTierOfReportsCertified() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50);
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 0);
        assertEq(boundBps, 50);
    }

    function test_certifyRevertsForTier2() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidTier.selector);
        reg.certify(target, bytes4(0x12345678), 2, 50);
    }

    function test_certifyRevertsForZeroBound() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.certify(target, bytes4(0x12345678), 0, 0);
    }

    function test_certifyRevertsForEOATarget() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.certify(makeAddr("eoa"), bytes4(0x12345678), 0, 50);
    }

    function test_certifyOnlyOwner() public {
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.certify(target, bytes4(0x12345678), 0, 50);
    }

    function test_codehashMismatchLazilyDemotesToTier2() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50);
        // swap the code under the certified target
        vm.etch(target, hex"6001600101");
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
        assertEq(boundBps, 10_000);
    }

    function test_pokePersistsDemotionOnMismatch() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50);
        vm.etch(target, hex"6001600101");
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.TierDemoted(target, bytes4(0x12345678));
        reg.poke(target, bytes4(0x12345678)); // permissionless
    }

    function test_pokeRevertsWhenCodehashStillMatches() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50);
        vm.expectRevert(TierRegistry.CodehashMatches.selector);
        reg.poke(target, bytes4(0x12345678));
    }

    function test_ownerDemote() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 100);
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));
        (uint8 tier,) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract TierRegistryTest -vv`
Expected: compilation failure — `certify` / `poke` / `demote` / errors undefined.

- [ ] **Step 3: Implement**

Add to `TierRegistry`:

```solidity
    event TierCertified(
        address indexed target, bytes4 indexed selector, uint8 tier, uint16 extractableBoundBps, bytes32 codehash
    );
    event TierDemoted(address indexed target, bytes4 indexed selector);

    error InvalidTier();
    error BoundRequired();
    error NotAContract();
    error CodehashMatches();
    error NotCertified();

    /// @notice Certify (target, selector) at tier 0/1 with its extractable bound.
    ///         Snapshots EXTCODEHASH — upgradeable/proxied targets will trip the
    ///         lazy demotion on their first post-upgrade read, by design.
    function certify(address target, bytes4 selector, uint8 tier, uint16 extractableBoundBps) external onlyOwner {
        if (tier >= TIER_ARBITRARY) revert InvalidTier();
        if (extractableBoundBps == 0 || extractableBoundBps >= FULL_NOTIONAL_BPS) revert BoundRequired();
        bytes32 ch = target.codehash;
        if (ch == bytes32(0)) revert NotAContract();
        _configs[key(target, selector)] =
            TierConfig({tier: tier, extractableBoundBps: extractableBoundBps, certifiedCodehash: ch});
        emit TierCertified(target, selector, tier, extractableBoundBps, ch);
    }

    /// @notice Owner demotion (revoke certification).
    function demote(address target, bytes4 selector) external onlyOwner {
        _demote(target, selector);
    }

    /// @notice Permissionless demotion when the live codehash no longer matches
    ///         the certified hash. Persists what `tierOf` already reports lazily.
    function poke(address target, bytes4 selector) external {
        TierConfig storage c = _configs[key(target, selector)];
        if (c.certifiedCodehash == bytes32(0)) revert NotCertified();
        if (target.codehash == c.certifiedCodehash) revert CodehashMatches();
        _demote(target, selector);
    }

    function _demote(address target, bytes4 selector) private {
        delete _configs[key(target, selector)];
        emit TierDemoted(target, selector);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract TierRegistryTest -vv`
Expected: 11 passed (Tasks 1+2).

- [ ] **Step 5: Commit**

```bash
git add src/TierRegistry.sol test/TierRegistry.t.sol
git commit -m "feat: TierRegistry certify/demote with lazy codehash fail-safe"
```

---

### Task 3: RiskEnvelope in propose() — declaration, validation, storage

**Files:**
- Modify: `src/interfaces/ISyndicateGovernor.sol` (the `propose` signature, ~line 327; add `RiskEnvelope` struct + errors)
- Modify: `src/SyndicateGovernor.sol` (`propose`, line 227; `StrategyProposal` struct — locate with `grep -rn "struct StrategyProposal" src/` ; APPEND fields at struct end)
- Test: `test/governor/RiskEnvelope.t.sol` (create; copy the setUp of the nearest existing propose-path test in `test/governor/`)

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Use the same harness/base the existing governor propose tests use.
// Assertions to cover (adapt the propose helper to the local base):

contract RiskEnvelopeTest is /* existing governor test base */ {
    function test_proposeStoresEnvelope() public {
        uint256 pid = _proposeWithEnvelope(1_000e6, 400); // maxCapital 1000 USDC, 4% drawdown
        (uint256 maxCapital, uint16 maxDrawdownBps) = governor.getRiskEnvelope(pid);
        assertEq(maxCapital, 1_000e6);
        assertEq(maxDrawdownBps, 400);
    }

    function test_proposeRevertsOnZeroMaxCapital() public {
        vm.expectRevert(ISyndicateGovernor.ZeroMaxCapital.selector);
        _proposeWithEnvelope(0, 400);
    }

    function test_proposeRevertsOnDrawdownOver100Pct() public {
        vm.expectRevert(ISyndicateGovernor.InvalidDrawdown.selector);
        _proposeWithEnvelope(1_000e6, 10_001);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-contract RiskEnvelopeTest -vv`
Expected: compilation failure — `RiskEnvelope` / `getRiskEnvelope` undefined.

- [ ] **Step 3: Implement**

In `ISyndicateGovernor.sol`, next to `propose`:

```solidity
    /// @notice Per-proposal risk envelope (spec 2026-07-22 §3.1).
    /// @param maxCapital   Net-outflow ceiling for the execute batch, enforced
    ///                     by the vault at custody level. Nonzero.
    /// @param maxDrawdownBps Declared drawdown envelope; losses beyond it are
    ///                     challengeable (Plan C). <= 10_000.
    struct RiskEnvelope {
        uint256 maxCapital;
        uint16 maxDrawdownBps;
    }

    error ZeroMaxCapital();
    error InvalidDrawdown();

    function getRiskEnvelope(uint256 proposalId) external view returns (uint256 maxCapital, uint16 maxDrawdownBps);
```

Add `RiskEnvelope calldata envelope` as the parameter after `strategyDuration` in `propose` (interface + implementation). In `SyndicateGovernor.propose`, after the `MAX_METADATA_URI_LENGTH` check (~line 252):

```solidity
        if (envelope.maxCapital == 0) revert ZeroMaxCapital();
        if (envelope.maxDrawdownBps > 10_000) revert InvalidDrawdown();
```

Append to the END of `StrategyProposal` (storage-parity: append-only):

```solidity
        uint256 maxCapital; // risk envelope: net-outflow ceiling (spec §3.1)
        uint16 maxDrawdownBps; // risk envelope: declared drawdown bound
```

In `propose`, alongside the other `p.` writes:

```solidity
        p.maxCapital = envelope.maxCapital;
        p.maxDrawdownBps = envelope.maxDrawdownBps;
```

Implement the view:

```solidity
    /// @inheritdoc ISyndicateGovernor
    function getRiskEnvelope(uint256 proposalId) external view returns (uint256, uint16) {
        StrategyProposal storage p = _proposals[proposalId];
        return (p.maxCapital, p.maxDrawdownBps);
    }
```

- [ ] **Step 4: Fix every existing propose() call site**

Run: `grep -rln "\.propose(" test/ script/` — every call site needs the new param. Add a shared helper in the governor test base (`RiskEnvelope({maxCapital: type(uint256).max, maxDrawdownBps: 10_000})` as the permissive default) so existing tests change mechanically, one line each.

- [ ] **Step 5: Run the full suite**

Run: `forge test`
Expected: all pass (previously-green count unchanged + 3 new).

- [ ] **Step 6: Storage parity + fmt**

Run the repo's storage-parity check (see `.github/workflows` for the exact command) and `forge fmt`.
Expected: parity green — fields were appended, not reordered.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: per-proposal risk envelope (maxCapital, maxDrawdownBps) in propose"
```

---

### Task 4: Net-outflow metering in executeGovernorBatch

**Files:**
- Modify: `src/interfaces/ISyndicateVault.sol` (`executeGovernorBatch`, line ~97)
- Modify: `src/SyndicateVault.sol` (`executeGovernorBatch`, line 420)
- Modify: `src/SyndicateGovernor.sol` (`executeProposal` line 349 → pass `p.maxCapital`; `settleProposal` line 384 → pass `type(uint256).max`; also any emergency-settle path — locate with `grep -rn "executeGovernorBatch" src/`)
- Test: `test/vault/OutflowMetering.t.sol` (create, following existing vault test setup)

- [ ] **Step 1: Write the failing tests**

Write as real tests against the existing vault test harness (mock target that pulls `asset` from the vault inside the batch — mirror how existing `executeGovernorBatch` tests build calls):

```solidity
    function test_batchWithinCapExecutes() public {
        // batch moves 500e6 out; cap 1_000e6 -> succeeds
    }

    function test_batchExceedingCapReverts() public {
        // batch moves 1_500e6 out; cap 1_000e6:
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, 1_500e6, 1_000e6)
        );
    }

    function test_inflowBatchPassesTrivially() public {
        // settle-style batch returning funds must not underflow the metering
        // even with cap 0 (netOut = 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract OutflowMeteringTest -vv`
Expected: compilation failure — new signature/error undefined.

- [ ] **Step 3: Implement**

Interface:

```solidity
    /// @notice The batch's net asset outflow exceeded the proposal's declared
    ///         maxCapital (risk envelope, spec §3.1).
    error MaxNetOutflowExceeded(uint256 netOutflow, uint256 cap);

    function executeGovernorBatch(BatchExecutorLib.Call[] calldata calls, uint256 maxNetOutflow) external;
```

In `SyndicateVault.executeGovernorBatch` (signature gains `uint256 maxNetOutflow`), after the existing `balanceAfter` read (line ~443), before the queue-reserve check:

```solidity
        // Spec 2026-07-22 §3.1: custody-level net-outflow ceiling. Inflow
        // batches (settle) pass trivially; the governor passes the proposal's
        // maxCapital on execute and type(uint256).max on settle paths.
        uint256 netOutflow = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (netOutflow > maxNetOutflow) revert MaxNetOutflowExceeded(netOutflow, maxNetOutflow);
```

Governor call sites:

```solidity
        // executeProposal (line ~377):
        ISyndicateVault(vault).executeGovernorBatch(_loadCalls(_executeCalls, proposalId), proposal.maxCapital);
        // settleProposal (line ~395) and any emergency-settle path:
        ISyndicateVault(proposal.vault).executeGovernorBatch(_loadCalls(_settlementCalls, proposalId), type(uint256).max);
```

- [ ] **Step 4: Fix remaining call sites and run full suite**

Run: `grep -rn "executeGovernorBatch" src/ test/ script/` — update every caller/mock. Then `forge test`.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: enforce risk-envelope maxCapital as net-outflow cap in executeGovernorBatch"
```

---

### Task 5: Tier resolution at propose + required coverage

**Files:**
- Create: `src/interfaces/ITierRegistry.sol`
- Modify: `src/SyndicateGovernor.sol` (`propose`; new `_resolveTier` private; `StrategyProposal` append)
- Modify: `src/interfaces/ISyndicateGovernor.sol` (views + event)
- Modify: wherever `_guardianRegistry` is wired into the governor (locate with `grep -rn "guardianRegistry" src/SyndicateGovernor.sol src/GovernorParameters.sol src/GovernorBeacon.sol`) — wire `tierRegistry` the same way (storage + owner setter + event)
- Test: `test/governor/TierResolution.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
    function test_allCertifiedTier0CallsYieldTier0Coverage() public {
        // certify (mockAdapter, selector) at tier 0, bound 50 bps
        // propose with maxCapital 1_000e6
        // expect: getProposalTier(pid) == 0, getRequiredCoverage(pid) == 5e6 (50 bps of 1000e6)
    }

    function test_oneUncertifiedCallMakesProposalTier2() public {
        // one certified tier-0 call + one unknown selector
        // expect tier 2, requiredCoverage == maxCapital
    }

    function test_zeroTierRegistryAddressDefaultsAllToTier2() public {
        // registry unset -> tier 2, full notional (safe default for existing deployments)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-contract TierResolutionTest -vv`
Expected: compilation failure.

- [ ] **Step 3: Implement**

`src/interfaces/ITierRegistry.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITierRegistry {
    function tierOf(address target, bytes4 selector) external view returns (uint8 tier, uint16 boundBps);
}
```

`StrategyProposal` — append at END (after Task 3's fields):

```solidity
        uint8 envelopeTier; // max tier across execute calls at propose (spec §3.2)
        uint256 requiredCoverage; // extractable-weighted coverage demand (Plan B consumes)
```

In `SyndicateGovernor`, private helper (memory params so Task 6 can reuse it on loaded calls):

```solidity
    /// @dev Proposal tier = max tier across execute calls; coverage = the
    ///      extractable-weighted demand Plan B's aggregate exposure cap will
    ///      consume. With no registry wired every proposal is tier 2 / full
    ///      notional — strictly the safe default.
    function _resolveTier(BatchExecutorLib.Call[] memory calls, uint256 maxCapital)
        private
        view
        returns (uint8 tier, uint256 coverage)
    {
        address registry = tierRegistry;
        if (registry == address(0)) return (2, maxCapital);
        uint16 maxBoundBps = 0;
        for (uint256 i = 0; i < calls.length; i++) {
            bytes memory d = calls[i].data;
            bytes4 sel;
            if (d.length >= 4) {
                assembly {
                    sel := mload(add(d, 32))
                }
            }
            (uint8 t, uint16 boundBps) = ITierRegistry(registry).tierOf(calls[i].target, sel);
            if (t > tier) tier = t;
            if (boundBps > maxBoundBps) maxBoundBps = boundBps;
        }
        coverage = tier == 2 ? maxCapital : (maxCapital * maxBoundBps) / 10_000;
    }
```

In `propose`, after envelope validation:

```solidity
        (p.envelopeTier, p.requiredCoverage) = _resolveTier(executeCalls, envelope.maxCapital);
```

Views on governor + interface: `getProposalTier(uint256) returns (uint8)`, `getRequiredCoverage(uint256) returns (uint256)` (read the two new fields).

- [ ] **Step 4: Run full suite, storage parity, fmt**

Run: `forge test && forge fmt`
Expected: all pass, parity green (append-only).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: propose-time tier resolution and required coverage from TierRegistry"
```

---

### Task 6: Execute-time tier regression check

**Files:**
- Modify: `src/SyndicateGovernor.sol` (`executeProposal`, line 349)
- Modify: `src/interfaces/ISyndicateGovernor.sol` (error)
- Test: `test/governor/TierResolution.t.sol` (extend)

- [ ] **Step 1: Write the failing test**

```solidity
    function test_executeRevertsWhenTierRegressedSincePropose() public {
        // propose at tier 0 (certified adapter), pass review
        // vm.etch the adapter target to change its codehash (lazy demotion)
        vm.expectRevert(ISyndicateGovernor.TierRegressed.selector);
        governor.executeProposal(pid);
    }

    function test_executeSucceedsWhenTierUnchanged() public {
        // happy path: certified adapter untouched, executeProposal succeeds
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-contract TierResolutionTest -vv`
Expected: FAIL — `TierRegressed` undefined / no check.

- [ ] **Step 3: Implement**

Add `error TierRegressed();` to the interface. In `executeProposal`, before the `executeGovernorBatch` call (line ~377):

```solidity
        // Spec §3.2: fail-safe on stale certification. A proposal priced at
        // tier 0/1 whose adapter demoted (codehash change, revocation) since
        // propose is under-covered — block execution rather than run a
        // possibly-unbounded batch against a bounded-tier coverage price.
        (uint8 liveTier,) = _resolveTier(_loadCalls(_executeCalls, proposalId), proposal.maxCapital);
        if (liveTier > proposal.envelopeTier) revert TierRegressed();
```

- [ ] **Step 4: Run full suite + fmt**

Run: `forge test && forge fmt`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: execute-time tier regression check (fail-safe on stale certification)"
```

---

### Task 7: Reference certification + end-to-end lifecycle test

**Files:**
- Read first: `src/adapters/UniswapSwapAdapter.sol` — verify it enforces a min-out. If the min-out is caller-supplied calldata (not oracle-checked on-chain), certify at tier 1 ONLY with a documented rationale (the min-out is part of the proposal calldata guardians price); otherwise leave tier 2 and record that in the test comments.
- Create: `test/integration/TierEndToEnd.t.sol`
- Modify: the deploy script that wires governor params (locate with `grep -rln "guardianRegistry" script/`) — add TierRegistry deploy + wiring.

- [ ] **Step 1: Write the end-to-end tests**

Full lifecycle at both tiers against the real adapter:

```solidity
    function test_e2e_tier2UnknownAdapterFullNotionalCoverage() public {
        // propose swap through UNCERTIFIED adapter -> tier 2, requiredCoverage == maxCapital
        // execute within maxCapital -> succeeds; batch exceeding it -> MaxNetOutflowExceeded
    }

    function test_e2e_certifiedAdapterReducedCoverage() public {
        // owner certifies (adapter, swap-selector) tier 1 bound 100 bps
        // same proposal -> tier 1, requiredCoverage == 1% of maxCapital
        // vm.etch adapter -> executeProposal reverts TierRegressed
    }
```

- [ ] **Step 2: Run, wire deploy gaps, iterate until green**

Run: `forge test --match-contract TierEndToEnd -vv`
Expected: pass after deploy-script wiring.

- [ ] **Step 3: Full suite + fmt + storage parity**

Run: `forge test && forge fmt`
Expected: everything green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: e2e tier lifecycle test + TierRegistry deploy wiring"
```

---

## Explicitly OUT of Plan A (comes next)

- **Plan B:** aggregate exposure cap — GuardianRegistry consumes `getRequiredCoverage` at `voteOnProposal` (approve side), per-tier `k` params, unstake-queue earmark of open exposure in StakedWood.
- **Plan C:** challenge game (predicates, bonds, per-proposal freeze), two-layer adjudication (panel + WOOD-vote appeal with pre-exploit snapshot), submitter bond escrow, slash-to-victims routing.
- Per-adapter valuation guards beyond codehash (balance-delta invariant with manipulation-resistant TWAP, oracle staleness, `paused()` probes) — per-adapter engineering; the first concrete instance ships with the first real tier-0 certification.

## Self-review notes

- Spec coverage: §3.1 → Tasks 3–4; §3.2 tier table + codehash + default-deny → Tasks 1–2, 5–6; §3.2 oracle-health/divergence checks → deferred to first tier-0 certification (documented above); spec §4 v1 items 1–2 → this plan; items 3–5 → Plans B/C.
- Type consistency: `tierOf` returns `(uint8, uint16)` everywhere; `RiskEnvelope` fields `(uint256, uint16)`; `requiredCoverage` is `uint256` in asset units; `_resolveTier` takes `memory` from day one so propose (calldata auto-copies) and execute (loaded from storage) share it.
- Known friction: `propose()` signature change touches many tests — Task 3 Step 4 handles it via a permissive default-envelope helper; `executeGovernorBatch` signature change touches mocks — Task 4 Step 4 greps all call sites.
