## Context

See `proposal.md` § Why for motivation. The constraints that actually shape the approach:

- **The upstream design is not this repo's design.** `docs/specs/2026-07-24-fee-model-design.md`,
  `docs/product/2026-07-24-fee-model-product-spec.md`, and
  `docs/superpowers/plans/2026-07-24-fee-mechanism.md` were authored on a branch based at
  `9fafa00` (PR #13), 26 commits behind this change's base `integration/lifecycle-planb`.
  They are carried onto this branch as the source of truth for *intent*; three of their
  prescriptions do not survive contact with the current tree, and this document records
  the deviations.
- **One fee chokepoint exists today.** `SyndicateGovernor._distributeFees` (`:1153`),
  reached from `_finishSettlement` (`:1062`), gated on `pnl > 0` (`:1092`). P&L is a pure
  balance delta net of mid-proposal flows. Payment goes through `_payFee` (`:1267`), which
  already try/catches so a bricked recipient cannot block settlement.
- **The vaults are upgradeable (UUPS) and the governor's storage layout is pinned.**
  `test/governor/GovernorLayoutPins.t.sol` freezes governor slots 0–81, and
  `script/check-layout-goldens.sh` runs in CI. `SyndicateVault` reserves `uint256[32]
  __gap` at `:186`.
- **Strategies are ERC-1167 clones.** `src/strategies/` holds 12+ concrete strategies, all
  deployed as minimal proxies. Anything added to `BaseStrategy` multiplies by 12 in both
  code and test surface.
- **Two exit lanes exist and cannot overlap.** `VaultWithdrawalQueue.claim` reverts
  `VaultLocked` unless `!redemptionsLocked()`; the Lane A instant path requires
  `redemptionsLocked()`. Their windows are disjoint by construction.

## Goals / Non-Goals

**Goals:**

- One accrual mechanism for the management fee that is correct under mid-proposal deposits
  and exits, and that adds no per-strategy code.
- A high-water mark that composes correctly with the management fee's effect on price per
  share, and with shares leaving mid-proposal.
- Exit-path charges that keep the ERC-4626 `withdraw`/`redeem` path free of external calls
  and recipient resolution.
- No linear storage reordering in either the governor or the vault; layout goldens stay green.

**Non-Goals:**

- **Share-dilution fee collection.** The onchain standard (Set, Enzyme, dHEDGE, Yearn,
  Balancer) mints fee shares rather than transferring assets. It is strictly better for
  capital efficiency and is the recommended eventual mechanic, but it rewrites the vault
  share ledger and interacts with the ERC-4626 inflation-attack defence (`_decimalsOffset`).
  Deferred by product decision; asset-based collection ships first. It changes *how* fees
  are paid, not *what* is owed, so it can land later without revisiting these specs.
- **Hurdle rate.** Needs a benchmark oracle; rare onchain. The high-water-mark slot is the
  natural place to add one later (a hurdle is a shifted mark).
- **Per-depositor high-water marks.** Would require non-fungible shares. The
  series/equalization problem is accepted, as it is by every onchain single-share-class vault.
- **Continuous (between-proposal) management-fee accrual.** See Decision 4.
- **Removing the volume fee.** It was never built — `grep -rn "volumeFee\|_chargeVolume\|VolumeFeePaid" src/`
  returns nothing. The upstream spec's §2.3 removal is a no-op with no task.
- **Touching any strategy contract.** See Decision 1. The one strategy-adjacent behaviour
  change is that `selfManagesFees` now exempts the performance leg only, and that is a
  governor-side condition.

## Decisions

### Decision 1 — The management-fee accumulator lives on the vault, not on strategies

**Deviates from** upstream design checklist item 3, which places a "TWA-of-deployed-capital
accumulator" on the strategy.

Every event that changes the management-fee base already passes through `SyndicateVault`:
the execute-time capital stamp (`SyndicateGovernor:395`), Lane A deposits
(`SyndicateVault:866`), Lane A instant exits (`:909`), and the custody hooks
`strategyMint`/`strategyBurn` (`:1083`/`:1098`). A single vault-side accumulator is
therefore complete.

*Alternative — per-strategy accumulators.* Requires an accumulator, an update on every
base-changing path, and a test suite in each of 12+ clones, and adds gas to strategy hot
paths. It buys nothing the vault-side accumulator does not already observe. Rejected.

The accumulator is an **asset-seconds integral**: on each base-changing event, add
`base × (now − lastUpdate)` and restamp. At settlement,
`fee = assetSeconds × rate / (BPS_DENOMINATOR × 365 days)`. This is exact under arbitrary
mid-proposal flows and needs no assumption that the base is constant.

### Decision 2 — Exit-time fees are retained by the vault, not transferred at exit

**Deviates from** upstream design §4.1, which routes `perfFeeExit`/`mgmtFeeExit` "to the
split recipients immediately via `_payFee`".

The vault cannot resolve those recipients. The agent is the proposal's `proposer`, which
lives in governor storage (`SyndicateGovernor:1157`); the protocol and guardian recipients
and both splits live on the propose-time snapshot on `StrategyProposal`. Resolving them
from `_withdraw` means a governor call on the ERC-4626 hot path plus a new brick vector on
a path that must not be brickable.

Instead the exiting shares' fees are booked into per-vault crystallization counters,
**excluded from `totalAssets()`**, and paid to the correct snapshot recipients at the next
settlement through the existing `_payFee` escrow. Excluding them from `totalAssets()` makes
the remaining holders' price per share identical to what an immediate transfer would have
produced — so net incidence is unchanged and the exit path stays call-free.

*Alternative — resolve recipients from the vault.* Rejected on the brick vector alone.
*Alternative — leave exit fees uncharged and true up at settle.* This is the current
(broken) behaviour: the exiter has already left with the money, so there is nothing to true
up against.

### Decision 3 — `selfManagesFees` exempts the performance leg only

**Deviates from** upstream design §6, which says the self-managed path "folds its management
+ performance legs the same way".

`selfManagesFees` exists because the governor's float-delta P&L misreads custody-model
deposits as profit (`SyndicateGovernor:1093-1097`). That is a defect in *profit measurement*.
The management fee does not use P&L at all — it is capital × time — so the reason for the
exemption does not reach it. Charging management on the self-fee'd path while keeping
performance skipped is the behaviour that matches the exemption's actual justification.

### Decision 4 — Capital idle between proposals accrues nothing; accept and document

The accrual base is stamped at `executeProposal` and zeroed at settle, so capital sitting in
the vault between proposals accrues no management fee. This matches the upstream design's
"time-weighted deployed capital over the proposal" and contradicts the product spec's "on
fund assets (AUM) … **Always**". The product spec's wording is what changes, not the code.

Charging continuously is not merely more work — it is **blocked on the same recipient-resolution
wall as Decision 2**. The management fee splits three ways and "the agent" is
`proposal.proposer`. Between proposals there is no proposal, so there is no address to pay
the agent's share to. A permissionless `crystallizeManagementFee()` hits exactly that wall.

The behaviour is defensible on the merits: between proposals nobody is managing the money,
guardians have nothing to review, and `redemptionsLocked()` is false so depositors can leave
freely. A management fee with no management is the anomaly, not its absence. Exposure is a
function of duty cycle: with the factory default `cooldownPeriod: 1 hours`
(`SyndicateFactory:420`) against strategy durations up to 30 days, back-to-back proposals
lose a rounding error. The real accepted case is a fund whose agent stops proposing while
depositors stay — that fund charges 0%/yr.

*Alternative — rebase the base to vault float at settle instead of zeroing.* Closes cooldown
gaps, does not close dormancy, and forces the accrual update onto the unconditional
`_deposit`/`_withdraw` paths — a permanent ~5k gas cost on every deposit for a partial fix.
Rejected.
*Alternative — move management-fee recipients onto the vault plus a permissionless crystallize.*
Fully closes it, but the agent's share would go to a standing vault address rather than the
proposer who earned it, breaking the "agent is the largest earner, in every market" property
the product model is built on. That is a product decision, not an implementation one.

### Decision 5 — Performance-fee ceiling 3000; factory default 2000

The absolute protocol constant rises 1500 → **3000**. The factory default per-vault maximum
rises 1500 → **2000** (the headline), not to the ceiling.

This matters because the existing clamp resolves the conflict **silently** — it emits
`FeeClamped` and continues rather than reverting. A too-permissive default therefore fails
*open* (an owner quietly charges more than advertised); a too-restrictive one fails *closed*
(the agent quietly earns less, with an event). Fail-closed is the right default for a
depositor-facing rate. Leaving the factory at 1500 would silently clamp every new vault below
the 20% headline at settle — precisely the failure `FeeClamped` exists to surface.

Three limits stack, so 30% is a backstop and not a target: the protocol constant (code),
the per-vault governor maximum (default 2000), and the vault's own configured rate. A vault
that never configures a rate keeps charging the existing 500 bps default, unchanged.

The factory value ships as a named constant, not a literal — `FeeConstants` exists so fee
numbers cannot be hand-edited into divergence.

### Decision 6 — Splits are snapshotted onto `StrategyProposal`, inside the mapping

Both splits are packed onto `StrategyProposal`, which lives in the `_proposals` mapping.
Mapping values are not part of linear storage, so the frozen governor slot pins (0–81) are
untouched and `script/check-layout-goldens.sh` stays green without a golden update. This is
the same mechanism `protocolFeeBps`/`guardianFeeBps` already use (`SyndicateGovernor:307-313`).

### Decision 7 — The early-exit penalty is charged on the pulled portion only

The penalty compensates remaining depositors for a forced unwind, so it is charged on the
portion of an exit that actually forced one — the part sourced by pulling capital back from
the strategy, not the part idle float absorbed. This makes the fee function kinked at the
float boundary and therefore not cleanly invertible, so `previewWithdraw` grosses up once and
rounds conservatively, burning marginally more shares than strictly necessary.
`previewRedeem` is exact and monotone under either basis, so invertibility is the only
mechanical difference. See Open Question 1 for the argument against.

## Risks / Trade-offs

- **The upstream plan's line anchors may have drifted.** It was written 26 commits back.
  Spot-checked anchors still hold — `_distributeFees:1153`, `_finishSettlement:1062`,
  `_payFee:1267`, `selfManagesFees:1098`, `SyndicateVault.transferPerformanceFee:543`,
  `__gap[32]:186`, `SyndicateFactory.maxPerformanceFeeBps:1500@419` — but the rest are
  unverified. → Re-confirm each anchor at the start of the task that uses it rather than
  trusting the plan; treat a missed anchor as a signal to re-read the surrounding function,
  not to search-and-replace.
- **`managementFeeBps` changes meaning while reusing its storage slot.** Any deployed vault
  carrying a nonzero value under the old profit-gated semantics will, post-upgrade, charge
  it as an annual AUM rate. → Audit stored values on every live vault before upgrading and
  reset them in the same transaction batch as the upgrade; do not assume the default.
- **Four new vault storage slots consume `__gap` 32 → 28.** Correct for UUPS, but only if
  the slots are appended and the gap shrunk by exactly four. → The layout-golden script is
  the gate; run it as part of the task that adds the slots, not at the end.
- **Fee ordering is load-bearing and easy to get subtly wrong.** Management before the mark
  comparison before performance. Reversing any pair charges performance on assets the
  management fee already took, or ratchets the mark past value that was never earned.
  → The ordering is a spec requirement with its own scenarios (`specs/performance-fee/spec.md`),
  not just an implementation note.
- **Crystallization and settlement can double-charge.** Performance is safe by construction
  (exited shares are burned, so they leave the settlement base), but management is not —
  it needs an explicit crystallized-to-date counter netted out at settle. → This asymmetry
  is the most likely source of a silent accounting bug; the "no double-charge" scenarios
  exist specifically to pin it.
- **Raising the headline to 20% while the total fee load falls is counter-intuitive.** The
  old four-step waterfall compounded four haircuts; one split on one base extracts less on
  the same month. → Worth stating explicitly wherever the rate change is communicated, or
  it reads as a fee increase.
- **`via_ir = true` with `optimizer_runs = 50` means slow feedback.** A full 335-file compile
  runs ~10 minutes. → Scope test runs with `--match-path 'test/fees/*'` during development;
  reserve full-suite runs for task boundaries.
- **The optimizer CSE-s `block.timestamp` across `vm.warp`.** Every management-fee test is
  time-based and therefore exposed: a local `uint256 t = block.timestamp` captured before a
  warp silently reads the post-warp value. → Use `vm.getBlockTimestamp()` or anchor to a
  timestamp the contract itself stored. Also note `vm.warp` backwards does not take effect
  in forge 1.7.1, so time tests must be structured forward-only.

## Migration Plan

1. Land the change behind no flag — the fee model is not feature-flagged, so ordering is the
   safety mechanism. Ship in the task order in `tasks.md`: configuration and constants
   first, accrual second, distribution third, exit path last. Each stage leaves the suite green.
2. Before upgrading any live vault, read and record the stored `managementFeeBps` on each.
   Any nonzero legacy value must be reset in the same batch as the upgrade proxy call, since
   its meaning changes.
3. Set the two splits on `ProtocolConfig` **before** the first proposal is created
   post-upgrade. An unset split is a zero-sum split and will be rejected by validation, which
   fails closed — a proposal cannot be created rather than one settling with a bad split.
4. Raise the factory default and the protocol constant together. Raising the constant alone
   leaves every new vault clamped at 1500 with a `FeeClamped` event on each settlement.
5. **Rollback:** the UUPS proxies can be pointed back at the prior implementation. Storage is
   append-only, so a rollback leaves the four new vault slots populated but unread; a
   subsequent re-upgrade reads them intact. The one non-reversible effect is any
   high-water mark already ratcheted — rolling back does not un-ratchet it, and it should
   not, since the fee it recorded was genuinely charged.

## Open Questions

1. **Early-exit penalty basis — pulled portion (implemented) vs. flat.** Decision 7 charges
   the pulled portion, matching the fee's stated purpose. The argument against is that it
   creates a race: in a rush for the exit the first out pays nothing (float covers them) and
   the last pays full, adding pressure to run early — the opposite of what an anti-mercenary
   term wants. A flat basis prices everyone identically and is exactly invertible. Kept as
   specced because the run pressure is second-order — instant-exit capacity is already bounded
   by `IStrategy.availableLiquidity()` (`SyndicateVault:755`) regardless of the penalty.
   Deferrable: switching bases collapses to one expression behind the same Lane A gate and
   inverts one test, and changes no other requirement.
2. **Whether the early-exit penalty ships in this change or a follow-up.** It is independent
   of the management/performance work — different storage, different path, no shared math.
   `tasks.md` sequences it last so it can be dropped without unpicking anything if the release
   needs to be smaller. Answering this later costs nothing.
