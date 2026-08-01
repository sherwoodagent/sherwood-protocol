# Tasks — Guardian Economic Security, Plan A: Execution-Side Safety

> Historical record; all work merged (PR #13). Implements master design §3.1–§3.2 (see design.md — the full A–F master design). Storage caution honored throughout: `StrategyProposal` fields appended at struct end only, storage-parity checked after every struct change (governors are beacon-upgraded).

## 1. TierRegistry — key derivation and default tier

- [x] 1.1 Write failing tests in new `test/TierRegistry.t.sol`: unknown selector defaults to (tier 2, 10_000 bps full notional); `key(target, selector)` is deterministic and selector-sensitive
- [x] 1.2 Implement `src/TierRegistry.sol` skeleton (Ownable2Step): `TierConfig {tier, extractableBoundBps, certifiedCodehash}`, `TIER_ARBITRARY = 2`, `FULL_NOTIONAL_BPS = 10_000`, keccak key derivation, `tierOf` reporting (2, 10_000) for uncertified or codehash-mismatched entries
- [x] 1.3 Tests pass; commit

## 2. TierRegistry — certify, demote, codehash fail-safe

- [x] 2.1 Write failing tests: certify then read back; revert `InvalidTier` for tier 2, `BoundRequired` for zero/full bound, `NotAContract` for EOA targets, owner-only; live codehash swap lazily demotes `tierOf` to tier 2; `poke` persists demotion + emits `TierDemoted` (permissionless), reverts `CodehashMatches` when hash still matches; owner `demote`
- [x] 2.2 Implement `certify` (tier 0/1 only, bound in (0, 10_000), snapshots `EXTCODEHASH` — proxied/upgradeable targets trip lazy demotion on first post-upgrade read by design), owner `demote`, permissionless `poke`, `TierCertified`/`TierDemoted` events
- [x] 2.3 Tests pass (11 total for tasks 1+2); commit

## 3. RiskEnvelope in propose() — declaration, validation, storage

- [x] 3.1 Write failing tests in `test/governor/RiskEnvelope.t.sol` (existing governor harness): envelope stored and readable via `getRiskEnvelope`; revert `ZeroMaxCapital` / `InvalidDrawdown` (> 10_000)
- [x] 3.2 Add `RiskEnvelope {maxCapital, maxDrawdownBps}` struct + errors + `getRiskEnvelope` to `ISyndicateGovernor`; add the envelope parameter to `propose`, validate after the metadata-URI check, append `maxCapital`/`maxDrawdownBps` to the END of `StrategyProposal`
- [x] 3.3 Fix every existing `propose()` call site via a shared permissive-default helper (`maxCapital: type(uint256).max, maxDrawdownBps: 10_000`) — one mechanical line each
- [x] 3.4 Full suite green; storage-parity check green (append-only); fmt; commit

## 4. Net-outflow metering in executeGovernorBatch

- [x] 4.1 Write failing tests in `test/vault/OutflowMetering.t.sol`: batch within cap executes; batch exceeding cap reverts `MaxNetOutflowExceeded(netOutflow, cap)`; inflow (settle-style) batch passes trivially even at cap 0 (no underflow)
- [x] 4.2 Add `maxNetOutflow` to the `executeGovernorBatch` signature (interface + vault); after the existing before/after balance metering, revert when `balanceBefore − balanceAfter > maxNetOutflow`
- [x] 4.3 Governor call sites: `executeProposal` passes `proposal.maxCapital`; `settleProposal` and the emergency-settle path pass `type(uint256).max`; sweep every remaining caller/mock
- [x] 4.4 Full suite green; commit

## 5. Tier resolution at propose + required coverage

- [x] 5.1 Write failing tests in `test/governor/TierResolution.t.sol`: all-certified tier-0 calls yield tier 0 and `requiredCoverage = maxCapital × boundBps / 10_000`; one uncertified call makes the proposal tier 2 with `requiredCoverage == maxCapital`; unset registry address defaults everything to tier 2 / full notional
- [x] 5.2 Create `src/interfaces/ITierRegistry.sol`; append `envelopeTier` + `requiredCoverage` to `StrategyProposal` (END, after Task 3 fields); implement `_resolveTier` (memory params so propose and execute share it; proposal tier = max tier across execute calls; coverage = full `maxCapital` at tier 2, max-bound-weighted otherwise); call it in `propose`; add `getProposalTier`/`getRequiredCoverage` views; wire `tierRegistry` into the governor the same way as `guardianRegistry` (storage + owner setter + event)
- [x] 5.3 Full suite, storage parity, fmt green; commit

## 6. Execute-time tier regression check

- [x] 6.1 Write failing tests: `executeProposal` reverts `TierRegressed` when the certified adapter's codehash changed since propose (lazy demotion); happy path unchanged when tier is stable
- [x] 6.2 Add `TierRegressed` error; in `executeProposal`, before the batch call, re-run `_resolveTier` on the loaded execute calls and revert if the live tier exceeds `proposal.envelopeTier` — fail-safe on stale certification rather than running a possibly-unbounded batch against a bounded-tier coverage price
- [x] 6.3 Full suite + fmt green; commit

## 7. Reference certification + end-to-end lifecycle test

- [x] 7.1 Review `src/adapters/UniswapSwapAdapter.sol` min-out semantics before certifying (caller-supplied min-out ⇒ tier 1 only with documented rationale — the min-out is part of the proposal calldata guardians price)
- [x] 7.2 Write `test/integration/TierEndToEnd.t.sol`: uncertified adapter → tier 2, full-notional coverage, `MaxNetOutflowExceeded` past `maxCapital`; certified adapter → reduced coverage, then `vm.etch` → `TierRegressed` at execute
- [x] 7.3 Wire `TierRegistry` deploy + governor wiring into the deploy scripts; full suite + fmt + storage parity green; commit
