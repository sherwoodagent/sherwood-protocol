# Design — Guardian Economic Security Plan C (v1b part 1)

This plan had no dedicated design doc; it implements part 1 of the v1b phase of the master design — see `openspec/changes/archive/2026-07-22-guardian-econ-security-A-execution-safety/design.md` (§3.8, §4 authorized-slasher entrypoint, findings F1) for the threat model and rationale. What follows is this plan's own architecture notes, pinned decisions, and post-implementation corrections.

## Context

Plan A (PR #13) shipped execution-side bounds; Plan B (PR #22) completed v1a (coverage ledger, approve quorum, bonds). This is v1b part 1: the payout *sink*. Two follow-on plans complete v1b — Plan D (challenge game, §3.4: five predicates, bonded filing, coverage freeze, undisputed auto-slash, disputed → parked for the court; it *calls* this plan's `slashToEscrow`) and Plan E (approver premium §3.10 + watchtower funding, gated on the §4 blocking ROE validation). This slice ships first because it contains the F1 regression fix and every other v1b component terminates in it.

## Goals / Non-Goals

**Goals:** authorized-slasher entrypoint on `StakedWood` routing slash proceeds to a `CompensationEscrow`; snapshot-gated, non-transferable compensation claims paying pre-drain shareholders; residue sweep to the protocol backstop.

**Non-Goals (stated plainly in the PR):** the challenge game (§3.4, Plan D); approver premium + watchtower (§3.10, Plan E); two-layer court (§3.5, v1c). Until Plan D lands, `authorizedSlasher` is owner-set, so a verdict is a governance action, not an adjudicated one.

## Decisions

### Architecture

A standalone `CompensationEscrow` (Ownable2Step, like `TierRegistry`/`ProposerBondEscrow`) holds WOOD slash proceeds per *case*. A case is `(vault, snapshotTimestamp, proceeds)`; holders redeem pro-rata against `SyndicateVault.getPastVotes(holder, snapshotTimestamp) / getPastTotalSupply(snapshotTimestamp)` — the ERC20Votes checkpoint the vault already maintains. Claims are a mapping, never a token, so they are non-transferable by construction (no transfer surface means a claim cannot be bought from an exiting honest holder). `StakedWood` gains an owner-settable `authorizedSlasher` role and a `slashToEscrow` entrypoint that reuses the existing per-approver slash legs (own stake, delegated at the `maxDelegatedSlashBps` cap, first-loss spill) but sends the total to the escrow rather than `_burnWood`. A zero-total verdict is a no-op — no empty case is opened. Zero-supply snapshots are rejected at `openCase` rather than stranding WOOD in an unredeemable case. Redemption is pull-based with effects-before-interaction; `claimable` rounds down so the sum of claims can never exceed proceeds (dust leaves with the residue). `sweepResidue` is permissionless because the destination is the owner-set backstop — an arbitrary caller can only accelerate a fixed transfer, never redirect it.

### Pinned decisions (D1–D5)

**D1 — Claim basis is `getPastVotes`, not raw balance.** `SyndicateVault` is `ERC20VotesUpgradeable` and auto-delegates on receipt (`_delegate(to, to)`), so for the overwhelming majority of holders `getPastVotes(h, t) == balanceOf(h)` at `t`. Solidity keeps no historical *balance* checkpoint, and adding one means a new checkpoint array on a live upgradeable vault. **Accepted edge, documented in natspec:** a holder who explicitly delegated to a third party has its compensation credited to that delegate, not to itself — a real deviation from "pro-rata to shares held then." Accepted for v1b because (a) auto-delegation makes explicit delegation rare, (b) the delegate relationship is holder-chosen, and (c) the alternative is a storage addition to a live vault. Revisit if vault-share delegation becomes common.

**D2 — Snapshot timestamp is supplied by the slasher, not derived.** Per §3.8 the correct block differs by predicate: for predicates 1–4 (and predicate 5 on a short strategy) it is the block before the drain proposal executed; for a per-epoch drawdown conviction it is the epoch-N opening checkpoint block. The escrow cannot know which, so `openCase` takes it as a parameter and the caller (Plan D's challenge game) chooses. The escrow enforces only that it is in the past.

**D3 — Payout is WOOD** (§3.8 "WOOD-only payout boundary"). Victims are made whole in WOOD valued at slash time — exactly why §3.7's covered-TVL cap must bind. No conversion is attempted here.

**D4 — `refundSlash` must NOT reach this path** (§4). The registry's existing 20%/epoch appeal reserve stays bound to the *block-quorum review* slash. A verdict slash is proven malice and is not refundable. This plan adds no refund path and does not touch `GuardianRegistry.refundSlash`; the two slash paths (`onlyRegistry` review-burn vs `onlyAuthorizedSlasher` verdict-escrow) stay structurally distinct.

**D5 — Escrow is not upgradeable.** Like `TierRegistry`/`ProposerBondEscrow`, a plain Ownable2Step deploy, so its storage layout is unconstrained. `StakedWood` *is* UUPS and live: its additions are append-only, carved from `uint256[9] private __gap`.

### Invariant (spec §4: one per new accounting path, with a fuzz test)

The escrow's WOOD balance is always at least the sum over open cases of `(proceeds − redeemed)` (tracked as `totalEscrowed`; fuzzed in `testFuzz_balanceCoversOutstanding`).

## Risks / Trade-offs

- D1's delegation edge: compensation follows delegated votes, not raw balances.
- Residue is lost to holders after the residue window by design — the sweep is what bounds the escrow's liability, so redemption fails after sweep.
- A case whose vault had zero supply at the snapshot is rejected rather than parked.
- Until Plan D, a verdict is a governance action; FIX 5 below shrinks what a compromised `authorizedSlasher` can do meanwhile.

## Post-implementation amendments (2026-07-25, from code review)

The shipped code intentionally diverges from the plan's task snippets. Review found a **critical fund-mixing bug** and several hardening gaps; the fixes landed in `e7fcc24` and this section is the record of record where they disagree with the tasks:

1. **Per-case fund isolation (critical).** `claimable` caps at the case's own remaining balance: `min(proceeds * votes / snapshotSupply, proceeds - redeemed)`. Without the cap a `vault` reporting votes > its own supply let one case pay out of a sibling case's funds — demonstrated as a 1-WOOD case paying 50 WOOD — and larger skews underflowed `totalEscrowed`, bricking redemption.
2. **`slashBps` is clamped** in `slashToEscrow` to `[minSlashBps, maxSlashBps]`, the same envelope `GuardianRegistry._severityBps` applies on the review path. Note `slashBps = 0` now floors to `minSlashBps` rather than being a no-op.
3. **`escrow` is owner-set state, not a call parameter.** `StakedWood` gained `compensationEscrow` (slot 46, gap `8 → 7`) + `setCompensationEscrow`. `slashToEscrow`'s arity as of this plan is `(bytes32 caseKey, uint256 openedAt, address[] approvers, uint256 slashBps, address vault, uint256 snapshotTimestamp)` — the plan's Task 4 snippets show the older 7-arg form. Uses `forceApprove` and zeroes the allowance after `openCase`. **STALE as of the 2026-07-29 court-incentives design §2:** its Task 1 appended `(address bountyTo, uint256 bountyBps)`, so the real arity today is eight parameters, not six — see that spec for the conviction-bounty channel and its `MAX_CONVICTION_BOUNTY_BPS` cap.
4. **The residue window is frozen per case** (`Case.residueWindowAtOpen`), so the owner cannot lower it and sweep funds from cases opened under longer terms.
5. **`snapshotTimestamp <= openedAt`** is enforced in `slashToEscrow` (`SnapshotAfterVerdict`). This shrinks what a compromised `authorizedSlasher` can do before Plan D: it cannot pick a POST-drain snapshot at which the coalition holds everything and hand the attacker back its own slash.
6. **`caseOf` returns `swept`**, and `slashToEscrow` returns `(total, caseId)` and emits `VerdictSlashRouted`.

Two observations carried into Plan D:

- **The golden layout guard cannot see gap length.** Its canonicalizer strips the digits after `)`, so `t_array(t_uint256)7_storage` and `...)8_storage` compare equal. A wrong-sized `__gap` alone would pass the guard; only a *shifted* field is caught. Gap arithmetic still needs a human check on every append.
- **FIX 5 exposed a fixture bug rather than just adding a constraint:** the e2e suite had been setting `openedAt` BEFORE the LP deposits — i.e. the verdict opened before the drain it convicts. The ordering is now realistic.
