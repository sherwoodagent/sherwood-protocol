## MODIFIED Requirements

### Requirement: Plan B deployment pre-flights and wiring
`DeployPlanB` (ExposureLedger + ProposerBondEscrow against an existing Plan A deployment) SHALL fail its pre-flights BEFORE anything is deployed, and SHALL wire in the order: deploy ledger (epoch length 28d, immutable) → deploy escrow → seed ledger params (`setWoodUsdPrice`, `setWoodTwapOracle`, `setAssetFeed`, `setGuardianRegistry`, `setCoveredTvlCapUsd`) → `registry.setExposureLedger` → `factory.setExposureLedger` / `setBondEscrow`. Checks:
- PRE-FLIGHT (pre-broadcast): `swood.maxSlashBps() == 10_000` — a guardian's lock may equal their entire live stake, and the slash for a conviction is that lock expressed as bps of live stake; a ceiling below 100% would cap the burn beneath the lock and make recovery a strict shortfall by construction. The adversary is a deployment that quietly under-collateralises every fully-locked guardian. Also `COVERED_TVL_CAP_USD18 != 0` — a zero cap is fail-closed and would brick all proposing.
- Drift guard: the deployed ledger's `challengeWindow` SHALL equal the script's expected 14d constant.
- POST-wiring: `swood.exposureLedger() != address(0)` — `claimUnstakeGuardian` fails OPEN when unset, so an unwired pointer silently lets guardians walk out from under pending challenges; and `ledger.quorumTierThreshold() == 0` — coverage enforcement runs at every tier (ADR 2026-07-27 decision 2; the paired `maxEnvelopeTier <= 1` ceiling was dropped 2026-07-31, so there is no ceiling to assert).
- `ASSET_FEED_MAX_DELAY` SHALL be sized against the governor's actual `votingPeriod + reviewPeriod + executionWindow` lifecycle (the approve quorum re-reads the feed at execute time), not a habitual `1 days`.
- The obsolete cooldown pre-flight (`coolDownPeriod >= epochLength + challengeWindow`) is REMOVED — unsatisfiable (cooldown caps at 30d) and superseded by the exact exit gate on `claimUnstakeGuardian`.
- PRE-FLIGHT 8 (POST-broadcast, design revision 2): `ledger.woodUsdPriceX8() != 0` AND the composed `ledger.woodPriceX8()` SHALL resolve to a non-zero price. These are two independent failures with different remedies. The first is the price CAP being unset, which under the cap-only model is a revert (`NoWoodPrice`) rather than "uncapped" — reading zero as "no ceiling" would make the likeliest misconfiguration the one state in which a ~$438k pool prices every guardian bond without bound. The second is a CAP configured with nothing priced beneath it, which a cap-only check misses entirely. `woodPriceX8()` SHALL be read by low-level probe rather than a typed call, because it now reverts instead of returning zero when unpriceable, and a bare revert would surface as an opaque script failure with no instruction attached.
- The env key is `WOOD_PRICE_CAP_X8`, RENAMED from `WOOD_PRICE_HAIRCUT_X8` because the number's meaning inverted: it is a ceiling on manipulation, never served as a price, and SHALL be seeded **ABOVE** market — 1.25–2× is the intended band, reviewed monthly. The old "≤ 30-day low" instruction is now exactly backwards: a cap below market binds permanently, pins every bond at the cap and makes the market source inert.
- `WOOD_TWAP_ORACLE` SHALL name a `WoodTwapOracle` that ALREADY HAS A COMPLETED AVERAGING WINDOW. The oracle needs at least `twapWindow` of keeper activity before `consult()` answers, so the ceremony ordering is: deploy the oracle → run the keeper → run Plan B. Pre-flight 8 enforces this rather than merely documenting it.
- `WOOD_USD_FEED` and `WOOD_FEED_MAX_DELAY` are the SECOND way to satisfy pre-flight 8: an optional Chainlink-shaped WOOD/USD aggregator, wired inside the broadcast via `ledger.setWoodFeed`. Set, it becomes the PREFERRED market source and the TWAP oracle stays the fallback on all four degraded shapes; unset, the ledger is TWAP-only and the mainnet ceremony is unchanged. Chain 4663 publishes no such aggregator, so the mainnet ceremony leaves both keys unset. THE FORK SETS THEM AND MUST — a vnet cannot prime a TWAP oracle at all, so a feed is the only source that can produce a composed price there.
- PRE-FLIGHT 12 (pre-broadcast): `WOOD_USD_FEED` and `WOOD_FEED_MAX_DELAY` SHALL be set together or not at all, and a named feed SHALL hold code. `setWoodFeed` already enforces the pairing, but from inside the broadcast after the ledger and escrow exist and four setters have run; checking pre-broadcast turns a half-applied run into a free refusal.
- PRE-FLIGHT (pre-broadcast): `swood.minSlashBps()` SHALL be non-zero. Under declared locks it is the single deterrence floor — the least any convicted approver loses, as a fraction of everything they hold, whatever they declared — and a zero floor would let a guardian declare a token lock and face a token penalty. The launch value is a governance decision recorded in the runbook, not a code default; the pre-flight only refuses zero.

#### Scenario: Unset price cap refused post-broadcast
- **WHEN** `DeployPlanB` completes its broadcast with `woodUsdPriceX8` still zero
- **THEN** the run FAILS naming the cap, because a zero cap reverts every price read and nothing can be proposed, executed or challenged

#### Scenario: Cap set but nothing priced under it
- **GIVEN** `WOOD_PRICE_CAP_X8` is non-zero but no TWAP oracle is wired (and chain 4663 has no Chainlink WOOD/USD feed)
- **WHEN** the post-broadcast pre-flights run
- **THEN** the run FAILS on the composed price — proving the cap-only assert would have passed a dead deployment

#### Scenario: Oracle wired but not yet primed
- **GIVEN** the TWAP oracle is wired but has no completed averaging window
- **THEN** pre-flight 8 FAILS, directing the operator to run the keeper for at least `twapWindow` before re-running

#### Scenario: Half-edited feed environment refused pre-broadcast
- **WHEN** `WOOD_USD_FEED` is set with `WOOD_FEED_MAX_DELAY` left at zero, or the delay is set with no feed
- **THEN** pre-flight 12 refuses the run BEFORE the ledger and escrow are deployed, rather than letting `setWoodFeed` revert four setters into the broadcast

#### Scenario: Feed is the preferred source when both are wired
- **GIVEN** both `WOOD_TWAP_ORACLE` and `WOOD_USD_FEED` are set
- **THEN** `woodPriceDetail()` reports `fromFeed == true` and the oracle remains wired as the fallback

#### Scenario: Fork prices off the feed alone
- **GIVEN** no TWAP oracle is wired, because a vnet cannot prime one
- **WHEN** `WOOD_USD_FEED` names the fixture feed
- **THEN** pre-flight 8 PASSES on the feed alone and `woodPriceDetail()` reports `fromFeed == true`

#### Scenario: Wrong slash ceiling refused pre-deploy
- **WHEN** `DeployPlanB` runs against an sWOOD with `maxSlashBps < 10_000`
- **THEN** the script reverts its PRE-FLIGHT before deploying the ledger, because a fully-locked guardian could not be burned for their whole lock

#### Scenario: Zero deterrence floor refused pre-deploy
- **WHEN** `DeployPlanB` runs against an sWOOD with `minSlashBps == 0`
- **THEN** the script reverts its PRE-FLIGHT before deploying the ledger, naming `minSlashBps` as the deterrence floor that must be set by governance

#### Scenario: Unwired unstake gate refused post-wiring
- **WHEN** the broadcast completes but sWOOD's `exposureLedger` pointer is still zero
- **THEN** the script reverts, directing the operator to call `setExposureLedger(ledger)` by governance and re-run
