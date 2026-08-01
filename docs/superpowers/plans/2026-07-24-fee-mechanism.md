# Fee Mechanism Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Sherwood's four-fee sequential waterfall with the two-number hedge-fund model — an always-on time-weighted management fee and a performance fee above a high-water mark, each divided by governance-set splits — plus fee crystallization and an early-exit penalty on Lane A instant exits.

**Architecture:** The management-fee accrual base lives on `SyndicateVault` (not on strategies): the vault already observes every base-changing event (`executeProposal` stamp, Lane A deposit, Lane A instant exit, `strategyMint`/`strategyBurn`), so one accumulator replaces per-strategy metering across 12+ strategy clones. `SyndicateGovernor._distributeFees` becomes two split-distributions over that accrual and over above-high-water-mark profit. Lane A instant exits crystallize their pro-rata fees **into the vault** (retained, excluded from `totalAssets()`, paid out with correct recipients at the next settlement) rather than transferring at exit — this keeps the ERC-4626 withdraw path free of external calls and recipient resolution.

**Tech Stack:** Solidity 0.8.28, Foundry (forge 1.7.1+), OpenZeppelin upgradeable ERC-4626 / UUPS, `via_ir = true` with `optimizer_runs = 50`.

**Source spec:** `docs/specs/2026-07-24-fee-model-design.md` · **Product framing:** `docs/product/2026-07-24-fee-model-product-spec.md`

---

## Deviations from the spec (read before starting)

Three places where this plan deliberately differs from `docs/specs/2026-07-24-fee-model-design.md`. Each is justified; if you disagree, raise it before Task 4 rather than mid-implementation.

**D1 — The management-fee TWA lives on the vault, not on strategies.**
Spec checklist item 3 puts a "TWA-of-deployed-capital accumulator" on the strategy. There are 12+ concrete strategies (`src/strategies/*.sol`), all deployed as ERC-1167 clones, each needing its own accumulator and its own test. But every base-changing event already passes through `SyndicateVault`: the execute-time capital snapshot (`SyndicateGovernor.sol:395`), Lane A deposits (`SyndicateVault.sol:866`), Lane A instant exits (`SyndicateVault.sol:909`), and the custody hooks `strategyMint`/`strategyBurn` (`SyndicateVault.sol:1083`/`:1098`). One vault-side accumulator is complete, cheaper, and touches no strategy code.

**D2 — Instant-exit fees are retained by the vault, not transferred at exit.**
Spec §4.1 says `perfFeeExit` / `mgmtFeeExit` "route to the split recipients immediately via `_payFee`". The vault cannot resolve those recipients: the agent is the proposal's `proposer` (governor storage), and the protocol/guardian recipients live on the propose-time proposal snapshot. Resolving them from `_withdraw` means a governor call on the ERC-4626 hot path plus a new brick vector. Instead the exiting shares' fees are **booked into `_crystallizedMgmt` / `_crystallizedPerf` on the vault**, excluded from `totalAssets()` (so the remaining holders' price-per-share is unaffected — the same economic result), and paid to the correct snapshot recipients at the next settlement through the existing `_payFee` escrow. Net incidence is identical; the exit path stays call-free.

**D3 — `selfManagesFees` strategies still pay the management fee.**
Spec §6 says the self-managed path "folds its management + performance legs the same way". `selfManagesFees` exists because the governor's float-delta *PnL* misreads custody-model deposits as profit (`SyndicateGovernor.sol:1093-1097`). The management fee does not use PnL at all, so only the **performance** leg needs skipping. Task 9 charges management on the self-fee'd path and keeps performance skipped.

## Verified before writing this plan

- **The volume fee was never built.** `grep -rn "volumeFee\|_chargeVolume\|VolumeFeePaid" src/` returns nothing, so spec §2.3's "removal" is a no-op. There is no deletion task; the only thing actually removed is the four-step sequential waterfall in `_distributeFees` (Task 6).
- **Governor linear storage does not move.** The split snapshots go inside `StrategyProposal`, which lives in the `_proposals` mapping, so the frozen slot pins in `test/governor/GovernorLayoutPins.t.sol` (slots 0-81) are untouched.
- **The Lane B queue is structurally excluded from exit fees.** `VaultWithdrawalQueue.claim` reverts `VaultLocked` unless `!redemptionsLocked()`, and the exit-fee gate requires `laneA == true` (which requires `redemptionsLocked()`). The two windows cannot overlap, so no `caller`-based exemption is needed in `previewRedeem` — which is fortunate, because a view function has no caller context.

## Decisions taken

**Q1 — Idle capital earns no management fee. DECIDED 2026-07-24: accept the behaviour, correct the product-spec wording.**

The accrual base is stamped at `executeProposal` and zeroed at settle, so capital sitting in the vault between proposals accrues nothing. This matches the design spec's "time-weighted deployed capital over the proposal" but contradicts the product spec's "2%/yr on fund assets (AUM) … **Always**".

Charging continuously is not merely more work — it is **blocked on recipient resolution**. The management fee splits 70/20/10, and "the agent" is `proposal.proposer` (`SyndicateGovernor.sol:1157`); the protocol/guardian recipients and both splits come from the propose-time snapshot on `StrategyProposal`. Between proposals there is no proposal, so there is no address to send the agent's 70% to. A permissionless `crystallizeManagementFee()` hits exactly the wall that forced deviation D2 on the exit path.

The behaviour is also defensible on the merits: between proposals nobody is managing the money, guardians have nothing to review, and `redemptionsLocked()` is false so LPs can withdraw freely. A management fee with no management is the anomaly, not its absence.

Exposure is a function of duty cycle only. With the factory default `cooldownPeriod: 1 hours` (`SyndicateFactory.sol:420`) against strategy durations up to 30 days, back-to-back proposals lose a rounding error. The real (accepted) case is a fund whose agent stops proposing while LPs stay deposited — that fund charges 0%/yr.

Rejected alternatives, for the record:
- *Carry the gap into the next settlement* (rebase the base to vault float at settle instead of zeroing). Closes cooldown gaps, does **not** close dormancy, and forces `_adjustMgmtBase` onto the unconditional `_deposit`/`_withdraw` paths — a permanent ~5k gas cost on every deposit for a partial fix.
- *Move the mgmt-fee recipients onto the vault + permissionless crystallize.* Fully closes it, but the agent's 70% would go to a standing vault address rather than the proposer who earned it, breaking the "the agent is the largest earner, in every market" incentive the product spec is built on. That is a product decision, not an implementation one.

**Action:** no code change. Task 10 Step 3 carries the exact product-spec wording edit.

**Q2 — Final performance-fee cap. DECIDED 2026-07-24: `MAX_PERFORMANCE_FEE_BPS = 3000` (30%).**

Spec §2.2 left the ceiling open, noting the current 1500 must rise past 2000 for a 20% headline and proposing 3000. Confirmed at 3000. Task 1 is unblocked.

The ceiling is not the headline rate — it is the outer bound governance can ever set. Three separate limits stack below it, so 30% is a backstop, not a target:

| Limit | Value | Owner | Enforced at |
|---|---|---|---|
| `FeeConstants.MAX_PERFORMANCE_FEE_BPS` | 3000 | protocol (code) | `GovernorParameters.MAX_PERFORMANCE_FEE_CAP` + `SyndicateVault.MAX_AGENT_FEE_BPS` |
| `_params.maxPerformanceFeeBps` | per-vault, tunable; **factory default 2000** (Q3) | governor params | `_clampPerformanceFee` at propose AND at settle |
| `vault.performanceFeeBps()` | proposed headline **2000** | vault owner | `setAgentFeeBps`, snapshotted at propose |

A vault that never calls `setAgentFeeBps` charges `FeeConstants.DEFAULT_AGENT_FEE_BPS` = 500 (5%), unchanged. The headline 20% is a per-vault owner setting, not a protocol constant — nothing in this plan makes 30% reachable by default.

`SyndicateFactory._defaultGovernorParams()` currently hardcodes `maxPerformanceFeeBps: 1500` (`SyndicateFactory.sol:419`). Leaving it at 1500 would silently clamp every new vault below the 20% headline at settle — exactly the failure `_clampPerformanceFee`'s `FeeClamped` event exists to surface. Its new value is Q3.

**Q3 — Factory default `maxPerformanceFeeBps`. DECIDED 2026-07-24: 2000 (the headline), not the 3000 ceiling.**

Raising the protocol constant to 3000 does not by itself decide what a *new* fund starts with. Two options, different depositor-protection profiles:

- *3000 (the ceiling).* The governor adds no restriction beyond the protocol constant, so a vault owner can unilaterally `setAgentFeeBps(3000)` and charge 30% on day one with no oversight.
- *2000 (the headline) — **chosen**.* A vault owner who sets above 20% is clamped to 20% at settle. Charging more than the advertised headline then requires an explicit governor param change, which is a visible, separately-authorized action. The protocol constant stays at 3000, so the headroom still exists when governance wants it.

This matters because `_clampPerformanceFee` resolves the conflict **silently** — it emits `FeeClamped` and continues rather than reverting. A too-permissive default therefore fails open (owner quietly charges more than advertised) while a too-restrictive one fails closed (agent quietly earns less, event emitted). Fail-closed is the right default for a depositor-facing rate.

Implemented as a named constant, not a literal: `FeeConstants` exists precisely so fee numbers cannot be hand-edited into divergence (the L1 finding), and a bare `2000` in the factory would be exactly that.

## Open questions (do not block; flag at review)

1. **Instant-exit-penalty basis.** Spec §5 charges the penalty "only on the `withdrawTo`-sourced portion" — the part of an exit that forces the strategy to unwind, as opposed to the part idle float absorbs painlessly. Task 8 implements exactly that. The alternative is a flat penalty on the whole exit.

   `previewRedeem` is exact and monotone under **both** bases (`d(net)/d(assets) = 1 − bps/10_000 > 0`), so that is not the differentiator. Three things actually differ:

   | | Pulled portion (implemented) | Whole exit |
   |---|---|---|
   | `previewWithdraw` | fee function is kinked at the float boundary, so not cleanly invertible — Task 8 grosses up once and rounds conservatively, burning marginally more shares than strictly needed | exactly invertible: `net = gross × (1 − bps/10_000)` |
   | Quote stability | depends on float, so another exit earlier in the same block can turn a 0 quote into a nonzero one | constant |
   | Incidence | only exits that forced an unwind pay | every instant exit pays, including ones idle float absorbed |

   **The argument against the implemented basis:** it creates a race. In a rush for the exit the first out pays nothing (float covers them) and the last pays full. That is correct on damage grounds but adds pressure to run early — the opposite of what an anti-mercenary term wants. A flat basis prices everyone identically and creates no such ordering effect.

   **Kept as spec'd** because it matches the fee's stated purpose and the run pressure is second-order: instant-exit capacity is already bounded by `IStrategy.availableLiquidity()` (`SyndicateVault.sol:755`) regardless of the penalty. If you would rather have the flat basis, `_exitPenalty` in Task 8 Step 3 collapses to `(netAssets * bps) / FeeConstants.BPS_DENOMINATOR` behind the same Lane A gate, `previewWithdraw` loses its gross-up comment, and `test_noPenaltyWhenServedEntirelyFromFloat` inverts into `test_penaltyAppliesEvenWhenServedFromFloat`.

---

## File structure

| File | Change | Responsibility after this plan |
|---|---|---|
| `src/FeeConstants.sol` | Modify | Perf-fee ceiling (raised), agent-fee default, shared `BPS_DENOMINATOR` |
| `src/interfaces/IProtocolConfig.sol` | Modify | `MgmtSplit` / `PerfSplit` structs, setters, errors |
| `src/ProtocolConfig.sol` | Modify | Stores + validates the two splits (each summing to 10 000) |
| `src/interfaces/ISyndicateGovernor.sol` | Modify | `StrategyProposal` gains two packed split-snapshot fields |
| `src/interfaces/ISyndicateVault.sol` | Modify | `performanceFeeBps`, mgmt-accrual hooks, HWM + crystallized getters |
| `src/SyndicateVault.sol` | Modify | Mgmt-fee accrual accumulator, high-water mark, exit-fee preview/collection, exit penalty |
| `src/SyndicateGovernor.sol` | Modify | `_distributeFees` rewritten to two split-distributions; execute-time accrual stamp |
| `src/SyndicateFactory.sol` | Modify | Default `maxPerformanceFeeBps` raised to the new cap |
| `test/fees/FeeConstantsCap.t.sol` | Create | The raised cap propagates to every consumer |
| `test/fees/ProtocolConfigSplits.t.sol` | Create | Split validation and events |
| `test/fees/MgmtFeeAccrual.t.sol` | Create | Time-weighting, mid-proposal flows, consume-and-reset |
| `test/fees/HighWaterMark.t.sol` | Create | No double-charge across loss-then-recover; ratchet |
| `test/fees/FeeDistribution.t.sol` | Create | End-to-end settle: mgmt always, perf above HWM, splits, fail-open |
| `test/fees/CrystallizeOnExit.t.sol` | Create | Instant exiter pays; no double-count; exit timing is fee-neutral |
| `test/fees/InstantExitFee.t.sol` | Create | Penalty on the pulled portion only; accrues to the vault |

**New vault storage (4 slots, `__gap` 32 → 28):**

```
_mgmtAssetSeconds       uint256                                    1 slot
_mgmtBase / _mgmtLastUpdate            uint216 + uint40            1 slot (packed)
_highWaterPricePerShare uint256                                    1 slot
_crystallizedMgmt / _crystallizedPerf / _instantExitFeeBps
                        uint128 + uint112 + uint16                 1 slot (packed)
```

`GovernorParameters.MAX_PERFORMANCE_FEE_CAP` and `SyndicateVault.MAX_AGENT_FEE_BPS` both already derive from `FeeConstants.MAX_PERFORMANCE_FEE_BPS`, so raising the one constant in Task 1 moves them with no edit.

Governor linear storage is **unchanged** — the split snapshots go inside `StrategyProposal`, which lives in a mapping, so `test/governor/GovernorLayoutPins.t.sol` slot pins do not move.

---

### Task 1: Raise the performance-fee ceiling and add a shared BPS denominator

The model needs a 20% headline performance fee, but `FeeConstants.MAX_PERFORMANCE_FEE_BPS` is 1500 and is the single source of truth for the vault cap, the governor param cap, and the LeveragedAero strategy check. Raise it once; everything follows.

**Files:**
- Modify: `src/FeeConstants.sol`
- Modify: `src/SyndicateFactory.sol:419`
- Test: `test/fees/FeeConstantsCap.t.sol` (create)

- [ ] **Step 1: Write the failing test**

Create `test/fees/FeeConstantsCap.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeeConstants} from "../../src/FeeConstants.sol";
import {GovernorParameters} from "../../src/GovernorParameters.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";

/// @notice The two-number fee model needs a 20% headline performance fee, so the
///         protocol ceiling must sit at or above 2000 bps. This pins the raised
///         ceiling AND that every consumer still derives from the one constant
///         (no hand-edited literal drifting out of sync — the L1 finding).
contract FeeConstantsCapTest is Test {
    function test_ceilingAllowsTwentyPercentHeadline() public pure {
        assertEq(FeeConstants.MAX_PERFORMANCE_FEE_BPS, 3000, "ceiling should be 30%");
        assertGe(FeeConstants.MAX_PERFORMANCE_FEE_BPS, 2000, "must permit a 20% headline");
    }

    function test_consumersDeriveFromTheConstant() public pure {
        assertEq(GovernorParameters.MAX_PERFORMANCE_FEE_CAP, FeeConstants.MAX_PERFORMANCE_FEE_BPS);
        assertEq(SyndicateVault.MAX_AGENT_FEE_BPS, FeeConstants.MAX_PERFORMANCE_FEE_BPS);
    }

    function test_bpsDenominatorIsTenThousand() public pure {
        assertEq(FeeConstants.BPS_DENOMINATOR, 10_000);
    }

    /// @notice Decision Q3: a NEW fund's governor cap starts at the advertised
    ///         headline (20%), not at the protocol ceiling (30%). `_clampPerformanceFee`
    ///         resolves conflicts silently, so a too-permissive default would let a
    ///         vault owner quietly charge above the headline with no visible step.
    ///         Fail-closed by default; governance raises it deliberately.
    function test_factoryDefaultCapIsTheHeadlineNotTheCeiling() public pure {
        assertEq(FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS, 2000);
        assertLt(
            FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS,
            FeeConstants.MAX_PERFORMANCE_FEE_BPS,
            "default must leave governance headroom"
        );
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-path test/fees/FeeConstantsCap.t.sol -vv`
Expected: compile error — `FeeConstants.BPS_DENOMINATOR` is not defined. Comment that one assertion out and re-run to confirm `test_ceilingAllowsTwentyPercentHeadline` FAILs with `1500 != 3000`, then restore it.

- [ ] **Step 3: Raise the ceiling and add the denominator**

Replace the body of `src/FeeConstants.sol`'s library:

```solidity
library FeeConstants {
    /// @notice Hard ceiling on the total performance fee, in basis points (30%).
    /// @dev Raised 1500 -> 3000 for the two-number fee model (spec
    ///      2026-07-24-fee-model-design §2.2): the headline performance fee is
    ///      20% and is split four ways downstream, so the ceiling must clear
    ///      2000 with governance headroom. This is the ONE literal — the vault's
    ///      `MAX_AGENT_FEE_BPS` and the governor's `MAX_PERFORMANCE_FEE_CAP`
    ///      both derive from it (L1: never hand-edit a mirror).
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 3000;

    /// @notice Per-vault governor cap a NEWLY DEPLOYED fund starts with (20%) —
    ///         the advertised headline, deliberately below the 30% protocol
    ///         ceiling (plan decision Q3).
    /// @dev `_clampPerformanceFee` resolves a vault/param conflict SILENTLY
    ///      (emits `FeeClamped`, does not revert), so this default decides which
    ///      way a misconfiguration fails. At 3000 it fails OPEN — a vault owner
    ///      quietly charges above the headline with no separate authorization.
    ///      At 2000 it fails CLOSED — the agent earns the headline and an event
    ///      is emitted. Raising a specific vault past the headline is then an
    ///      explicit, visible governor param change. Named here rather than
    ///      inlined in `SyndicateFactory` so it cannot drift (L1).
    uint256 internal constant DEFAULT_MAX_PERFORMANCE_FEE_BPS = 2000;

    /// @notice Default agent performance fee a vault charges until its owner
    ///         sets one, in basis points (5%). Single source of truth for the
    ///         vault getter's fallback (mirror it in any off-chain default).
    uint256 internal constant DEFAULT_AGENT_FEE_BPS = 500;

    /// @notice Basis-point denominator, shared by the vault and the governor so
    ///         the fee math on both sides of the governor<->vault boundary uses
    ///         one constant. Compile-time, so it adds no runtime bytecode.
    uint256 internal constant BPS_DENOMINATOR = 10_000;
}
```

- [ ] **Step 4: Point the factory's default governor param at the headline**

In `src/SyndicateFactory.sol`, change line 419 from the stale `1500` to the headline default (decision Q3 — **not** `MAX_PERFORMANCE_FEE_BPS`; that would let a vault owner charge 30% with no governance step):

```solidity
            maxPerformanceFeeBps: FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS,
```

If the file has no `FeeConstants` import, add it below the other `./` imports:

```solidity
import {FeeConstants} from "./FeeConstants.sol";
```

Sanity-check the bound holds — `GovernorParameters._validateParamBounds` rejects `maxPerformanceFeeBps > MAX_PERFORMANCE_FEE_CAP` at `initialize` (`GovernorParameters.sol:165`), and 2000 < 3000, so every factory-deployed governor still initializes.

- [ ] **Step 5: Run the test and fix suites that pin the old cap**

Run: `forge test --match-path test/fees/FeeConstantsCap.t.sol -vv`
Expected: 3 tests PASS.

Run: `forge test 2>&1 | tail -30`
Expected: any test asserting the literal `1500` FAILs. Change each such assertion to `FeeConstants.MAX_PERFORMANCE_FEE_BPS` — never to the literal `3000`, which reintroduces exactly the drift this constant exists to prevent. Likely files: `test/GovernorParameters.t.sol`, `test/SyndicateVault.t.sol`, `test/SyndicateFactory.t.sol`.

Re-run: `forge test 2>&1 | tail -20`
Expected: whole suite green.

- [ ] **Step 6: Commit**

```bash
git add src/FeeConstants.sol src/SyndicateFactory.sol test/fees/FeeConstantsCap.t.sol test/
git commit -m "feat(fees): raise performance-fee ceiling to 30% and share BPS denominator"
```

---

### Task 2: ProtocolConfig — management and performance splits

The depositor pays two numbers; every recipient is paid from a governance-set split of those two. This task adds the split storage and its "must sum to 10 000" validation.

**Files:**
- Modify: `src/interfaces/IProtocolConfig.sol`
- Modify: `src/ProtocolConfig.sol`
- Test: `test/fees/ProtocolConfigSplits.t.sol` (create)

- [ ] **Step 1: Write the failing test**

Create `test/fees/ProtocolConfigSplits.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";

/// @notice The two-number model pays everyone out of internal splits. A split
///         that does not sum to 10_000 either strands assets in the vault with no
///         claimant or over-distributes past the computed fee, so the sum is
///         enforced at set time — the config can never hold a payable-but-wrong split.
contract ProtocolConfigSplitsTest is Test {
    ProtocolConfig cfg;
    address owner = makeAddr("owner");

    function setUp() public {
        cfg = new ProtocolConfig(owner);
    }

    function test_setMgmtSplitStoresProposedDefaults() public {
        vm.prank(owner);
        cfg.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 7000, protocolBps: 2000, guardianBps: 1000}));

        IProtocolConfig.MgmtSplit memory s = cfg.mgmtSplit();
        assertEq(s.agentBps, 7000);
        assertEq(s.protocolBps, 2000);
        assertEq(s.guardianBps, 1000);
    }

    function test_setPerfSplitStoresProposedDefaults() public {
        vm.prank(owner);
        cfg.setPerfSplit(
            IProtocolConfig.PerfSplit({agentBps: 6000, protocolBps: 1500, guardianBps: 1500, ownerBps: 1000})
        );

        IProtocolConfig.PerfSplit memory s = cfg.perfSplit();
        assertEq(s.agentBps, 6000);
        assertEq(s.protocolBps, 1500);
        assertEq(s.guardianBps, 1500);
        assertEq(s.ownerBps, 1000);
    }

    function test_revertsWhenMgmtSplitDoesNotSumToTenThousand() public {
        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidSplit.selector);
        cfg.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 7000, protocolBps: 2000, guardianBps: 999}));
    }

    function test_revertsWhenPerfSplitDoesNotSumToTenThousand() public {
        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidSplit.selector);
        cfg.setPerfSplit(
            IProtocolConfig.PerfSplit({agentBps: 6000, protocolBps: 1500, guardianBps: 1500, ownerBps: 1001})
        );
    }

    /// @notice The agent-earns-most invariant from the product spec: the agent's
    ///         slice is strictly larger than everyone else's combined, in both
    ///         splits, at the proposed defaults. Not enforced on-chain (governance
    ///         may choose otherwise) but pinned so a careless default change is
    ///         visible in review.
    function test_agentIsTheLargestSliceAtProposedDefaults() public {
        vm.startPrank(owner);
        cfg.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 7000, protocolBps: 2000, guardianBps: 1000}));
        cfg.setPerfSplit(
            IProtocolConfig.PerfSplit({agentBps: 6000, protocolBps: 1500, guardianBps: 1500, ownerBps: 1000})
        );
        vm.stopPrank();

        IProtocolConfig.MgmtSplit memory m = cfg.mgmtSplit();
        assertGt(m.agentBps, uint256(m.protocolBps) + m.guardianBps);

        IProtocolConfig.PerfSplit memory p = cfg.perfSplit();
        assertGt(p.agentBps, uint256(p.protocolBps) + p.guardianBps + p.ownerBps);
    }

    function test_onlyOwnerCanSetSplits() public {
        vm.expectRevert();
        cfg.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 7000, protocolBps: 2000, guardianBps: 1000}));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-path test/fees/ProtocolConfigSplits.t.sol -vv`
Expected: compile error — `IProtocolConfig.MgmtSplit` and `setMgmtSplit` do not exist.

- [ ] **Step 3: Add the structs, errors and events to the interface**

Add inside `interface IProtocolConfig` in `src/interfaces/IProtocolConfig.sol`:

```solidity
    /// @notice Split of the management fee. Members are `uint16` so the whole
    ///         struct occupies ONE slot both here and when embedded in
    ///         `StrategyProposal`. Must sum to `FeeConstants.BPS_DENOMINATOR`.
    struct MgmtSplit {
        uint16 agentBps;
        uint16 protocolBps;
        uint16 guardianBps;
    }

    /// @notice Split of the performance fee. `uint16` members for the same
    ///         one-slot reason. Must sum to `FeeConstants.BPS_DENOMINATOR`.
    struct PerfSplit {
        uint16 agentBps;
        uint16 protocolBps;
        uint16 guardianBps;
        uint16 ownerBps;
    }

    /// @notice A split whose members do not sum to exactly 10_000 bps.
    error InvalidSplit();

    event MgmtSplitSet(uint16 agentBps, uint16 protocolBps, uint16 guardianBps);
    event PerfSplitSet(uint16 agentBps, uint16 protocolBps, uint16 guardianBps, uint16 ownerBps);

    function mgmtSplit() external view returns (MgmtSplit memory);
    function perfSplit() external view returns (PerfSplit memory);
    function setMgmtSplit(MgmtSplit calldata s) external;
    function setPerfSplit(PerfSplit calldata s) external;
```

- [ ] **Step 4: Implement in ProtocolConfig**

Add the import at the top of `src/ProtocolConfig.sol`:

```solidity
import {FeeConstants} from "./FeeConstants.sol";
```

Add the state and setters inside the contract. Leave `protocolFeeBps` / `guardianFeeBps` in place — Task 6 stops reading them, but this contract is not upgradeable and governors accept a replacement address, so removing them now changes the deployed shape for no benefit:

```solidity
    /// @notice Management-fee split (agent / protocol / guardian). Read at
    ///         propose time and snapshotted onto the proposal — never read live
    ///         at settle, exactly like the fee recipients above.
    MgmtSplit private _mgmtSplit;

    /// @notice Performance-fee split (agent / protocol / guardian / owner).
    PerfSplit private _perfSplit;

    function mgmtSplit() external view returns (MgmtSplit memory) {
        return _mgmtSplit;
    }

    function perfSplit() external view returns (PerfSplit memory) {
        return _perfSplit;
    }

    /// @notice Set the management-fee split. Members must sum to exactly
    ///         10_000 bps: a short sum strands assets in the vault with no
    ///         claimant, a long sum over-distributes past the computed fee.
    function setMgmtSplit(MgmtSplit calldata s) external onlyOwner {
        if (uint256(s.agentBps) + s.protocolBps + s.guardianBps != FeeConstants.BPS_DENOMINATOR) {
            revert InvalidSplit();
        }
        _mgmtSplit = s;
        emit MgmtSplitSet(s.agentBps, s.protocolBps, s.guardianBps);
    }

    /// @notice Set the performance-fee split. Same sum rule as `setMgmtSplit`.
    function setPerfSplit(PerfSplit calldata s) external onlyOwner {
        if (uint256(s.agentBps) + s.protocolBps + s.guardianBps + s.ownerBps != FeeConstants.BPS_DENOMINATOR) {
            revert InvalidSplit();
        }
        _perfSplit = s;
        emit PerfSplitSet(s.agentBps, s.protocolBps, s.guardianBps, s.ownerBps);
    }
```

- [ ] **Step 5: Run the tests**

Run: `forge test --match-path test/fees/ProtocolConfigSplits.t.sol -vv`
Expected: 6 tests PASS.

Run: `forge test --match-path test/ProtocolConfig.t.sol -vv`
Expected: PASS — nothing existing was changed.

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/IProtocolConfig.sol src/ProtocolConfig.sol test/fees/ProtocolConfigSplits.t.sol
git commit -m "feat(fees): add management and performance split config"
```

---

### Task 3: Snapshot the splits onto the proposal at propose

Rates and recipients are snapshotted at propose so settlement uses what voters approved (`SyndicateGovernor.sol:305-313`). The splits must join that snapshot. The two flat rate fields (`snapshotProtocolFeeBps`, `snapshotGuardianFeeBps`) stop being written; the two **recipients** are still needed and keep being written.

**Files:**
- Modify: `src/interfaces/ISyndicateGovernor.sol` (append to `StrategyProposal`)
- Modify: `src/SyndicateGovernor.sol:305-313`
- Test: `test/fees/FeeDistribution.t.sol` (create — first test only; Tasks 6 and 9 extend it)

- [ ] **Step 1: Write the failing test**

Create `test/fees/FeeDistribution.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";

/// @notice Fee-distribution coverage for the two-number model. This first test
///         pins that both splits are snapshotted at propose — a post-vote split
///         change must never move what settlement pays out.
contract FeeDistributionTest is Test {
    ProtocolConfig cfg;

    address cfgOwner = makeAddr("cfgOwner");
    address protocolRecipient = makeAddr("protocolRecipient");
    address guardianRecipient = makeAddr("guardianRecipient");

    function setUp() public virtual {
        cfg = new ProtocolConfig(cfgOwner);
        vm.startPrank(cfgOwner);
        cfg.setProtocolFeeRecipient(protocolRecipient);
        cfg.setGuardiansFeeRecipient(guardianRecipient);
        cfg.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 7000, protocolBps: 2000, guardianBps: 1000}));
        cfg.setPerfSplit(
            IProtocolConfig.PerfSplit({agentBps: 6000, protocolBps: 1500, guardianBps: 1500, ownerBps: 1000})
        );
        vm.stopPrank();
    }

    /// @notice `StrategyProposal` carries both splits, and a later config change
    ///         does not reach back into a stored snapshot.
    function test_proposalStructCarriesBothSplitSnapshots() public {
        IProtocolConfig.MgmtSplit memory atProposeTime = cfg.mgmtSplit();
        assertEq(atProposeTime.agentBps, 7000);

        vm.prank(cfgOwner);
        cfg.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 5000, protocolBps: 3000, guardianBps: 2000}));
        assertEq(cfg.mgmtSplit().agentBps, 5000, "config is live-mutable");

        ISyndicateGovernor.StrategyProposal memory p;
        p.snapshotMgmtSplit = atProposeTime;
        p.snapshotPerfSplit = cfg.perfSplit();

        assertEq(p.snapshotMgmtSplit.agentBps, 7000, "snapshot froze the pre-change split");
        assertEq(p.snapshotPerfSplit.ownerBps, 1000);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-path test/fees/FeeDistribution.t.sol -vv`
Expected: compile error — `StrategyProposal` has no member `snapshotMgmtSplit`.

- [ ] **Step 3: Append the snapshot fields to StrategyProposal**

Add the import at the top of `src/interfaces/ISyndicateGovernor.sol`:

```solidity
import {IProtocolConfig} from "./IProtocolConfig.sol";
```

Append **at the very end** of `struct StrategyProposal` (after `requiredCoverage`) — the struct is append-only for beacon-upgraded governors:

```solidity
        // ── APPENDED: two-number fee model (spec 2026-07-24) ──
        /// @notice Management-fee split snapshotted from `ProtocolConfig` at
        ///         propose, so a post-vote governance change cannot move what
        ///         this proposal pays. One slot (three uint16 members).
        IProtocolConfig.MgmtSplit snapshotMgmtSplit;
        /// @notice Performance-fee split snapshotted at propose. One slot.
        IProtocolConfig.PerfSplit snapshotPerfSplit;
```

Mark the two now-unused rate fields deprecated in place — removing a field from a struct stored in a mapping is a layout change for every existing proposal. Add above `uint256 snapshotProtocolFeeBps;`:

```solidity
        /// @custom:deprecated Two-number fee model (spec 2026-07-24). The flat
        ///      protocol rate is replaced by the protocol slice of
        ///      `snapshotMgmtSplit` / `snapshotPerfSplit`. Field retained for
        ///      layout parity with in-flight proposals; no longer written or read.
```

Add the equivalent comment above `uint256 snapshotGuardianFeeBps;`.

- [ ] **Step 4: Snapshot the splits in `propose`**

In `src/SyndicateGovernor.sol`, replace the block at lines 305-313:

```solidity
        // Snapshot fee recipients AND both splits at propose time so settlement
        // uses what voters actually saw, not a post-vote governance change.
        // The former flat `protocolFeeBps` / `guardianFeeBps` rates are no longer
        // read — the two-number model derives every recipient's cut from the
        // splits (spec 2026-07-24-fee-model-design §2).
        {
            IProtocolConfig cfg = IProtocolConfig(protocolConfig);
            p.snapshotProtocolFeeRecipient = cfg.protocolFeeRecipient();
            p.snapshotGuardiansFeeRecipient = cfg.guardiansFeeRecipient();
            p.snapshotMgmtSplit = cfg.mgmtSplit();
            p.snapshotPerfSplit = cfg.perfSplit();
        }
```

- [ ] **Step 5: Run the test and build**

Run: `forge test --match-path test/fees/FeeDistribution.t.sol -vv`
Expected: 1 test PASS.

Run: `forge build`
Expected: compiles. If `propose` hits Yul stack-too-deep, move the four reads into a private `_snapshotFeeConfig(StrategyProposal storage p)` helper — the file already uses that pattern deliberately (see the comment at `SyndicateGovernor.sol:283`).

- [ ] **Step 6: Confirm the governor layout did not move**

Run: `forge test --match-path test/governor/GovernorLayoutPins.t.sol -vv`
Expected: PASS — the split fields live inside a mapping value, so no linear slot moved.

Run: `./script/check-layout-goldens.sh`
Expected: PASS. If it reports a diff on the `_proposals` value type, regenerate and inspect that **only appended members** changed:

```bash
forge inspect SyndicateGovernor storageLayout --json > script/syndicate-governor-layout.golden.json
git diff script/syndicate-governor-layout.golden.json
```

- [ ] **Step 7: Commit**

```bash
git add src/interfaces/ISyndicateGovernor.sol src/SyndicateGovernor.sol test/fees/FeeDistribution.t.sol script/
git commit -m "feat(fees): snapshot management and performance splits onto the proposal"
```

---

### Task 4: Vault — management-fee accrual accumulator

The management fee is time-weighted on the fund's assets. The accumulator integrates `base × elapsed` across every base-changing event and hands the total to the governor at settle. Deviation D1: this lives on the vault, not on strategies.

**Files:**
- Modify: `src/SyndicateVault.sol` (storage, `_touchMgmt`, hooks, `consumeMgmtAccrual`)
- Modify: `src/interfaces/ISyndicateVault.sol`
- Modify: `src/SyndicateGovernor.sol:395` (stamp the base at execute)
- Test: `test/fees/MgmtFeeAccrual.t.sol` (create)

- [ ] **Step 1: Write the failing test**

Create `test/fees/MgmtFeeAccrual.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice The management fee is charged on assets x time, so the accumulator
///         must integrate the base over the proposal — not sample it at settle.
///         A fund that halves its book at the midpoint owes three quarters of the
///         flat-book fee, and these tests pin exactly that.
contract MgmtFeeAccrualTest is Test {
    SyndicateVault vault;
    ERC20Mock usdc;

    address owner = makeAddr("owner");
    address constant MOCK_GOVERNOR = address(0xF00D);

    uint256 constant BASE = 1_000_000e6; // $1M, 6 decimals

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        BatchExecutorLib executorLib = new BatchExecutorLib();
        MockAgentRegistry agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (
                ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 200 // 2%/yr
                })
            )
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));
    }

    /// @notice A flat $1M book held for 30 days accrues 30 days of asset-seconds.
    function test_flatBookAccruesAssetSecondsLinearly() public {
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalExecuted(BASE);

        vm.warp(block.timestamp + 30 days);

        vm.prank(MOCK_GOVERNOR);
        uint256 accrued = vault.consumeMgmtAccrual();

        assertEq(accrued, BASE * 30 days, "asset-seconds = base x elapsed");
    }

    /// @notice Halving the book at the midpoint owes three quarters of the
    ///         flat-book accrual — this is the whole point of time-weighting.
    function test_midProposalOutflowReducesAccrualProRata() public {
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalExecuted(BASE);

        vm.warp(block.timestamp + 15 days);
        vm.prank(MOCK_GOVERNOR);
        vault.adjustMgmtBase(-int256(BASE / 2));

        vm.warp(block.timestamp + 15 days);
        vm.prank(MOCK_GOVERNOR);
        uint256 accrued = vault.consumeMgmtAccrual();

        assertEq(accrued, (BASE * 15 days) + ((BASE / 2) * 15 days));
        assertEq(accrued, (BASE * 30 days) * 3 / 4, "three quarters of the flat book");
    }

    /// @notice Consuming resets the accumulator AND the base, so nothing accrues
    ///         between proposals (documented limitation: idle capital is free).
    function test_consumeResetsAccumulatorAndBase() public {
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalExecuted(BASE);
        vm.warp(block.timestamp + 30 days);

        vm.prank(MOCK_GOVERNOR);
        vault.consumeMgmtAccrual();

        vm.warp(block.timestamp + 90 days);
        vm.prank(MOCK_GOVERNOR);
        uint256 second = vault.consumeMgmtAccrual();

        assertEq(second, 0, "no accrual between proposals");
    }

    /// @notice The accrual hooks are governor-only — an LP must not be able to
    ///         stamp a base and mint a fee obligation out of nothing.
    function test_accrualHooksAreGovernorOnly() public {
        vm.expectRevert(ISyndicateVault.NotGovernor.selector);
        vault.onProposalExecuted(BASE);

        vm.expectRevert(ISyndicateVault.NotGovernor.selector);
        vault.consumeMgmtAccrual();

        vm.expectRevert(ISyndicateVault.NotGovernor.selector);
        vault.adjustMgmtBase(1);
    }

    /// @notice The view getter reports accrual pending since the last touch, so
    ///         off-chain readers and the exit-fee math see the live figure with
    ///         no state write.
    function test_pendingAccrualIsVisibleWithoutTouching() public {
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalExecuted(BASE);
        vm.warp(block.timestamp + 10 days);

        assertEq(vault.mgmtAccrualAssetSeconds(), BASE * 10 days);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-path test/fees/MgmtFeeAccrual.t.sol -vv`
Expected: compile error — `onProposalExecuted`, `adjustMgmtBase`, `consumeMgmtAccrual`, `mgmtAccrualAssetSeconds` do not exist.

- [ ] **Step 3: Add the vault storage**

In `src/SyndicateVault.sol`, delete the `uint256[32] private __gap;` declaration and its comment (lines 183-186) and put this in its place:

```solidity
    /// @notice Integral of the management-fee base over time, in asset-seconds.
    ///         `mgmtFee = _mgmtAssetSeconds * managementFeeBps / (10_000 * 365 days)`.
    ///         Accumulated here rather than on the strategy: every base-changing
    ///         event (execute stamp, Lane A deposit, Lane A instant exit, the
    ///         `strategyMint`/`strategyBurn` custody hooks) already passes through
    ///         this contract, so one accumulator covers all 12+ strategy clones.
    uint256 private _mgmtAssetSeconds;

    /// @notice Current management-fee base (fund assets at the last touch) and
    ///         the timestamp of that touch. Packed: 216 + 40 = 256 bits. `uint216`
    ///         holds ~1e65 of any 18-decimal asset — no realistic book overflows it.
    uint216 private _mgmtBase;
    uint40 private _mgmtLastUpdate;

    /// @notice Per-share price at the fund's prior peak, scaled by `_PPS_SCALE`.
    ///         The performance fee applies only above this mark; it ratchets up
    ///         after each crystallization and never down.
    uint256 private _highWaterPricePerShare;

    /// @notice Fees crystallized out of Lane A instant exits and RETAINED in the
    ///         vault pending payout at the next settlement. Excluded from
    ///         `totalAssets()` so remaining holders' share price is untouched.
    ///         Packed with the exit penalty: 128 + 112 + 16 = 256 bits.
    uint128 private _crystallizedMgmt;
    uint112 private _crystallizedPerf;

    /// @notice Early-exit penalty on the strategy-pulled portion of a Lane A
    ///         instant exit, in bps. Accrues to the VAULT (remaining depositors),
    ///         not to any fee recipient — a redemption term, not revenue.
    uint16 private _instantExitFeeBps;

    /// @dev Reserved storage for future upgrades. Shrunk 32 -> 28:
    ///      _mgmtAssetSeconds, the packed _mgmtBase/_mgmtLastUpdate slot,
    ///      _highWaterPricePerShare, and the packed
    ///      _crystallizedMgmt/_crystallizedPerf/_instantExitFeeBps slot
    ///      (spec 2026-07-24 fee model).
    uint256[28] private __gap;
```

Add the two constants near `MAX_MIN_BUFFER_BPS` (line 88):

```solidity
    /// @notice Fixed-point scale for `_highWaterPricePerShare`.
    uint256 private constant _PPS_SCALE = 1e18;

    /// @notice Seconds in the management fee's annualization year.
    uint256 private constant _FEE_YEAR = 365 days;
```

Add the `FeeConstants` import if the file does not already have it:

```solidity
import {FeeConstants} from "./FeeConstants.sol";
```

- [ ] **Step 4: Add the accrual logic**

Add this section to `src/SyndicateVault.sol`, next to `interimNetFlow` (around line 1119):

```solidity
    // ==================== MANAGEMENT-FEE ACCRUAL ====================

    /// @dev Fold elapsed time at the current base into the accumulator and
    ///      restamp the clock. Called before EVERY base change and by
    ///      `consumeMgmtAccrual`, so the integral never loses a segment.
    ///      `_mgmtLastUpdate == 0` means "not accruing" (between proposals) and
    ///      contributes nothing.
    function _touchMgmt() private {
        uint40 last = _mgmtLastUpdate;
        if (last == 0) return;
        uint256 elapsed = block.timestamp - uint256(last);
        if (elapsed != 0) {
            _mgmtAssetSeconds += uint256(_mgmtBase) * elapsed;
            _mgmtLastUpdate = uint40(block.timestamp);
        }
    }

    /// @dev Move the base by `delta`, flooring at 0. Folds elapsed time FIRST so
    ///      the segment before the change is credited at the OLD base — that
    ///      ordering is the whole reason mid-proposal flows are priced correctly.
    ///      No-op while not accruing.
    function _adjustMgmtBase(int256 delta) private {
        if (_mgmtLastUpdate == 0) return;
        _touchMgmt();
        if (delta >= 0) {
            _mgmtBase = uint216(uint256(_mgmtBase) + uint256(delta));
        } else {
            uint256 sub = uint256(-delta);
            uint256 cur = uint256(_mgmtBase);
            _mgmtBase = uint216(cur > sub ? cur - sub : 0);
        }
    }

    /// @inheritdoc ISyndicateVault
    function onProposalExecuted(uint256 baseAssets) external onlyGovernor {
        _touchMgmt();
        _mgmtBase = uint216(baseAssets);
        _mgmtLastUpdate = uint40(block.timestamp);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Governor-only escape hatch for base corrections the vault cannot
    ///      observe itself — the vault applies its OWN Lane A / custody flows via
    ///      the private `_adjustMgmtBase`. Exists so the governor can true up
    ///      after an emergency-settle unwind.
    function adjustMgmtBase(int256 delta) external onlyGovernor {
        _adjustMgmtBase(delta);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Returns the integral and STOPS accrual — base and clock are cleared,
    ///      so idle capital between proposals accrues nothing (documented
    ///      limitation, plan open question 1).
    function consumeMgmtAccrual() external onlyGovernor returns (uint256 assetSeconds) {
        _touchMgmt();
        assetSeconds = _mgmtAssetSeconds;
        _mgmtAssetSeconds = 0;
        _mgmtBase = 0;
        _mgmtLastUpdate = 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev View form: the stored integral PLUS the segment pending since the
    ///      last touch. Off-chain readers and the exit-fee math both use this.
    function mgmtAccrualAssetSeconds() public view returns (uint256) {
        uint40 last = _mgmtLastUpdate;
        if (last == 0) return _mgmtAssetSeconds;
        return _mgmtAssetSeconds + (uint256(_mgmtBase) * (block.timestamp - uint256(last)));
    }
```

- [ ] **Step 5: Declare the new surface on the interface**

Add to `src/interfaces/ISyndicateVault.sol`:

`NotGovernor` already exists at `src/interfaces/ISyndicateVault.sol:24` (the `onlyGovernor` modifier reverts with it) — do not re-declare it. Add only:

```solidity
    /// @notice Governor-only: stamp `baseAssets` as the management-fee base and
    ///         start time-weighting. Called from `executeProposal`.
    function onProposalExecuted(uint256 baseAssets) external;

    /// @notice Governor-only: move the management-fee base by `delta` (floors at 0).
    function adjustMgmtBase(int256 delta) external;

    /// @notice Governor-only: return the accrued asset-seconds and stop accrual.
    function consumeMgmtAccrual() external returns (uint256 assetSeconds);

    /// @notice Accrued management-fee base-seconds, including the segment pending
    ///         since the last state-changing touch.
    function mgmtAccrualAssetSeconds() external view returns (uint256);
```

- [ ] **Step 6: Wire the vault's own base-changing events**

In `_deposit`, inside the `if (laneA)` block, immediately after `_interimNetFlow += int256(assets);` (line 866):

```solidity
            // Mid-proposal capital in — the management fee is time-weighted, so
            // this money is only charged for the time it was actually here.
            _adjustMgmtBase(int256(assets));
```

In `_withdraw`, inside the `if (caller != _withdrawalQueue && redemptionsLocked())` block, immediately after `_interimNetFlow -= int256(assets);` (line 909):

```solidity
            _adjustMgmtBase(-int256(assets));
```

In `strategyMint` (line 1083), after the mint:

```solidity
        // Custody model: LPs deposit into the strategy and shares mint here, so
        // the vault never sees the assets. Value the minted shares to keep the
        // management-fee base tracking the real book.
        _adjustMgmtBase(int256(convertToAssets(shares)));
```

In `strategyBurn` (line 1098), **before** the burn so `convertToAssets` prices at the pre-burn ratio:

```solidity
        _adjustMgmtBase(-int256(convertToAssets(shares)));
```

- [ ] **Step 7: Stamp the base at execute**

In `src/SyndicateGovernor.sol`, in `executeProposal`, immediately after line 395:

```solidity
        // Start the management-fee clock at the fund's assets on execute. The
        // vault time-weights from here; Lane A flows adjust the base as they land.
        ISyndicateVault(vault).onProposalExecuted(balanceBefore);
```

- [ ] **Step 8: Run the tests**

Run: `forge test --match-path test/fees/MgmtFeeAccrual.t.sol -vv`
Expected: 5 tests PASS.

Run: `forge test --match-path "test/SyndicateVault*.t.sol" -vv 2>&1 | tail -20`
Expected: PASS.

Run: `forge test --match-path "test/invariants/*.t.sol" -vv 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/SyndicateVault.sol src/interfaces/ISyndicateVault.sol src/SyndicateGovernor.sol test/fees/MgmtFeeAccrual.t.sol
git commit -m "feat(fees): time-weighted management-fee accrual on the vault"
```

---

### Task 5: Vault — high-water mark

Today profit is measured per proposal against the execute-time balance, so a fund that loses under proposal N and recovers under N+1 pays performance fees on the same recovered dollars twice. A stored per-share peak fixes it.

**Files:**
- Modify: `src/SyndicateVault.sol`
- Modify: `src/interfaces/ISyndicateVault.sol`
- Test: `test/fees/HighWaterMark.t.sol` (create)

- [ ] **Step 1: Write the failing test**

Create `test/fees/HighWaterMark.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice The high-water mark exists so a volatile fund is never charged twice
///         on the same recovered dollars. $100 -> $120 (charged) -> $95 -> $120
///         must charge NOTHING on the recovery leg.
contract HighWaterMarkTest is Test {
    SyndicateVault vault;
    ERC20Mock usdc;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address constant MOCK_GOVERNOR = address(0xF00D);

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        BatchExecutorLib executorLib = new BatchExecutorLib();
        MockAgentRegistry agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (
                ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 200
                })
            )
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));

        usdc.mint(lp, 1_000e6);
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100e6, lp);
        vm.stopPrank();
    }

    /// @notice The mark initializes at the first deposit's share price. A zero
    ///         mark would make the ENTIRE NAV chargeable on the first settle.
    function test_markInitializesAtFirstDeposit() public view {
        assertEq(vault.highWaterPricePerShare(), vault.currentPricePerShare());
        assertGt(vault.highWaterPricePerShare(), 0);
    }

    /// @notice Profit above the mark is the fee base; the mark then ratchets.
    function test_profitAboveMarkIsChargeableThenRatchets() public {
        usdc.mint(address(vault), 20e6); // $100 -> $120

        assertApproxEqAbs(vault.performanceBaseAssets(), 20e6, 1, "profit above the mark is the base");

        vm.prank(MOCK_GOVERNOR);
        vault.ratchetHighWaterMark();
        assertEq(vault.performanceBaseAssets(), 0, "nothing left above the new mark");
    }

    /// @notice The core fix: after a drawdown, recovering back to the prior peak
    ///         is NOT chargeable. Pre-HWM this was charged a second time.
    function test_recoveryToPriorPeakIsNotChargedAgain() public {
        usdc.mint(address(vault), 20e6); // $120
        vm.prank(MOCK_GOVERNOR);
        vault.ratchetHighWaterMark();

        vm.prank(address(vault));
        usdc.transfer(address(0xdead), 25e6); // $95 — drawdown
        assertEq(vault.performanceBaseAssets(), 0, "underwater: no performance fee");

        usdc.mint(address(vault), 25e6); // back to $120 — the recovery leg
        assertEq(vault.performanceBaseAssets(), 0, "recovery to the old peak is free");

        usdc.mint(address(vault), 5e6); // $125 — new ground
        assertApproxEqAbs(vault.performanceBaseAssets(), 5e6, 1, "only the new high is charged");
    }

    /// @notice The mark never moves down — a losing settlement must not reset it.
    function test_markNeverRatchetsDown() public {
        usdc.mint(address(vault), 20e6);
        vm.prank(MOCK_GOVERNOR);
        vault.ratchetHighWaterMark();
        uint256 peak = vault.highWaterPricePerShare();

        vm.prank(address(vault));
        usdc.transfer(address(0xdead), 30e6);

        vm.prank(MOCK_GOVERNOR);
        vault.ratchetHighWaterMark();
        assertEq(vault.highWaterPricePerShare(), peak, "mark is monotone");
    }

    /// @notice A late depositor buys at the current (already-appreciated) price,
    ///         so their principal must never register as chargeable profit.
    function test_lateDepositorDoesNotCreateChargeableProfit() public {
        usdc.mint(address(vault), 20e6); // $120
        vm.prank(MOCK_GOVERNOR);
        vault.ratchetHighWaterMark();

        address late = makeAddr("late");
        usdc.mint(late, 100e6);
        vm.startPrank(late);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100e6, late);
        vm.stopPrank();

        assertEq(vault.performanceBaseAssets(), 0, "principal is never profit");
    }

    function test_ratchetIsGovernorOnly() public {
        vm.expectRevert(ISyndicateVault.NotGovernor.selector);
        vault.ratchetHighWaterMark();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-path test/fees/HighWaterMark.t.sol -vv`
Expected: compile error — `highWaterPricePerShare`, `currentPricePerShare`, `performanceBaseAssets`, `ratchetHighWaterMark` do not exist.

- [ ] **Step 3: Implement the mark on the vault**

Add this section to `src/SyndicateVault.sol`, next to the accrual section from Task 4:

```solidity
    // ==================== HIGH-WATER MARK ====================

    /// @dev Price per share scaled by `_PPS_SCALE`, using the SAME virtual-offset
    ///      convention as `onProposalSettled`'s queue stamp so the mark and the
    ///      Lane B settle price can never disagree about what a share is worth.
    function _currentPps() private view returns (uint256) {
        return ((totalAssets() + 1) * _PPS_SCALE) / (totalSupply() + 10 ** _decimalsOffset());
    }

    /// @inheritdoc ISyndicateVault
    function currentPricePerShare() external view returns (uint256) {
        return _currentPps();
    }

    /// @inheritdoc ISyndicateVault
    function highWaterPricePerShare() external view returns (uint256) {
        return _highWaterPricePerShare;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Assets above the fund's prior peak — the performance-fee base. Zero
    ///      while underwater, and zero for the recovery leg back to the peak:
    ///      that ground was already paid for.
    function performanceBaseAssets() public view returns (uint256) {
        uint256 pps = _currentPps();
        uint256 mark = _highWaterPricePerShare;
        if (pps <= mark) return 0;
        return ((pps - mark) * totalSupply()) / _PPS_SCALE;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Governor-only, called at settlement AFTER both fees are paid so the
    ///      mark records the POST-fee peak — ratcheting on the pre-fee price
    ///      would raise the bar by the fee itself and under-charge next period.
    ///      Monotone: `max(old, new)`.
    function ratchetHighWaterMark() external onlyGovernor {
        uint256 pps = _currentPps();
        if (pps > _highWaterPricePerShare) {
            _highWaterPricePerShare = pps;
            emit HighWaterMarkUpdated(pps);
        }
    }

    /// @dev Set the mark at the first share issuance. Called from `_deposit` and
    ///      `strategyMint` — a custody-model vault never touches `_deposit`.
    function _initMarkIfUnset() private {
        if (_highWaterPricePerShare == 0) {
            _highWaterPricePerShare = _currentPps();
            emit HighWaterMarkUpdated(_highWaterPricePerShare);
        }
    }
```

Call `_initMarkIfUnset();` as the last statement of `_deposit`, and as the last statement of `strategyMint`.

- [ ] **Step 4: Declare the surface on the interface**

Add to `src/interfaces/ISyndicateVault.sol`:

```solidity
    /// @notice Emitted when the high-water mark ratchets up.
    event HighWaterMarkUpdated(uint256 pricePerShare);

    /// @notice Current price per share, scaled by 1e18.
    function currentPricePerShare() external view returns (uint256);

    /// @notice The fund's prior peak price per share, scaled by 1e18.
    function highWaterPricePerShare() external view returns (uint256);

    /// @notice Assets above the high-water mark — the performance-fee base.
    function performanceBaseAssets() external view returns (uint256);

    /// @notice Governor-only: ratchet the mark to the current (post-fee) price.
    function ratchetHighWaterMark() external;
```

- [ ] **Step 5: Run the tests**

Run: `forge test --match-path test/fees/HighWaterMark.t.sol -vv`
Expected: 6 tests PASS.

Run: `forge test --match-path "test/SyndicateVault*.t.sol" -vv 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/SyndicateVault.sol src/interfaces/ISyndicateVault.sol test/fees/HighWaterMark.t.sol
git commit -m "feat(fees): per-share high-water mark on the vault"
```

---

### Task 6: Governor — rewrite `_distributeFees` to two split-distributions

The heart of the change. The four-step sequential waterfall (protocol → guardian → agent → owner), which compounded four haircuts, becomes: management fee always, then performance fee on above-mark profit, each divided by one split.

**Files:**
- Modify: `src/SyndicateVault.sol` (rename the perf-fee accessor, add crystallized getters)
- Modify: `src/interfaces/ISyndicateVault.sol`
- Modify: `src/SyndicateGovernor.sol:1091-1218`
- Modify: `src/interfaces/ISyndicateGovernor.sol` (two events)
- Test: `test/fees/FeeDistribution.t.sol` (extend)

- [ ] **Step 1: Rename the vault's performance-fee accessor**

Do this first so the governor rewrite compiles against the final name. In `src/SyndicateVault.sol`, replace the existing `agentFeeBps()` (line 602) with:

```solidity
    /// @inheritdoc ISyndicateVault
    /// @notice Total performance fee this fund charges above its high-water mark,
    ///         in bps. Under the two-number model this is the WHOLE performance
    ///         fee, split four ways at settlement (agent / protocol / guardian /
    ///         owner) per the proposal's `snapshotPerfSplit` — not the agent's cut.
    /// @dev One SLOAD: 0 = never set -> the 5% default (agent never silently
    ///      unpaid, H1); otherwise the stored value is fee+1, so an explicit 0%
    ///      (stored 1) stays distinct from unset.
    function performanceFeeBps() public view returns (uint256) {
        uint256 stored = _agentFeeBpsPlusOne;
        return stored == 0 ? FeeConstants.DEFAULT_AGENT_FEE_BPS : stored - 1;
    }

    /// @inheritdoc ISyndicateVault
    /// @custom:deprecated Renamed to `performanceFeeBps`. Retained so existing
    ///      integrations and the subgraph do not break on the rename.
    function agentFeeBps() external view returns (uint256) {
        return performanceFeeBps();
    }

    /// @inheritdoc ISyndicateVault
    function crystallizedMgmt() external view returns (uint256) {
        return uint256(_crystallizedMgmt);
    }

    /// @inheritdoc ISyndicateVault
    function crystallizedPerf() external view returns (uint256) {
        return uint256(_crystallizedPerf);
    }
```

Add to `src/interfaces/ISyndicateVault.sol`:

```solidity
    /// @notice Total performance fee in bps, charged above the high-water mark.
    function performanceFeeBps() external view returns (uint256);

    /// @notice Management fees already crystallized out of Lane A instant exits
    ///         and retained in the vault, pending settlement payout. Zero until
    ///         the crystallization task lands.
    function crystallizedMgmt() external view returns (uint256);

    /// @notice Performance fees already crystallized out of Lane A instant exits.
    function crystallizedPerf() external view returns (uint256);
```

- [ ] **Step 2: Write the failing tests**

Extend `test/fees/FeeDistribution.t.sol` with an end-to-end fixture — real vault + real governor + a mock strategy — modelled on the propose→vote→execute→settle helpers in `test/SyndicateGovernorIntegration.t.sol`. Add private helpers `_fundAndExecute(uint256)`, `_settleWithPnl(int256)`, `_blacklist(address)` (using `test/mocks/BlacklistingERC20Mock.sol`), and the fields `vault`, `governor`, `usdc`, `agent`, `vaultOwner`. Then:

```solidity
    /// @notice A $1M fund over 30 days at 2%/yr owes ~$1,644 management, split
    ///         70/20/10 — the worked example from the product spec.
    function test_managementFeeSplitsSeventyTwentyTen() public {
        _fundAndExecute(1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        _settleWithPnl(0); // FLAT month

        uint256 expected = (1_000_000e6 * 30 days * 200) / (10_000 * 365 days);
        assertApproxEqAbs(usdc.balanceOf(agent), expected * 7000 / 10_000, 2);
        assertApproxEqAbs(usdc.balanceOf(protocolRecipient), expected * 2000 / 10_000, 2);
        assertApproxEqAbs(usdc.balanceOf(guardianRecipient), expected * 1000 / 10_000, 2);
    }

    /// @notice The always-on leg: a LOSING month still charges management. This is
    ///         what funds the guardian network in flat and down markets — the gap
    ///         the removed volume fee used to cover.
    function test_managementFeeIsChargedOnALoss() public {
        _fundAndExecute(1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        _settleWithPnl(-50_000e6);

        assertGt(usdc.balanceOf(guardianRecipient), 0, "guardians earn in down months");
        assertEq(usdc.balanceOf(vaultOwner), 0, "no performance fee on a loss");
    }

    /// @notice Performance splits 60/15/15/10 on the above-mark profit.
    function test_performanceFeeSplitsSixtyFifteenFifteenTen() public {
        _fundAndExecute(1_000_000e6);
        _settleWithPnl(21_500e6); // the product spec's +2.15% month

        uint256 perf = 21_500e6 * 2000 / 10_000; // 20% headline
        assertApproxEqAbs(usdc.balanceOf(vaultOwner), perf * 1000 / 10_000, 2);
        assertApproxEqAbs(usdc.balanceOf(protocolRecipient), perf * 1500 / 10_000, 2e6);
    }

    /// @notice No performance fee while under the high-water mark, even on a
    ///         positive-PnL proposal — the recovery leg is not new ground. This is
    ///         the double-charge the pre-HWM code had.
    function test_noPerformanceFeeWhileUnderTheMark() public {
        _fundAndExecute(1_000_000e6);
        _settleWithPnl(100_000e6); // sets a peak

        uint256 ownerBefore = usdc.balanceOf(vaultOwner);

        _fundAndExecute(1_000_000e6);
        _settleWithPnl(-80_000e6); // drawdown

        _fundAndExecute(1_000_000e6);
        _settleWithPnl(70_000e6); // recovery, still below the peak

        assertEq(usdc.balanceOf(vaultOwner), ownerBefore, "recovery leg pays no performance fee");
    }

    /// @notice Fail-open: a blacklisted recipient escrows rather than bricking
    ///         settlement. The pre-existing `_payFee` guarantee must survive the
    ///         rewrite.
    function test_blacklistedRecipientEscrowsAndSettlementProceeds() public {
        _blacklist(protocolRecipient);
        _fundAndExecute(1_000_000e6);
        _settleWithPnl(21_500e6);

        assertGt(governor.unclaimedFees(address(vault), protocolRecipient, address(usdc)), 0);
        assertGt(usdc.balanceOf(agent), 0, "other recipients still paid");
    }

    /// @notice Total fees can never exceed the vault's float — an over-large
    ///         accrual must clamp, not escrow a phantom liability.
    function test_totalFeesAreClampedToVaultFloat() public {
        _fundAndExecute(1_000e6);
        vm.warp(block.timestamp + 3650 days); // absurd accrual
        _settleWithPnl(0);

        uint256 paid =
            usdc.balanceOf(agent) + usdc.balanceOf(protocolRecipient) + usdc.balanceOf(guardianRecipient);
        assertLe(paid, 1_000e6, "cannot pay out more than the fund holds");
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `forge test --match-path test/fees/FeeDistribution.t.sol -vv`
Expected: FAIL — no management fee is charged on flat/loss settlements, and the splits are not applied.

- [ ] **Step 4: Rewrite the fee block in `_finishSettlement`**

In `src/SyndicateGovernor.sol`, replace lines 1091-1103 with:

```solidity
        // Two-number fee model (spec 2026-07-24-fee-model-design):
        //   1. management — ALWAYS, on time-weighted assets, regardless of PnL.
        //   2. performance — only on profit above the high-water mark.
        // Ordering is load-bearing: management first (it lowers price-per-share),
        // then the mark check, then performance. Charging performance first would
        // take a cut of assets the management fee is about to remove.
        //
        // H2/M4: a self-fee'd strategy still pays MANAGEMENT — that leg never
        // touches PnL, so the float-delta misread `selfManagesFees` exists to
        // dodge does not apply to it. Only the performance leg is skipped.
        uint256 totalFee =
            _distributeFees(proposalId, vault, asset, proposal.proposer, proposal.selfManagesFees);
```

The `agentFee` named return on `_finishSettlement` is no longer meaningful under a split model (the agent is paid from two legs). Delete it from the signature and from `_finishSettlementHook` (line 228) — check every caller with:

```bash
grep -n "_finishSettlement\|_finishSettlementHook" src/*.sol
```

and update each. `ProposalSettled` still reports `pnl` and `totalFee`.

- [ ] **Step 5: Rewrite `_distributeFees`**

Replace `_distributeFees` and its NatSpec (lines 1123-1218) entirely:

```solidity
    /// @dev Distribute the two headline fees. Reads splits and recipients from the
    ///      propose-time snapshot so settlement uses what voters approved.
    ///
    ///      ── THE FEE MAP (two-number model, spec 2026-07-24) ──
    ///        1. mgmtFee = vault.consumeMgmtAccrual() * vault.managementFeeBps()
    ///                     / (10_000 * 365 days)          — ALWAYS, any PnL sign
    ///             base:  time-weighted fund assets, accumulated vault-side
    ///             split: prop.snapshotMgmtSplit {agent, protocol, guardian}
    ///             minus: fees already crystallized out of Lane A instant exits
    ///        2. perfFee = vault.performanceBaseAssets() * perfFeeBps / 10_000
    ///             base:  assets above the high-water mark ONLY (never raw pnl)
    ///             split: prop.snapshotPerfSplit {agent, protocol, guardian, owner}
    ///             gate:  skipped entirely when `selfManaged`
    ///      Both are clamped to the vault's float so an accrual larger than the
    ///      fund can never escrow a phantom liability. Any recipient transfer that
    ///      reverts escrows in `_unclaimedFees` (pull via `claimUnclaimedFees`) so
    ///      settlement never bricks.
    function _distributeFees(
        uint256 proposalId,
        address vault,
        address asset,
        address proposer,
        bool selfManaged
    ) internal returns (uint256 totalFee) {
        StrategyProposal storage prop = _proposals[proposalId];
        uint256 float = IERC20(asset).balanceOf(vault);

        // ── 1. Management fee (always) ──
        uint256 mgmtFee;
        {
            uint256 assetSeconds = ISyndicateVault(vault).consumeMgmtAccrual();
            uint256 due = (assetSeconds * ISyndicateVault(vault).managementFeeBps())
                / (FeeConstants.BPS_DENOMINATOR * 365 days);
            // Lane A exiters already paid their pro-rata slice at exit; charge the
            // fund only the remainder so the same asset-seconds are never billed twice.
            uint256 already = ISyndicateVault(vault).crystallizedMgmt();
            mgmtFee = due > already ? due - already : 0;
            if (mgmtFee > float) mgmtFee = float;
            float -= mgmtFee;
        }
        if (mgmtFee > 0) {
            IProtocolConfig.MgmtSplit memory ms = prop.snapshotMgmtSplit;
            uint256 toProtocol = (mgmtFee * ms.protocolBps) / FeeConstants.BPS_DENOMINATOR;
            uint256 toGuardian = (mgmtFee * ms.guardianBps) / FeeConstants.BPS_DENOMINATOR;
            // The agent takes the rounding remainder, so the split sums to exactly
            // `mgmtFee` and no dust is stranded in the vault.
            uint256 toAgent = mgmtFee - toProtocol - toGuardian;

            _payProtocol(prop.snapshotProtocolFeeRecipient, vault, asset, toProtocol);
            _payGuardian(proposalId, prop.snapshotGuardiansFeeRecipient, vault, asset, toGuardian);
            _distributeAgentFee(proposalId, vault, asset, proposer, toAgent);
            emit ManagementFeeCharged(proposalId, vault, mgmtFee, toAgent, toProtocol, toGuardian);
        }

        // ── 2. Performance fee (above the mark only) ──
        uint256 perfFee;
        if (!selfManaged) {
            uint256 base = ISyndicateVault(vault).performanceBaseAssets();
            if (base > 0) {
                uint256 perfBps = _clampPerformanceFee(
                    proposalId, ISyndicateVault(vault).performanceFeeBps(), _params.maxPerformanceFeeBps
                );
                uint256 gross = (base * perfBps) / FeeConstants.BPS_DENOMINATOR;
                uint256 already = ISyndicateVault(vault).crystallizedPerf();
                perfFee = gross > already ? gross - already : 0;
                if (perfFee > float) perfFee = float;
                float -= perfFee;
            }
        }
        if (perfFee > 0) {
            IProtocolConfig.PerfSplit memory ps = prop.snapshotPerfSplit;
            uint256 toProtocol = (perfFee * ps.protocolBps) / FeeConstants.BPS_DENOMINATOR;
            uint256 toGuardian = (perfFee * ps.guardianBps) / FeeConstants.BPS_DENOMINATOR;
            uint256 toOwner = (perfFee * ps.ownerBps) / FeeConstants.BPS_DENOMINATOR;
            uint256 toAgent = perfFee - toProtocol - toGuardian - toOwner;

            _payProtocol(prop.snapshotProtocolFeeRecipient, vault, asset, toProtocol);
            _payGuardian(proposalId, prop.snapshotGuardiansFeeRecipient, vault, asset, toGuardian);
            _payFee(vault, asset, ISyndicateVault(vault).owner(), toOwner);
            _distributeAgentFee(proposalId, vault, asset, proposer, toAgent);
            emit PerformanceFeeCharged(proposalId, vault, perfFee, toAgent, toProtocol, toGuardian, toOwner);
        }

        totalFee = mgmtFee + perfFee;

        // Ratchet AFTER both fees so the mark records the POST-fee peak.
        ISyndicateVault(vault).ratchetHighWaterMark();
    }

    /// @dev Protocol slice. A zero recipient with a nonzero amount is a
    ///      misconfiguration the propose-time snapshot should have caught; fail
    ///      loudly rather than burn the assets.
    function _payProtocol(address recipient, address vault, address asset, uint256 amount) private {
        if (amount == 0) return;
        if (recipient == address(0)) revert InvalidProtocolFeeRecipient();
        _payFee(vault, asset, recipient, amount);
    }

    /// @dev Guardian slice. `GuardianFeeAccrued` is emitted ONLY on actual
    ///      delivery — the off-chain Merkl bot airdrops WOOD against this event,
    ///      so emitting on an escrowed transfer would pay for a fee that never
    ///      landed, then double-pay when the escrow is recovered.
    function _payGuardian(uint256 proposalId, address recipient, address vault, address asset, uint256 amount)
        private
    {
        if (amount == 0) return;
        if (_payFee(vault, asset, recipient, amount)) {
            emit GuardianFeeAccrued(proposalId, asset, recipient, amount);
        }
    }
```

Add the `FeeConstants` and `IProtocolConfig` imports to `SyndicateGovernor.sol` if absent.

- [ ] **Step 6: Add the two events**

Add to `src/interfaces/ISyndicateGovernor.sol`:

```solidity
    /// @notice Management fee charged at settlement, with its three-way split.
    event ManagementFeeCharged(
        uint256 indexed proposalId,
        address indexed vault,
        uint256 total,
        uint256 toAgent,
        uint256 toProtocol,
        uint256 toGuardian
    );

    /// @notice Performance fee charged on above-high-water-mark profit, with its
    ///         four-way split.
    event PerformanceFeeCharged(
        uint256 indexed proposalId,
        address indexed vault,
        uint256 total,
        uint256 toAgent,
        uint256 toProtocol,
        uint256 toGuardian,
        uint256 toOwner
    );
```

- [ ] **Step 7: Run the tests**

Run: `forge test --match-path test/fees/FeeDistribution.t.sol -vv`
Expected: 7 tests PASS.

Run: `forge test --match-path "test/governor/*.t.sol" -vv 2>&1 | tail -30`
Expected: PASS. `test/governor/FeeBlacklistResilience.t.sol` and `test/invariants/FeeBlacklistInvariant.t.sol` exercise the escrow path — if they assert the old waterfall's amounts, update the expected amounts to the split amounts. Do NOT weaken the escrow assertions themselves.

Run: `forge test --match-path "test/SyndicateGovernor*.t.sol" -vv 2>&1 | tail -30`
Expected: PASS after updating any test asserting the old four-step amounts.

Run: `forge build && forge fmt --check`
Expected: clean. If `_distributeFees` hits Yul stack-too-deep under the coverage profile (`via_ir = false`), keep the two `{ }` scopes and push each split's arithmetic into a `_payMgmtSplit` / `_payPerfSplit` private helper.

- [ ] **Step 8: Commit**

```bash
git add src/SyndicateGovernor.sol src/interfaces/ISyndicateGovernor.sol src/SyndicateVault.sol src/interfaces/ISyndicateVault.sol test/
git commit -m "feat(fees): two split-distributions replace the sequential fee waterfall"
```

---

### Task 7: Crystallize fees on Lane A instant exit

Fees crystallize at settlement, but a Lane A instant exit happens mid-proposal at a live oracle price with no fee deducted — the exiter escapes their share and leaks it onto the depositors who stay. Lane B queue exits are already correct (they claim at the frozen post-fee settle price). This fixes the instant path only. Deviation D2: the crystallized amounts are retained in the vault and paid at the next settlement.

**Files:**
- Modify: `src/SyndicateVault.sol` (`_exitFees`, `previewRedeem`, `previewWithdraw`, `_withdraw`, `totalAssets`, `_availableFloat`, `onProposalSettled`)
- Modify: `src/interfaces/ISyndicateVault.sol`
- Test: `test/fees/CrystallizeOnExit.t.sol` (create)

- [ ] **Step 1: Write the failing test**

Create `test/fees/CrystallizeOnExit.t.sol`. Build the fixture on `test/SyndicateVault.LaneA.t.sol`'s setup (real governor + a PriceRouter mock so `_laneState()` reports `laneA == true`), with helpers `_enterLaneA(address,uint256)`, `_executeWithProfit(uint256)`, `_settle()`, `_totalMgmtPaid()`.

```solidity
    /// @notice The headline guarantee: exit timing is fee-neutral. An instant
    ///         exiter and an otherwise identical hold-to-settlement depositor end
    ///         up with the same net, so nobody dodges fees by leaving early.
    function test_exitTimingIsFeeNeutral() public {
        _enterLaneA(alice, 100_000e6);
        _enterLaneA(bob, 100_000e6);
        _executeWithProfit(20_000e6); // fund is above its mark

        vm.warp(block.timestamp + 15 days);
        vm.prank(alice);
        uint256 aliceNet = vault.redeem(vault.balanceOf(alice), alice, alice);

        vm.warp(block.timestamp + 15 days);
        _settle();
        vm.prank(bob);
        uint256 bobNet = vault.redeem(vault.balanceOf(bob), bob, bob);

        // Bob held 15 days longer, so he owes 15 more days of management fee.
        // Net of that, the two paths must agree within rounding.
        uint256 extraMgmt = (100_000e6 * 15 days * 200) / (10_000 * 365 days);
        assertApproxEqAbs(aliceNet - extraMgmt, bobNet, 1e6, "exit timing is fee-neutral");
    }

    /// @notice The exiter's fees are booked to the vault, not handed to them.
    function test_instantExitCrystallizesBothFees() public {
        _enterLaneA(alice, 100_000e6);
        _executeWithProfit(20_000e6);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);

        assertGt(vault.crystallizedMgmt(), 0, "management fee crystallized");
        assertGt(vault.crystallizedPerf(), 0, "performance fee crystallized");
    }

    /// @notice Crystallized fees are NOT fund property — they must not show up in
    ///         totalAssets, or remaining holders' share price would include assets
    ///         that are already spoken for.
    function test_crystallizedFeesAreExcludedFromTotalAssets() public {
        _enterLaneA(alice, 100_000e6);
        _enterLaneA(bob, 100_000e6);
        _executeWithProfit(20_000e6);
        vm.warp(block.timestamp + 30 days);

        uint256 ppsBefore = vault.currentPricePerShare();
        vm.prank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);

        assertApproxEqRel(vault.currentPricePerShare(), ppsBefore, 1e15, "stayers' pps is untouched");
    }

    /// @notice No double-charge at settlement: the exiting shares are burned (so
    ///         they leave the performance base), and the management leg subtracts
    ///         what was already crystallized.
    function test_settlementDoesNotDoubleChargeTheExiter() public {
        _enterLaneA(alice, 100_000e6);
        _enterLaneA(bob, 100_000e6);
        _executeWithProfit(20_000e6);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);
        assertGt(vault.crystallizedMgmt(), 0);

        _settle();

        uint256 fullBookFee = (200_000e6 * 30 days * 200) / (10_000 * 365 days);
        assertApproxEqAbs(_totalMgmtPaid(), fullBookFee, 1e6, "fund-level total charged exactly once");
    }

    /// @notice previewRedeem must equal what redeem actually pays — breaking this
    ///         breaks every ERC-4626 integrator.
    function test_previewRedeemMatchesActualProceeds() public {
        _enterLaneA(alice, 100_000e6);
        _executeWithProfit(20_000e6);
        vm.warp(block.timestamp + 30 days);

        uint256 shares = vault.balanceOf(alice);
        uint256 preview = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 actual = vault.redeem(shares, alice, alice);

        assertEq(preview, actual, "preview must be exact");
    }

    /// @notice Outside a Lane A window nothing is accrued and nothing sits above
    ///         the mark, so an ordinary redeem charges nothing.
    function test_noExitFeeOutsideLaneA() public {
        _enterLaneA(alice, 100_000e6);
        // no proposal active
        uint256 shares = vault.balanceOf(alice);
        assertEq(vault.previewRedeem(shares), vault.convertToAssets(shares));
    }

    /// @notice The mark does NOT ratchet on a partial exit — remaining holders
    ///         keep measuring from the same mark (spec §4.1).
    function test_partialExitDoesNotRatchetTheMark() public {
        _enterLaneA(alice, 100_000e6);
        _enterLaneA(bob, 100_000e6);
        _executeWithProfit(20_000e6);
        uint256 markBefore = vault.highWaterPricePerShare();

        vm.prank(alice);
        vault.redeem(vault.balanceOf(alice) / 2, alice, alice);

        assertEq(vault.highWaterPricePerShare(), markBefore);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-path test/fees/CrystallizeOnExit.t.sol -vv`
Expected: FAIL — `previewRedeem` returns the gross conversion and `crystallizedMgmt()` stays 0.

- [ ] **Step 3: Implement the exit-fee computation**

Add to `src/SyndicateVault.sol`:

```solidity
    // ==================== EXIT FEE CRYSTALLIZATION ====================

    /// @dev The management + performance fees `shares` owe if they exit right now.
    ///      Applies ONLY on a live Lane A instant exit: between proposals the
    ///      accrual base is zero and price-per-share sits at the mark (both were
    ///      settled), and the Lane B queue claims at the frozen post-fee settle
    ///      price, so it already bears its share. The queue's `claim` requires
    ///      `!redemptionsLocked()`, so the Lane A gate excludes it structurally.
    ///
    ///      MUST be read before `_crystallized*` is updated — `totalAssets()`
    ///      subtracts those counters, so a post-update read would price the exit
    ///      against a book already reduced by this very fee.
    function _exitFees(uint256 shares) private view returns (uint256 mgmt, uint256 perf) {
        (,,, bool laneA) = _laneState();
        if (!laneA || shares == 0) return (0, 0);

        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);

        // Management: this holder's pro-rata slice of the fund's uncollected accrual.
        uint256 due = (mgmtAccrualAssetSeconds() * _managementFeeBps) / (FeeConstants.BPS_DENOMINATOR * _FEE_YEAR);
        uint256 already = uint256(_crystallizedMgmt);
        if (due > already) {
            mgmt = ((due - already) * shares) / supply;
        }

        // Performance: the per-share gain above the mark, on the leaving shares
        // only. The mark is NOT ratcheted here — it advances only at settlement,
        // so remaining holders keep measuring from the same mark (spec §4.1).
        uint256 pps = _currentPps();
        uint256 mark = _highWaterPricePerShare;
        if (pps > mark) {
            uint256 gain = ((pps - mark) * shares) / _PPS_SCALE;
            perf = (gain * performanceFeeBps()) / FeeConstants.BPS_DENOMINATOR;
        }
    }

    /// @dev Early-exit penalty on `netAssets`. Implemented in the next task;
    ///      returning 0 keeps the preview overrides below correct today.
    function _exitPenalty(uint256) private view returns (uint256) {
        return 0;
    }
```

- [ ] **Step 4: Exclude crystallized fees from fund assets**

Replace `totalAssets()` (line 815):

```solidity
    function totalAssets() public view override returns (uint256) {
        (,, uint256 liveNav,) = _laneState();
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + liveNav;
        // Fees crystallized out of instant exits are held for their recipients,
        // not owned by the fund. Excluding them keeps remaining holders' share
        // price exactly where it was before the exiter left.
        uint256 owed = uint256(_crystallizedMgmt) + uint256(_crystallizedPerf);
        return gross > owed ? gross - owed : 0;
    }
```

Replace `_availableFloat()` (line 744) — that asset is spoken for and must not back another exit:

```solidity
    function _availableFloat() private view returns (uint256) {
        uint256 reserve = reservedQueueAssets() + uint256(_crystallizedMgmt) + uint256(_crystallizedPerf);
        uint256 float = IERC20(asset()).balanceOf(address(this));
        return float > reserve ? float - reserve : 0;
    }
```

- [ ] **Step 5: Override the previews**

Add to `src/SyndicateVault.sol`:

```solidity
    /// @inheritdoc ERC4626Upgradeable
    /// @dev OZ's `redeem` pays exactly `previewRedeem(shares)`, so the exit fees
    ///      must be visible here or the transfer and the quote diverge and every
    ///      ERC-4626 integrator mis-prices. Same shape as OZ's `ERC4626Fees`.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 gross = super.previewRedeem(shares);
        (uint256 mgmt, uint256 perf) = _exitFees(shares);
        uint256 net = gross - mgmt - perf;
        return net - _exitPenalty(net);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Inverse of `previewRedeem`: `assets` is what the caller RECEIVES, so
    ///      the shares burned must also cover the fees. Gross the request up, then
    ///      re-quote — exact for the linear fee terms and conservative (never
    ///      under-burns) for the penalty.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 grossShares = super.previewWithdraw(assets);
        (uint256 mgmt, uint256 perf) = _exitFees(grossShares);
        uint256 needed = assets + mgmt + perf;
        needed += _exitPenalty(needed);
        return super.previewWithdraw(needed);
    }
```

- [ ] **Step 6: Book the fees in `_withdraw`**

The `assets` argument is already the NET (OZ computed it via `previewRedeem`). Insert after the strategy-pull block and before `super._withdraw`:

```solidity
        // Crystallize this exit's fee share into the vault. Deviation D2: the
        // amounts are RETAINED here (excluded from `totalAssets`) and paid to the
        // proposal's snapshot recipients at the next settlement — the vault cannot
        // resolve the agent / protocol / guardian recipients itself, and adding a
        // governor call to this path would create a new brick vector.
        if (caller != _withdrawalQueue) {
            (uint256 mgmtFee_, uint256 perfFee_) = _exitFees(shares);
            if (mgmtFee_ != 0 || perfFee_ != 0) {
                _crystallizedMgmt += uint128(mgmtFee_);
                _crystallizedPerf += uint112(perfFee_);
                emit ExitFeesCrystallized(_owner, shares, mgmtFee_, perfFee_);
            }
        }
```

Replace the stale "Fee incidence (spec Q3)" comment block at lines 899-907 with:

```solidity
        // Mid-proposal principal out — excluded from settlement PnL. Queue
        // settlements post-date the PnL read, so only live instant exits count.
        //
        // The fee-incidence leak this comment used to document (an instant exiter
        // taking their slice of unrealized gain fee-free, with the settlement fee
        // then borne by remaining holders) is CLOSED by the crystallization above:
        // the exiter now pays their pro-rata management and performance fees at exit.
```

Add the event to `src/interfaces/ISyndicateVault.sol`:

```solidity
    /// @notice A Lane A instant exit paid its pro-rata accrued fees at exit.
    event ExitFeesCrystallized(address indexed owner, uint256 shares, uint256 mgmtFee, uint256 perfFee);
```

- [ ] **Step 7: Clear the counters at settlement**

Task 9 makes the governor pay them out first. Add to `onProposalSettled` (line 1107), **before** the queue stamp so the frozen price reflects the post-payout book:

```solidity
        // The governor has already paid these out (see `_distributeFees`); clear
        // them so the next proposal starts from zero and `totalAssets()` stops
        // excluding assets that have already left.
        _crystallizedMgmt = 0;
        _crystallizedPerf = 0;
```

- [ ] **Step 8: Run the tests**

Run: `forge test --match-path test/fees/CrystallizeOnExit.t.sol -vv`
Expected: 7 tests PASS.

Run: `forge test --match-path "test/SyndicateVault*.t.sol" -vv 2>&1 | tail -30`
Expected: PASS.

Run: `forge test --match-path "test/invariants/*.t.sol" -vv 2>&1 | tail -30`
Expected: `test/invariants/VaultSolvencyInvariant.t.sol` and `test/invariants/InstantLiquidityInvariants.t.sol` compare float against `totalAssets()` and must now account for the exclusion. Change the invariant to add the crystallized counters back before comparing:

```solidity
        uint256 backing = vault.totalAssets() + vault.crystallizedMgmt() + vault.crystallizedPerf();
```

Do not relax the invariant to a tautology — it must still fail if float goes missing.

- [ ] **Step 9: Commit**

```bash
git add src/SyndicateVault.sol src/interfaces/ISyndicateVault.sol test/fees/CrystallizeOnExit.t.sol test/invariants/
git commit -m "feat(fees): crystallize accrued fees on Lane A instant exit"
```

---

### Task 8: Instant-exit penalty

A second, independent charge that stacks on Task 7's crystallization. Different purpose (compensate remaining depositors for the early unwind), different destination (the vault, not a fee recipient). `instantExitFeeBps` was specced and deferred in `docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md` §6 on vault bytecode headroom; Robinhood Chain's 98 304-byte `MaxCodeSize` lifts that constraint.

**Files:**
- Modify: `src/SyndicateVault.sol`
- Modify: `src/interfaces/ISyndicateVault.sol`
- Test: `test/fees/InstantExitFee.t.sol` (create)

- [ ] **Step 1: Write the failing test**

Create `test/fees/InstantExitFee.t.sol`, reusing the Lane A fixture from Task 7 plus helpers `_executeAndDrainFloat()`, `_executeLeavingAmpleFloat()`, `_executeWithProfitAndDrainFloat(uint256)`, `_quoteExitFees(uint256)`.

```solidity
    /// @notice The penalty accrues to the VAULT — remaining depositors' share
    ///         price rises by exactly the penalty. It is not protocol revenue.
    function test_penaltyAccruesToRemainingDepositors() public {
        vm.prank(owner);
        vault.setInstantExitFeeBps(50); // 0.5%

        _enterLaneA(alice, 100_000e6);
        _enterLaneA(bob, 100_000e6);
        _executeAndDrainFloat(); // force the exit to pull from the strategy

        uint256 ppsBefore = vault.currentPricePerShare();
        vm.prank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);

        assertGt(vault.currentPricePerShare(), ppsBefore, "stayers are compensated");
    }

    /// @notice Charged only on the strategy-pulled portion (spec §5): an exit
    ///         served entirely from idle float forced no unwind and owes nothing.
    function test_noPenaltyWhenServedEntirelyFromFloat() public {
        vm.prank(owner);
        vault.setInstantExitFeeBps(50);

        _enterLaneA(alice, 100_000e6);
        _executeLeavingAmpleFloat();

        uint256 shares = vault.balanceOf(alice);
        (uint256 mgmt, uint256 perf) = _quoteExitFees(shares);
        assertEq(vault.previewRedeem(shares), vault.convertToAssets(shares) - mgmt - perf);
    }

    /// @notice The Lane B queue never pays the penalty — waiting is free.
    function test_queueExitPaysNoPenalty() public {
        vm.prank(owner);
        vault.setInstantExitFeeBps(50);

        _enterLaneA(alice, 100_000e6);
        _executeAndDrainFloat();

        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(vault.balanceOf(alice), alice);
        _settle();

        uint256 out = queue.claim(reqId);
        assertApproxEqAbs(out, _settlePriceValueOf(alice), 1, "queue claims at the frozen settle price");
    }

    function test_penaltyIsCappedAtTwoHundredBps() public {
        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.ExitFeeTooHigh.selector);
        vault.setInstantExitFeeBps(201);
    }

    function test_setterIsOwnerOnly() public {
        vm.expectRevert();
        vault.setInstantExitFeeBps(50);
    }

    /// @notice Both charges stack, in order: crystallization first (to the fee
    ///         recipients), then the penalty on the net (to the vault).
    function test_crystallizationAndPenaltyStackInOrder() public {
        vm.prank(owner);
        vault.setInstantExitFeeBps(50);

        _enterLaneA(alice, 100_000e6);
        _executeWithProfitAndDrainFloat(20_000e6);
        vm.warp(block.timestamp + 30 days);

        uint256 shares = vault.balanceOf(alice);
        uint256 gross = vault.convertToAssets(shares);
        (uint256 mgmt, uint256 perf) = _quoteExitFees(shares);
        uint256 net = gross - mgmt - perf;

        assertEq(vault.previewRedeem(shares), net - (net * 50) / 10_000, "penalty applies to the NET");
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-path test/fees/InstantExitFee.t.sol -vv`
Expected: compile error — `setInstantExitFeeBps` and `ExitFeeTooHigh` do not exist.

- [ ] **Step 3: Implement the penalty**

Add the cap next to the other vault constants:

```solidity
    /// @notice Ceiling on the early-exit penalty (2%). Spec 2026-07-24 §5.
    uint256 public constant MAX_INSTANT_EXIT_FEE_BPS = 200;
```

Replace the `_exitPenalty` stub from Task 7:

```solidity
    /// @dev Early-exit penalty on `netAssets` — an ADDITIONAL charge on top of the
    ///      fee crystallization in `_exitFees`, with a different purpose and a
    ///      different destination. It compensates the depositors who stay for the
    ///      cost of an early unwind, so it simply stays in the vault (their share
    ///      price rises by it); no transfer, no recipient, no escrow path.
    ///
    ///      Charged only on the portion this exit must PULL from the strategy — an
    ///      exit served from idle float forced no unwind and owes nothing (spec
    ///      §5). `previewRedeem` and `_withdraw` observe the same pre-pull float
    ///      within a transaction, so the quote is exact.
    function _exitPenalty(uint256 netAssets) private view returns (uint256) {
        uint16 bps = _instantExitFeeBps;
        if (bps == 0 || netAssets == 0) return 0;
        (,,, bool laneA) = _laneState();
        if (!laneA) return 0;

        uint256 reserve = reservedQueueAssets() + uint256(_crystallizedMgmt) + uint256(_crystallizedPerf);
        uint256 float = IERC20(asset()).balanceOf(address(this));
        uint256 need = netAssets + reserve;
        if (need <= float) return 0; // fully covered by idle float
        uint256 pulled = need - float;
        if (pulled > netAssets) pulled = netAssets;
        return (pulled * bps) / FeeConstants.BPS_DENOMINATOR;
    }

    /// @inheritdoc ISyndicateVault
    function instantExitFeeBps() external view returns (uint256) {
        return uint256(_instantExitFeeBps);
    }

    /// @inheritdoc ISyndicateVault
    function setInstantExitFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_INSTANT_EXIT_FEE_BPS) revert ExitFeeTooHigh();
        _instantExitFeeBps = bps;
        emit InstantExitFeeUpdated(bps);
    }
```

Add to `src/interfaces/ISyndicateVault.sol`:

```solidity
    /// @notice Early-exit penalty exceeds `MAX_INSTANT_EXIT_FEE_BPS`.
    error ExitFeeTooHigh();

    event InstantExitFeeUpdated(uint16 bps);

    /// @notice Early-exit penalty on the strategy-pulled portion of a Lane A
    ///         instant exit, in bps. Accrues to the vault, not to any recipient.
    function instantExitFeeBps() external view returns (uint256);

    function setInstantExitFeeBps(uint16 bps) external;
```

No `_withdraw` change is needed: `previewRedeem` already deducts the penalty, so the caller receives less and the difference never leaves the vault.

- [ ] **Step 4: Run the tests**

Run: `forge test --match-path test/fees/InstantExitFee.t.sol -vv`
Expected: 6 tests PASS.

Run: `forge test --match-path test/SyndicateVault.InstantLiquidity.t.sol -vv`
Expected: PASS.

Run: `forge test --match-path test/SyndicateVault.LaneA.t.sol -vv`
Expected: PASS.

- [ ] **Step 5: Check the bytecode budget**

Run: `forge build --sizes 2>&1 | grep -E "SyndicateVault|SyndicateGovernor"`
Expected: `SyndicateVault` runtime under **98 304** bytes — Robinhood Chain (id 4663) sets `MaxCodeSize = 0x18000`, four times standard EIP-170. Exceeding 24 576 is expected and fine for this deployment; record the number in the commit body. If a Base (8453) deployment of this vault is ever targeted, this is a hard blocker and the exit-fee code must move into `SyndicateVaultAdminLib` behind a delegatecall, as `approveDepositor` already does.

- [ ] **Step 6: Commit**

```bash
git add src/SyndicateVault.sol src/interfaces/ISyndicateVault.sol test/fees/InstantExitFee.t.sol
git commit -m "feat(fees): early-exit penalty on the strategy-pulled portion of Lane A exits"
```

---

### Task 9: Pay crystallized fees at settlement; cover the self-managed path

Task 7 books crystallized fees into the vault; Task 6 subtracts them from what the fund owes. Neither pays them to their recipients yet. This closes the loop and settles the `selfManagesFees` question (deviation D3).

**Files:**
- Modify: `src/SyndicateGovernor.sol` (`_distributeFees`)
- Test: `test/fees/FeeDistribution.t.sol` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `test/fees/FeeDistribution.t.sol` (add `_instantExit(address,uint256)`, `_queueRedeem(address,uint256)`, `_useSelfManagedStrategy()`, `_grossValueOf(uint256)` helpers):

```solidity
    /// @notice Fees crystallized out of an instant exit reach the SAME recipients,
    ///         with the same splits, at the next settlement.
    function test_crystallizedFeesArePaidToSnapshotRecipientsAtSettle() public {
        _fundAndExecute(1_000_000e6);
        _instantExit(alice, 100_000e6); // crystallizes into the vault
        assertGt(vault.crystallizedMgmt() + vault.crystallizedPerf(), 0);

        uint256 guardianBefore = usdc.balanceOf(guardianRecipient);
        _settleWithPnl(0);

        assertGt(usdc.balanceOf(guardianRecipient), guardianBefore, "the exiter's slice reached the guardians");
        assertEq(vault.crystallizedMgmt(), 0, "counters cleared");
        assertEq(vault.crystallizedPerf(), 0);
    }

    /// @notice Deviation D3: a self-fee'd strategy still pays MANAGEMENT (that leg
    ///         never touches PnL, so the float-delta misread does not apply), but
    ///         its performance leg stays skipped.
    function test_selfManagedStrategyPaysManagementButNotPerformance() public {
        _useSelfManagedStrategy();
        _fundAndExecute(1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        _settleWithPnl(50_000e6);

        assertGt(usdc.balanceOf(guardianRecipient), 0, "management is charged");
        assertEq(usdc.balanceOf(vaultOwner), 0, "performance is skipped");
    }

    /// @notice Lane B claims at the POST-fee price — the queue stamp is taken
    ///         after `_distributeFees`, so queue exiters bear their share too.
    function test_queueStampIsPostFee() public {
        _fundAndExecute(1_000_000e6);
        uint256 reqId = _queueRedeem(bob, 50_000e6);
        vm.warp(block.timestamp + 30 days);
        _settleWithPnl(21_500e6);

        uint256 claimed = queue.claim(reqId);
        assertLt(claimed, _grossValueOf(50_000e6), "queue claims at the POST-fee price");
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-path test/fees/FeeDistribution.t.sol -vv`
Expected: `test_crystallizedFeesArePaidToSnapshotRecipientsAtSettle` FAILs — the guardian balance does not move and the counters are cleared without any payout.

- [ ] **Step 3: Add the crystallized payout leg**

In `src/SyndicateGovernor.sol`, inside `_distributeFees`, immediately after the performance-fee block and **before** `ratchetHighWaterMark()`. Move the `totalFee = mgmtFee + perfFee;` assignment above this block so the `+=` compounds:

```solidity
        totalFee = mgmtFee + perfFee;

        // ── 3. Pay out what Lane A exiters crystallized ──
        // These assets were retained by the vault at exit and excluded from
        // `totalAssets()`. They belong to the same recipients under the same
        // splits as the fund-level legs above; settle is the first point where
        // the vault-side amounts can be matched to the proposal's snapshot
        // recipients (deviation D2). The vault clears the counters in
        // `onProposalSettled`, which `_finishSettlement` calls after this.
        {
            uint256 cMgmt = ISyndicateVault(vault).crystallizedMgmt();
            uint256 cPerf = ISyndicateVault(vault).crystallizedPerf();
            if (cMgmt > 0) {
                IProtocolConfig.MgmtSplit memory ms = prop.snapshotMgmtSplit;
                uint256 pShare = (cMgmt * ms.protocolBps) / FeeConstants.BPS_DENOMINATOR;
                uint256 gShare = (cMgmt * ms.guardianBps) / FeeConstants.BPS_DENOMINATOR;
                _payProtocol(prop.snapshotProtocolFeeRecipient, vault, asset, pShare);
                _payGuardian(proposalId, prop.snapshotGuardiansFeeRecipient, vault, asset, gShare);
                _distributeAgentFee(proposalId, vault, asset, proposer, cMgmt - pShare - gShare);
            }
            if (cPerf > 0) {
                IProtocolConfig.PerfSplit memory ps = prop.snapshotPerfSplit;
                uint256 pShare = (cPerf * ps.protocolBps) / FeeConstants.BPS_DENOMINATOR;
                uint256 gShare = (cPerf * ps.guardianBps) / FeeConstants.BPS_DENOMINATOR;
                uint256 oShare = (cPerf * ps.ownerBps) / FeeConstants.BPS_DENOMINATOR;
                _payProtocol(prop.snapshotProtocolFeeRecipient, vault, asset, pShare);
                _payGuardian(proposalId, prop.snapshotGuardiansFeeRecipient, vault, asset, gShare);
                _payFee(vault, asset, ISyndicateVault(vault).owner(), oShare);
                _distributeAgentFee(proposalId, vault, asset, proposer, cPerf - pShare - gShare - oShare);
            }
            totalFee += cMgmt + cPerf;
        }
```

- [ ] **Step 4: Verify the call ordering**

Run: `grep -n "_distributeFees\|onProposalSettled\|ratchetHighWaterMark" src/SyndicateGovernor.sol`
Expected: `_distributeFees` (which pays and ratchets) precedes `onProposalSettled` (which clears the counters and stamps the queue price) in `_finishSettlement`. If the order is inverted, the payout reads zeroed counters and the exiter's fees are silently burned — fix the order before proceeding. `test_queueStampIsPostFee` is the regression guard.

- [ ] **Step 5: Confirm the self-managed path**

Task 6's `_distributeFees` already gates only the performance leg on `!selfManaged`, and Task 4 wired `strategyMint`/`strategyBurn` into the accrual base, so `test_selfManagedStrategyPaysManagementButNotPerformance` should pass with no further change. Run it and confirm. If the management fee comes out zero, the custody strategy is not going through `strategyMint` — trace which vault hook it does use and add the matching `_adjustMgmtBase` call there.

- [ ] **Step 6: Run the tests**

Run: `forge test --match-path test/fees/FeeDistribution.t.sol -vv`
Expected: 10 tests PASS.

Run: `forge test 2>&1 | tail -30`
Expected: whole suite green.

- [ ] **Step 7: Commit**

```bash
git add src/SyndicateGovernor.sol test/fees/FeeDistribution.t.sol
git commit -m "feat(fees): pay crystallized exit fees at settlement; management fee on self-managed strategies"
```

---

### Task 10: Documentation, goldens, and spec status

**Files:**
- Modify: `docs/specs/2026-07-24-fee-model-design.md`
- Modify: `docs/product/2026-07-24-fee-model-product-spec.md`
- Modify: `README.md`
- Modify: `script/syndicate-governor-layout.golden.json`

- [ ] **Step 1: Regenerate and inspect the storage goldens**

```bash
./script/check-layout-goldens.sh || true
forge inspect SyndicateGovernor storageLayout --json > script/syndicate-governor-layout.golden.json
git diff script/syndicate-governor-layout.golden.json
./script/check-storage-parity.sh
```

Expected: `check-storage-parity.sh` PASSES, and the golden diff shows **only appended** members. Any moved existing slot is a bug to fix, not a golden to accept.

- [ ] **Step 2: Add the fee table to the README**

Insert under the protocol overview:

```markdown
## Fees

Sherwood funds charge two numbers, like a hedge fund.

| Fee | Rate | Charged on | Paid when |
|---|---|---|---|
| Management | 2%/yr (cap 3%) | fund assets while a strategy is live, time-weighted | every settlement — profit, flat, or loss |
| Performance | 20% (cap 30%) | profit above the high-water mark | profitable settlements only |

The management fee accrues while a strategy is live and is charged at every
settlement regardless of P&L. Capital sitting in the vault between strategies is
not under management and is not charged.

Every recipient is paid out of those two numbers via governance-set splits:
management **70/20/10** (agent / protocol / guardian), performance
**60/15/15/10** (agent / protocol / guardian / fund owner).

Redemption terms: no deposit fee; the Lane B queue is free; a Lane A instant exit
crystallizes the exiter's accrued fees at exit **and** pays an early-exit penalty
(≤ 2%, proposed 0.5%) on the strategy-pulled portion, which accrues to the
depositors who stay.
```

- [ ] **Step 3: Correct the product spec's always-on wording (decision Q1)**

The management fee accrues only while a strategy is live (decision Q1 above). Three places in `docs/product/2026-07-24-fee-model-product-spec.md` currently claim otherwise and must be corrected — the depositor-facing disclosure has to match the contract.

Line 41, the headline table row. Before:

```markdown
| **Management fee** | 2%/yr | fund assets (AUM), time-weighted | **Always** — profit, flat, or loss |
```

After:

```markdown
| **Management fee** | 2%/yr | fund assets under a live strategy, time-weighted | **Every settlement** — profit, flat, or loss |
```

Lines 44-46. Before:

```markdown
That's the whole depositor-facing picture, plus one-time and redemption terms
(below). The management fee keeps every party that does continuous work funded in
flat months; the performance fee rewards everyone on the upside.
```

After:

```markdown
That's the whole depositor-facing picture, plus one-time and redemption terms
(below). The management fee keeps every party that does continuous work funded in
flat months; the performance fee rewards everyone on the upside.

The management fee accrues while a strategy is live and is charged at every
settlement, whatever the P&L. Capital resting in the vault between strategies is
not under management and is not charged — nobody is trading it, no guardian is
reviewing it, and you can withdraw it freely.
```

Lines 78-79. Before:

```markdown
*management* fee — 0.20%/yr on AUM, paid regardless of profit — is what replaces
the volume fee's flat-month role, and it closes the guardian-funding gap our
```

After:

```markdown
*management* fee — 0.20%/yr on assets under a live strategy, paid regardless of
profit — is what replaces the volume fee's flat-month role, and it closes the
guardian-funding gap our
```

Re-wrap the following line if `forge fmt`-style 100-column prose wrapping in that file leaves it ragged; the surrounding paragraph must still read as one sentence.

- [ ] **Step 4: Flip both specs to implemented**

In `docs/specs/2026-07-24-fee-model-design.md`, change `**Status:** Design — not implemented` to `**Status:** Implemented (PR #<n>)` and append a short "As built" section recording deviations D1/D2/D3, decision Q1, and the two remaining open questions from this plan, so the spec and the code do not silently diverge.

In `docs/product/2026-07-24-fee-model-product-spec.md`, change `**Status:** Proposed` to `**Status:** Implemented`, and in the "Open decisions" list mark item 1 ("The two numbers") as still open but note that the management fee's accrual window is now settled per decision Q1.

- [ ] **Step 5: Final verification**

```bash
forge fmt --check
forge build --sizes 2>&1 | grep -E "SyndicateVault|SyndicateGovernor"
forge test 2>&1 | tail -20
```

Expected: formatting clean, `SyndicateVault` runtime under 98 304 bytes, whole suite green. Record the vault and governor runtime sizes in the commit body.

- [ ] **Step 6: Commit**

```bash
git add docs/ README.md script/
git commit -m "docs(fees): two-number fee model shipped — README table, spec status, storage goldens"
```

---

## Not in scope

Named here so nobody assumes they were forgotten:

- **Share-dilution fee collection.** The onchain standard (Set, Enzyme, dHEDGE, Yearn) mints fee shares instead of transferring assets, so a fully-deployed strategy never liquidates to pay a fee. Spec §4 defers it: it is an architecture change to the vault share ledger and it interacts with the ERC-4626 inflation-attack defence (`_decimalsOffset`). It changes *how* fees are paid, not *what* is owed, so it is a clean follow-up.
- **Hurdle rate.** Needs a benchmark oracle. `_highWaterPricePerShare` is the natural place to add one later (a hurdle is a shifted mark).
- **Per-depositor marks / series accounting.** Would require non-fungible shares. Every onchain single-share-class vault accepts the same residual.
- **Staking discounts and the WOOD buyback.** Product-spec rollout items 2 and 3, downstream of this contract release.
- **Subgraph.** Spec §6 asks for `managementFee` / `performanceFee` per proposal with their splits, plus the high-water-mark series. The events emitted in Tasks 6 and 7 (`ManagementFeeCharged`, `PerformanceFeeCharged`, `HighWaterMarkUpdated`, `ExitFeesCrystallized`) carry everything needed; the indexer work lives in the subgraph repo.
