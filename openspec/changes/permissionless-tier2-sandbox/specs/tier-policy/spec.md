## MODIFIED Requirements

### Requirement: Tier semantics and the tier-2 default
The registry SHALL recognize exactly three tiers. Tier 0 (closed-loop) and tier 1 (oracle-bounded discretion) are certified tiers whose extractable value is bounded to a certified `extractableBoundBps` (bps of notional). Tier 2 (`TIER_ARBITRARY = 2`, bound `FULL_NOTIONAL_BPS = 10_000`) is arbitrary calldata at full notional and SHALL be the default for any uncertified `(target, selector)`. No on-chain tier ceiling exists: tier-2 exposure is admissible (the ADR 2026-07-27 tier-2 refusal was reversed 2026-07-31; the guardian ROE gap at tier 2 is closed by off-chain team token incentives, not by refusing the tier).

TIER PRICES, IT DOES NOT ADMIT. A tier is a coverage price and SHALL NOT confer reachability: no tier, including tier 0, permits an address to be a governor-batch callee, and tier 2 SHALL NOT be read as permission to call an uncertified address from a batch. Reachability is decided solely by the adapter-allowlist axis below.

ARBITRARY TARGETS ARE REACHED THROUGH A SANDBOX, NOT THROUGH THE BATCH, AND WITH NO OWNER ACTION. Tier-2 calldata aimed at an address with no registry entry SHALL be admissible via the `sandbox-execution` capability, where the calls dispatch from a protocol-minted per-proposal sandbox under its own identity and against capital explicitly funded to it. The adversary this separation answers is authorization-shaped calldata reaching a target as the vault: the per-call meter observes only the vault's asset balance delta, so an approval grant meters zero and prices zero coverage while licensing an unbounded later withdrawal — a loss no `cap_i` can bound because it lands outside the metered transaction. Inside a sandbox the loss ceiling is the funded amount, which is exactly what full-notional coverage charged for, so the target's identity ceases to be load-bearing.

THE REVIEWER OF AN ARBITRARY TARGET IS THE GUARDIAN COHORT, NOT THE REGISTRY OWNER. The registry owner SHALL have no role in admitting a sandbox target: no allowlist entry, no class grant, no certification, and no template approval SHALL be required for any address a sandbox calls. Review happens at approval time, against a call set stored on the proposal and readable before the vote, and is backed by the coverage quorum's slashable stake. The registry axis continues to gate governor-batch callees unchanged — the sandbox does not widen it, it declines to use it.

#### Scenario: Uncertified pair reads as tier 2
- **WHEN** `tierOf(target, selector)` is called for a pair with no certification
- **THEN** it returns `(2, 10_000)` — full notional, no certified bound

#### Scenario: Certified pair reads its certified values
- **WHEN** `tierOf(target, selector)` is called for a pair certified at tier 0 or 1 whose target's live codehash still matches the certified codehash
- **THEN** it returns the certified `(tier, extractableBoundBps)`

#### Scenario: Tier 2 confers no batch reachability
- **WHEN** a governor batch names an uncertified, non-allowlisted address as a callee
- **THEN** the vault's callee gate SHALL reject it, regardless of the tier the pair resolves to

#### Scenario: An uncertified target is reachable inside a sandbox
- **WHEN** a proposal routes calls to an uncertified, non-allowlisted target through a sandbox funded within the tier-2 capital ceiling
- **THEN** the calls SHALL execute, priced at full notional, with no owner action taken on that target

### Requirement: Governance certification discipline
Certification SHALL be treated as a governance judgment the code cannot check: governance SHALL NOT certify proxied adapters at tier 0/1 (the codehash guard cannot see implementation swaps), and SHALL NOT certify with a loose `extractableBoundBps` — an over-generous bound slides the economics continuously back toward the tier-2 result while looking safe. Coverage sizing consumes the bound directly (`requiredCoverage = maxCapital × Σ boundBps / 10_000`, tier-2 calls contributing full notional), so the bound is the real risk parameter.

THE SANDBOX TEMPLATE IS A CLASS GRANT, AND ITS CODE IS THE REVIEWED ARTIFACT. Admitting the sandbox path is a one-time class ceremony on the sandbox template — a class allowlist entry plus a class certification for its lifecycle selectors — and SHALL NOT be read as vouching for any target a sandbox will later reach. What governance attests is that the template confines loss to funded capital, refuses privileged protocol addresses, and surrenders its balance at settlement; the targets are proposer-chosen, unreviewed by design, and priced accordingly at full notional. Governance SHALL NOT class-certify a sandbox template at tier 0 or 1, because a bound on extractable value cannot hold under proposer-supplied calldata.

#### Scenario: Loose bound distorts coverage
- **WHEN** a tier-0 certification carries a bound far above the adapter's true extractable value
- **THEN** every proposal touching it demands correspondingly inflated guardian coverage priced as if the leak were real — the certification is worse than refusing to certify

#### Scenario: Sandbox template stays at tier 2
- **WHEN** a sandbox template is class-certified
- **THEN** it SHALL carry tier 2 / full notional, never a bounded tier

#### Scenario: A class grant vouches for the template only
- **WHEN** a sandbox clone dispatches calls to an unreviewed target
- **THEN** that target SHALL gain no allowlist or certification standing from the template's class grant
