## MODIFIED Requirements

### Requirement: Plan B deployment pre-flights and wiring
The Plan B phase (ExposureLedger + ProposerBondEscrow) SHALL fail its pre-flights BEFORE anything is minted, and SHALL wire in the order: deploy ledger (epoch length 28d, immutable) → deploy escrow → seed ledger params (`setWoodUsdPrice`, `setWoodHaircutBps`, `setWoodFeed`, `setAssetFeed`, `setGuardianRegistry`, `setCoveredTvlCapUsd`) → `registry.setExposureLedger` → `factory.setExposureLedger` → `factory.setBondEscrow` → `swood.setExposureLedger` → `protocolConfig.setMaxStrategyDuration`. Its numeric inputs are `RobinhoodParams` constants — `EPOCH_LENGTH`, `EXPECTED_CHALLENGE_WINDOW`, `WOOD_HAIRCUT_BPS`, `MAX_STRATEGY_DURATION`, `ASSET_FEED_MAX_DELAY`, `COVERED_TVL_CAP_USD18`, `CAP_OVER_SPOT_BPS` — committed and reviewed in the PR, never read from the environment. Checks:
- PRE-FLIGHT (pre-broadcast): `swood.maxSlashBps() == 10_000` — a guardian's declared lock may equal their entire live stake and a conviction burns that lock as bps of the stake basis, so a lower ceiling would clip the burn beneath the lock; `swood.minSlashBps() != 0` — it is the single deterrence floor under declared locks, and at zero a token lock buys a token penalty; and `COVERED_TVL_CAP_USD18 != 0` — a zero cap is fail-closed and would brick all proposing.
- Drift guard: the deployed ledger's `challengeWindow` SHALL equal the expected 14d constant.
- POST-wiring: `swood.exposureLedger()` SHALL equal the minted ledger — `claimUnstakeGuardian` fails OPEN when unset, so an unwired pointer silently lets guardians walk out from under pending challenges.
- WIRING refusal: each pointer slot this phase writes (`StakedWood.exposureLedger`, `GuardianRegistry.exposureLedger`, `SyndicateFactory.exposureLedger`, `SyndicateFactory.bondEscrow`, `ExposureLedger.guardianRegistry`) SHALL be free or already hold the address this run will mint. A slot naming a FOREIGN address is refused — the ceremony never repoints a live slot. Because CREATE3 makes the addresses knowable before the mint, the refusal lands before anything is deployed for the four sWOOD, registry and factory slots; `ExposureLedger.guardianRegistry` is checked on the minted (or adopted) ledger.
- `ASSET_FEED_MAX_DELAY` SHALL be sized above the aggregator's publication heartbeat (24h on 4663), because it bounds that aggregator's own `updatedAt` age on every `coverageUsd` read; a bound at or below the heartbeat makes every covered proposal revert `StalePrice`.
- The obsolete cooldown pre-flight (`coolDownPeriod >= epochLength + challengeWindow`) is REMOVED — unsatisfiable (cooldown caps at 30d) and superseded by the exact exit gate on `claimUnstakeGuardian`.
- PRE-FLIGHT 8 (STAGE GATE): the WOOD feed SHALL answer `latestRoundData()` with a positive price BEFORE any Plan B contract is minted. On Mainnet a feed that does not yet answer is not a failure but a CHECKPOINT: `deployAll` returns `Checkpoint.AwaitingWoodFeed` and the operator re-runs after the keeper has primed it. Post-broadcast the phase additionally requires `ledger.woodUsdPriceX8() != 0` AND the composed `ledger.woodPriceX8()` to resolve non-zero. These are two independent failures with different remedies. The first is the price CAP being unset, which under the cap-only model is a revert (`NoWoodPrice`) rather than "uncapped" — reading zero as "no ceiling" would make the likeliest misconfiguration the one state in which a ~$438k pool prices every guardian bond without bound. The second is a CAP configured with nothing priced beneath it, which a cap-only check misses entirely. `woodPriceX8()` SHALL be read by low-level probe rather than a typed call, because it reverts instead of returning zero when unpriceable, and a bare revert would surface as an opaque script failure with no instruction attached.
- No WOOD price is committed. BOTH postures SHALL DERIVE the cap at deploy time as `spot * CAP_OVER_SPOT_BPS / 10_000` from the live WOOD/WETH pair and the ETH/USD feed, and the ceremony SHALL still refuse a cap outside `[1.25x, 2x]` of that same spot — below 1.25x the cap binds permanently and pins every bond, above 2x it stops bounding manipulation. The cap is a ceiling on manipulation, never served as a price, and sits ABOVE market; the old "≤ 30-day low" instruction is exactly backwards. Deriving is what keeps the two postures on one code path and stops a measured constant from drifting out of its own band between the PR and the run.
- The market source is `src/pricing/WoodPoolFeed.sol`, minted by the ceremony itself and wired through `ledger.setWoodFeed(feed, maxDelay)` with `maxDelay = window + 2h + 1` (`RobinhoodParams.WOOD_FEED_MAX_DELAY`): `updatedAt` rolls at most once per window, so the bound must clear a window plus the keeper cadence. There is no separate TWAP-oracle contract and no unwired-market-source configuration — a ledger with no live WOOD price source never gets minted, because the stage gate runs first.
- PRE-FLIGHT 12 (pre-mint): the WOOD feed and its `maxDelay` SHALL be set together, a set feed SHALL hold code, and `maxDelay` SHALL exceed the feed's `window` plus the 2h keeper allowance. `setWoodFeed` already enforces the pairing, but only once the ledger and escrow exist and several setters have run; checking before the mint turns a half-applied run into a free refusal.

#### Scenario: Unset price cap refused post-broadcast
- **WHEN** the Plan B phase completes its writes with `woodUsdPriceX8` still zero
- **THEN** the run FAILS naming the cap, because a zero cap reverts every price read and nothing can be proposed, executed or challenged

#### Scenario: Cap outside the band refused pre-broadcast
- **WHEN** `CAP_OVER_SPOT_BPS` is edited so the derived cap sits below 1.25x or above 2x the spot derived from the live WOOD/WETH pair and the ETH/USD feed
- **THEN** the Mainnet run refuses before broadcasting, naming which side of the band was breached

#### Scenario: Fork posture seats a cap in the same band
- **WHEN** a Fork-posture ceremony mints its WOOD feed fixture
- **THEN** the cap it seeds in the ledger is derived from that fork's own spot and satisfies the same `[1.25x, 2x]` bound, exactly as the Mainnet posture derives its own

#### Scenario: Feed deployed but not yet primed
- **GIVEN** `WoodPoolFeed` is minted but has not completed a `window` of keeper updates
- **THEN** the run returns `Checkpoint.AwaitingWoodFeed`: no ledger, no escrow, no handoff, and the operator's instruction is to run `update()` and re-run the same command

#### Scenario: Foreign pointer slot refused before the mint
- **WHEN** `StakedWood.exposureLedger` already names a ledger other than the one this run would mint
- **THEN** the run reverts "WIRING: StakedWood.exposureLedger already names a foreign address …", having deployed nothing

#### Scenario: Wrong slash ceiling refused pre-deploy
- **WHEN** the Plan B phase runs against an sWOOD with `maxSlashBps < 10_000`
- **THEN** the script reverts its PRE-FLIGHT before deploying the ledger

#### Scenario: Zero deterrence floor refused pre-deploy
- **WHEN** the Plan B phase runs against an sWOOD with `minSlashBps == 0`
- **THEN** the script reverts its PRE-FLIGHT before deploying the ledger, naming `minSlashBps` as the deterrence floor that must be set by governance

#### Scenario: Unwired unstake gate refused post-wiring
- **WHEN** the writes complete but sWOOD's `exposureLedger` pointer does not name the minted ledger
- **THEN** the script reverts, stating that the broadcast should have wired it and that the run must be repeated from the sWOOD owner
