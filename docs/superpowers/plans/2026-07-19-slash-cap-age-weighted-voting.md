# Slash Cap + Age-Weighted Voting + Deterministic Severity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap delegator slash exposure at `maxDelegatedSlashBps` with first-loss spill onto guardian stake, age-weight guardian voting power (linear discount-to-par), and replace the blocker-voted slash median with a deterministic decisiveness formula.

**Architecture:** All weight/slash changes live in `StakedWood.sol` (params + setters, read-time age factor in `getPastVotes`, `_slashOne` rework). Severity moves to a pure `_severityBps` helper in `GuardianRegistry.sol`, deleting the median machinery and the `slashBps` vote argument. `StakedWoodDelegation.sol` is untouched.

**Tech Stack:** Solidity 0.8.28, Foundry (forge 1.7.1 local — CI-matching fmt), OpenZeppelin upgradeable + Checkpoints.

**Spec:** `docs/superpowers/specs/2026-07-19-slash-cap-age-weighted-voting-design.md`

**Branch:** `feat/slash-cap-age-weighted-voting` (already checked out)

---

## File map

| File | Change |
|---|---|
| `src/StakedWood.sol` | 4 new params + setters + `InitParams` fields; `maxSlashBps` bound relaxed to `<= 10_000`; `_ageFactorBps` helper; aged/capped `getPastVotes`; top-up `stakedAt` average; reset on `requestUnstakeGuardian`; `_slashOne` rework (raw own basis, C cap, spill); delete `voteStake`/`recordVoteStake`; `__gap` 12 → 8 |
| `src/GuardianRegistry.sol` | Drop `slashBps` from `voteOnProposal`; delete `blockerSlashBps` + `_weightedMedianSlashBps`; add `SUPERMAJORITY_BPS` + `_severityBps`; delete `swood.recordVoteStake` mirror calls |
| `src/interfaces/IGuardianRegistry.sol` | `voteOnProposal` signature change |
| `src/StakedWoodDelegation.sol` | **no changes** |
| `script/Deploy.s.sol`, `script/testnet/Deploy.s.sol`, `script/robinhood-testnet/Deploy.s.sol` | New `InitParams` fields + defaults |
| `test/StakedWoodAgeWeight.t.sol` | **new** — Parts B/C tests |
| `test/StakedWoodSlashing.t.sol` | Cap/spill matrix; C-2 tests re-targeted to `maxDelegatedSlashBps`; `maxSlashBps = 10_000` now valid |
| `test/GuardianRegistrySeverity.t.sol` | **new** — Part D formula tests |
| ~20 test files + mocks + invariant handlers | Mechanical: `InitParams` literal sweep, `voteOnProposal` arity sweep |

Constants used throughout (proposed defaults): `maxDelegatedSlashBps = 2_000`, `ageFloorBps = 2_500`, `maturationPeriod = 30 days`, `delegatedWeightCapX = 4`, `SUPERMAJORITY_BPS = 6_667`.

---

### Task 1: New parameters, InitParams, setters, bound relaxation

**Files:**
- Modify: `src/StakedWood.sol` (storage ~`:288`, `InitParams` `:303-321`, `initialize` `:328-349`, setters after `:552`, param keys after `:145`)
- Test: `test/StakedWood.t.sol` (append a params section)

- [ ] **Step 1: Write failing tests for init validation + setters**

Append to `test/StakedWood.t.sol` (follow the file's existing proxy-deploy helper pattern — it constructs `StakedWood.InitParams` literals; use the helper added in Step 3's sweep):

```solidity
function test_initialize_acceptsFullMaxSlash() public {
    // maxSlashBps = 10_000 is now valid (C-2 guard moved to maxDelegatedSlashBps).
    StakedWood w = _deploySWoodWithSlashBounds(1000, 10_000, 2000);
    assertEq(w.maxSlashBps(), 10_000);
}

function test_initialize_revertsDelegatedCapAtFullSlash() public {
    // maxDelegatedSlashBps must stay < 10_000 (pool-brick guard lives here now).
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    _deploySWoodWithSlashBounds(1000, 10_000, 10_000);
}

function test_initialize_revertsDelegatedCapAboveMaxSlash() public {
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    _deploySWoodWithSlashBounds(1000, 5000, 6000); // C > maxSlashBps
}

function test_setMaxDelegatedSlashBps_boundsAndEvent() public {
    vm.prank(owner);
    vm.expectEmit(true, false, false, true);
    emit StakedWood.ParameterChangeFinalized(swood.PARAM_MAX_DELEGATED_SLASH_BPS(), 2000, 1500);
    swood.setMaxDelegatedSlashBps(1500);
    assertEq(swood.maxDelegatedSlashBps(), 1500);

    vm.prank(owner);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setMaxDelegatedSlashBps(10_000); // >= 10_000 rejected

    vm.prank(owner);
    swood.setMaxSlashBps(5000);
    vm.prank(owner);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setMaxDelegatedSlashBps(5001); // > maxSlashBps rejected
}

function test_setAgeParams_bounds() public {
    vm.startPrank(owner);
    swood.setAgeFloorBps(5000);
    assertEq(swood.ageFloorBps(), 5000);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setAgeFloorBps(0);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setAgeFloorBps(10_001);

    swood.setMaturationPeriod(60 days);
    assertEq(swood.maturationPeriod(), 60 days);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setMaturationPeriod(6 days);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setMaturationPeriod(91 days);

    swood.setDelegatedWeightCapX(10);
    assertEq(swood.delegatedWeightCapX(), 10);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setDelegatedWeightCapX(0);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setDelegatedWeightCapX(21);
    vm.stopPrank();
}

function test_setMaxSlashBps_allowsFullAndGuardsDelegatedCap() public {
    vm.startPrank(owner);
    swood.setMaxSlashBps(10_000); // now legal
    assertEq(swood.maxSlashBps(), 10_000);
    // Lowering maxSlashBps below current C must revert (keeps C <= maxSlashBps).
    swood.setMaxDelegatedSlashBps(3000);
    vm.expectRevert(StakedWood.InvalidParameter.selector);
    swood.setMaxSlashBps(2999);
    vm.stopPrank();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-path test/StakedWood.t.sol --match-test "test_initialize_acceptsFullMaxSlash|test_setMaxDelegatedSlashBps|test_setAgeParams|test_setMaxSlashBps_allowsFull" -vv`
Expected: compile FAIL (`maxDelegatedSlashBps` undeclared) — that is the failing state for storage-level changes.

- [ ] **Step 3: Implement storage, InitParams, initialize, setters**

In `src/StakedWood.sol`:

Param keys (after `PARAM_MAX_SLASH_BPS`, line ~145):

```solidity
    /// @notice Parameter key for `maxDelegatedSlashBps`.
    bytes32 public constant PARAM_MAX_DELEGATED_SLASH_BPS = keccak256("maxDelegatedSlashBps");

    /// @notice Parameter key for `ageFloorBps`.
    bytes32 public constant PARAM_AGE_FLOOR_BPS = keccak256("ageFloorBps");

    /// @notice Parameter key for `maturationPeriod`.
    bytes32 public constant PARAM_MATURATION_PERIOD = keccak256("maturationPeriod");

    /// @notice Parameter key for `delegatedWeightCapX`.
    bytes32 public constant PARAM_DELEGATED_WEIGHT_CAP_X = keccak256("delegatedWeightCapX");
```

Storage (after `maxSlashBps`, line ~268; decrement `__gap` 12 → 8 and update its comment):

```solidity
    /// @notice Per-incident ceiling (bps) on the delegated + unbonding pool
    ///         slash. The pool legs of `_slashOne` are sized by
    ///         `min(slashBps, maxDelegatedSlashBps)`; the uncovered remainder
    ///         spills onto the approver's own stake (first-loss bond).
    /// @dev Strictly `< 10_000` — this is where the C-2 pool-bricking guard
    ///      lives now: a 100% pool slash zeroes `poolTokens` while
    ///      `poolShares` stay nonzero, bricking `delegateStake` with a
    ///      `Math.mulDiv` divide-by-zero. `maxSlashBps` itself may be 10_000
    ///      (own stake is a plain integer, no share math).
    uint256 public maxDelegatedSlashBps;

    /// @notice Vote-weight fraction (bps) of raw own stake at age 0.
    uint256 public ageFloorBps;

    /// @notice Stake age at which own-stake weight reaches par (100%).
    uint256 public maturationPeriod;

    /// @notice Max delegated vote weight as a multiple of AGED own weight.
    uint256 public delegatedWeightCapX;
```

`InitParams` — append fields:

```solidity
        /// @dev Per-incident delegated-slash ceiling (bps, < 10_000).
        uint256 maxDelegatedSlashBps;
        /// @dev Own-stake weight fraction at age 0 (bps, [1, 10_000]).
        uint256 ageFloorBps;
        /// @dev Age at which own-stake weight reaches par ([7, 90] days).
        uint256 maturationPeriod;
        /// @dev Delegated-weight cap multiple over aged own weight ([1, 20]).
        uint256 delegatedWeightCapX;
```

`initialize` — replace the slash-bounds check and add new validation:

```solidity
        // Severity ceiling may be a full 100% (own stake is a plain integer).
        // The C-2 pool-bricking guard lives on `maxDelegatedSlashBps` below.
        if (p.minSlashBps > p.maxSlashBps || p.maxSlashBps > 10_000) {
            revert InvalidParameter();
        }
        minSlashBps = p.minSlashBps;
        maxSlashBps = p.maxSlashBps;
        // C-2 guard: pool legs are sized by `min(S, C)`, so C < 10_000 keeps
        // at least 1 wei in every slashed pool.
        if (p.maxDelegatedSlashBps > p.maxSlashBps || p.maxDelegatedSlashBps >= 10_000) {
            revert InvalidParameter();
        }
        maxDelegatedSlashBps = p.maxDelegatedSlashBps;
        if (p.ageFloorBps == 0 || p.ageFloorBps > 10_000) revert InvalidParameter();
        ageFloorBps = p.ageFloorBps;
        if (p.maturationPeriod < 7 days || p.maturationPeriod > 90 days) revert InvalidParameter();
        maturationPeriod = p.maturationPeriod;
        if (p.delegatedWeightCapX == 0 || p.delegatedWeightCapX > 20) revert InvalidParameter();
        delegatedWeightCapX = p.delegatedWeightCapX;
```

Setters (after `setMaxSlashBps`; also update `setMaxSlashBps` itself):

```solidity
    /// @notice Set the upper clamp bound for the slash severity.
    /// @dev Owner-only. `10_000` (100%) is legal for the OWN-stake ceiling;
    ///      the pool-bricking guard lives on `maxDelegatedSlashBps`. Must
    ///      keep `minSlashBps <= maxSlashBps` and `maxDelegatedSlashBps <=
    ///      maxSlashBps`.
    function setMaxSlashBps(uint256 v) external onlyOwner {
        if (v < minSlashBps || v > 10_000 || v < maxDelegatedSlashBps) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MAX_SLASH_BPS, maxSlashBps, v);
        maxSlashBps = v;
    }

    /// @notice Set the per-incident delegated-slash ceiling.
    /// @dev Owner-only. Strict `< 10_000` is the relocated C-2 pool-bricking
    ///      guard; also bounded by `maxSlashBps` so the spill term
    ///      `S - min(S, C)` is never negative-by-config.
    function setMaxDelegatedSlashBps(uint256 v) external onlyOwner {
        if (v >= 10_000 || v > maxSlashBps) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MAX_DELEGATED_SLASH_BPS, maxDelegatedSlashBps, v);
        maxDelegatedSlashBps = v;
    }

    /// @notice Set the age-0 weight floor.
    function setAgeFloorBps(uint256 v) external onlyOwner {
        if (v == 0 || v > 10_000) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_AGE_FLOOR_BPS, ageFloorBps, v);
        ageFloorBps = v;
    }

    /// @notice Set the age at which own-stake weight reaches par.
    function setMaturationPeriod(uint256 v) external onlyOwner {
        if (v < 7 days || v > 90 days) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MATURATION_PERIOD, maturationPeriod, v);
        maturationPeriod = v;
    }

    /// @notice Set the delegated-weight cap multiple.
    function setDelegatedWeightCapX(uint256 v) external onlyOwner {
        if (v == 0 || v > 20) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_DELEGATED_WEIGHT_CAP_X, delegatedWeightCapX, v);
        delegatedWeightCapX = v;
    }
```

- [ ] **Step 4: Sweep every `StakedWood.InitParams` literal**

`grep -rln "StakedWood.InitParams({" src/ script/ test/` — every literal gains the four fields. Use these values:

- `script/Deploy.s.sol` (~line 315): add constants near `DEFAULT_MAX_SLASH_BPS` (line ~102) —
  ```solidity
  uint256 constant DEFAULT_MAX_DELEGATED_SLASH_BPS = 2000; // 20%
  uint256 constant DEFAULT_AGE_FLOOR_BPS = 2500; // 25%
  uint256 constant DEFAULT_MATURATION_PERIOD = 30 days;
  uint256 constant DEFAULT_DELEGATED_WEIGHT_CAP_X = 4;
  ```
  and change `DEFAULT_MAX_SLASH_BPS` to `10_000; // 100% — pool guard lives on maxDelegatedSlashBps`. Pass all four in the literal.
- `script/testnet/Deploy.s.sol` (~line 94) and `script/robinhood-testnet/Deploy.s.sol` (~line 87): same fields, values `maxDelegatedSlashBps: 2000, ageFloorBps: 2500, maturationPeriod: 30 days, delegatedWeightCapX: 4`, and bump `maxSlashBps: 9999` → `10_000`. Update each script's `_checkUint` verification block to match.
- Tests (~20 files): keep existing `maxSlashBps: 9999` values where present (still legal) and add `maxDelegatedSlashBps: 2000, ageFloorBps: 2500, maturationPeriod: 30 days, delegatedWeightCapX: 4`. In `test/StakedWood.t.sol` add the helper used by Step 1:
  ```solidity
  function _deploySWoodWithSlashBounds(uint256 lo, uint256 hi, uint256 cap) internal returns (StakedWood) {
      // clone the file's existing proxy-deploy helper, overriding
      // minSlashBps/maxSlashBps/maxDelegatedSlashBps with lo/hi/cap.
  }
  ```

  NOTE: `test/StakedWoodSlashing.t.sol:813` has a C-2 test asserting `initialize` with `maxSlashBps = 10_000` REVERTS — invert it: 10_000 now succeeds; add the sibling assertion that `maxDelegatedSlashBps = 10_000` reverts (Step 1 already covers this at unit level; keep the file's end-to-end variant consistent).

- [ ] **Step 5: Build + run the new tests**

Run: `forge build && forge test --match-path "test/StakedWood*.t.sol" -vv`
Expected: Step 1 tests PASS; pre-existing suite still green (age params exist but nothing reads them yet).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(swood): slash-cap + age-weight params, relax maxSlashBps to 100%"
```

---

### Task 2: Age factor + aged own weight in vote reads (Part B read path)

**Files:**
- Modify: `src/StakedWood.sol` (`getPastVotes` `:438-442`, new `_ageFactorBps` helper next to it)
- Create: `test/StakedWoodAgeWeight.t.sol`

- [ ] **Step 1: Write failing tests**

`test/StakedWoodAgeWeight.t.sol` — new file; copy the deploy/setup scaffolding from `test/StakedWood.t.sol` (owner, WOOD mock, proxy deploy with Task 1 defaults: floor 2500, maturation 30 days), one guardian `alice` staking `100e18`:

```solidity
function test_ageWeight_floorAtStake() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    // Same-block read: age 0 → floor 25%.
    assertEq(swood.getVotes(alice), 25e18);
}

function test_ageWeight_linearMidpoint() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    skip(15 days); // half maturation → 25% + 75%/2 = 62.5%
    assertEq(swood.getVotes(alice), 62.5e18);
}

function test_ageWeight_parAtMaturationAndBeyond() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    skip(30 days);
    assertEq(swood.getVotes(alice), 100e18);
    skip(300 days); // plateau — never exceeds par
    assertEq(swood.getVotes(alice), 100e18);
}

function test_ageWeight_pastReadUsesRequestedTimestamp() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    uint256 t0 = block.timestamp;
    skip(30 days);
    // Past read at t0 + 15d computes age from stakedAt to THAT timestamp.
    assertEq(swood.getPastVotes(alice, t0 + 15 days), 62.5e18);
}

function test_ageWeight_totalsStayRaw() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    // Quorum denominator is deliberately un-aged (spec Part C).
    assertEq(swood.getPastTotalVotes(block.timestamp), 100e18);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/StakedWoodAgeWeight.t.sol -vv`
Expected: FAIL — `getVotes` returns `100e18` (raw) where `25e18` expected.

- [ ] **Step 3: Implement `_ageFactorBps` + aged own term**

In `src/StakedWood.sol`, add above `getPastVotes`:

```solidity
    /// @dev Linear discount-to-par age factor (bps of raw stake). Weight
    ///      ramps from `ageFloorBps` at age 0 to 10_000 (par) at
    ///      `maturationPeriod`, then plateaus — never exceeds raw stake, so
    ///      the raw checkpointed totals remain a valid (conservative) quorum
    ///      denominator. `ts < stakedAt_` (a past read after a forward
    ///      re-anchor) saturates to age 0 — drift is deflation-only.
    function _ageFactorBps(uint64 stakedAt_, uint256 ts) internal view returns (uint256) {
        if (stakedAt_ == 0) return ageFloorBps; // never staked in this era
        uint256 age = ts > stakedAt_ ? ts - uint256(stakedAt_) : 0;
        uint256 m = maturationPeriod;
        if (age >= m) return 10_000;
        return ageFloorBps + ((10_000 - ageFloorBps) * age) / m;
    }
```

Replace `getPastVotes` (delegated cap comes in Task 4 — keep the flat delegated term for now):

```solidity
    function getPastVotes(address guardian, uint256 timestamp) public view returns (uint256) {
        uint256 rawOwn = _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp));
        uint256 agedOwn = rawOwn * _ageFactorBps(_guardians[guardian].stakedAt, timestamp) / 10_000;
        return agedOwn + getPastDelegatedInbound(guardian, timestamp);
    }
```

Update the function's natspec: votes = AGE-WEIGHTED own checkpointed stake + delegated inbound; totals (`getPastTotalVotes`, `getPastTotalSupply`) deliberately stay raw (conservative denominator — spec §5 of `2026-07-19-slash-cap-age-weighted-voting-design.md`).

- [ ] **Step 4: Run tests**

Run: `forge test --match-path test/StakedWoodAgeWeight.t.sol -vv`
Expected: PASS.

- [ ] **Step 5: Repair pre-existing weight assertions**

Run: `forge test -vv 2>&1 | grep -E "FAIL" | head -40`

Many existing tests assert `getVotes == staked amount` right after staking. Repair pattern — prefer `skip(30 days)` (or the suite's maturation constant) after staking in setup helpers so guardians vote at par, UNLESS the test specifically targets young-stake behavior. `test/helpers/RegistryTestHarness.sol` and governor/registry suites stake in `setUp` — add the skip there once rather than per-test.

- [ ] **Step 6: Full suite green, commit**

Run: `forge test`
Expected: PASS (0 failures).

```bash
git add -A && git commit -m "feat(swood): age-weighted own-stake voting (linear discount-to-par)"
```

---

### Task 3: `stakedAt` lifecycle — top-up average + reset on unstake request

**Files:**
- Modify: `src/StakedWood.sol` (`stakeAsGuardian` `:389-427`, `requestUnstakeGuardian` `:560-587`)
- Test: `test/StakedWoodAgeWeight.t.sol`

- [ ] **Step 1: Write failing tests**

```solidity
function test_topUp_weightedAverageAge() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    skip(30 days); // fully matured
    vm.prank(alice);
    swood.stakeAsGuardian(300e18, 1); // top-up 3x at age 0
    // Weighted stakedAt = (100 * t0 + 300 * t30) / 400 → 22.5 days ago.
    // ageFactor = 2500 + 7500 * 22.5/30 = 8125 → weight = 400e18 * 0.8125.
    assertEq(swood.getVotes(alice), 325e18);
}

function test_topUp_roundsTowardNow() public {
    vm.prank(alice);
    swood.stakeAsGuardian(1, 1); // 1 wei aged
    skip(30 days);
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1); // whale top-up
    // Average is ~now (ceil): the whale position must NOT inherit the wei's age.
    // Weight ≈ floor. Allow tiny tolerance for 1s of age.
    uint256 w = swood.getVotes(alice);
    uint256 floorW = (100e18 + 1) * 2500 / 10_000;
    assertLe(w, floorW + 1e15);
}

function test_requestUnstake_resetsAgeClock() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    skip(30 days);
    vm.prank(alice);
    swood.requestUnstakeGuardian();
    skip(1 days);
    vm.prank(alice);
    swood.cancelUnstakeGuardian();
    // Clock restarted at request time → age 1 day, not 31 days.
    // ageFactor = 2500 + 7500 * 1/30 = 2750.
    assertEq(swood.getVotes(alice), 100e18 * 2750 / 10_000);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/StakedWoodAgeWeight.t.sol --match-test "test_topUp|test_requestUnstake_resets" -vv`
Expected: FAIL — top-up keeps original `stakedAt` (weight too high), request/cancel keeps 31-day age.

- [ ] **Step 3: Implement lifecycle writes**

`stakeAsGuardian` — replace the `if (wasInactive)` stakedAt block (mind ordering: compute the average with the OLD `g.stakedAmount` BEFORE writing `newTotal` into the struct):

```solidity
        bool wasInactive = g.stakedAmount == 0;
        if (wasInactive) {
            g.stakedAt = uint64(block.timestamp);
            g.agentId = agentId; // recorded once; ignored on top-ups
        } else {
            // Weighted-average age re-anchor (spec Part B): a top-up ages in
            // pro-rata instead of inheriting the old tranche's full age.
            // Ceil-divide so rounding moves toward `now` — never grants age.
            uint256 num =
                uint256(g.stakedAmount) * uint256(g.stakedAt) + amount * block.timestamp;
            // forge-lint: disable-next-line(unchecked-cast)
            g.stakedAt = uint64((num + newTotal - 1) / newTotal);
        }
        g.stakedAmount = uint128(newTotal);
```

`requestUnstakeGuardian` — after `g.unstakeRequestedAt = uint64(block.timestamp);` add:

```solidity
        // Age clock resets at exit-signal time (spec Part B): a request →
        // cancel round-trip restarts maturation; no free age-parking while
        // the stake is unvotable.
        g.stakedAt = uint64(block.timestamp);
```

- [ ] **Step 4: Run tests**

Run: `forge test --match-path test/StakedWoodAgeWeight.t.sol -vv`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `forge test`
Expected: PASS. Repair any cancel-flow tests assuming preserved weight (add `skip`).

```bash
git add -A && git commit -m "feat(swood): stakedAt top-up average + reset on unstake request"
```

---

### Task 4: Delegated-weight cap (Part C)

**Files:**
- Modify: `src/StakedWood.sol` (`getPastVotes` from Task 2)
- Test: `test/StakedWoodAgeWeight.t.sol`

- [ ] **Step 1: Write failing tests**

Setup: enable delegation (`vm.prank(owner); swood.setDelegationEnabled(true);`), delegator `bob` with WOOD approved.

```solidity
function test_delegatedWeight_cappedAtKTimesAgedOwn() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    skip(30 days); // alice at par: agedOwn = 100e18
    vm.prank(bob);
    swood.delegateStake(alice, 1000e18); // raw inbound 1000e18
    // cap = 4 * 100e18 = 400e18 → total = 100 + 400.
    assertEq(swood.getVotes(alice), 500e18);
}

function test_delegatedWeight_underCapCountsFlat() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1);
    skip(30 days);
    vm.prank(bob);
    swood.delegateStake(alice, 300e18); // under 400e18 cap
    assertEq(swood.getVotes(alice), 400e18);
}

function test_delegatedWeight_capScalesWithAge() public {
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1); // age 0: agedOwn = 25e18
    vm.prank(bob);
    swood.delegateStake(alice, 1000e18);
    // cap = 4 * 25e18 = 100e18 → total = 125e18. Aging is NOT bypassable
    // via delegation (spec Part C, aged cap base).
    assertEq(swood.getVotes(alice), 125e18);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/StakedWoodAgeWeight.t.sol --match-test test_delegatedWeight -vv`
Expected: FAIL — flat delegated term (1100e18 where 500e18 expected).

- [ ] **Step 3: Implement the cap**

Final `getPastVotes`:

```solidity
    function getPastVotes(address guardian, uint256 timestamp) public view returns (uint256) {
        uint256 rawOwn = _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp));
        uint256 agedOwn = rawOwn * _ageFactorBps(_guardians[guardian].stakedAt, timestamp) / 10_000;
        uint256 delegated = getPastDelegatedInbound(guardian, timestamp);
        // Delegated weight is capped at k × AGED own weight: the cap base
        // being aged means delegation cannot bypass maturation, and a
        // zero-own (or unstake-requested → 0-checkpoint) guardian carries no
        // delegated weight. The cap bounds VOTING POWER only — the pool's
        // slashable base stays the raw inbound snapshot (spec §5).
        uint256 cap = delegatedWeightCapX * agedOwn;
        return agedOwn + Math.min(delegated, cap);
    }
```

- [ ] **Step 4: Run tests**

Run: `forge test --match-path test/StakedWoodAgeWeight.t.sol -vv`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `forge test`
Expected: PASS. Delegation-weight tests in `test/StakedWoodDelegation.t.sol` asserting flat `own + inbound` may need the k-cap applied to expectations (most stake small inbound relative to own — check failures individually).

```bash
git add -A && git commit -m "feat(swood): cap delegated vote weight at k x aged own weight"
```

---

### Task 5: `_slashOne` rework — raw own basis, C cap, first-loss spill (Part A)

**Files:**
- Modify: `src/StakedWood.sol` (`_slashOne` `:898-1021`; delete `voteStake` `:277` + `recordVoteStake` `:843-845`)
- Modify: `src/GuardianRegistry.sol` (delete the three `swood.recordVoteStake(...)` mirror calls at `:374`, `:400`, `:409`)
- Test: `test/StakedWoodSlashing.t.sol`

- [ ] **Step 1: Write failing tests**

Append to `test/StakedWoodSlashing.t.sol` (use its existing registry-caller harness; `C = 2000` from Task 1 defaults). The suite's slash entry is `slashGuardians(key, openedAt, approvers, slashBps)` pranked as registry:

```solidity
function test_slash_belowCap_noSpill() public {
    // alice: 100e18 own; bob delegates 100e18. S = 1500 < C = 2000.
    _stakeAndDelegate(alice, 100e18, bob, 100e18);
    uint256 openedAt = block.timestamp;
    _slash(alice, openedAt, 1500);
    assertEq(swood.guardianStake(alice), 85e18);   // 15% own
    assertEq(swood.poolTokens(alice), 85e18);      // 15% pool — cap idle
}

function test_slash_aboveCap_spillCoveredByOwnStake() public {
    // alice: 100e18 own; bob delegates 100e18. S = 5000, C = 2000.
    _stakeAndDelegate(alice, 100e18, bob, 100e18);
    uint256 openedAt = block.timestamp;
    _slash(alice, openedAt, 5000);
    // own base = 50e18; pool pays min(S,C) = 20% → 20e18;
    // excess = (5000-2000) bps of 100e18 = 30e18 → spills to own.
    assertEq(swood.poolTokens(alice), 80e18);
    assertEq(swood.guardianStake(alice), 100e18 - 50e18 - 30e18); // 20e18
}

function test_slash_spillClampedAtRemainingOwnStake() public {
    // alice: 10e18 own; bob delegates 1000e18 (sybil shape). S = 9000.
    _stakeAndDelegate(alice, 10e18, bob, 1000e18);
    uint256 openedAt = block.timestamp;
    _slash(alice, openedAt, 9000);
    // own base = 9e18, remaining 1e18; excess = 70% of 1000e18 = 700e18
    // → clamped to 1e18. Own stake fully wiped; pool pays 20%.
    assertEq(swood.guardianStake(alice), 0);
    assertEq(swood.poolTokens(alice), 800e18);
}

function test_slash_fullSeverity_poolsSurvive() public {
    // maxSlashBps = 10_000 end-to-end: own wiped, pools clamped at C,
    // share math stays alive (C-2 regression moved to the C bound).
    _stakeAndDelegate(alice, 100e18, bob, 100e18);
    uint256 openedAt = block.timestamp;
    _slash(alice, openedAt, 10_000);
    assertEq(swood.guardianStake(alice), 0);
    assertEq(swood.poolTokens(alice), 80e18);
    assertGt(swood.poolShares(alice), 0);
    // Share path stays functional: bob can still request-unstake and the
    // redeem math must not divide by zero.
    vm.prank(bob);
    swood.requestUnstakeDelegation(alice);
}

function test_slash_ownBasisIsRawCheckpointNotAgedWeight() public {
    // Young guardian: aged weight 25% but slash liability is RAW stake.
    vm.prank(alice);
    swood.stakeAsGuardian(100e18, 1); // age 0
    uint256 openedAt = block.timestamp;
    _slash(alice, openedAt, 5000);
    assertEq(swood.guardianStake(alice), 50e18); // 50% of RAW 100e18
}
```

(`_stakeAndDelegate` / `_slash` — add tiny local helpers if the harness lacks them: stake as guardian, enable delegation, delegate, then `vm.prank(registry); swood.slashGuardians(key, openedAt, [alice], bps)`.)

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/StakedWoodSlashing.t.sol --match-test "test_slash_belowCap|test_slash_aboveCap|test_slash_spill|test_slash_fullSeverity|test_slash_ownBasis" -vv`
Expected: FAIL — pool slashed at S (not C), no spill, own basis reads `voteStake` snapshot (0 when not recorded).

- [ ] **Step 3: Rework `_slashOne`**

Replace `src/StakedWood.sol:_slashOne` with:

```solidity
    function _slashOne(bytes32 reviewKey, uint256 openedAt, address approver, uint256 slashBps)
        private
        returns (uint256 amt)
    {
        Guardian storage g = _guardians[approver];
        uint256 live = g.stakedAmount;
        // Sherlock #39 / Run-1 #22: snapshot pre-slash active state + pool
        // so the active-delegated adjustment can pick the right delta.
        bool wasActive = live > 0 && g.unstakeRequestedAt == 0;
        uint256 oldPool = poolTokens[approver];

        // Own-slash basis: the RAW own-stake checkpoint at openedAt, read
        // directly. Age discounts VOTING POWER, not liability — the capital
        // at risk is the staked amount (spec 2026-07-19 §5). Replaces the
        // old voteStake-minus-delegated derivation.
        uint256 snapOwnRaw = _stakeCheckpoints[approver].upperLookupRecent(uint32(openedAt));
        uint256 snapDelegated = getPastDelegatedInbound(approver, openedAt);
        uint256 ownSlash = Math.mulDiv(Math.min(snapOwnRaw, live), slashBps, 10_000);

        // Delegated legs capped at C = maxDelegatedSlashBps (spec Part A).
        // Budget basis mirrors the PR #351/#359 mechanics: at-open exposure,
        // live-pool-first, remainder to the unbonding pool. snapDelegated == 0
        // keeps the uninformative-snapshot fallback (full live + unbonding
        // pools), now at the capped rate.
        uint256 poolBps = Math.min(slashBps, maxDelegatedSlashBps);
        uint256 delSlashBasis;
        uint256 unbondBasis;
        if (snapDelegated == 0) {
            delSlashBasis = oldPool;
            unbondBasis = unbondingPoolTokens[approver];
        } else {
            delSlashBasis = Math.min(snapDelegated, oldPool);
            unbondBasis = Math.min(snapDelegated - delSlashBasis, unbondingPoolTokens[approver]);
        }
        uint256 delSlash = Math.mulDiv(delSlashBasis, poolBps, 10_000);
        uint256 unbondSlash = Math.mulDiv(unbondBasis, poolBps, 10_000);

        // First-loss spill (spec Part A): the delegated damage the cap
        // absorbed is charged to the approver's remaining own stake — the
        // guardian bond backs the delegated book (Rocket Pool pattern; also
        // closes the LIP-10 self-delegation shield).
        uint256 spillBasis =
            snapDelegated == 0 ? oldPool + unbondingPoolTokens[approver] : snapDelegated;
        uint256 spill = Math.mulDiv(spillBasis, slashBps - poolBps, 10_000);
        uint256 ownRemaining = live - ownSlash;
        if (spill > ownRemaining) spill = ownRemaining;
        uint256 ownDebit = ownSlash + spill;

        if (ownDebit != 0) {
            // forge-lint: disable-next-line(unchecked-cast)
            // Safe-by-construction: ownDebit <= live (both terms clamped),
            // and `live` originates from the uint128 stakedAmount field.
            g.stakedAmount = uint128(live - ownDebit);
            if (g.unstakeRequestedAt == 0) {
                totalGuardianStake -= ownDebit;
                _stakeCheckpoints[approver].push(uint32(block.timestamp), uint224(g.stakedAmount));
            } else if (g.stakedAmount == 0) {
                // Fully slashed while unstake-requested: clear the stamp so
                // cancelUnstakeGuardian can't resurrect a ghost guardian.
                g.unstakeRequestedAt = 0;
            }
        }
        if (delSlash != 0) {
            poolTokens[approver] -= delSlash;
            totalDelegatedStake -= delSlash;
            _pushDelegationCheckpoints(address(0), approver); // re-checkpoint pool aggregates
        }
        // Sherlock #39 / Run-1 #22: active-delegated adjustment on the
        // (wasActive, nowActive) transition — unchanged logic.
        if (wasActive) {
            bool nowActive = g.stakedAmount > 0 && g.unstakeRequestedAt == 0;
            if (nowActive) {
                if (delSlash != 0) _writeActiveDelegated(totalActiveDelegatedStake - delSlash);
            } else if (oldPool != 0) {
                _writeActiveDelegated(totalActiveDelegatedStake - oldPool);
            }
        }
        // I-1 unbonding-escrow slash at the capped rate. No checkpoint /
        // totalDelegatedStake decrement — the unbonding pool is not votable.
        if (unbondSlash != 0) {
            unbondingPoolTokens[approver] -= unbondSlash;
        }
        amt = ownDebit + delSlash + unbondSlash;
        // ownSlash in the event = base + spill (total own-stake hit).
        if (amt != 0) {
            emit GuardianSlashed(reviewKey, approver, ownDebit, delSlash + unbondSlash);
        }
    }
```

Preserve the surviving Sherlock/PR provenance comments as shown; the PR #359 review #4 LIMIT comment block (per-delegator isolation impossibility) stays relevant — keep it near the delegated-basis computation.

Delete from `src/StakedWood.sol`: the `voteStake` mapping (`:277`) and `recordVoteStake` (`:843-845`) — dead once nothing sizes off them. Delete the three `swood.recordVoteStake(...)` calls in `src/GuardianRegistry.sol` (`voteOnProposal` `:374`, `:400`, `:409`) plus the natspec sentences referencing the mirror. The registry's own `_voteStake` mapping STAYS (Merkl attribution reads it via `getApproverWeights`).

Sweep stale references: `grep -rn "recordVoteStake\|voteStake" src/ test/ | grep -v "_voteStake"` — update `src/MinimalGuardianRegistry.sol` and `test/mocks/MockStakedWood.sol` hits.

- [ ] **Step 4: Run tests**

Run: `forge test --match-path test/StakedWoodSlashing.t.sol -vv`
Expected: new tests PASS. Pre-existing slash tests derived expectations from `recordVoteStake`-seeded snapshots — amounts are mostly IDENTICAL (raw own checkpoint == old own snapshot in the common case); rewrite the few that set synthetic `recordVoteStake` values against the new raw-checkpoint basis.

- [ ] **Step 5: Full suite + commit**

Run: `forge test`
Expected: PASS.

```bash
git add -A && git commit -m "feat(swood): cap delegated slash at C with first-loss spill; raw own-stake slash basis"
```

---

### Task 6: Deterministic severity (Part D)

**Files:**
- Modify: `src/GuardianRegistry.sol` (constant near `:57`; `voteOnProposal` `:338`; `resolveReview` `:686`; delete `blockerSlashBps` `:97-103` + `_weightedMedianSlashBps` `:694-758`)
- Modify: `src/interfaces/IGuardianRegistry.sol:84`
- Create: `test/GuardianRegistrySeverity.t.sol`
- Modify: `test/mocks/MockRegistryMinimal.sol:85`, `test/invariants/handlers/GuardianHandler.sol:295`, `test/invariants/handlers/ProtocolHandler.sol` (~`:137`), every `voteOnProposal(` call site

- [ ] **Step 1: Write failing severity tests**

`test/GuardianRegistrySeverity.t.sol` — scaffold from `test/helpers/RegistryTestHarness.sol` (it drives open → vote → warp → resolve). Guardians must `skip(30 days)` after staking (par weight, Task 2). Read the harness's configured block quorum into `Q`. min/max slash via InitParams: 1000 / 10_000.

Write a local helper `_runReviewWithBlockFraction(uint256 bps)`: stake one approver and one blocker sized so `blockerWeight * 10_000 / (totalStakeAtOpen + totalDelegatedAtOpen) == bps` (no delegation → denominator is total guardian stake; BOTH voters' stakes count in it), drive open → both vote → warp past `reviewEnd` → `resolveReview`.

```solidity
function test_severity_floorAtScrapedQuorum() public {
    // Block weight lands ~at quorum → severity = minSlashBps (10%).
    _runReviewWithBlockFraction(Q);
    assertEq(swood.guardianStake(approver1), _initialStake * 9000 / 10_000);
}

function test_severity_ceilingAtSupermajority() public {
    // Block weight >= 2/3 of total → severity = maxSlashBps = 10_000.
    _runReviewWithBlockFraction(6700);
    assertEq(swood.guardianStake(approver1), 0); // full wipe at 100%
}

function test_severity_quadraticMidpoint() public {
    // t = 0.5 between quorum and 6667 → severity = lo + (hi-lo) * 0.25.
    uint256 mid = Q + (6667 - Q) / 2;
    _runReviewWithBlockFraction(mid);
    uint256 expectedBps = 1000 + (10_000 - 1000) * 25 / 100;
    assertApproxEqRel(
        swood.guardianStake(approver1),
        _initialStake * (10_000 - expectedBps) / 10_000,
        0.01e18 // 1% tolerance for stake-sizing rounding
    );
}

function test_severity_degenerateQuorumAboveSupermajority() public {
    // blockQuorumBps >= SUPERMAJORITY_BPS → any successful block is ceiling.
    _setBlockQuorum(7000); // harness owner call to the registry setter
    _runReviewWithBlockFraction(7100);
    assertEq(swood.guardianStake(approver1), 0);
}

function test_vote_blockCarriesNoSeverityArg() public {
    // New 3-arg signature compiles and works end-to-end.
    vm.prank(blocker1);
    registry.voteOnProposal(address(gov), pid, GuardianVoteType.Block);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/GuardianRegistrySeverity.t.sol -vv`
Expected: compile FAIL — `voteOnProposal` still takes 4 args.

- [ ] **Step 3: Implement Part D**

`src/interfaces/IGuardianRegistry.sol:84`:

```solidity
    function voteOnProposal(address governor, uint256 proposalId, GuardianVoteType support) external;
```

`src/GuardianRegistry.sol`:

1. Constant (with the other constants, near `:57`):

```solidity
    /// @notice Block decisiveness (bps of at-open total weight) at which the
    ///         deterministic severity hits `maxSlashBps`. 2/3 supermajority.
    uint256 public constant SUPERMAJORITY_BPS = 6_667;
```

2. Delete the `blockerSlashBps` mapping (`:97-103`) and its two write sites in `voteOnProposal` (`:378`, `:398`). Drop the `slashBps` parameter and its `@param` natspec; update the function natspec: severity is no longer voted — see `_severityBps`.

3. Replace `_weightedMedianSlashBps` (`:694-758`) with:

```solidity
    /// @dev Deterministic slash severity from block-side decisiveness
    ///      (spec 2026-07-19 Part D). Replaces the blocker-voted
    ///      stake-weighted median: the winning side of a review must not
    ///      choose the losers' penalty. Quadratic ramp from the at-open
    ///      block quorum (floor — a scraped quorum is a genuinely contested
    ///      call) to SUPERMAJORITY_BPS (ceiling — overwhelming condemnation).
    ///      Approvers cannot lower it (honest blockers' weight is not theirs
    ///      to remove) and blockers gain nothing by inflating it (slashed
    ///      WOOD burns; blocker rewards are epoch-level, not
    ///      slash-proportional). Only called when the block quorum was
    ///      reached, so bBps >= qBps up to rounding; the bBps <= qBps branch
    ///      floors defensively.
    function _severityBps(Review storage r) private view returns (uint256) {
        uint256 lo = swood.minSlashBps();
        uint256 hi = swood.maxSlashBps();
        uint256 denom = uint256(r.totalStakeAtOpen) + uint256(r.totalDelegatedAtOpen);
        if (denom == 0) return lo; // defensive: a reached quorum implies denom > 0
        uint256 bBps = uint256(r.blockStakeWeight) * 10_000 / denom;
        uint256 qBps = uint256(r.blockQuorumBpsAtOpen);
        if (qBps >= SUPERMAJORITY_BPS || bBps >= SUPERMAJORITY_BPS) return hi;
        if (bBps <= qBps) return lo;
        // t in 1e18 fixed point; severity = lo + (hi - lo) * t^2.
        uint256 t = (bBps - qBps) * 1e18 / (SUPERMAJORITY_BPS - qBps);
        return lo + (hi - lo) * (t * t / 1e18) / 1e18;
    }
```

4. `resolveReview` (`:686`): `_weightedMedianSlashBps(key)` → `_severityBps(r)`; rewrite the comment block above the call (severity = deterministic decisiveness formula, not median).

5. Sweep `voteOnProposal` to 3 args everywhere: `grep -rln "voteOnProposal(" src/ test/ script/` — includes `test/mocks/MockRegistryMinimal.sol:85`, `test/invariants/handlers/GuardianHandler.sol:295`, `test/invariants/handlers/ProtocolHandler.sol:137`, registry/governor suites, and `src/MinimalGuardianRegistry.sol` if it declares the same entry point. Delete median-specific tests: `grep -rln "blockerSlashBps\|weightedMedian" test/`.

- [ ] **Step 4: Run tests**

Run: `forge test --match-path test/GuardianRegistrySeverity.t.sol -vv`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `forge test`
Expected: PASS — remaining failures are median-era expectations in registry suites (severity was the voted value; now formula-derived). Recompute each with the Step 3 formula; the common single-blocker-at-quorum shape resolves to `minSlashBps`.

```bash
git add -A && git commit -m "feat(registry): deterministic slash severity from block decisiveness"
```

---

### Task 7: Invariants, gap comments, fmt, final verification

**Files:**
- Modify: `test/invariants/GuardianInvariants.t.sol`, `test/invariants/DelegationInvariants.t.sol`
- Modify: `src/StakedWood.sol` (`__gap` + storage-history comments)

- [ ] **Step 1: Add invariants**

Follow the existing handler-based pattern in the invariant suites:

```solidity
/// Aged weight never exceeds raw stake + k × raw stake, and a zero-stake
/// guardian carries zero weight (spec Parts B/C).
function invariant_agedWeightBounds() public view {
    address[] memory gs = handler.guardians();
    for (uint256 i = 0; i < gs.length; i++) {
        uint256 raw = swood.guardianStake(gs[i]);
        uint256 votes = swood.getVotes(gs[i]);
        assertLe(votes, raw + swood.delegatedWeightCapX() * raw);
        if (raw == 0) assertEq(votes, 0);
    }
}

/// Relocated C-2: a slashed pool with outstanding shares retains >= 1 wei
/// (maxDelegatedSlashBps < 10_000 guarantees the share math never divides
/// by zero).
function invariant_poolsNeverZeroWithLiveShares() public view {
    address[] memory gs = handler.guardians();
    for (uint256 i = 0; i < gs.length; i++) {
        if (swood.poolShares(gs[i]) != 0) assertGt(swood.poolTokens(gs[i]), 0);
        if (swood.unbondingPoolShares(gs[i]) != 0) assertGt(swood.unbondingPoolTokens(gs[i]), 0);
    }
}
```

- [ ] **Step 2: Update gap + storage-history comments**

`src/StakedWood.sol` `__gap` doc: append `Decremented 12 → 8 (spec 2026-07-19): maxDelegatedSlashBps, ageFloorBps, maturationPeriod, delegatedWeightCapX.` and set `uint256[8]`. For the deleted `voteStake` slot, follow the file's existing pre-mainnet re-baseline precedent (see the I-1 escrow note in `StakedWoodDelegation.sol:164-181`) — document the deletion where the mapping lived. If storage-parity tooling exists (`ls script | grep -i storage` — the repo synced storage-parity tooling in `df6bf53`), run it per its README and fix findings.

- [ ] **Step 3: Full verification**

```bash
forge build && forge test && forge fmt --check src/ test/ script/
```

Expected: build clean, all tests PASS, fmt clean. Local forge is 1.7.1; if CI pins a different version (`grep -rn "foundry-toolchain" .github/workflows/`), fmt with the pinned version — see error-guardrails note on fmt version mismatches. Do NOT switch the toolchain silently; surface it.

Run invariants: `forge test --match-path "test/invariants/*" -vv`
Expected: PASS.

- [ ] **Step 4: Commit + push**

```bash
git add -A && git commit -m "test: invariants for aged-weight bounds and relocated C-2 pool guard"
git push -u origin feat/slash-cap-age-weighted-voting
```

---

## Self-review notes (already applied)

- **Spec coverage**: Part A → Task 5; Part B → Tasks 2-3; Part C → Task 4; Part D → Task 6; params/ceiling relaxation → Task 1; spec §10 test-plan items distributed across task test sections; storage/gap → Tasks 1, 7.
- **Ordering**: params first (compile dependency); age (Task 2) before k-cap (Task 4) because the cap base is aged own weight; `_slashOne` (Task 5) before Part D (Task 6) — Task 5's tests drive `slashGuardians` directly as the registry, so no dependency on the severity source.
- **Known repair zones** (expected, not surprises): weight assertions after Task 2 (`skip(30 days)` in setUps), `InitParams` sweep in Task 1 Step 4, `voteOnProposal` arity sweep in Task 6 Step 3.5, median-era severity expectations in Task 6 Step 5, `recordVoteStake` mock/minimal-registry references in Task 5 Step 3.
- **Type consistency**: `maxDelegatedSlashBps`/`ageFloorBps`/`maturationPeriod`/`delegatedWeightCapX` are `uint256` storage + `uint256` InitParams fields throughout; `_ageFactorBps(uint64, uint256) returns (uint256)` used identically in Tasks 2, 4; `_severityBps(Review storage) returns (uint256)` matches the `resolveReview` call site.
