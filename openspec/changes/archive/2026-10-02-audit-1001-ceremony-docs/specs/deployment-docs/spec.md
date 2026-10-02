# deployment-docs (delta)

## ADDED Requirements

### Requirement: Syndicate creation is closed until the end of Mainnet run 2
A governor minted before the Plan B phase has wired the factory carries no exposure ledger and no bond escrow, and nothing in the ceremony can reliably wire it afterwards: `pushWiring` reverts while the governor has an open proposal, and a gap-vault owner can keep one open indefinitely. On Mainnet posture the factory SHALL therefore be initialised with a closed agent-registry sentinel, `RobinhoodParams.AGENT_REGISTRY_CLOSED`: a non-zero, codeless address (zero would turn identity gating off). `createSyndicate` calls `ownerOf` on it and reverts for every caller, sponsored or not, from the factory's own initialisation transaction onward — through all of run 1 and the gap. As the last step of run 2 before the handoff, while the deployer still owns the factory and only while the registry still equals the sentinel, the ceremony SHALL require `syndicateCount() == 0` and call `setAgentRegistry(RobinhoodParams.AGENT_REGISTRY)`. The pre-flight SHALL refuse a sentinel that holds code. The `AwaitingWoodFeed` validation SHALL require the sentinel and `syndicateCount() == 0`; the `Complete` validation the real registry. Fork posture is unchanged: one run, the real registry from initialisation. `script/verify-robinhood.sh` SHALL still check, read-only, that every live governor's ledger, escrow and tier registry equal the factory's.

#### Scenario: No vault can be created from the factory's initialisation
- **GIVEN** `deployCore` has just initialised the Mainnet factory
- **WHEN** an outsider with a prepared owner stake and an agent identity calls `createSyndicate`
- **THEN** the call reverts and `syndicateCount()` stays zero

#### Scenario: Sponsorship does not open the gap
- **GIVEN** run 1 has completed at `AwaitingWoodFeed` and the deployer has sponsored a creator
- **WHEN** that creator calls `createSyndicate`
- **THEN** the call reverts

#### Scenario: Run 2 opens creation and every vault is wired at creation
- **WHEN** run 2 completes
- **THEN** the factory's registry is the ERC-8004 registry, creation costs the invite-only fee, a new syndicate's governor has the factory's `exposureLedger` and `bondEscrow` from creation, and a full-capital proposal with no approvals reverts `InsufficientApproveCoverage` at execute

#### Scenario: Validation refuses an open registry or a syndicate between the runs
- **WHEN** `_validateAll` runs at `AwaitingWoodFeed` and the registry is not the sentinel, or a syndicate exists
- **THEN** it reverts naming the registry or the syndicate count

### Requirement: The ETH/USD staleness bound exceeds the feed heartbeat
`RobinhoodParams.ETH_USD_MAX_AGE` SHALL be strictly greater than the 4663 ETH/USD feed's 24h heartbeat (`ETH_USD_HEARTBEAT`); the shipped value is 26 hours, the same 2h allowance as `ASSET_FEED_MAX_DELAY`. At exactly the heartbeat a round published one second late makes `WoodPoolFeed` revert, which halts propose, approve, execute and `ChallengeGame.file` protocol-wide. The WOOD feed phase's pre-flight SHALL refuse a bound at or below the heartbeat before anything is minted.

#### Scenario: A late heartbeat round still prices
- **WHEN** the ETH/USD answer is 24 hours and one second old
- **THEN** `WoodPoolFeed.latestRoundData` answers and every priced entry point lands

#### Scenario: A bound at the heartbeat is refused
- **WHEN** the feed phase is run with `ethUsdMaxAge` equal to 24 hours
- **THEN** the pre-flight reverts before the feed is minted

## MODIFIED Requirements

### Requirement: Rate limiting is enforced off-chain, and the contract imposes none
`ExposureLedger.setWoodUsdPrice` and `setWoodHaircutBps` SHALL impose no rate limit and no per-call size ceiling. The owner may move either lever to any legal value, any number of times, within one block. **Rate limiting is enforced OFF-CHAIN by a Zodiac Delay/Roles module on the owner Safe** (owner decision 2026-08-02).

This is a TRUST-MODEL CHANGE and SHALL be documented as one in both the setter natspec and this runbook. An auditor reading `ExposureLedger` previously saw a self-limiting owner; they now see an unrestricted one, with the control living in a Safe configuration that is invisible from the source. Undocumented, the next reviewer either files it as a finding or — worse — assumes a protection that was moved.

**What was removed, and why both together.** A 1-day `MIN_PRICE_UPDATE_INTERVAL` on both setters, and a `newPriceX8 <= current * 2` ceiling on cap raises. The interval was the only thing that made the ceiling a rate limit at all — N calls in one multisig batch move the price 2ᴺ — so the ceiling could not be kept alone without advertising a protection that the exact party it constrains can bypass in a single batch. The storage that backed the interval (`lastPriceUpdateAt`, `lastHaircutUpdateAt`) was deleted; this is safe because `ExposureLedger` is not upgradeable and is not among the layouts `check-layout-goldens.sh` pins.

**Why moved rather than fixed.** The interval gated BOTH directions while the size ceiling gated only raises, so the code limited a move's *size* by direction but its *timing* regardless. After design revision 2 lowering the cap IS the emergency action, so the limit sat directly on crisis response: whoever touched the lever first spent it, urgency-blind, and a routine morning adjustment left no brake that afternoon. A self-limit on an already-trusted owner bought little and cost exactly the responsiveness it most needed to preserve.

**THE PROPERTY THE ZODIAC CONFIGURATION MUST PRESERVE — the delay SHALL be ASYMMETRIC: raises delayed, drops immediate.** A plain Zodiac Delay module is symmetric and would delay the emergency lowering too, relocating the bug rather than fixing it — possibly with a longer delay than the one removed. A Roles modifier can scope by selector and by static parameter conditions but **cannot compare an argument against current on-chain state**, so it cannot express "allow if lower than the stored value". The practical shape is therefore a **fast path for arguments below a fixed threshold** set comfortably beneath any plausible cap, with everything above it routed through the Delay module. **If the configuration cannot preserve the asymmetry, the in-contract limit SHALL NOT have been removed** — restore the direction-scoped interval instead.

**It must actually be deployed.** A documented off-chain control that nobody configured is worse than an on-chain one, because the source no longer carries a trace of the requirement. Pre-flight 10 has MOVED out of the Plan B phase and into the ceremony's post-handoff validation, because the ledger owner is the deployer until the handoff runs and only afterwards is the Safe the answer: on Mainnet posture, `ExposureLedger.pendingOwner()` SHALL be `OWNER_MULTISIG` and that address SHALL hold code. On Fork posture it is SKIPPED — the owner is the deployer, an EOA, and there is no Safe — which retires `ALLOW_EOA_LEDGER_OWNER`: the waiver is now a property of posture rather than an env key an operator could set on mainnet. `script/verify-robinhood.sh` accepts the Safe as either owner or pending owner on Mainnet, so acceptance itself SHALL be confirmed by reading `owner()` after the Safe has called `acceptOwnership()`. This is the most an on-chain check can establish. It deliberately does not probe for modules: enumerating a Safe's modules would prove only that *some* module is attached, not that the delay is asymmetric, and a probe that appears to verify the requirement while verifying something weaker is worse than none. **The asymmetry is a runbook obligation, verified by a human before launch.** The Zodiac configuration is a prerequisite for LAUNCH, not for merge; until it exists the protocol has neither the on-chain limit nor the off-chain one.

#### Scenario: Auditor reads the price setters
- **WHEN** a reviewer reads `setWoodUsdPrice` and finds no interval and no size ceiling
- **THEN** the natspec states plainly that rate limiting is enforced off-chain by a Zodiac module and that this contract deliberately imposes none, so the absence reads as a documented decision rather than a missing control

#### Scenario: EOA owner refused at deploy
- **WHEN** a Mainnet run is started with `OWNER_MULTISIG` naming an externally-owned account
- **THEN** the pre-broadcast pre-flight reverts "OWNER_MULTISIG must be a contract (Safe), not an EOA", and the post-handoff validation repeats the same check, because the protocol would otherwise carry neither the on-chain limit nor the off-chain one

#### Scenario: Fork posture skips the owner check
- **GIVEN** a Tenderly vnet, whose deployer is an impersonated EOA and where no Safe exists
- **THEN** pre-flight 10 does not run at all, because a fork hands off to its own deployer and there is no Safe to check — the waiver is derived from posture rather than set by an operator, so no key exists that could waive it on mainnet

#### Scenario: Symmetric delay module configured
- **GIVEN** the Safe carries a plain Zodiac Delay module applying the same delay to every call
- **THEN** the configuration is REJECTED at review: the emergency lowering is delayed exactly as the removed interval delayed it, which relocates the problem instead of solving it

#### Scenario: Crash requires two cap reductions in one day
- **WHEN** WOOD drops 40% in the morning and a further 50% that afternoon
- **THEN** both reductions land — the on-chain interval that previously locked the lever until the next day is gone, and the Safe's fast path passes low arguments straight through

#### Scenario: ETH drawdown inside the feed heartbeat
- **GIVEN** ETH falls sharply while the ETH/USD answer is several hours old
- **THEN** WOOD/USD reads high by roughly the ETH move until the feed ticks, bonds are over-valued for that period, and the exposure is bounded above by the cap and below by the haircut — an accepted risk, documented, not a defect to file

#### Scenario: Short averaging window with a slow USD feed
- **WHEN** the feed's averaging `window` is at its 24-hour minimum while `ethUsdMaxAge` is 26 hours (the 24h ETH/USD heartbeat plus a 2h allowance)
- **THEN** the configuration is ACCEPTED — the two bounds are independent by design, and the window is not lengthened to match the USD feed's staleness
