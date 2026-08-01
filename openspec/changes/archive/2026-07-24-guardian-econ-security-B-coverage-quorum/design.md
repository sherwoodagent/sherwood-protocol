# Design — Guardian Economic Security Plan B (v1a completion)

This plan had no dedicated design doc; it implements the v1a phase of the master design — see `openspec/changes/archive/2026-07-22-guardian-econ-security-A-execution-safety/design.md` (§3.3, §3.3a, §3.4a, §3.6, §3.7, §3.9, §4, §5, §8) for threat model, rationale, and parameter derivations. What follows is this plan's own architecture notes only.

## Context

Plan A stored `requiredCoverage` per proposal without consuming it. Plan B builds the dollar-accounting layer that consumes it: exposure caps at approve-vote time, quorum at execute time, bonds at propose/certify time. Sequencing: v1b (authorized-slasher entrypoint, compensation escrow §3.8, challenge game §3.4, approver premium §3.10) was deliberately split out as Plans C–E — v1b is an independent subsystem (retroactive liability). v1c (two-layer court §3.5) is later still.

## Goals / Non-Goals

**Goals:** aggregate exposure cap with epoch-bucketed accounting; explicit approve quorum for coverage-consuming proposals; risk-scaled proposer bond; hard WOOD-only covered-TVL cap; adapter-submitter bond; rewire path for pre-existing governors (LOW-1, issue #19).

**Non-Goals (deferred, stated in the PR):** compensation escrow, challenge game, bond forfeiture (Plan C+); multi-collateral (v2); renewal / renew-before-reveal / forced wind-down of §3.4a (Plan C); coverage-exact emergency-settle owner bond scaling.

## Decisions

### Architecture

A new standalone `ExposureLedger` (Ownable2Step singleton, like `TierRegistry`) owns all dollar accounting: a governance-set conservative WOOD→USD price (`priceHaircut`, spec §5 — no WOOD Chainlink feed exists, spec §8), per-asset Chainlink feeds for vault assets, `slashableBondUsd(g)` per spec §3.3, and per-guardian epoch-bucketed open-exposure tracking (spec §3.4a: "Plan B's exposure ledger must build epoch semantics from day one"). `GuardianRegistry` (UUPS upgrade) calls the ledger on every approve-side review vote — recording exposure, reverting the vote if the guardian's cap is exceeded. `SyndicateGovernor` (beacon upgrade) checks the covered-TVL cap and locks a risk-scaled proposer bond at `propose`, and enforces the approve quorum at `executeProposal` for proposals at/above a governance tier threshold. A new `ProposerBondEscrow` holds WOOD bonds keyed by `(governor, proposalId)` with a single permissionless release path on terminal states. `TierRegistry` gains a submitter bond on `certify` (held while certified, timelocked release after demote). `SyndicateFactory` wires the two new addresses into every new governor and gains rewire entrypoints for existing governors.

### Key accounting rules

- `slashableBond(g)` (spec §3.3): `ownStake(g) * priceHaircut + delegatedInbound(g) * maxDelegatedSlashBps/10_000 * priceHaircut`. Delegated stake counts only at the delegated-slash cap — counting full vote weight would violate the coalition inequality at the accounting layer.
- Exposure is epoch-bucketed: `recordApproval` books USD into `_buckets[guardian][currentEpoch()]` and remembers `(usd, epoch)` per `(reviewKey, guardian)` so a vote-change releases exactly what was recorded. `openExposureUsd(g)` sums exactly the buckets whose challenge window has not elapsed — bucket `e` drops at exactly `end(e) + W`, so the coverage budget recycles every challenge window with no epoch-granularity slack.
- Cap check: `openExposureUsd(g) + newUsd <= kNumerator * slashableBondUsd(g)`, revert `ExposureCapExceeded`, enforced at vote time.
- Approve quorum (§3.3a): execution requires the covering approvers' aggregate `slashableBondUsd` (live read) to meet the proposal's coverage. Live rather than at-vote: sWOOD's `coolDownPeriod >= epoch + challengeWindow` prevents full escape, and a live read is strictly conservative. Zero approvers always reverts, even at zero coverage — an identified signer is required for anything tier-gated into the check.
- Bond formula (§3.9/§5): `bondWood = coverageUsd * proposerBondBps / 10_000 * 1e8 / woodUsdPriceX8`, computed ledger-side so the governor makes one call.
- Fail-closed everywhere: unset WOOD price values every bond at $0; unconfigured/stale asset feed reverts; zero covered-TVL cap means nothing proposable through a wired governor until governance seeds it. No L2-sequencer branch (no sequencer-uptime feed in the Robinhood chain config).
- Pre-wiring compatibility: ledger/escrow unset (`address(0)`) skips the hooks/gates, matching the tierRegistry pattern — Plan A behavior preserved for unwired deployments.

### Unit conventions

- USD amounts: 18 decimals (`1e18` = $1).
- `woodUsdPriceX8`: 8 decimals (Chainlink convention). `usd = woodWei * priceX8 / 1e8`.
- Asset→USD: `usd18 = amount * feedPrice * 1e18 / (10^assetDecimals * 10^feedDecimals)`; asset decimals cached at feed registration.

### Storage cautions (upgradeable contracts)

- `StrategyProposal` gains two appended fields (`proposerBondWood`, then `proposerBondEscrow`) — append at the END only. The escrow address is stored per proposal because the bond is custodial: `reclaimProposerBond` must release against the escrow that actually holds the bond, not the governor's live `_bondEscrow` slot — otherwise re-pointing that slot strands every outstanding bond permanently (the escrow has no owner and no discretionary exit; its bond key is `(governor, proposalId)`, so only this governor can ever address them).
- `SyndicateGovernor`: two address slots, `__gap` 33 → 31. `GuardianRegistry`: one slot, `__gap` 50 → 49. `SyndicateFactory`: two slots. After any change, regenerate layout goldens and verify append-only; if a pin on an existing slot moves, stop and surface.

### Reentrancy ordering at propose (found in review)

`lockBond` is a state-changing external call pulling WOOD via `transferFrom`, so a hooked WOOD can re-enter the governor mid-`propose`. Every field the proposal's state machine reads must be written before the call. `collaborationDeadline[proposalId]` was written inside `_storeCoProposers` (after `_snapshotTier`) — a collaborative Draft was observable mid-`lockBond` with `state == Draft` and `collaborationDeadline == 0`, which `_resolveStateView` maps to Expired, permanently bricking the proposal. Fix: hoist the `collaborationDeadline` write into the `isCollaborative` branch before any external call; invariant stated at the `lockBond` site: no proposal-state write may move below this call.

### Launch gates (spec §4, both gates baked in)

1. Every new accounting path carries a one-sentence invariant + fuzz test (exposure conservation, escrow balance conservation, tier-bond conservation).
2. BLOCKING pre-launch gate: the approve quorum is fail-closed only for `envelopeTier >= quorumTierThreshold`, launch value 2 (tier-2 only) — bounded-tier flow keeps optimistic passage so liveness does not depend on §3.10 premium economics that do not exist yet. Lowering to 1 or 0 is a governance action gated on the §3.10 ROE validation.

### Cross-contract invariant (deploy gate)

sWOOD `coolDownPeriod >= epochLength + challengeWindow` (spec §5: a guardian cannot unstake before its epoch's approvals can be challenged). At defaults: `28d + 14d = 42 days`. Enforced in the ledger's `setChallengeWindow` and asserted as a pre-flight in `DeployPlanB.s.sol`; raising a live cooldown is a governance action, surfaced rather than performed.

## Risks / Trade-offs

Known deliberate gaps, stated in the PR rather than silently shipped:

- Exposure is released by TIME (epoch + challenge window), not by settle — a settled-early proposal's coverage stays booked until its bucket ages out. Conservative and spec-consistent.
- `requiredCoverage` still over-counts multi-call batches (Plan A finding-5): the cap is conservative; per-call notional threading is future work.
- The quorum reads approver bonds live at execute, not at slash time — true slash-time dollar coverage arrives with the challenge game (Plan C); the covered-TVL cap bounds the gap meanwhile. The WOOD-price-crash e2e test demonstrates the live read blocking execution (F2 approximation for v1a).
- §3.9's emergency-settle owner bond clause is satisfied only approximately: sWOOD's `requiredOwnerBond` is TVL-scaled, which upper-bounds any proposal's coverage but is not coverage-exact; re-scaling it off `requiredCoverage` is deferred to Plan C.
- Type-consistency pins: `requiredCoverage` is vault-asset units until it crosses `coverageUsd()`; USD is always 18-dec; `woodUsdPriceX8` 8-dec; reviewKey derivation `keccak256(abi.encode(governor, proposalId))` is byte-identical in GuardianRegistry, ExposureLedger, and ProposerBondEscrow.
