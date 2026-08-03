## MODIFIED Requirements

### Requirement: Slash gas floor
Because `resolve` is permissionless, `_settle` SHALL revert `InsufficientSlashGas` when `gasleft() < approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE`, with `SLASH_GAS_PER_APPROVER = 180_000` and `SLASH_GAS_BASE = 2_000_000` — measured end to end through court `finalize`, not against the slash call alone. When the challenge names a non-zero adapter, the floor SHALL additionally require `DEMOTION_GAS = 200_000`: the check becomes `gasleft() >= approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE + DEMOTION_GAS`, so a settle that passes it is GUARANTEED to reach the best-effort `demoteByChallenge` child with enough gas for the demotion to succeed on a willing registry — a caller cannot choose a gas budget on which the conviction lands but the demotion is starved. A filing that accuses no adapter (zero `adapterTarget`) demotes nothing and SHALL owe nothing for it: its floor is the slash terms alone. Without the term, the demotion's gas safety rested on two incidental facts — the slash constants' measured slack reaching the demotion call, and an out-of-gas demotion child consuming its whole 63/64 stipend so the 1/64 remainder could not pay for the settle's own tail (the whole call reverted rather than settling with a silent miss). Both held at the time this term was added, but neither was stated or tested; the explicit term is what survives retuning the slash constants, slimming the settle tail, or reordering the demotion. The full-cap floor including `DEMOTION_GAS` SHALL fit Robinhood's 32M per-transaction limit (`100 * 180_000 + 2_000_000 + 200_000 = 20,200,000` against `32M * (63/64)^3 = 30,523,315`). The check is skipped on the `VerdictAlreadyCollected` branch (nothing is slashed, nothing is demoted) and a failed check changes no challenge state — retry with more gas.

#### Scenario: Under-gassed resolve reverts cleanly
- **WHEN** `resolve` reaches the slash with less than the floor remaining
- **THEN** it reverts `InsufficientSlashGas` and the challenge remains resolvable by a retry with more gas

#### Scenario: A budget that covers the slash but not the demotion is refused up front
- **WHEN** `resolve` or `rule` reaches `_settle` on an adapter-naming challenge with gas at or above the slash terms but below the demotion-extended floor
- **THEN** it reverts `InsufficientSlashGas` before any state moves — the conviction cannot land on a budget that cannot also afford the demotion

#### Scenario: A settle that clears the extended floor lands the demotion
- **WHEN** an adapter-naming challenge settles with the demoter role intact and gas exactly at the extended floor
- **THEN** the demotion succeeds — no `AdapterDemotionFailed` is emitted and the adapter's certification is revoked

#### Scenario: No-adapter filings pay no demotion term
- **WHEN** a challenge naming the zero adapter settles with gas at or above the slash-only floor
- **THEN** the floor passes and the settle completes, demoting nothing

### Requirement: Adapter demotion is best-effort on a passed challenge only
A passed challenge naming a non-zero adapter SHALL attempt `tierRegistry.demoteByChallenge(target, selector)` inside a `try/catch`: a registry refusal (e.g. the game's demoter role was rotated away mid-challenge) MUST NOT revert the verdict — the slash, bond refund, and freeze release proceed, and the miss is surfaced as `AdapterDemotionFailed`. The catch exists for REGISTRY-SIDE refusals, which no caller selects at call time; the caller-selectable failure axis — the gas budget — is refused up front by the demotion-extended slash gas floor, so `AdapterDemotionFailed` can no longer be induced by dialling gas. The catch SHALL remain bare (no selector filter): every reachable failure behind the floor is registry-side, and bubbling any of them would re-open the permanent wedge the best-effort design exists to prevent (a revoked role stranding the bond, the freeze, and the accused's unstake path forever). The game's registry surface SHALL be demote-only (`ITierRegistryDemoterMinimal`): it can revoke a certification on a passed challenge and never grant one. No demotion occurs on any non-settled outcome.

#### Scenario: Rotated demoter role does not strand the verdict
- **WHEN** `demoteByChallenge` reverts during settle
- **THEN** `AdapterDemotionFailed` is emitted and the settlement completes; the registry owner's own `demote` is the remedy
