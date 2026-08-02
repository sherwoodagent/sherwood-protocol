// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {ISyndicateFactory} from "../src/interfaces/ISyndicateFactory.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";

interface ISwoodCooldown {
    function coolDownPeriod() external view returns (uint256);
    function maxSlashBps() external view returns (uint256);
    function exposureLedger() external view returns (address);
    /// @dev `onlyOwner` on sWOOD. This script CALLS it (see the wiring block)
    ///      rather than only asserting it: the ledger the pointer has to name
    ///      does not exist until this script has already deployed it, so
    ///      "go set it first, then re-run" is not an instruction an operator
    ///      can follow on a first deploy.
    function setExposureLedger(address ledger) external;
    /// @dev Read PRE-broadcast, to prove the broadcaster can actually make the
    ///      `setExposureLedger` call below instead of discovering it cannot
    ///      halfway through the broadcast, with two contracts already deployed.
    function owner() external view returns (address);
}

/// @dev The admin surface of `ProtocolConfig` this script needs. Declared here
///      rather than taken from `IProtocolConfig` because that interface is the
///      READ side — what `GovernorParameters` consumes — and deliberately
///      carries no setters. Same local-interface idiom as `ISwoodCooldown`.
interface IProtocolConfigAdmin {
    function maxStrategyDuration() external view returns (uint256);
    /// @dev `onlyOwner`. CALLED inside the broadcast (pre-flight 6): a ceiling
    ///      an operator is merely TOLD to set afterwards is a ceiling that ships
    ///      unset, which is exactly the state this pre-flight exists to end.
    function setMaxStrategyDuration(uint256 newValue) external;
    /// @dev Read PRE-broadcast, same reason as `ISwoodCooldown.owner`.
    function owner() external view returns (address);
}

/**
 * @title  DeployPlanB
 * @notice Plan B deployment against an EXISTING Plan A deployment. Address
 *         book via env vars (from chains/<chainid>.json). Order:
 *           1. pre-flights (see below) — fail BEFORE anything is deployed
 *           2. deploy ExposureLedger (epochLength 28d) + ProposerBondEscrow
 *           3. seed ledger params (WOOD price cap, TWAP oracle, asset feed, caps, registry link)
 *           4. registry.setExposureLedger   (owner op — REQUIRES the UUPS-upgraded impl)
 *           5. factory.setExposureLedger / setBondEscrow (new syndicates)
 *           6. swood.setExposureLedger      (owner op — arms the unstake gate)
 *         MANUAL follow-ups printed at the end (UUPS upgrade, TierRegistry
 *         redeploy + recertify, and — CONDITIONAL ON THE CHAIN, see pre-flight
 *         5 — either a governor beacon upgrade or pushWiring per governor).
 *
 * @dev PRE-FLIGHT 1 was REMOVED (ADR 2026-07-26) — it demanded a 42d sWOOD
 *      cooldown that `setCooldownPeriod`'s own 30d cap made unreachable, so its
 *      printed remedy was not an action any operator could take. Pre-flight 3
 *      replaces it and is strictly stronger. Kept named here so the numbering
 *      below is not read as a gap; see the body for the full argument.
 * @dev PRE-FLIGHT 1b (review N9): `maxSlashBps == 10_000`. The ledger books at
 *      100% of allocation, so any lower ceiling makes recovery a strict
 *      shortfall against it.
 * @dev PRE-FLIGHT 4 (ADR 2026-07-27): `quorumTierThreshold == 0` — a covering
 *      approve quorum is required at EVERY tier. The `maxEnvelopeTier <= 1`
 *      half this was once paired with was dropped (owner decision 2026-07-31);
 *      see the block itself.
 * @dev PRE-FLIGHT 2: a zero `coveredTvlCapUsd` is fail-closed — the moment the
 *      ledger is wired into a governor, NOTHING can be proposed. Refuse to
 *      deploy into that state rather than brick proposing.
 * @dev PRE-FLIGHT 5 (review M5): a factory with LIVE governor proxies whose
 *      beacon impl predates Plan B is refused. Plan B cannot be wired into
 *      those governors, and the beacon upgrade that would make it possible is
 *      forbidden on this stack — `SyndicateGovernor`'s layout was re-baselined
 *      non-append-only, so an impl swap on a populated beacon corrupts every
 *      proxy. See the block itself; it also shapes the manual follow-ups.
 * @dev PRE-FLIGHT 6 (issue #32, ADR 2026-07-26): `ProtocolConfig.maxStrategyDuration`
 *      is SEATED by this script, not merely checked. It ships 0 = no ceiling, and
 *      a vault owner may then bind guardians for up to `ABSOLUTE_MAX_STRATEGY_DURATION`
 *      (3,650 days) per approval. The ADR defers the VALUE to the multisig but not
 *      the invariant; seating it here is what makes the deferral safe.
 * @dev PRE-FLIGHT 7 (issue #32): `delegationEnabled == false`. Delegation is
 *      deferred to v2, and the delegator-walkout hole stays dormant only while it
 *      is off. See the block itself.
 * @dev PRE-FLIGHT 8 (design revision 2, 2026-08-02): POST-broadcast, the WOOD
 *      price CAP must be non-zero AND the composed `woodPriceX8()` must resolve
 *      to a non-zero price. The cap is no longer a fallback price — it only
 *      caps a market source — so a deployment with the cap unset, or with no
 *      live market source under it, reverts `NoWoodPrice` on every price read
 *      and cannot propose, execute or be challenged. See the block itself.
 * @dev PRE-FLIGHT 3 (review B3): the three ledger pointers — registry, factory
 *      and sWOOD — must all name THE LEDGER THIS RUN DEPLOYED. sWOOD's is wired
 *      inside the broadcast rather than demanded of the operator beforehand,
 *      because the ledger does not exist until step 2. See the block itself.
 *
 *      Ownership: the broadcaster becomes the ledger owner and must ALREADY own
 *      the GuardianRegistry, the SyndicateFactory and StakedWood (all three
 *      setters are onlyOwner; `Deploy.s.sol` hands all three to the same owner
 *      multisig). On mainnet that means running this from the owner multisig, or
 *      running it with the deployer as owner and handing off afterwards.
 *      Pre-flight 2b checks the sWOOD half of that up front. Pre-flight 6b does
 *      the same for the ProtocolConfig, which this script also writes to.
 *
 *   Environment:
 *     STAKED_WOOD               — sWOOD (cooldown pre-flight + bond reads).
 *     SYNDICATE_FACTORY         — factory to wire (new syndicates).
 *     GUARDIAN_REGISTRY         — registry to wire (approve-side exposure recording).
 *     WOOD_TOKEN                — bond collateral held by the escrow.
 *     USDG                      — vault asset to register a feed for.
 *     CHAINLINK_USDG_USD_FEED   — that asset's Chainlink USD feed.
 *     ASSET_FEED_MAX_DELAY      — feed staleness bound, seconds (see setAssetFeed below).
 *     WOOD_PRICE_CAP_X8         — WOOD/USD price CAP, 8-dec. SEED IT ABOVE MARKET.
 *                                 Renamed from WOOD_PRICE_HAIRCUT_X8, whose
 *                                 "<= 30-day low" instruction is now exactly
 *                                 backwards: this number is never served as a
 *                                 price, it only bounds how far a manipulated
 *                                 market source may be trusted upward. Set
 *                                 BELOW market it binds permanently, pins every
 *                                 bond at the cap and makes the TWAP inert.
 *                                 A cap at M x market caps manipulation at M x;
 *                                 1.25-2x market is the intended band, reviewed
 *                                 monthly. Non-zero (pre-flight 8).
 *     WOOD_TWAP_ORACLE          — deployed WoodTwapOracle, the live WOOD price
 *                                 source. OPTIONAL as a key, REQUIRED in
 *                                 practice: chain 4663 has no Chainlink
 *                                 WOOD/USD feed, so without it every price read
 *                                 reverts NoWoodPrice. It must already have a
 *                                 COMPLETED averaging window when this runs —
 *                                 deploy it and run the keeper for at least
 *                                 `twapWindow` first (pre-flight 8).
 *     COVERED_TVL_CAP_USD18     — per-vault covered-TVL ceiling, USD-18. Non-zero.
 *     PROTOCOL_CONFIG           — ProtocolConfig to seat the duration ceiling on
 *                                 (`Deploy.s.sol` already writes this key into
 *                                 chains/<chainid>.json).
 *     MAX_STRATEGY_DURATION     — OPTIONAL protocol-wide strategy-duration ceiling,
 *                                 seconds. Defaults to DEFAULT_MAX_STRATEGY_DURATION
 *                                 (30d) when unset. 0 is REFUSED — see pre-flight 6.
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployPlanB.s.sol:DeployPlanB --rpc-url <rpc> -vvvv
 */
contract DeployPlanB is Script {
    /// @notice Epoch length (spec §5: 28d initial). Immutable in the ledger.
    uint256 internal constant EPOCH_LENGTH = 28 days;

    /// @notice Mirror of `ExposureLedger`'s default `challengeWindow` (14d).
    ///         Needed for the cooldown pre-flight, which must run BEFORE the
    ///         ledger exists to read it from. Asserted against the deployed
    ///         ledger below so this constant can never silently drift.
    uint256 internal constant EXPECTED_CHALLENGE_WINDOW = 14 days;

    /// @notice Protocol-wide strategy-duration ceiling seated when
    ///         `MAX_STRATEGY_DURATION` is not set. Public so the pre-flight
    ///         tests can assert against the SAME value an unset environment
    ///         produces, without touching the process environment.
    ///
    /// @dev    WHY 30 DAYS. The ADR (openspec/specs/guardian-coverage/spec.md)
    ///         defers the value to the multisig, so this is the script's default,
    ///         not a protocol constant — but it is not a free choice either. Three
    ///         things already assume it:
    ///
    ///           - `ExposureLedger.MAX_COVERAGE_HORIZON` is 60 days and its own
    ///             comment sizes it as "a 30d duration cap plus a 7d execution
    ///             window with room to spare". A ceiling above 30d walks
    ///             approvals into `CoverageHorizonExceeded` at propose time.
    ///           - `SyndicateFactory._defaultGovernorParams()` seats every new
    ///             vault's own `maxStrategyDuration` at 30 days. A protocol
    ///             ceiling BELOW that would make `createSyndicate` revert on its
    ///             own defaults (`GovernorParameters` validates the vault value
    ///             against this one), bricking syndicate creation outright.
    ///           - The testnet scripts pin the same figure — `script/testnet`
    ///             checks 30 days, `script/robinhood-testnet` checks 7 days.
    ///             A 30d ceiling admits both; anything lower refuses the first.
    ///
    ///         So 30 days is the unique value that binds without breaking
    ///         anything already shipped: the largest ceiling the coverage horizon
    ///         supports, and the smallest one the factory's own defaults survive.
    ///         Raising it means re-examining `MAX_COVERAGE_HORIZON` first.
    uint256 public constant DEFAULT_MAX_STRATEGY_DURATION = 30 days;

    /// @notice Mirror of `ProtocolConfig.MIN_PROTOCOL_MAX_STRATEGY_DURATION`.
    /// @dev    Mirrored rather than read so the refusal happens BEFORE the
    ///         broadcast. The setter's own revert is an `InvalidMaxStrategyDuration`
    ///         custom error raised mid-broadcast, after a ledger and an escrow are
    ///         already deployed — same argument as pre-flight 2b.
    uint256 internal constant MIN_PROTOCOL_MAX_STRATEGY_DURATION = 1 days;

    /// @notice The address book this deployment runs against, exactly as
    ///         `run()` reads it out of the environment.
    /// @dev    THE ENV READ AND THE DEPLOYMENT ARE SPLIT ON PURPOSE. `vm.setEnv`
    ///         writes the PROCESS environment — one shared mutable global for
    ///         the whole `forge test` run, which forge does not roll back
    ///         between tests and which every test suite executing in parallel
    ///         writes to. A pre-flight test driven through `run()` therefore
    ///         races every sibling suite that seeds the same keys, and loses
    ///         non-deterministically (observed: all 9 tests of this script's
    ///         suite failing on an address another suite had just written).
    ///         `deploy()` takes the book as an argument so the tests never
    ///         touch that global at all; `run()` is the thin env adapter and
    ///         stays the only production entry point.
    struct AddressBook {
        address swood;
        address factory;
        address registry;
        address wood;
        address usdg;
        address usdgFeed;
        uint256 feedMaxDelay;
        /// @dev The WOOD/USD price CAP, 8 decimals — seeded ABOVE market. It is
        ///      never served as a price; see pre-flight 8.
        uint256 woodPriceCapX8;
        uint256 coveredTvlCapUsd;
        address protocolConfig;
        uint256 maxStrategyDuration; // protocol-wide ceiling. Non-zero.
        /// @dev The `WoodTwapOracle` this ledger prices against, or zero to
        ///      wire none. Zero only works if a Chainlink WOOD/USD feed is
        ///      wired by hand before pre-flight 8's composed-price assert runs —
        ///      and chain 4663 has no such feed, so in practice this is required.
        address woodTwapOracle;
    }

    function run() external {
        deploy(
            AddressBook({
                swood: vm.envAddress("STAKED_WOOD"),
                factory: vm.envAddress("SYNDICATE_FACTORY"),
                registry: vm.envAddress("GUARDIAN_REGISTRY"),
                wood: vm.envAddress("WOOD_TOKEN"),
                usdg: vm.envAddress("USDG"),
                usdgFeed: vm.envAddress("CHAINLINK_USDG_USD_FEED"),
                feedMaxDelay: vm.envUint("ASSET_FEED_MAX_DELAY"),
                // RENAMED from WOOD_PRICE_HAIRCUT_X8, because the number's
                // MEANING changed and a stale name would have carried the old
                // instruction ("<= 30-day low") into the new semantics. It is a
                // CAP now, not a price — seed it ABOVE market. See pre-flight 8.
                woodPriceCapX8: vm.envUint("WOOD_PRICE_CAP_X8"),
                coveredTvlCapUsd: vm.envUint("COVERED_TVL_CAP_USD18"),
                protocolConfig: vm.envAddress("PROTOCOL_CONFIG"),
                // `envOr`, so the ordinary run needs no new key in the operator's
                // environment and still seats a ceiling. An operator who WANTS a
                // different one sets the key; one who wants NO ceiling cannot
                // express that here at all (pre-flight 6).
                maxStrategyDuration: vm.envOr("MAX_STRATEGY_DURATION", DEFAULT_MAX_STRATEGY_DURATION),
                // `envOr` with a zero default: a chain that somehow HAS a
                // Chainlink WOOD/USD feed does not need this, and pre-flight 8
                // is what actually refuses a ledger with no live price source —
                // so the requirement is expressed once, as a property of the
                // deployed state, rather than twice as an env precondition too.
                woodTwapOracle: vm.envOr("WOOD_TWAP_ORACLE", address(0))
            })
        );
    }

    /// @notice Every pre-flight, deploy and wiring step. Public so the
    ///         pre-flight tests can drive the real thing without the process
    ///         environment — see `AddressBook`.
    function deploy(AddressBook memory book) public {
        address deployer = msg.sender;

        address swood = book.swood;
        address factory = book.factory;
        address registry = book.registry;
        address wood = book.wood;
        address usdg = book.usdg;
        address usdgFeed = book.usdgFeed;
        uint256 feedMaxDelay = book.feedMaxDelay;
        uint256 woodPriceCapX8 = book.woodPriceCapX8;
        uint256 coveredTvlCapUsd = book.coveredTvlCapUsd;
        address protocolConfig = book.protocolConfig;
        uint256 maxStrategyDuration = book.maxStrategyDuration;
        // ── Pre-flight 1: REMOVED (ADR 2026-07-26) ──
        // This asserted `coolDownPeriod >= epochLength + challengeWindow` (42d
        // at defaults). It was both unsatisfiable and unnecessary:
        //
        //   - `StakedWood.setCooldownPeriod` caps the cooldown at 30 days, so
        //     the remedy this check printed — "raise the sWOOD cooldown by
        //     governance FIRST" — was not an action any operator could take.
        //     Only `initialize` could reach 42, i.e. only a fresh sWOOD.
        //   - The property it approximated (an approver cannot exit from under
        //     a pending challenge) is now enforced exactly by the exit gate on
        //     `claimUnstakeGuardian`, which reads `openExposureUsd` directly.
        //
        // Pre-flight 3 below replaces it, and is strictly stronger: it checks
        // the mechanism is WIRED rather than that a proxy for it is large
        // enough.
        uint256 coolDown = ISwoodCooldown(swood).coolDownPeriod();

        // ── Pre-flight 1b: the slash ceiling must not clip the allocation ──
        // The ledger books liability at 100% of a guardian's allocation, and
        // after the n1 fix `allocation == live slashable bond` is the DESIGNED
        // outcome whenever a co-approver's bond collapses, not a corner case.
        // With delegation deferred there is no surplus to absorb a clipped
        // ceiling, so any `maxSlashBps` below 10_000 makes recovery a strict
        // shortfall against the allocation and breaks §2's inequality by
        // construction.
        //
        // Every shipped config already seats 10_000 (`Deploy.s.sol`'s
        // DEFAULT_MAX_SLASH_BPS and both testnet scripts). This asserts the
        // choice rather than leaving it to a later governance transaction that
        // could lower it silently (review N9).
        require(
            ISwoodCooldown(swood).maxSlashBps() == 10_000,
            "PRE-FLIGHT: sWOOD maxSlashBps != 10000 -- the ledger books at 100% of allocation, "
            "so a lower ceiling makes recovery a strict shortfall."
        );

        // ── Pre-flight 2: a zero covered-TVL cap bricks all proposing ──
        require(
            coveredTvlCapUsd != 0, "PRE-FLIGHT: COVERED_TVL_CAP_USD18 is 0 (fail-closed: nothing could be proposed)"
        );

        // ── Pre-flight 2b: the broadcaster must be able to arm the exit gate ──
        // `StakedWood.setExposureLedger` is `onlyOwner`, and the wiring block
        // below CALLS it (see pre-flight 3 for why it cannot merely assert it).
        // Checked here rather than left to revert inside the broadcast: a
        // failure there costs a ledger and an escrow deploy before it lands, and
        // reports itself as an opaque `OwnableUnauthorizedAccount` rather than
        // as the one thing the operator has to change. This is the same
        // ownership assumption the script already makes of the GuardianRegistry
        // and the SyndicateFactory — `Deploy.s.sol` hands all three to the same
        // owner multisig — stated where it can be checked.
        require(
            ISwoodCooldown(swood).owner() == deployer,
            "PRE-FLIGHT: broadcaster does not own STAKED_WOOD, so it cannot arm the unstake gate. "
            "Re-run with --sender set to the sWOOD owner (the same multisig that owns the registry " "and the factory)."
        );

        // ── Pre-flight 6: "no ceiling" must not be expressible through this
        //    script (issue #32) ──
        // `ProtocolConfig.maxStrategyDuration` treats 0 as UNSET, hence
        // unbounded, and that default is correct where it lives: failing closed
        // there would brick every vault deployed before the parameter existed.
        // What is NOT correct is a fresh deployment shipping in it. With the
        // ceiling unset a vault owner may seat `maxStrategyDuration` anywhere up
        // to `ABSOLUTE_MAX_STRATEGY_DURATION` (3,650 days) and bind the
        // APPROVING GUARDIANS — who never agreed to it and are not the party
        // setting it — for a decade per approval. That is finding N4's enabling
        // condition, and the ADR's deferral of the VALUE to the multisig was
        // never a deferral of the INVARIANT.
        //
        // So the script seats it (inside the broadcast, below) rather than
        // printing a follow-up: a ceiling an operator is told to set afterwards
        // is a ceiling that ships unset, which is the state being closed.
        //
        // A ZERO OVERRIDE IS REFUSED RATHER THAN PASSED THROUGH. Zero is a legal
        // argument to the setter, so without this an operator could route an
        // explicit "no ceiling" through the very script that exists to prevent
        // one — and it would look like a deliberate configuration rather than the
        // omission it reproduces. Unsetting the ceiling on a live protocol
        // remains possible; it just is not something this deployment path can do.
        require(
            maxStrategyDuration != 0,
            "PRE-FLIGHT: MAX_STRATEGY_DURATION is 0, which means NO protocol ceiling -- a vault "
            "owner could then bind guardians for up to 3650 days per approval. Unset the variable "
            "to take the 30d default, or set a non-zero value."
        );
        require(
            maxStrategyDuration >= MIN_PROTOCOL_MAX_STRATEGY_DURATION,
            "PRE-FLIGHT: MAX_STRATEGY_DURATION is below ProtocolConfig's 1-day floor, which would "
            "make every vault unproposable protocol-wide. Set it to at least 1 days."
        );

        // ── Pre-flight 6b: the broadcaster must be able to seat that ceiling ──
        // `setMaxStrategyDuration` is `onlyOwner` and the broadcast below CALLS
        // it. Same argument as pre-flight 2b: left to revert inside the
        // broadcast this costs a ledger and an escrow deploy and reports itself
        // as an opaque `OwnableUnauthorizedAccount`. Note `Deploy.s.sol` hands
        // ProtocolConfig over with `Ownable2Step`, so a handoff whose
        // `acceptOwnership()` was never called lands here — and that is exactly
        // the state worth naming, since the address book still looks right.
        require(
            IProtocolConfigAdmin(protocolConfig).owner() == deployer,
            "PRE-FLIGHT: broadcaster does not own PROTOCOL_CONFIG, so it cannot seat the strategy-"
            "duration ceiling. Re-run with --sender set to the ProtocolConfig owner (if ownership "
            "was just transferred, the new owner must call acceptOwnership() first)."
        );

        // ── Pre-flight 5: the governor beacon must not need an impl swap it
        //    cannot survive (review M5) ──
        // Plan B needs every governor to carry `_exposureLedger` / `_bondEscrow`:
        // `createSyndicate` pushes both into each new governor, and `pushWiring`
        // pushes them into the existing ones. On a beacon whose implementation
        // predates Plan B, BOTH of those calls revert — so the moment this script
        // sets `factory.exposureLedger`, syndicate creation on that factory is
        // bricked until the beacon is upgraded.
        //
        // AND THE BEACON UPGRADE IS THE ONE THING THAT MUST NOT HAPPEN HERE. This
        // stack re-baselined `SyndicateGovernor`'s storage layout non-append-only:
        // `GovernorParameters` now inherits `ProposalLifecycle`, which C3
        // PREPENDS, so every field moved (`vault` 0 -> 15, `_guardianRegistry`
        // 43 -> 0, `_tierRegistry` 48 -> 58). That is legitimate for a FRESH
        // deployment and only for a fresh deployment — pushed onto a beacon with
        // live proxies, every governor reads garbage at every slot. See
        // `test/governor/GovernorLayoutPins.t.sol`, which pins the new baseline
        // and carries the same warning.
        //
        // So the three live states differ completely and the script must not
        // treat them alike:
        //   - `syndicateCount == 0`  — no proxies exist; a beacon upgrade is a
        //     no-op on live state and the manual follow-up is safe to print.
        //   - `syndicateCount != 0` and the beacon ALREADY serves a Plan B-capable
        //     governor — nothing needs upgrading; `pushWiring` alone finishes the
        //     job. This is the ordinary "Plan A from this stack, then Plan B"
        //     path and stays allowed: having syndicates is not by itself a
        //     problem, and refusing it would block legitimate work.
        //   - `syndicateCount != 0` and the beacon serves a PRE-Plan B governor —
        //     refused below. There is no ordering of the remaining steps that is
        //     both safe and complete: wiring the factory bricks creation,
        //     `pushWiring` reverts, and the upgrade that would fix either
        //     corrupts the live proxies. Those syndicates need a fresh factory
        //     and beacon, not an upgrade.
        //
        // REFUSES rather than warns, and refuses BEFORE the broadcast, for the
        // same reason as every other pre-flight here: the failure is silent and
        // the remedy is a redeployment. The scope is the narrowest one that is
        // still honest — this is not "the chain has syndicates", it is "the chain
        // has syndicates this deployment cannot reach without an upgrade that
        // would corrupt them".
        //
        // TWO WAYS THIS READS CONSERVATIVELY, both deliberate. `syndicateCount`
        // counts every syndicate this factory ever created, so after a
        // `setBeacon` migration it over-counts the CURRENT beacon's proxies; and
        // if two factories were ever pointed at one beacon, this factory's count
        // says nothing about the other's proxies. Over-refusal is the safe
        // direction for the first; the second is an operator obligation — check
        // every factory sharing the beacon.
        //
        // INVARIANT THIS GUARD DEPENDS ON: ONE BEACON SERVES EXACTLY ONE FACTORY.
        // Nothing on-chain enforces it and nothing today violates it — but once a
        // beacon serves two factories this check becomes unsound in the DANGEROUS
        // direction, not the safe one: a factory reporting zero would wave through
        // an upgrade that corrupts a sibling factory's live proxies. A beacon
        // cannot enumerate its proxies, so no on-chain check can recover this.
        // Preserving the invariant is free; losing it is discovered only after
        // governors start reading garbage. Deploy a beacon per factory.
        //
        // TOCTOU: this read and the beacon upgrade are separate transactions,
        // possibly days apart. A syndicate created in between flips a safe upgrade
        // into a corrupting one. Re-read the count immediately before broadcasting
        // any `upgradeTo` — the console output below says so, but a signed-off
        // runbook step is the real control.
        //
        // Both are closed by the same thing: a guard contract owning the beacon,
        // holding the factory reference, and re-reading this count in the SAME
        // transaction as `upgradeTo`. Deferred until the first governor upgrade
        // needs it, rather than shipped untested against a scenario months away.
        uint256 liveGovernors = ISyndicateFactory(factory).syndicateCount();
        if (liveGovernors != 0) {
            require(
                _beaconServesPlanBGovernor(ISyndicateFactory(factory).beacon()),
                "PRE-FLIGHT: SYNDICATE_FACTORY has live governor proxies on a PRE-PLAN-B governor "
                "impl. Plan B cannot be wired into them: createSyndicate/pushWiring would revert, and "
                "upgrading the beacon is FORBIDDEN on this stack -- SyndicateGovernor's layout was "
                "re-baselined non-append-only (fresh deploys only, see GovernorLayoutPins.t.sol), so "
                "every live governor would read garbage. Deploy a FRESH SyndicateFactory + "
                "GovernorBeacon on the Plan B governor impl and run this against that factory."
            );
        }

        console.log("sWOOD coolDownPeriod (s): %s", coolDown);
        console.log("deployer / ledger owner:  %s", deployer);
        console.log("existing syndicates on this factory: %s", liveGovernors);

        vm.startBroadcast();

        ExposureLedger ledger = new ExposureLedger(deployer, swood, EPOCH_LENGTH);
        // Drift guard: if the ledger's default challenge window ever changes,
        // pre-flight 1 above was checked against a stale bound.
        require(
            ledger.challengeWindow() == EXPECTED_CHALLENGE_WINDOW,
            "ExposureLedger default challengeWindow changed - update EXPECTED_CHALLENGE_WINDOW"
        );

        // The ledger third: the escrow reads `coverageFreezer()` off it to
        // decide who may forfeit a bond, so it must be deployed first (it is,
        // just above) and the pointer is immutable.
        ProposerBondEscrow escrow = new ProposerBondEscrow(wood, registry, address(ledger));

        ledger.setWoodUsdPrice(woodPriceCapX8);
        // THE MARKET SOURCE. Wired inside the broadcast rather than left as a
        // manual follow-up for the same reason the duration ceiling is: chain
        // 4663 has no Chainlink WOOD/USD aggregator, so a ledger that ships
        // without this has NO price source at all and every price read reverts
        // `NoWoodPrice` — proposing and executing are dead on arrival. An
        // operator merely TOLD to wire it afterwards is an operator who ships
        // the broken state. Pre-flight 8 below proves it landed and works.
        if (book.woodTwapOracle != address(0)) {
            ledger.setWoodTwapOracle(book.woodTwapOracle);
        }
        // maxDelay is LOAD-BEARING, not cosmetic: the §3.3a approve quorum
        // re-reads this feed at EXECUTE time, a full
        // `votingPeriod + reviewPeriod + executionWindow` after propose. A
        // maxDelay shorter than that lifecycle makes fully-covered proposals
        // die at execution with `StalePrice`. Size ASSET_FEED_MAX_DELAY against
        // the governor's ACTUAL lifecycle params (and the feed's real heartbeat),
        // not against a habitual `1 days`.
        ledger.setAssetFeed(usdg, usdgFeed, feedMaxDelay);
        ledger.setGuardianRegistry(registry);
        ledger.setCoveredTvlCapUsd(coveredTvlCapUsd);
        // quorumTierThreshold stays at its default, which ADR 2026-07-27 moved
        // to 0 (every tier fail-closed). Asserted in pre-flight 4 rather than
        // re-set here, so a ledger whose default ever drifts is caught instead
        // of silently corrected.

        IGuardianRegistry(registry).setExposureLedger(address(ledger));
        ISyndicateFactory(factory).setExposureLedger(address(ledger));
        ISyndicateFactory(factory).setBondEscrow(address(escrow));
        // THE READ SIDE OF THE SAME POINTER. The registry BOOKS exposure into
        // the ledger; sWOOD READS it to gate `claimUnstakeGuardian`. Both have
        // to name the same contract or the gate reads an empty ledger — so this
        // call belongs in the same block as the two above, not in a follow-up
        // transaction an operator is trusted to remember.
        ISwoodCooldown(swood).setExposureLedger(address(ledger));

        // THE DURATION CEILING (pre-flight 6). Seated in the same broadcast as
        // the wiring for the same reason sWOOD's pointer is: this is the last
        // moment where the omission is still cheap, and every deployment made
        // without it has already shipped the unbounded state.
        IProtocolConfigAdmin(protocolConfig).setMaxStrategyDuration(maxStrategyDuration);

        vm.stopBroadcast();

        // ── Pre-flight 3 (POST-wiring): the unstake gate must be live, and
        //    must be reading THE LEDGER THIS DEPLOYMENT BOOKS INTO ──
        // `StakedWood.claimUnstakeGuardian` FAILS OPEN when `exposureLedger` is
        // unset, because there is necessarily a window at deploy — and again on
        // a UUPS upgrade — where the pointer is still zero, and failing closed
        // there would brick withdrawals over a missed configuration step.
        //
        // The cost of that choice is a deployment which looks entirely healthy
        // while guardians can walk out from under a pending challenge. Asserting
        // it here converts that silent hole into a refused deploy, which is the
        // only point where the mistake is still cheap. Checked AFTER the
        // broadcast because the wiring happens inside it.
        //
        // WHY THIS IS AN `==` AND NOT A `!= address(0)` (review B3). A non-zero
        // test is passed by a sWOOD pointing at ANY ledger, including a stale
        // one from an earlier deployment — and that is not a hypothetical, it is
        // precisely the state the old "set it by governance FIRST, then re-run"
        // remedy produced: an operator who deployed a ledger by hand to satisfy
        // the check got a SECOND ledger from this script, with the registry and
        // the factory booking into the new one while sWOOD read the old. Every
        // guardian then shows `openExposureUsd == 0` and walks out carrying live
        // exposure — the exact failure the check exists to prevent, reached by
        // following its own instructions.
        //
        // WHY THE THREE ARE ASSERTED TOGETHER. Booking (registry), issuance
        // (factory) and the exit gate (sWOOD) are one mechanism split across
        // three pointers; any one of them naming a different ledger is silently
        // unsafe in the same way. Splitting them into separate blocks would let
        // a partial state look like a partial success.
        require(
            address(IGuardianRegistry(registry).exposureLedger()) == address(ledger),
            "WIRING: GuardianRegistry.exposureLedger != the ledger just deployed. Approvals would "
            "be booked nowhere the exit gate can see. Re-run this script from the registry owner."
        );
        require(
            ISyndicateFactory(factory).exposureLedger() == address(ledger),
            "WIRING: SyndicateFactory.exposureLedger != the ledger just deployed. New syndicates "
            "would be issued against a different ledger. Re-run this script from the factory owner."
        );
        require(
            ISwoodCooldown(swood).exposureLedger() == address(ledger),
            "PRE-FLIGHT: sWOOD exposureLedger != the ledger just deployed -- the unstake gate is "
            "open, or reads a ledger holding none of this deployment's bookings. This script wires "
            "it inside the broadcast; if it did not land, re-run from the sWOOD owner."
        );

        // ── Pre-flight 4 (POST-wiring): coverage is enforced at every tier ──
        // ADR 2026-07-27 originally paired this with a `maxEnvelopeTier <= 1`
        // ceiling that refused tier-2 exposure outright. THAT HALF WAS DROPPED
        // (owner decision 2026-07-31): tier-2 guardian ROE is to be closed with
        // off-chain team token incentives rather than by refusing the tier, so
        // tier 2 remains admissible on-chain and there is no ceiling to assert.
        //
        // What remains is the half that was never a policy choice. Coverage
        // SIZING was already correct at every tier; only ENFORCEMENT was gated,
        // and at the old default of 2 it ran at tier 2 alone — so a tier-0/1
        // proposal could execute with NO covering approver at all, its
        // correctly-sized coverage never checked. Threshold 0 closes that.
        //
        // Asserted after the broadcast, the only point where the value is
        // readable in the form the protocol will actually run with.
        require(
            ledger.quorumTierThreshold() == 0,
            "PRE-FLIGHT: ExposureLedger.quorumTierThreshold != 0 -- a covering approve quorum is "
            "required at EVERY tier. Call setQuorumTierThreshold(0), then re-run."
        );

        // ── Pre-flight 6 (POST-broadcast): the ceiling actually landed ──
        // The same shape as pre-flight 3's sWOOD leg, and for the same reason: a
        // ProtocolConfig that swallows the write — a proxy on an impl without the
        // setter, an address book naming a contract that is not this protocol's
        // config — leaves a deployment that looks entirely healthy while the
        // ceiling is still unset. Read back rather than trusted.
        require(
            IProtocolConfigAdmin(protocolConfig).maxStrategyDuration() != 0,
            "PRE-FLIGHT: ProtocolConfig.maxStrategyDuration is still 0 after this run seated it -- "
            "the ceiling did not land, so vault owners can bind guardians for up to 3650 days per "
            "approval. Check PROTOCOL_CONFIG names this protocol's config, then re-run."
        );

        // ── Pre-flight 7 (POST-broadcast): delegation must be OFF ──
        // Delegation is deferred to v2 (ADR 2026-07-26), and the deferral is
        // load-bearing, not bookkeeping. While it is on, `slashableBondUsd`
        // credits delegated stake toward a coverage window of ~35 days, but
        // `requestUnstakeDelegation` checks only the DELEGATOR's own state and
        // the unbonding pool stays slashable for just `coolDownPeriod` (7d). A
        // delegator therefore backs coverage they can exit from under while a
        // conviction is still heading for their delegate — credit, liability and
        // hold period are misaligned, and the ledger's `recovery >= allocation`
        // argument is built on delegation being off.
        //
        // The two candidate fixes were both rejected on their merits (stop
        // crediting delegated stake, or gate the delegator's exit on the
        // DELEGATE's exposure); deferring delegation is what removed the need to
        // choose. This asserts the deferral instead of assuming it, which is what
        // the ADR itself asks for.
        //
        // A CAPABILITY PROBE, NOT A TYPED CALL. `StakedWood` no longer HAS this
        // selector — the `StakedWoodDelegation` base was removed pre-mainnet — so
        // a typed call would revert on every healthy chain. But this script runs
        // against an EXISTING sWOOD proxy, and a chain still serving a
        // pre-removal implementation is precisely the case worth catching. A
        // missing selector therefore PASSES: delegation absent from the bytecode
        // is strictly stronger than a flag reading false. Anything that answers
        // with a non-zero word is refused, including a fallback returning
        // garbage — over-refusal is the safe direction here, and it costs a
        // re-run rather than a redeployment.
        require(
            !_delegationIsOn(swood),
            "PRE-FLIGHT: sWOOD reports delegationEnabled == true, but delegation is deferred to v2 "
            "and this deployment's coverage math assumes it is off. THE DELEGATOR-WALKOUT HOLE IS "
            "OPEN: delegated stake is credited to a ~35-day coverage window while "
            "requestUnstakeDelegation checks only the delegator and the unbonding pool stays "
            "slashable for coolDownPeriod alone, so a delegator can exit from under a conviction "
            "still heading for their delegate. Call setDelegationEnabled(false), then re-run."
        );

        // ── Pre-flight 8 (POST-broadcast): WOOD must actually be priceable ──
        //
        // Two asserts, because the cap and the market source fail differently
        // and an operator needs to be told which one is missing.
        //
        // (a) THE CAP MUST BE NON-ZERO. Under design revision 2 the cap is not
        //     a price and a zero cap is not "uncapped" — `_woodPrice` reverts
        //     `NoWoodPrice` on it, so a ledger deployed before governance
        //     seeded the number cannot price a single bond. This assert is what
        //     makes that revert a CONFIGURATION guard rather than a live
        //     failure mode; without it the design is worse than what it
        //     replaced. Read back rather than trusted: a swallowed write leaves
        //     a deployment that looks entirely healthy.
        require(
            ledger.woodUsdPriceX8() != 0,
            "PRE-FLIGHT: ExposureLedger.woodUsdPriceX8 is 0 -- the WOOD price CAP is unset, so every "
            "price read reverts NoWoodPrice and nothing can be proposed, executed or challenged. Set "
            "WOOD_PRICE_CAP_X8 ABOVE market (it is a ceiling on manipulation, NOT a conservative "
            "price -- a cap below market binds permanently and makes the market source inert)."
        );
        //
        // (b) THE COMPOSED PRICE MUST RESOLVE. `woodUsdPriceX8 != 0` alone
        //     proves only that the CEILING is configured; it says nothing about
        //     whether anything is priced under it. This calls the figure the
        //     protocol actually divides by, which fails on all three shapes
        //     that matter: no oracle wired, an oracle with no completed
        //     averaging window yet, and an oracle whose ETH/USD leg is
        //     unusable. That middle case is the operationally important one —
        //     `WoodTwapOracle` needs at least `twapWindow` of keeper activity
        //     BEFORE this script runs, so the ordering is deploy-and-prime the
        //     oracle first, Plan B second.
        //
        //     Probed rather than called typed: `woodPriceX8()` REVERTS rather
        //     than returning zero when no source can price WOOD, and a bare
        //     revert here would surface as an opaque script failure instead of
        //     the instruction below.
        (bool priced, bytes memory priceRet) = address(ledger).staticcall(abi.encodeWithSignature("woodPriceX8()"));
        require(
            priced && priceRet.length >= 32 && abi.decode(priceRet, (uint256)) != 0,
            "PRE-FLIGHT: ExposureLedger.woodPriceX8() does not resolve to a non-zero price. There is "
            "no live WOOD price source: either WOOD_TWAP_ORACLE is unset, or the oracle has no "
            "completed averaging window yet (deploy it and run the keeper for at least twapWindow "
            "BEFORE this script), or its ETH/USD leg is stale. Chain 4663 has no Chainlink WOOD/USD "
            "feed, so without the TWAP oracle nothing can be proposed or executed."
        );

        console.log("ExposureLedger:     %s", address(ledger));
        console.log("ProposerBondEscrow: %s", address(escrow));
        console.log("WoodTwapOracle:     %s", ledger.woodTwapOracle());
        console.log("WOOD price cap (X8): %s", ledger.woodUsdPriceX8());
        console.log("asset feed maxDelay (s): %s", feedMaxDelay);
        console.log("protocol maxStrategyDuration (s): %s", maxStrategyDuration);

        // The manual follow-ups are NOT the same list in both states, and the
        // difference is the whole of review M5. The old unconditional text told
        // every operator to upgrade the governor beacon and then `pushWiring`
        // each existing governor — an instruction that is correct on a fresh
        // chain and destroys a populated one. Pre-flight 5 above has already
        // refused the genuinely unreachable case, so only two states get here;
        // each is printed with its own precondition spelled out, so the safety
        // of the step is legible from the transcript rather than from having
        // read this file.
        console.log("MANUAL NEXT: registry UUPS upgrade, TierRegistry redeploy + recertify.");
        if (liveGovernors == 0) {
            console.log("MANUAL NEXT: governor beacon upgrade.");
            console.log("  PRECONDITION MET: syndicateCount == 0 -- this beacon has no live governor");
            console.log("  proxies, so swapping its impl cannot corrupt anyone. This is the ONLY");
            console.log("  state in which the upgrade is safe on this stack: SyndicateGovernor's");
            console.log("  layout was re-baselined non-append-only (see GovernorLayoutPins.t.sol).");
            console.log("  Re-check the count immediately before broadcasting the upgrade -- a");
            console.log("  syndicate created in between makes it unsafe.");
            console.log("  No pushWiring calls: there are no existing governors to wire.");
        } else {
            console.log("MANUAL NEXT: factory.pushWiring(<each existing governor>) -- %s syndicates.", liveGovernors);
            console.log("  DO *NOT* UPGRADE THE GOVERNOR BEACON ON THIS CHAIN. %s live governor", liveGovernors);
            console.log("  proxies read their impl from it, and this stack's SyndicateGovernor layout");
            console.log("  was re-baselined non-append-only (vault 0->15, _guardianRegistry 43->0,");
            console.log("  _tierRegistry 48->58): an impl swap makes every one of them read garbage.");
            console.log("  No upgrade is needed -- pre-flight 5 confirmed the beacon impl already");
            console.log("  exposes the Plan B wiring, which is why this run was allowed to proceed.");
            console.log("  If some future governor change DOES require a new impl here, those");
            console.log("  syndicates need a FRESH factory + beacon and a migration, not an upgrade.");
        }
        console.log("MANUAL NEXT: hand ledger ownership to the protocol owner (Ownable2Step: transfer + accept).");
    }

    /// @notice True when `swood` answers `delegationEnabled()` with a non-zero
    ///         word — i.e. delegation is live on the deployment this script is
    ///         about to wire itself into.
    /// @dev    A staticcall rather than a typed call because the CURRENT
    ///         `StakedWood` has no such selector: the `StakedWoodDelegation`
    ///         base was removed pre-mainnet, and a typed call would revert on
    ///         every healthy chain. A missing selector answers `false` — code
    ///         that does not exist cannot be enabled — while a pre-removal impl
    ///         behind the same proxy still answers honestly.
    ///
    ///         Decoded as a `uint256`, not a `bool`, on purpose: `abi.decode`
    ///         into a `bool` REVERTS on any word that is not 0 or 1, which would
    ///         turn a malformed answer into an undecodable script failure
    ///         instead of the refusal it should be. Any non-zero word counts as
    ///         "on" and is refused.
    function _delegationIsOn(address swood) internal view returns (bool) {
        (bool ok, bytes memory ret) = swood.staticcall(abi.encodeWithSignature("delegationEnabled()"));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (uint256)) != 0;
    }

    /// @notice True when `beacon`'s CURRENT implementation is a governor that
    ///         already carries the Plan B wiring slots.
    /// @dev Probes for the two views (`exposureLedger()` / `bondEscrow()`) that
    ///      only a Plan B-era `SyndicateGovernor` has. A pre-Plan B impl has no
    ///      such selector and no fallback, so the staticcall reverts and returns
    ///      `false` — which is also the answer for a `beacon` that is not a
    ///      beacon at all, or one whose impl has no code. FAIL-CLOSED
    ///      throughout: every unknown answers "not capable", and pre-flight 5
    ///      turns that into a refusal rather than a silent pass.
    ///
    ///      Deliberately a CAPABILITY probe, not a version or codehash
    ///      comparison. What Plan B needs from the beacon is exactly that
    ///      `setExposureLedger`/`setBondEscrow` land somewhere the governor
    ///      reads back; any impl offering that is fine, and pinning a specific
    ///      codehash would refuse legitimate governor builds for no gain.
    ///
    ///      A `view` staticcall on an UNINITIALIZED implementation is fine here:
    ///      these getters read storage unconditionally, so the selector's
    ///      existence — not the impl's initialization state — is what answers.
    function _beaconServesPlanBGovernor(address beacon) internal view returns (bool) {
        if (beacon.code.length == 0) return false;
        (bool okImpl, bytes memory implRet) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        if (!okImpl || implRet.length != 32) return false;

        address impl = abi.decode(implRet, (address));
        if (impl.code.length == 0) return false;

        (bool okLedger, bytes memory ledgerRet) = impl.staticcall(abi.encodeWithSignature("exposureLedger()"));
        if (!okLedger || ledgerRet.length != 32) return false;

        (bool okEscrow, bytes memory escrowRet) = impl.staticcall(abi.encodeWithSignature("bondEscrow()"));
        return okEscrow && escrowRet.length == 32;
    }
}
