# Instant-Withdrawal Liquidity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let LPs withdraw at any time during a live strategy proposal, via (A) a governance-enforced idle buffer the strategy can never deploy, and (B) same-transaction on-demand pulls from strategies that support it — per spec `docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md`.

**Architecture:** `SyndicateVault` (ERC-4626, UUPS) already allows Lane A instant exits capped at idle float when the `PriceRouter` proves live NAV. We add: a `minBufferBps` floor enforced when `executeGovernorBatch` deploys capital; an `IStrategy.availableLiquidity()/withdrawTo()` pair (defaults keep every existing strategy unchanged) so `_withdraw` can pull shortfall from the active strategy in the same tx; an `_interimNetFlow` accumulator so `SyndicateGovernor._finishSettlement` computes strategy PnL correctly under mid-proposal flows (this also fixes an existing latent bug — see Task 5); and a `minHoldingPeriod` anti-flash-arb stamp.

**Tech Stack:** Solidity 0.8.28, Foundry (forge 1.7.1 local — verify against this repo's CI pin before fmt), OpenZeppelin upgradeable ERC-4626.

**Key design decisions (locked in, do not re-litigate mid-implementation):**

1. **No `InitParams` change.** The two new parameters (`minBufferBps`, `minHoldingPeriod`) get owner setters and default to 0 (feature off). This keeps every existing `InitParams` construction site (10+ test files, deploy scripts) untouched and makes the upgrade storage-safe (new slots read 0 on already-deployed proxies).
2. **Buffer target is computed on the pre-batch balance** (`balanceBefore * minBufferBps / 10_000`), not on `totalAssets()`. Deterministic, no oracle dependency, and it means exactly "X% of the float at deployment time stays in the vault".
3. **`withdrawTo` is all-or-revert.** The vault verifies delivery by balance-diff and reverts `UnwindShortfall` on partial delivery. Partial fills are a future extension (spec Q4).
4. **`instantExitFeeBps` is DEFERRED.** Rationale: the G1 Lane-A lock (`_laneALockPid`) already blocks intra-proposal deposit→exit cycling (the main griefing vector); charging a fee on the strategy-sourced portion breaks EIP-4626 preview exactness unless `previewWithdraw`/`previewRedeem` are also overridden, which costs EIP-170 budget the vault doesn't have. Documented in the spec as an accepted gap.
5. **`nonReentrant` is added to `_withdraw`.** The existing comment (SyndicateVault.sol:666-671) says the withdraw path deliberately had no guard *because it made no external calls*. Task 4 introduces one (`strategy.withdrawTo`), so the stated precondition no longer holds.

**EIP-170 WARNING:** the vault is near the 24KB limit (multiple getters were already dropped for size — see comments at SyndicateVault.sol:239, 688). **Every task that touches `SyndicateVault.sol` ends with `forge build --sizes | grep SyndicateVault`.** If runtime size exceeds 24,576 bytes, stop and surface to the user before attempting extraction to a library.

**File structure (all changes):**

| File | Change |
|---|---|
| `src/interfaces/ISyndicateVault.sol` | new errors, events, setters, views |
| `src/SyndicateVault.sol` | storage (3 slots from `__gap`), buffer check, strategy pull, netflow, holding period |
| `src/interfaces/IStrategy.sol` | `availableLiquidity()`, `withdrawTo(uint256)` |
| `src/strategies/BaseStrategy.sol` | default implementations (no-op / revert) |
| `src/strategies/MoonwellSupplyStrategy.sol` | real overrides |
| `src/interfaces/ICToken.sol` | add `getCash()` |
| `src/SyndicateGovernor.sol` | netflow-adjusted PnL in `_finishSettlement` |
| `test/SyndicateVault.InstantLiquidity.t.sol` | new — buffer, pull, netflow, holding period |
| `test/MoonwellSupplyStrategy.fork.t.sol` | new — pinned-block fork test for `withdrawTo` |
| `test/invariants/InstantLiquidityInvariant.t.sol` | new — reserve seniority, PnL integrity, pricing gate |

Branch note: current worktree is on `feat/slash-cap-age-weighted-voting`. **Create `feat/instant-withdrawal-liquidity` off `main` before Task 1** (`git checkout main && git pull && git checkout -b feat/instant-withdrawal-liquidity`).

---

### Task 1: `minBufferBps` parameter + setter

**Files:**
- Modify: `src/interfaces/ISyndicateVault.sol` (errors block ~line 48, views ~line 101, events ~line 139)
- Modify: `src/SyndicateVault.sol` (storage after `_agentFeeBpsPlusOne` ~line 143, setter near `setAgentFeeBps` ~line 516)
- Test: `test/SyndicateVault.InstantLiquidity.t.sol` (new file)

- [ ] **Step 1: Write the failing tests**

Create `test/SyndicateVault.InstantLiquidity.t.sol`. Reuse the LaneA test scaffolding (mock governor + mock router — copy the `setUp`, `_setLocked` pattern from `test/SyndicateVault.LaneA.t.sol:34-105`, renaming the contract):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {VaultWithdrawalQueue} from "../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

/// @notice Mock PriceRouter returning a configurable strategy valuation.
contract MockRouter {
    uint256 public v;
    bool public ok;

    function set(uint256 v_, bool ok_) external {
        v = v_;
        ok = ok_;
    }

    function valueStrategy(address) external view returns (uint256, bool) {
        return (v, ok);
    }
}

/// @notice Strategy mock holding real USDC it can return on demand (Task 4+).
contract MockLiquidStrategy {
    ERC20Mock immutable usdc;
    address immutable vaultAddr;
    uint256 public liq;
    bool public lie; // report liquidity but under-deliver

    constructor(ERC20Mock usdc_, address vault_) {
        usdc = usdc_;
        vaultAddr = vault_;
    }

    function setLiquidity(uint256 l) external {
        liq = l;
    }

    function setLie(bool l) external {
        lie = l;
    }

    function pushBack(uint256 amt) external {
        usdc.transfer(vaultAddr, amt);
    }

    function availableLiquidity() external view returns (uint256) {
        return liq;
    }

    function withdrawTo(uint256 assets) external {
        require(msg.sender == vaultAddr, "not vault");
        usdc.transfer(vaultAddr, lie ? assets / 2 : assets);
    }
}

contract VaultInstantLiquidityTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockRouter router;
    MockLiquidStrategy strat;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address constant MOCK_GOVERNOR = address(0xF00D);
    uint256 constant PID = 1;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MockRouter();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        strat = new MockLiquidStrategy(usdc, address(vault));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        _setLocked(false);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setLocked(bool locked) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(locked ? PID : uint256(0))
        );
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(locked ? uint256(1) : 0));
        if (locked) {
            ISyndicateGovernor.StrategyProposal memory p;
            p.id = PID;
            p.vault = address(vault);
            p.strategy = address(strat);
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, PID), abi.encode(p)
            );
        }
    }

    // ── Task 1: minBufferBps setter ──

    function test_minBufferBps_defaultZero() public view {
        assertEq(vault.minBufferBps(), 0, "buffer off by default");
    }

    function test_setMinBufferBps_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        vault.setMinBufferBps(1_000);
    }

    function test_setMinBufferBps_setsAndEmits() public {
        vm.prank(owner);
        vm.expectEmit();
        emit ISyndicateVault.MinBufferUpdated(1_000);
        vault.setMinBufferBps(1_000);
        assertEq(vault.minBufferBps(), 1_000);
    }

    function test_setMinBufferBps_revertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.BufferTooHigh.selector);
        vault.setMinBufferBps(5_001);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract VaultInstantLiquidityTest -vv`
Expected: FAIL — compile error, `minBufferBps` is not a member of `SyndicateVault`.

- [ ] **Step 3: Add interface members**

In `src/interfaces/ISyndicateVault.sol`, after `error AgentFeeTooHigh();` (line 48):

```solidity
    /// @notice `setMinBufferBps` was called with `bps > 5_000` (50%).
    error BufferTooHigh();
```

After `function setAgentFeeBps(uint256 bps) external;` (line 101):

```solidity
    /// @notice Idle-liquidity floor in basis points of the pre-batch float.
    ///         `executeGovernorBatch` reverts if a batch would leave less than
    ///         this fraction (plus the queue reserve) in the vault. 0 = off.
    function minBufferBps() external view returns (uint16);
    /// @notice Set the idle-liquidity floor (owner only, max 5_000 = 50%).
    function setMinBufferBps(uint16 bps) external;
```

After `event AgentFeeUpdated(uint256 bps);` (line 139):

```solidity
    /// @notice Emitted when the vault owner updates the idle-liquidity floor.
    event MinBufferUpdated(uint16 bps);
```

- [ ] **Step 4: Add storage + setter to the vault**

In `src/SyndicateVault.sol`, replace the gap declaration (lines 145-147):

```solidity
    /// @dev Reserved storage for future upgrades. Grew 34 → 35 when the
    ///      `_agentFeeSet` bool slot was reclaimed (PR #384 review pass 3).
    uint256[35] private __gap;
```

with:

```solidity
    /// @notice Idle-liquidity floor (bps of pre-batch float) enforced against
    ///         governor batches. 0 = off. Packed with `minHoldingPeriod`.
    uint16 public minBufferBps;

    /// @notice Seconds an account must hold after a deposit before instant
    ///         exit (anti flash-arb, GLP-cooldown pattern). Lane B is exempt.
    uint32 public minHoldingPeriod;

    /// @notice Net LP asset flow (deposits − instant exits) accumulated while
    ///         the current proposal is active. Read by the governor at
    ///         settlement so mid-proposal flows don't corrupt strategy PnL;
    ///         reset in `onProposalSettled`.
    int256 private _interimNetFlow;

    /// @notice Timestamp of each account's most recent instant deposit
    ///         (receiver-side). Gates instant exit via `minHoldingPeriod`.
    mapping(address => uint40) public lastDepositAt;

    /// @dev Reserved storage for future upgrades. Shrunk 35 → 32: one packed
    ///      slot (minBufferBps + minHoldingPeriod), _interimNetFlow,
    ///      lastDepositAt (spec 2026-07-19 instant-withdrawal-liquidity).
    uint256[32] private __gap;
```

(`minHoldingPeriod`, `_interimNetFlow`, `lastDepositAt` are declared now so the storage layout is settled once; they're wired up in Tasks 5-6.)

Then add the setter after `setAgentFeeBps` (line 522):

```solidity
    /// @inheritdoc ISyndicateVault
    function setMinBufferBps(uint16 bps) external onlyOwner {
        if (bps > 5_000) revert BufferTooHigh();
        minBufferBps = bps;
        emit MinBufferUpdated(bps);
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `forge test --match-contract VaultInstantLiquidityTest -vv`
Expected: 4 PASS.

- [ ] **Step 6: Size check + full-suite smoke**

Run: `forge build --sizes | grep SyndicateVault` — runtime must be < 24,576 bytes.
Run: `forge test` — no regressions.

- [ ] **Step 7: Commit**

```bash
git add src/interfaces/ISyndicateVault.sol src/SyndicateVault.sol test/SyndicateVault.InstantLiquidity.t.sol
git commit -m "feat(vault): minBufferBps idle-liquidity floor param + setter"
```

---

### Task 2: Buffer enforcement in `executeGovernorBatch`

**Files:**
- Modify: `src/interfaces/ISyndicateVault.sol` (errors block)
- Modify: `src/SyndicateVault.sol:422-445` (`executeGovernorBatch`)
- Test: `test/SyndicateVault.InstantLiquidity.t.sol`

- [ ] **Step 1: Write the failing tests**

Append to `VaultInstantLiquidityTest`. A governor batch that transfers vault float out simulates strategy deployment (the batch runs as delegatecall from the vault, so a direct ERC-20 `transfer` moves vault funds — same shape as real `[approve, execute]` batches):

```solidity
    /// @dev Build a single-call batch that sends `amount` of vault float to `to`
    ///      (stands in for a strategy deployment pulling capital).
    function _deployBatch(address to, uint256 amount) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc),
            data: abi.encodeCall(usdc.transfer, (to, amount)),
            value: 0
        });
    }

    // ── Task 2: buffer enforcement ──

    function test_governorBatch_respectsBuffer() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000); // 10% of 1_000e6 = 100e6 must stay

        // Deploying exactly 90% passes.
        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6));
        assertEq(usdc.balanceOf(address(vault)), 100e6);
    }

    function test_governorBatch_revertsOnBufferBreach() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000);

        // 90% + 1 wei breaches the floor.
        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(ISyndicateVault.BufferBreached.selector);
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6 + 1));
    }

    function test_governorBatch_bufferOff_allowsFullDeploy() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        // minBufferBps == 0 (default): behavior identical to today.
        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_deployBatch(address(strat), 1_000e6));
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_governorBatch_settleBatch_passesTrivially() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000);
        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6));

        // Settle: strategy returns funds — inflow batches always pass the floor.
        strat.pushBack(900e6);
        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(new BatchExecutorLib.Call[](0));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract VaultInstantLiquidityTest --match-test governorBatch -vv`
Expected: compile error on `BufferBreached` first; after adding just the error, `test_governorBatch_revertsOnBufferBreach` FAILS (no revert).

- [ ] **Step 3: Add error + enforcement**

`src/interfaces/ISyndicateVault.sol`, after `error BufferTooHigh();`:

```solidity
    /// @notice A governor batch left the vault below the idle floor
    ///         (`reservedQueueAssets + minBufferBps%` of the pre-batch float).
    error BufferBreached();
```

`src/SyndicateVault.sol` — in `executeGovernorBatch`, snapshot the pre-batch float and extend the post-batch check. Replace the body (lines 427-445) with:

```solidity
        if (_executorImpl.codehash != _expectedExecutorCodehash) revert ExecutorCodehashMismatch();
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        (bool success, bytes memory returnData) =
            _executorImpl.delegatecall(abi.encodeCall(BatchExecutorLib.executeBatch, (calls)));
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        // V-M9: first-class vault-level execution marker. Emitted after the
        // delegatecall succeeds so indexers only see confirmed executions.
        emit GovernorBatchExecuted(msg.sender, calls.length);

        // Honor pending redemptions first: a strategy execution may not deploy
        // float reserved for already-settled, unclaimed redeem claims, so a
        // later proposal cannot strand them. Settle batches return float and
        // pass trivially; an execute batch that over-deploys reverts here.
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
        uint256 reserve = reservedQueueAssets();
        if (balanceAfter < reserve) revert QueueReserveBreached();
        // Idle-liquidity floor: a batch may deploy at most (1 − minBufferBps)
        // of the pre-batch float. Inflow (settle) batches pass trivially.
        if (balanceAfter < reserve + (balanceBefore * minBufferBps) / 10_000) revert BufferBreached();
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract VaultInstantLiquidityTest -vv`
Expected: all PASS.

- [ ] **Step 5: Size check + full suite**

Run: `forge build --sizes | grep SyndicateVault` (< 24,576) and `forge test`.
Existing `QueueReserveBreached` tests must still pass (the reserve check is unchanged and fires first).

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/ISyndicateVault.sol src/SyndicateVault.sol test/SyndicateVault.InstantLiquidity.t.sol
git commit -m "feat(vault): enforce minBufferBps idle floor on governor batches"
```

---

### Task 3: `IStrategy.availableLiquidity` / `withdrawTo` + `BaseStrategy` defaults

**Files:**
- Modify: `src/interfaces/IStrategy.sol`
- Modify: `src/strategies/BaseStrategy.sol`
- Test: `test/SyndicateVault.InstantLiquidity.t.sol`

- [ ] **Step 1: Write the failing tests**

Append a minimal concrete BaseStrategy (top-level in the test file):

```solidity
/// @notice Minimal concrete BaseStrategy that overrides nothing liquidity-related.
contract MockDefaultStrategy is BaseStrategy {
    function name() external pure returns (string memory) {
        return "Default";
    }

    function _initialize(bytes calldata) internal override {}
    function _execute() internal override {}
    function _settle() internal override {}
    function _updateParams(bytes calldata) internal override {}
}
```

And in the test contract:

```solidity
    // ── Task 3: BaseStrategy defaults ──

    function test_baseStrategy_defaults_noOnDemandExit() public {
        MockDefaultStrategy tmpl = new MockDefaultStrategy();
        MockDefaultStrategy s = MockDefaultStrategy(payable(Clones.clone(address(tmpl))));
        s.initialize(address(vault), alice, "");

        assertEq(s.availableLiquidity(), 0, "default: no on-demand liquidity");
        vm.prank(address(vault));
        vm.expectRevert(BaseStrategy.OnDemandExitUnsupported.selector);
        s.withdrawTo(1);
    }

    function test_baseStrategy_withdrawTo_onlyVault() public {
        MockDefaultStrategy tmpl = new MockDefaultStrategy();
        MockDefaultStrategy s = MockDefaultStrategy(payable(Clones.clone(address(tmpl))));
        s.initialize(address(vault), alice, "");

        vm.prank(alice);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        s.withdrawTo(1);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract VaultInstantLiquidityTest --match-test baseStrategy -vv`
Expected: FAIL — compile error, `availableLiquidity` not defined.

- [ ] **Step 3: Extend the interface**

`src/interfaces/IStrategy.sol`, after `function selfManagesFees() external view returns (bool);` (line 66):

```solidity
    /// @notice Assets (vault-asset units) the strategy can return to the vault
    ///         on demand, mid-lifecycle, net of unwind costs. 0 when the
    ///         strategy does not support on-demand exit (the default) or is not
    ///         in the Executed state. A serviceability signal only — the vault
    ///         verifies actual delivery by balance-diff, never trusts this for
    ///         pricing.
    function availableLiquidity() external view returns (uint256);

    /// @notice Unwind and transfer exactly `assets` of the vault asset back to
    ///         the vault, mid-lifecycle. MUST deliver at least `assets` or
    ///         revert (all-or-revert; the vault reverts `UnwindShortfall` on a
    ///         lying strategy). Vault-only.
    function withdrawTo(uint256 assets) external;
```

- [ ] **Step 4: Add BaseStrategy defaults**

`src/strategies/BaseStrategy.sol` — add to the errors block (after `error ZeroAddress();`, line 37):

```solidity
    error OnDemandExitUnsupported();
```

After `selfManagesFees()` (line 140):

```solidity
    /// @inheritdoc IStrategy
    /// @dev Default: no on-demand exit — instant withdrawals are served from
    ///      vault float only; excess routes to the Lane B queue. Strategies
    ///      with venue-liquid positions (e.g. Moonwell supply) override both
    ///      this and `withdrawTo`.
    function availableLiquidity() external view virtual returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStrategy
    function withdrawTo(uint256) external virtual onlyVault {
        revert OnDemandExitUnsupported();
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `forge test --match-contract VaultInstantLiquidityTest -vv`
Expected: all PASS.

- [ ] **Step 6: Full-suite check**

Run: `forge test`
Every concrete strategy (Moonwell, Aerodrome, Hyperliquid, Portfolio, LeveragedAeroCL) inherits the defaults — nothing overrides yet, so all existing tests must stay green.

- [ ] **Step 7: Commit**

```bash
git add src/interfaces/IStrategy.sol src/strategies/BaseStrategy.sol test/SyndicateVault.InstantLiquidity.t.sol
git commit -m "feat(strategy): availableLiquidity/withdrawTo on-demand exit interface with inert defaults"
```

---

### Task 4: Vault same-tx strategy pull (instant capacity beyond float)

**Files:**
- Modify: `src/interfaces/ISyndicateVault.sol` (error)
- Modify: `src/SyndicateVault.sol` (`maxWithdraw` :756, `maxRedeem` :768, `_withdraw` :738, new helpers near `_availableFloat` :644)
- Test: `test/SyndicateVault.InstantLiquidity.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
    // ── Task 4: instant exit spanning float + strategy pull ──

    function _enterAndLock(uint256 depositAmt, uint256 deployAmt, uint256 liveVal) internal {
        vm.prank(alice);
        vault.deposit(depositAmt, alice);
        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_deployBatch(address(strat), deployAmt));
        strat.setLiquidity(deployAmt);
        _setLocked(true);
        router.set(liveVal, true); // Lane A on
    }

    function test_maxWithdraw_includesStrategyLiquidity() public {
        _enterAndLock(1_000e6, 900e6, 900e6); // float 100e6, strategy 900e6
        // Alice owns 100% of shares → maxWithdraw = min(1_000e6, 100e6 + 900e6).
        assertEq(vault.maxWithdraw(alice), 1_000e6, "capacity = float + strategy liquidity");
    }

    function test_withdraw_pullsShortfallFromStrategy() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(500e6, alice, alice); // float only covers 100e6
        assertEq(usdc.balanceOf(alice) - before, 500e6, "full amount paid");
        assertEq(usdc.balanceOf(address(strat)), 500e6, "400e6 pulled from strategy");
    }

    function test_withdraw_floatOnly_noStrategyCall() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        vm.prank(alice);
        vault.withdraw(50e6, alice, alice); // fits in the 100e6 float
        assertEq(usdc.balanceOf(address(strat)), 900e6, "strategy untouched");
    }

    function test_withdraw_revertsOnUnderDelivery() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        strat.setLie(true);
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.UnwindShortfall.selector);
        vault.withdraw(500e6, alice, alice);
    }

    function test_maxWithdraw_zeroStrategyCapacity_whenLaneAOff() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        router.set(0, false); // Lane A off → no instant exit at all (float-only NAV)
        assertEq(vault.maxWithdraw(alice), 0, "no pricing, no instant exit");
    }

    function test_maxWithdraw_floatOnly_whenStrategyHasNoLiquidity() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        strat.setLiquidity(0); // default-strategy behavior
        assertEq(vault.maxWithdraw(alice), 100e6, "capped at float");
    }
```

Note on `test_maxWithdraw_includesStrategyLiquidity`: alice deposited pre-proposal so she is not Lane-A-locked; live NAV 900e6 + float 100e6 keeps `totalAssets` at 1_000e6, so her full balance converts to 1_000e6 assets. If rounding makes the exact assertion flaky, use `assertApproxEqAbs(..., 1)`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract VaultInstantLiquidityTest --match-test "maxWithdraw_includes|withdraw_pulls|withdraw_reverts|zeroStrategyCapacity|floatOnly_when" -vv`
Expected: FAIL — `UnwindShortfall` undefined; `maxWithdraw` returns 100e6 not 1_000e6.

- [ ] **Step 3: Add error**

`src/interfaces/ISyndicateVault.sol`, after `error BufferBreached();`:

```solidity
    /// @notice The active strategy's `withdrawTo` delivered fewer assets than
    ///         requested (balance-diff verified vault-side).
    error UnwindShortfall();
```

- [ ] **Step 4: Add vault helpers + wire the pull**

`src/SyndicateVault.sol` — add import at the top (with the other interface imports):

```solidity
import {IStrategy} from "./interfaces/IStrategy.sol";
```

After `_availableFloat()` (line 648), add:

```solidity
    /// @dev On-demand liquidity the active strategy can return mid-lifecycle,
    ///      counted toward instant-exit capacity ONLY while Lane A is available
    ///      (no pricing ⇒ no instant exit, regardless of serviceability).
    ///      try/catch + fail-to-0 so a strategy without the interface can never
    ///      brick `maxWithdraw` / `maxRedeem`.
    function _strategyLiquidity() private view returns (uint256) {
        (, bool laneA) = _liveNAV();
        if (!laneA) return 0;
        address strat = _activeStrategy();
        if (strat == address(0)) return 0;
        try IStrategy(strat).availableLiquidity() returns (uint256 l) {
            return l;
        } catch {
            return 0;
        }
    }

    /// @dev Pull `shortfall` of the vault asset from the active strategy for an
    ///      in-flight instant exit. All-or-revert: delivery is verified by
    ///      balance-diff so a lying `availableLiquidity` cannot under-fund the
    ///      exit. Reverts `QueueReserveBreached` when there is no pullable
    ///      strategy (preserves the pre-existing error surface for float-only
    ///      exits).
    function _pullFromStrategy(uint256 shortfall) private {
        (, bool laneA) = _liveNAV();
        address strat = _activeStrategy();
        if (strat == address(0) || !laneA) revert QueueReserveBreached();
        IERC20 asset_ = IERC20(asset());
        uint256 balBefore = asset_.balanceOf(address(this));
        IStrategy(strat).withdrawTo(shortfall);
        if (asset_.balanceOf(address(this)) < balBefore + shortfall) revert UnwindShortfall();
    }
```

Replace `_withdraw` (lines 738-749) — note the added `nonReentrant` (design decision 5) and the pull:

```solidity
    /// @dev `maxWithdraw` / `maxRedeem` remain the canonical gate (OZ ERC4626
    ///      invokes them before `_withdraw`). Shortfall beyond idle float is
    ///      pulled from the active strategy in the same tx (Yearn
    ///      default_queue pattern, queue length 1). The pull happens BEFORE
    ///      the burn/transfer; value moves position → float, so live NAV (and
    ///      thus this exit's share pricing) is unchanged. `nonReentrant` added
    ///      alongside the new external call — the prior "no guard needed"
    ///      rationale (no external calls on this path) no longer holds.
    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
    {
        if (caller != _withdrawalQueue) {
            uint256 reserve = reservedQueueAssets();
            uint256 float = IERC20(asset()).balanceOf(address(this));
            if (assets + reserve > float) {
                _pullFromStrategy(assets + reserve - float);
            }
        }
        super._withdraw(caller, receiver, _owner, assets, shares);
    }
```

In `maxWithdraw` (line 761), change:

```solidity
        uint256 available = _availableFloat();
```

to:

```solidity
        uint256 available = _availableFloat() + _strategyLiquidity();
```

In `maxRedeem` (line 777), change:

```solidity
        uint256 backingAssets = _availableFloat();
```

to:

```solidity
        uint256 backingAssets = _availableFloat() + _strategyLiquidity();
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `forge test --match-contract VaultInstantLiquidityTest -vv`
Expected: all PASS.

- [ ] **Step 6: Size check + full suite**

Run: `forge build --sizes | grep SyndicateVault` (< 24,576) and `forge test`.
Watch specifically: `test/SyndicateVault.AsyncRedeem.t.sol`; `test/SyndicateVault.LaneA.t.sol` (its `STRAT = address(0x57A7)` has no code, so `availableLiquidity` try/catch fails → 0 → the float-capped exit test still passes); the reentrancy tests in `test/SyndicateVault.t.sol`; and the queue's claim path (`VaultWithdrawalQueue` tests) — the queue-caller branch of `_withdraw` is unchanged and the vault-side `nonReentrant` is a fresh transient slot per contract, so no conflict is expected. If a queue test fails on the guard, investigate before proceeding (do not remove the guard silently).

- [ ] **Step 7: Commit**

```bash
git add src/interfaces/ISyndicateVault.sol src/SyndicateVault.sol test/SyndicateVault.InstantLiquidity.t.sol
git commit -m "feat(vault): same-tx strategy pull extends instant-exit capacity beyond float"
```

---

### Task 5: `_interimNetFlow` — settlement PnL correction

**Context for the implementer:** `SyndicateGovernor._finishSettlement` computes `pnl = balance − capitalSnapshot` (SyndicateGovernor.sol:911-914). Any Lane A deposit during the proposal inflates that delta — performance fees get charged on depositor principal. **This is an existing live bug**, not one introduced by this feature (the custody-model strategies dodge it via `selfManagesFees`, but a plain Lane A strategy does not). Any instant exit deflates the delta symmetrically (real profit misread as loss). The fix: the vault accumulates the signed LP-flow delta while a proposal is active; the governor subtracts it. **Surface this bug-fix explicitly in the PR description.**

**Files:**
- Modify: `src/interfaces/ISyndicateVault.sol` (view)
- Modify: `src/SyndicateVault.sol` (`_deposit` :705, `_withdraw` from Task 4, `onProposalSettled` :945, view near :874)
- Modify: `src/SyndicateGovernor.sol` (`_finishSettlement` :907-914)
- Test: `test/SyndicateVault.InstantLiquidity.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
    // ── Task 5: interim net-flow tracking ──

    function test_interimNetFlow_tracksLaneADeposit() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        vm.prank(bob);
        vault.deposit(300e6, bob);
        assertEq(vault.interimNetFlow(), int256(300e6), "deposit tracked");
    }

    function test_interimNetFlow_tracksInstantExit() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        vm.prank(alice);
        vault.withdraw(500e6, alice, alice);
        assertEq(vault.interimNetFlow(), -int256(500e6), "exit tracked");
    }

    function test_interimNetFlow_notTrackedOutsideProposal() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(alice);
        vault.withdraw(400e6, alice, alice);
        assertEq(vault.interimNetFlow(), 0, "no proposal, no tracking");
    }

    function test_interimNetFlow_resetOnSettle() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        vm.prank(bob);
        vault.deposit(300e6, bob);
        _setLocked(false); // proposal cleared
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalSettled(PID);
        assertEq(vault.interimNetFlow(), 0, "reset at settlement stamp");
    }

    /// @notice The governor-side formula: float delta minus netflow == true
    ///         strategy PnL. Break-even strategy + 300e6 mid-proposal deposit
    ///         + 200e6 instant exit → formula must yield exactly 0.
    function test_settlementPnl_excludesLaneAFlows() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        uint256 snapshot = 1_000e6; // what the governor snapshotted pre-execute

        vm.prank(bob);
        vault.deposit(300e6, bob); // principal in — not strategy performance

        vm.prank(alice);
        vault.withdraw(200e6, alice, alice); // principal out (float covers it)

        // Strategy breaks even: returns exactly what it took.
        strat.pushBack(usdc.balanceOf(address(strat)));

        int256 pnl =
            int256(usdc.balanceOf(address(vault))) - int256(snapshot) - vault.interimNetFlow();
        assertEq(pnl, 0, "flows excluded: break-even strategy shows zero pnl");
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract VaultInstantLiquidityTest --match-test "interimNetFlow|settlementPnl" -vv`
Expected: FAIL — `interimNetFlow` not defined.

- [ ] **Step 3: Interface + vault wiring**

`src/interfaces/ISyndicateVault.sol`, after `function onProposalSettled(uint256 proposalId) external; // governor-only` (line 117):

```solidity
    /// @notice Signed LP asset flow (Lane A deposits − instant exits)
    ///         accumulated while the current proposal is active. The governor
    ///         subtracts this from the float delta at settlement so
    ///         mid-proposal flows don't corrupt strategy PnL (and performance
    ///         fees are never charged on depositor principal).
    function interimNetFlow() external view returns (int256);
```

`src/SyndicateVault.sol`:

Add the view (near `reservedQueueAssets`, line 874):

```solidity
    /// @inheritdoc ISyndicateVault
    function interimNetFlow() external view returns (int256) {
        return _interimNetFlow;
    }
```

In `_deposit`, extend the existing Lane A branch (lines 727-729) — a `laneA` deposit is by construction mid-proposal:

```solidity
        // G1: a Lane A entry locks the receiver's shares until this proposal
        // settles — closes the deposit-low / exit-high intra-proposal MEV.
        if (laneA) {
            _laneALockPid[receiver] = _activePid();
            // Mid-proposal principal in — excluded from settlement PnL.
            _interimNetFlow += int256(assets);
        }
```

In `_withdraw` (as written in Task 4), add tracking after `super._withdraw`:

```solidity
        super._withdraw(caller, receiver, _owner, assets, shares);
        // Mid-proposal principal out — excluded from settlement PnL. Queue
        // settlements post-date the PnL read; only live instant exits count.
        if (caller != _withdrawalQueue && redemptionsLocked()) {
            _interimNetFlow -= int256(assets);
        }
```

In `onProposalSettled` (lines 945-951), reset FIRST — before the no-queue early return, or a queueless vault never resets:

```solidity
    function onProposalSettled(uint256 proposalId) external onlyGovernor {
        // Reset the flow accumulator for the next proposal. MUST precede the
        // no-queue early-return below.
        delete _interimNetFlow;
        address q = _withdrawalQueue;
        if (q == address(0)) return;
        uint256 num = totalAssets() + 1;
        uint256 den = totalSupply() + 10 ** _decimalsOffset();
        IVaultWithdrawalQueue(q).stampSettlement(proposalId, num, den);
    }
```

- [ ] **Step 4: Governor-side PnL adjustment**

`src/SyndicateGovernor.sol`, in `_finishSettlement` — replace the PnL computation (lines 907-914):

```solidity
        // Asset-only measurement (see NatSpec above). PnL is the realized float
        // delta minus the interim LP net flow: Lane A deposits and instant
        // exits during the proposal move the float but are principal, not
        // strategy performance. The vault resets the accumulator in
        // `onProposalSettled` (called below, after fees).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 snapshot = _capitalSnapshots[proposalId];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 balanceAdjusted = IERC20(asset).balanceOf(vault);
        pnl = int256(balanceAdjusted) - int256(snapshot) - ISyndicateVault(vault).interimNetFlow();
```

`SyndicateGovernor.sol` already imports `ISyndicateVault` (it calls `executeGovernorBatch` at :377) — no new import.

- [ ] **Step 5: Run tests to verify they pass**

Run: `forge test --match-contract VaultInstantLiquidityTest -vv`
Expected: all PASS.

- [ ] **Step 6: Size check + full suite**

Run: `forge build --sizes | grep -E "SyndicateVault|SyndicateGovernor"` and `forge test`.
Governor test suites (`test/SyndicateGovernor*.t.sol`, `test/governor/`) exercise `_finishSettlement` heavily — real vaults there have `interimNetFlow == 0` (no mid-proposal Lane A flows), so `pnl` is numerically unchanged and all fee assertions must stay green. If any governor test uses a hand-rolled vault mock without `interimNetFlow()`, add `vm.mockCall(vaultAddr, abi.encodeWithSignature("interimNetFlow()"), abi.encode(int256(0)))` or extend the mock.

- [ ] **Step 7: Commit**

```bash
git add src/interfaces/ISyndicateVault.sol src/SyndicateVault.sol src/SyndicateGovernor.sol test/SyndicateVault.InstantLiquidity.t.sol
git commit -m "fix(governor): exclude mid-proposal LP flows from settlement PnL via vault interimNetFlow"
```

---

### Task 6: `minHoldingPeriod` anti-flash-arb gate

**Files:**
- Modify: `src/interfaces/ISyndicateVault.sol` (errors, event, setter, view)
- Modify: `src/SyndicateVault.sol` (`_deposit`, `_withdraw`, `maxWithdraw`, `maxRedeem`, setter)
- Test: `test/SyndicateVault.InstantLiquidity.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
    // ── Task 6: minHoldingPeriod ──

    function test_setMinHoldingPeriod_boundsAndEvent() public {
        vm.prank(owner);
        vm.expectEmit();
        emit ISyndicateVault.MinHoldingPeriodUpdated(1 hours);
        vault.setMinHoldingPeriod(1 hours);
        assertEq(vault.minHoldingPeriod(), 1 hours);

        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.HoldingPeriodTooLong.selector);
        vault.setMinHoldingPeriod(7 days + 1);
    }

    function test_holdingPeriod_blocksInstantExit_thenLifts() public {
        vm.prank(owner);
        vault.setMinHoldingPeriod(1 hours);

        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        assertEq(vault.maxWithdraw(alice), 0, "within holding period");
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.HoldingPeriodActive.selector);
        vault.withdraw(100e6, alice, alice);

        vm.warp(block.timestamp + 1 hours);
        assertGt(vault.maxWithdraw(alice), 0, "holding period elapsed");
        vm.prank(alice);
        vault.withdraw(100e6, alice, alice);
    }

    function test_holdingPeriod_laneBExempt() public {
        vm.prank(owner);
        vault.setMinHoldingPeriod(1 hours);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        _setLocked(true);
        router.set(0, false); // Lane B only

        // Lane B request works immediately — escrow-then-settle can't flash-arb
        // the NAV, so the cooldown doesn't apply.
        uint256 someShares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 id = vault.requestRedeem(someShares, alice);
        assertGt(id, 0, "Lane B exempt from holding period");
    }

    function test_holdingPeriod_zeroDefault_noGate() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(alice);
        vault.withdraw(100e6, alice, alice); // same block, fine
    }
```

Note: the `HoldingPeriodActive` revert in `test_holdingPeriod_blocksInstantExit_thenLifts` fires from `_withdraw` — but OZ's public `withdraw` checks `maxWithdraw` first and reverts `ERC4626ExceededMaxWithdraw` (since we return 0). Expect THAT error instead on the direct call, and keep the `HoldingPeriodActive` revert as defense-in-depth (reachable only if a future `maxWithdraw` regression opens the gate). Adjust the test to:

```solidity
        vm.prank(alice);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw (maxWithdraw == 0)
        vault.withdraw(100e6, alice, alice);
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract VaultInstantLiquidityTest --match-test holdingPeriod -vv`
Expected: FAIL — `setMinHoldingPeriod` not defined.

- [ ] **Step 3: Interface members**

`src/interfaces/ISyndicateVault.sol` — errors block:

```solidity
    /// @notice `setMinHoldingPeriod` was called with a period > 7 days.
    error HoldingPeriodTooLong();
    /// @notice Instant exit attempted before `minHoldingPeriod` elapsed since
    ///         the owner's last deposit. Lane B (`requestRedeem`) is exempt.
    error HoldingPeriodActive();
```

Views/setters (after `setMinBufferBps`):

```solidity
    /// @notice Seconds an account must hold after a deposit before instant
    ///         exit. Anti flash-arb (GLP cooldown pattern). 0 = off.
    function minHoldingPeriod() external view returns (uint32);
    /// @notice Set the holding period (owner only, max 7 days).
    function setMinHoldingPeriod(uint32 secs) external;
```

Events block:

```solidity
    /// @notice Emitted when the vault owner updates the instant-exit holding period.
    event MinHoldingPeriodUpdated(uint32 secs);
```

- [ ] **Step 4: Vault wiring**

Storage already exists (Task 1). Add the setter after `setMinBufferBps`:

```solidity
    /// @inheritdoc ISyndicateVault
    function setMinHoldingPeriod(uint32 secs) external onlyOwner {
        if (secs > 7 days) revert HoldingPeriodTooLong();
        minHoldingPeriod = secs;
        emit MinHoldingPeriodUpdated(secs);
    }
```

Private helper next to `_isLaneALocked` (line 628):

```solidity
    /// @dev True while `owner_` is inside the post-deposit holding period —
    ///      instant exit is closed (flash deposit→redeem NAV-arb guard). Lane B
    ///      is exempt: escrow-then-settle can't arb the live NAV.
    function _holdingPeriodActive(address owner_) private view returns (bool) {
        return block.timestamp < uint256(lastDepositAt[owner_]) + minHoldingPeriod;
    }
```

Stamp in `_deposit` (after `super._deposit(caller, receiver, assets, shares);`):

```solidity
        lastDepositAt[receiver] = uint40(block.timestamp);
```

Gate in `_withdraw` (first line inside the `caller != _withdrawalQueue` branch):

```solidity
            if (_holdingPeriodActive(_owner)) revert HoldingPeriodActive();
```

Gate in `maxWithdraw` and `maxRedeem` (EIP-4626: max functions must reflect every gate) — extend the `_laneBOnly` line in both:

```solidity
        if (_laneBOnly(owner_) || _holdingPeriodActive(owner_)) return 0;
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `forge test --match-contract VaultInstantLiquidityTest -vv`
Expected: all PASS.

- [ ] **Step 6: Size check + full suite**

Run: `forge build --sizes | grep SyndicateVault` and `forge test`.
`minHoldingPeriod` defaults to 0 → `_holdingPeriodActive` always false in existing tests → zero regressions expected.

- [ ] **Step 7: Commit**

```bash
git add src/interfaces/ISyndicateVault.sol src/SyndicateVault.sol test/SyndicateVault.InstantLiquidity.t.sol
git commit -m "feat(vault): minHoldingPeriod cooldown gates instant exit (Lane B exempt)"
```

---

### Task 7: `MoonwellSupplyStrategy` on-demand exit + pinned fork test

**Files:**
- Modify: `src/interfaces/ICToken.sol`
- Modify: `src/strategies/MoonwellSupplyStrategy.sol`
- Test: `test/MoonwellSupplyStrategy.fork.t.sol` (new)

- [ ] **Step 1: Add `getCash` to ICToken**

`src/interfaces/ICToken.sol`, after `exchangeRateStored()`:

```solidity
    /// @notice Underlying held by the market and available for redemption.
    function getCash() external view returns (uint256);
```

- [ ] **Step 2: Write the failing fork test**

Before writing, find the repo's canonical fork conventions: `grep -rn "createSelectFork" test/ | head -5` — reuse the same RPC env-var name and, if a Base USDC/mUSDC constant exists in `test/helpers/` or an existing fork test, import/copy it (do not trust the addresses below without checking). Block pin 47255670 matches the existing `WstETHMoonwellStrategy` pin.

Create `test/MoonwellSupplyStrategy.fork.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MoonwellSupplyStrategy} from "../src/strategies/MoonwellSupplyStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {ICToken} from "../src/interfaces/ICToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @notice Fork tests for MoonwellSupplyStrategy on-demand exit (withdrawTo).
///         Base mainnet, pinned block (repo guardrail: never fork `latest`).
contract MoonwellSupplyStrategyForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    uint256 constant FORK_BLOCK = 47255670;

    MoonwellSupplyStrategy strat;
    address vault = makeAddr("vault");
    address proposer = makeAddr("proposer");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        MoonwellSupplyStrategy tmpl = new MoonwellSupplyStrategy();
        strat = MoonwellSupplyStrategy(payable(Clones.clone(address(tmpl))));
        strat.initialize(vault, proposer, abi.encode(USDC, MUSDC, 100_000e6, 0, false));

        deal(USDC, vault, 100_000e6);
        vm.prank(vault);
        IERC20(USDC).approve(address(strat), type(uint256).max);
        vm.prank(vault);
        strat.execute(); // pulls 100_000e6, supplies to Moonwell
    }

    function test_fork_availableLiquidity_reflectsPosition() public view {
        uint256 liq = strat.availableLiquidity();
        // Position ≈ 100_000e6 (rounding via exchangeRateStored), capped by market cash.
        assertApproxEqRel(liq, 100_000e6, 0.01e18, "liquidity ~= supplied amount");
    }

    function test_fork_withdrawTo_deliversExactAssets() public {
        uint256 before = IERC20(USDC).balanceOf(vault);
        vm.prank(vault);
        strat.withdrawTo(40_000e6);
        assertEq(IERC20(USDC).balanceOf(vault) - before, 40_000e6, "exact delivery");
        assertGt(ICToken(MUSDC).balanceOf(address(strat)), 0, "position remains");
    }

    function test_fork_withdrawTo_thenSettle_returnsRemainder() public {
        vm.prank(vault);
        strat.withdrawTo(40_000e6);
        vm.prank(vault);
        strat.settle();
        // Total returned ≈ supplied (same-block: negligible accrued interest).
        assertGe(IERC20(USDC).balanceOf(vault), 100_000e6 - 1, "no principal lost");
    }

    function test_fork_withdrawTo_onlyVault() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strat.withdrawTo(1e6);
    }

    function test_fork_withdrawTo_revertsBeforeExecute() public {
        MoonwellSupplyStrategy tmpl = new MoonwellSupplyStrategy();
        MoonwellSupplyStrategy fresh = MoonwellSupplyStrategy(payable(Clones.clone(address(tmpl))));
        fresh.initialize(vault, proposer, abi.encode(USDC, MUSDC, 1e6, 0, false));
        vm.prank(vault);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        fresh.withdrawTo(1e6);
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `forge test --match-contract MoonwellSupplyStrategyForkTest -vv`
Expected: FAIL — `withdrawTo` reverts `OnDemandExitUnsupported` (BaseStrategy default), `availableLiquidity` returns 0.

- [ ] **Step 4: Implement the overrides**

`src/strategies/MoonwellSupplyStrategy.sol`, after `positions()` (line 60):

```solidity
    /// @inheritdoc IStrategy
    /// @dev On-demand liquidity = our redeemable underlying, capped by market
    ///      cash. `exchangeRateStored` (no accrual) slightly understates — fine
    ///      for a serviceability signal; the vault verifies actual delivery.
    function availableLiquidity() external view override returns (uint256) {
        if (_state != State.Executed) return 0;
        uint256 held = (ICToken(mToken).balanceOf(address(this)) * ICToken(mToken).exchangeRateStored()) / 1e18;
        uint256 cash = ICToken(mToken).getCash();
        return held < cash ? held : cash;
    }

    /// @inheritdoc IStrategy
    /// @dev Mid-lifecycle partial redeem for the vault's instant-exit path.
    ///      Redeems exactly `assets` underlying and pushes it back; the rest of
    ///      the position keeps earning until `settle()`.
    function withdrawTo(uint256 assets) external override onlyVault {
        if (_state != State.Executed) revert NotExecuted();
        uint256 err = ICToken(mToken).redeemUnderlying(assets);
        if (err != 0) revert RedeemFailed();
        if (address(this).balance > 0) {
            if (!isNativeEthMarket) revert EthWrapFailed();
            IWETH(underlying).deposit{value: address(this).balance}();
        }
        _pushToVault(underlying, assets);
    }
```

`_state` is `internal` in BaseStrategy (line 48) — accessible. `NotExecuted` is a BaseStrategy error — inherited.

- [ ] **Step 5: Run fork tests to verify they pass**

Run: `forge test --match-contract MoonwellSupplyStrategyForkTest -vv`
Expected: all PASS. (Requires the Base RPC env var — use the repo's canonical name found in Step 2.)

- [ ] **Step 6: Full suite + commit**

Run: `forge test`

```bash
git add src/interfaces/ICToken.sol src/strategies/MoonwellSupplyStrategy.sol test/MoonwellSupplyStrategy.fork.t.sol
git commit -m "feat(strategy): MoonwellSupplyStrategy on-demand exit via redeemUnderlying"
```

---

### Task 8: Invariant tests, fmt, docs, wrap-up

**Files:**
- Create: `test/invariants/InstantLiquidityInvariant.t.sol`
- Modify: `docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md` (status + deferred items)

- [ ] **Step 1: Study the existing invariant harness**

Run: `ls test/invariants/ && head -100 test/invariants/*.t.sol`
Follow the existing handler/actor pattern (naming, `targetContract`, actor selection, bound() usage). Do not invent a new harness style.

- [ ] **Step 2: Write the invariant suite**

`test/invariants/InstantLiquidityInvariant.t.sol` — the three properties from spec §9, with a handler that randomly interleaves actions. Handler actions (each `bound()`ed and `vm.prank`ed):

- `deposit(actorSeed, amt)` — instant deposit (skipped/expected-revert when gate closed)
- `withdrawInstant(actorSeed, amt)` — bounded by `maxWithdraw(actor)`
- `requestRedeem(actorSeed, shares)` — Lane B (only while locked)
- `deployToStrategy(amt)` — governor batch moving float to the mock strategy; sets the ghost snapshot on first deploy of a "proposal"
- `strategyYield(delta)` — mint/burn USDC at the strategy, accumulate `ghostStrategyPnl += delta`
- `settle()` — strategy pushes all back, handler asserts `int256(vaultBal) − int256(ghostSnapshot) − vault.interimNetFlow() == ghostStrategyPnl`, then clears lock + calls `onProposalSettled` (pranked governor) and resets ghosts
- `toggleLaneA(ok)` — flips the mock router

Invariant functions:

```solidity
    function invariant_queueReserveSenior() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.reservedQueueAssets());
    }

    function invariant_noExitWithoutPricing() public view {
        if (handler.lockedWithoutLaneA()) {
            assertEq(vault.maxWithdraw(handler.currentActor()), 0);
            assertEq(vault.maxRedeem(handler.currentActor()), 0);
        }
    }
```

The PnL property (spec §9 invariant a) lives inside the handler's `settle()` action as an `assertEq` — it is a per-settlement property, not a global one.

- [ ] **Step 3: Run the invariant suite**

Run: `forge test --match-contract InstantLiquidityInvariant -vv`
Expected: PASS at the runs/depth configured in `foundry.toml`.

- [ ] **Step 4: Full regression + fmt + sizes**

Run: `forge test` — entire suite green.
Run: `forge build --sizes | grep -E "SyndicateVault|SyndicateGovernor|MoonwellSupplyStrategy"` — all < 24,576.
fmt: check the CI pin first (`grep -rn -A2 "foundry-toolchain" .github/workflows/`). Repo guardrail: `forge fmt` output differs across forge versions — only run fmt with a forge matching CI; if versions differ, surface to the user instead of committing fmt churn.

- [ ] **Step 5: Update the spec**

In `docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md`:
- `**Status:** Implemented — see docs/superpowers/plans/2026-07-19-instant-withdrawal-liquidity.md`
- §6: add *"`instantExitFeeBps` and `maxUnwindSlippageBps` deferred — the G1 Lane-A lock covers intra-proposal cycling; the slippage bound is a per-strategy concern (Moonwell `redeemUnderlying` has none). Revisit with the first AMM-position `withdrawTo` override."*
- §7: note *"Parameters are owner-set post-deploy (no `InitParams` change); defaults 0 = feature off."*
- §10: mark Q1/Q2 resolved accordingly.

- [ ] **Step 6: Final commit**

```bash
git add test/invariants/InstantLiquidityInvariant.t.sol docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md
git commit -m "test: instant-liquidity invariants (reserve seniority, pnl integrity, pricing gate)"
```

---

## Deviations from the spec (deliberate — carry into review)

| Spec item | Plan decision | Why |
|---|---|---|
| §7 `InitParams` extension | Setters only, defaults off | Avoids 10+ file constructor sweep; storage-safe on live proxies |
| §6 `instantExitFeeBps` | **Deferred** | G1 lock already blocks intra-proposal cycling; fee breaks 4626 preview exactness; EIP-170 budget |
| §6 `maxUnwindSlippageBps` | **Deferred** (per-strategy concern) | Moonwell `redeemUnderlying` is slippage-free; the bound belongs in AMM strategy overrides when they arrive |
| §4.3 `LeveragedAerodromeCLStrategy` refactor onto `withdrawTo` | **Out of scope** | Its custody model already provides mid-lifecycle exit, and `selfManagesFees` opts it out of governor PnL — no double-count risk while it keeps its bespoke path. Its `availableLiquidity` stays 0 (BaseStrategy default) so the vault never pulls from it |
| §3.2 buffer target on post-batch `totalAssets()` | Pre-batch asset balance | Deterministic, oracle-free, same "X% stays idle" semantics |

## Risks the implementer must watch

1. **EIP-170**: size-check after every vault task; escalate before extracting libraries.
2. **Governor mocks**: Task 5 adds a vault call inside `_finishSettlement`; governor tests that mock the vault need `interimNetFlow()` mocked to `int256(0)`.
3. **`forge fmt` version drift** (repo guardrail): only fmt with a forge matching this repo's CI pin.
4. **Fork pin + addresses**: `FORK_BLOCK` must stay pinned; verify `MUSDC` against existing repo constants before trusting the one in this plan.
5. **Rounding in capacity tests**: live-NAV share conversions carry the virtual-shares offset; where an exact `assertEq` flakes by 1 wei, use `assertApproxEqAbs(..., 1)` and note why.
