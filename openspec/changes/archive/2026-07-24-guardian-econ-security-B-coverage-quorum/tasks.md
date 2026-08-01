# Tasks — Guardian Economic Security Plan B

## 1. ExposureLedger — skeleton, WOOD price, slashableBondUsd

- [x] 1.1 Write failing tests: `slashableBondUsd` (own + capped delegated at $0.05 haircut), fail-closed zero on unset price, owner-only price setter, epoch advancement
- [x] 1.2 Write `IExposureLedger` (full interface up front — errors, events, registry mutations, governor checks, views, owner setters)
- [x] 1.3 Implement `ExposureLedger` skeleton: Ownable2Step, immutable sWOOD/epochLength/genesis, `priceHaircut` setter, `slashableBondUsd`, bounded param setters (challenge window checked against sWOOD cooldown), reverting stubs for later tasks
- [x] 1.4 Run `ExposureLedgerTest` green; commit

## 2. ExposureLedger — asset→USD conversion via Chainlink feeds

- [x] 2.1 Write failing tests: 6-dec and 18-dec assets, unconfigured feed reverts `FeedNotConfigured`, stale feed reverts `StalePrice`
- [x] 2.2 Implement `setAssetFeed` (caches asset/feed decimals) and `coverageUsd` (fail-closed on non-positive answer or age > maxDelay; no sequencer branch — no uptime feed on Robinhood)
- [x] 2.3 Run suite green; commit

## 3. ExposureLedger — epoch-bucketed exposure recording + aggregate cap

- [x] 3.1 Write failing tests: registry-only, exposure booked, cap-exceeded revert, budget recycles across epoch + challenge window, simultaneous over-exposure (batching attack) blocked, release frees exact amount, release idempotent, conservation fuzz
- [x] 3.2 Implement `recordApproval` / `releaseApproval` / `openExposureUsd`: per-`(reviewKey, guardian)` recorded exposure, per-epoch buckets, exact-expiry lookback, cap check `open + new <= k * slashableBondUsd`
- [x] 3.3 Run suite green including fuzz; commit

## 4. ExposureLedger — covered-TVL cap check + approve-quorum check

- [x] 4.1 Write failing tests: cap enforced, zero cap fails closed, quorum passes when summed approver bonds cover coverage, zero approvers fails closed (cold start)
- [x] 4.2 Implement `requireWithinCoveredTvlCap` and `requireApproveQuorum` (live bond reads, early exit, zero-approver revert)
- [x] 4.3 Run suite green; commit

## 5. ProposerBondEscrow

- [x] 5.1 Write failing tests: lock pulls WOOD and records, unauthorized governor reverts, duplicate lock reverts, release returns to proposer, governor-only + once-only release, balance-conservation fuzz
- [x] 5.2 Implement ownerless escrow: bond key `keccak256(governor, proposalId)`, `lockBond`/`releaseBond` gated on `registry.isAuthorizedGovernor(msg.sender)`, no forfeit path in v1a
- [x] 5.3 Run suite green; commit

## 6. TierRegistry — adapter-submitter bond

- [x] 6.1 Write failing tests: certify pulls bond, zero-bond config preserves Plan A path, demote starts release timelock and claim succeeds only after delay, re-certify while pending release reverts
- [x] 6.2 Update every existing `certify` call site in test/ and script/ for the new arity (append `address(0)` no-bond form)
- [x] 6.3 Implement: `wood`/`submitterBondWood`/`bondReleaseDelay` config, bond pull in `certify` (any existing bond blocks re-certification), timelock start in `_demote`, `claimSubmitterBond`
- [x] 6.4 Run TierRegistry/SelectorGuard/TierResolution/TierEndToEnd suites green; commit

## 7. GuardianRegistry upgrade — exposure hooks on approve votes

- [x] 7.1 Write failing tests against real ledger + real `voteOnProposal`: approve records, block records nothing, Approve→Block releases, over-cap approve reverts, unwired registry unaffected
- [x] 7.2 Implement: `exposureLedger` slot (gap 50→49), owner `setExposureLedger`, `recordApproval` hook in first-vote Approve branch and `release`/`record` in vote-change branch (after state write, before emit; unset ledger skips hooks; ledger revert reverts the vote)
- [x] 7.3 Run new + pre-existing GuardianRegistry suites green; commit

## 8. Governor — covered-TVL cap + proposer bond at propose

- [x] 8.1 Write failing tests: over-cap propose reverts, risk-scaled bond locked and recorded on the proposal, insufficient WOOD allowance reverts, unwired governor skips gates
- [x] 8.2 Implement ledger-side `proposerBondWood(asset, requiredCoverage)` (fail-closed on unset price)
- [x] 8.3 Implement governor: `_exposureLedger`/`_bondEscrow` slots (gap 33→31), factory-gated setters, `StrategyProposal` appends `proposerBondWood` + `proposerBondEscrow`, gates in `_snapshotTier` with CEI ordering (`collaborationDeadline` hoisted before `lockBond`; stack-budget hoist fallback noted)
- [x] 8.4 Run new + Plan A suites green; commit

## 9. Governor — approve quorum at execute + bond reclaim on terminal states

- [x] 9.1 Write failing tests: tier-2 zero-approvers execute reverts, covered approvers execute succeeds, tier below threshold skips quorum (optimistic lane intact), reclaim after settle (idempotent), reclaim on active proposal reverts, reclaim after expiry
- [x] 9.2 Implement quorum check in `executeProposal` after the `CoverageRegressed` check, gated on `envelopeTier >= quorumTierThreshold`
- [x] 9.3 Implement permissionless `reclaimProposerBond`: terminal-state check, zero-bond guard, effects-before-interaction, release against the stored per-proposal escrow
- [x] 9.4 Run suite green; commit

## 10. Factory — wire ledger + escrow into new and existing governors

- [x] 10.1 Write failing tests: createSyndicate pushes both, unset leaves unwired, `pushWiring` rewires an existing governor, foreign governor reverts, owner-only
- [x] 10.2 Implement `exposureLedger`/`bondEscrow` slots + setters (cloning the tierRegistry idiom), pushes in `createSyndicate`, and owner-only `pushWiring` gated on factory governor bookkeeping (closes LOW-1 / issue #19)
- [x] 10.3 Run factory suites green; commit

## 11. Storage-layout goldens + full-suite regression

- [x] 11.1 Run layout pins, manually verify the diff is append-only for every pre-existing slot (stop and surface otherwise)
- [x] 11.2 Regenerate governor + factory goldens; run full `forge test` with zero new failures; commit

## 12. Deploy script + parameter seeding

- [x] 12.1 Write `script/DeployPlanB.s.sol`: deploy ledger (28d epoch) + escrow, seed price/feed/caps/registry link, wire registry and factory; sWOOD `coolDownPeriod >= 42d` pre-flight assertion; manual follow-ups (upgrades, per-governor `pushWiring`, TierRegistry redeploy) printed
- [x] 12.2 Dry-run against the Tenderly fork (simulation only; cooldown raise surfaced as a governance action, not performed); commit

## 13. End-to-end lifecycle + adversarial tests

- [x] 13.1 Full lifecycle round-trip: propose → approve → execute → settle → bond reclaim → exposure budget recycles after epoch + challenge window
- [x] 13.2 Batching attack: second simultaneous approve reverts `ExposureCapExceeded` across two governors
- [x] 13.3 Thin cohort cannot force execution: zero approvers ⇒ execute reverts ⇒ expiry ⇒ bond reclaimable (cold start)
- [x] 13.4 WOOD price crash between approve and execute blocks execution (live quorum read)
- [x] 13.5 Bounded-tier flow unaffected: tier-1 target executes with zero approvers
- [x] 13.6 Run `CoverageEndToEnd` green; commit

## 14. Format, full suite, docs, PR

- [x] 14.1 `forge fmt` with the CI-matching forge; full `forge test` with zero non-fork failures
- [x] 14.2 Update the master spec's status header: v1a complete (Plans A+B), v1b next
- [x] 14.3 Push and open PR stating scope, deliberate exclusions, both launch gates, and the invariant + fuzz table
