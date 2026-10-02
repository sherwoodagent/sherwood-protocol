# OpenSpec sync corrections: requirements no open change corrected

## Why

The 2026-10-02 OpenSpec sync archived every implemented change on `post-audit-v2` so `openspec/specs/` would state what the code does. Reading the result against the code found requirements that no open change touched and that were false: text written for mechanisms the branch no longer has (a governance WOOD price fallback and its rate limit, USD reservations and pro-rata allocations, a self-managed-fees exemption, an adapter allowlist, a stake-growth clamp, a `ChainlinkReader` library), numbers that moved (the agent-fee default, the buffer bound), and deploy-script facts that drifted. This change corrects them through deltas, so the specs stay derived from the change history. It is documents only.

## What Changes

- `epoch-nav`: the WOOD price, feed wiring, price-cap and haircut requirements restated as cap-only with no fallback and no on-chain rate limit (the full text lives in `guardian-coverage`); an approve vote reverts on an unpriceable asset; the coverage-epoch booking rule; the `ChainlinkReader` requirement removed.
- `dimensional-conventions`: USD producers and carriers, the WOOD lock in place of reservation/allocation, the recoverable-value ladder, dynamic Portfolio decimals, the settle-price denominator, the per-approver slash rate, the eight `BPS_DENOMINATOR` declarations, and removed nonexistent constants.
- `guardian-coverage`: the horizon reverts at vote time, the bucket scan reads `openExposure`, release works on the WOOD lock, the challenge-window and freezer-rotation checks, the proposer bond's `NoWoodPrice`, and the covered-TVL cap's zero-coverage exception.
- `guardian-staking`: the age anchor feeds only `getPastVotes`; the claim gate reads `openExposure` and pins; checkpoint pushes happen only on a non-zero slash; `initialize` bounds; the slasher role's separation is an owner obligation.
- `challenge-game`: the two live reads after filing, the conviction majority, the escrow-less settle, who can be a payee, and the `VerdictAlreadyCollected` branch.
- `syndicate-governor` and `syndicate-vault`: the lifecycle edges, the review fallbacks, Draft timing, factory creation order and vault upgradeability, the tier registry cannot be unwired, the escrowed-fee term in NAV and fee transfers, the buffer bound, the 2000-bps agent default, the Draft deposit lock and the async-deposit gate.
- `fee-splits`, `performance-fee`, `management-fee`: the per-vault ceiling is raised by the vault owner; the performance base is capped by realized profit; the high-water mark ratchets every settlement and resets after a full exit; clamping happens at propose and at settle; no proposal is exempt.
- `guardian-agent`, `guardian-fleet`: on-chain facts only — review events carry the governor, the registry's pause-adjusted clock, vote history from events, raw snapshot weights, no lookback clamp, lazy review opening.
- `tier-policy`: the registry's other owner axes, including the Morpho market-id allowlist.
- `operator-docs`: the onboarding requirement names the counterparty allowlist instead of the deleted adapter allowlist. The checklist document itself is still marked stale and does not yet meet it.
- `test-fixtures`, `supply-chain`, `deployment-docs`: test helper scope, the provenance workflow trigger, and the deploy-script facts (phase order, template refusal string, TierRegistry minting, CREATE3 hash and verification, Plan D numbering, quorum denominator, identity registry checkpoints, removed internal ticket references).

## Capabilities

### Modified Capabilities

- `epoch-nav`, `dimensional-conventions`, `guardian-coverage`, `guardian-staking`, `challenge-game`, `syndicate-governor`, `syndicate-vault`, `fee-splits`, `performance-fee`, `management-fee`, `guardian-agent`, `guardian-fleet`, `tier-policy`, `operator-docs`, `test-fixtures`, `supply-chain`, `deployment-docs`.

## Impact

`openspec/` only. No source, test, script or storage change. Purpose paragraphs cannot be changed through a delta and are not corrected here; the PR lists the stale ones.
