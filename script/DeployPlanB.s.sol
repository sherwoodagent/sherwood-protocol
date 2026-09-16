// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {RobinhoodParams} from "./robinhood-mainnet/RobinhoodParams.sol";
import {Create3Factory} from "./utils/Create3Factory.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {ISyndicateFactory} from "../src/interfaces/ISyndicateFactory.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";

/// @dev The sWOOD surface this phase reads and writes. `setExposureLedger` is CALLED,
///      not merely asserted: the ledger it must name does not exist until this phase
///      mints it, so "set it first, then re-run" is not a first-deploy instruction.
interface ISwoodCooldown {
    function coolDownPeriod() external view returns (uint256);
    function maxSlashBps() external view returns (uint256);
    function minSlashBps() external view returns (uint256);
    function exposureLedger() external view returns (address);
    function setExposureLedger(address ledger) external;
    function owner() external view returns (address);
}

/// @dev The ProtocolConfig ADMIN surface. `IProtocolConfig` is the read side that
///      `GovernorParameters` consumes and deliberately carries no setters.
interface IProtocolConfigAdmin {
    function maxStrategyDuration() external view returns (uint256);
    function setMaxStrategyDuration(uint256 newValue) external;
    function owner() external view returns (address);
}

/**
 * @title  DeployPlanB
 * @notice Guardian-coverage phase: mints `ExposureLedger` + `ProposerBondEscrow` and
 *         wires them into sWOOD, the registry and the factory. An abstract mixin —
 *         `DeployAll` owns `run()`, the broadcast and the address book.
 *
 *         Order: pre-flights (refuse before anything is minted), CREATE3 mint, ledger
 *         params, the four pointer slots, the duration ceiling, then the post-flights
 *         that read the wiring back.
 *
 * @dev Idempotent: every mint is `_c3` (adopt-if-present) and every write is guarded on
 *      the value already there, so a resumed run makes no state-changing call. A pointer
 *      slot holding a FOREIGN address is refused, never repointed.
 * @dev PRE-FLIGHT 1 was removed (ADR 2026-07-26): it demanded a 42d sWOOD cooldown that
 *      `setCooldownPeriod`'s own 30d cap made unreachable. Pre-flight 3 replaces it and is
 *      strictly stronger. PRE-FLIGHT 10 (the ledger owner is a Safe) moved to DeployAll's
 *      post-handoff validate, where `pendingOwner()` is the thing to read. PRE-FLIGHT 11
 *      (a bound on this file's own constant) is deleted.
 *
 *      Ownership: the deployer owns the ledger and must ALREADY own sWOOD, the registry,
 *      the factory and the ProtocolConfig — every setter below is `onlyOwner`. Pre-flights
 *      2b and 6b check the two that are not otherwise read.
 */
abstract contract DeployPlanB is ScriptBase {
    /// @dev Mirror of `ProtocolConfig.MIN_PROTOCOL_MAX_STRATEGY_DURATION`. Mirrored so the
    ///      refusal happens before the mint, not as a mid-run custom error.
    uint256 internal constant MIN_PROTOCOL_MAX_STRATEGY_DURATION = 1 days;

    /// @dev Mirror of `ExposureLedger.MIN_WOOD_HAIRCUT_BPS`, which is `internal`. The
    ///      post-flight uses it to catch a DRIFTED mirror, not a bad input.
    uint256 internal constant MIN_WOOD_HAIRCUT_BPS = 5_000;

    /// @notice Policy value for `SyndicateGovernor.tier2CallCapBps` (issue #43): 200 bps.
    /// @dev    Printed, never seated: `setTier2CallCapBps` is `onlyVaultOwner` on each
    ///         governor, a role no ceremony script holds. Unset reads the inert 10_000.
    uint256 internal constant TIER2_CALL_CAP_BPS = 200;

    /// @notice The Plan B inputs. Named `PlanBBook` because `DeployAll` inherits this
    ///         mixin alongside Plan D's, and a shared `AddressBook` would collide.
    struct PlanBBook {
        address swood;
        address factory;
        address registry;
        address wood;
        address usdg;
        address usdgFeed;
        uint256 feedMaxDelay;
        /// @dev The WOOD/USD price CAP, 8 decimals, seeded ABOVE market. Never served as
        ///      a price: it only bounds how far a manipulated market source is trusted.
        uint256 woodPriceCapX8;
        /// @dev Bond-valuation haircut in bps. 10,000 is NO haircut and is refused below.
        uint256 woodHaircutBps;
        uint256 coveredTvlCapUsd;
        address protocolConfig;
        uint256 maxStrategyDuration; // protocol-wide ceiling. Non-zero.
        /// @dev The AggregatorV3-shaped WOOD/USD feed — the ledger's ONLY market source,
        ///      so pre-flight 8 requires it wired AND answering.
        address woodUsdFeed;
        /// @dev Staleness bound for `woodUsdFeed`. Set together with it or not at all.
        uint256 woodFeedMaxDelay;
    }

    /// @notice Pre-flights, CREATE3 mint, wiring and post-flights. Public so the
    ///         pre-flight suite drives the real thing without the process environment.
    /// @dev The caller must be the `Create3Factory` owner — `_c3Factory` bootstraps it at
    ///      `msg.sender`, exactly as `deployCore` does.
    function deploy(PlanBBook memory book) public returns (address ledgerAddr, address escrowAddr) {
        address deployer = msg.sender;
        address swood = book.swood;
        address factory = book.factory;
        address registry = book.registry;

        uint256 liveGovernors = _preflight(book, deployer);

        Create3Factory c3 = _c3Factory(deployer);
        ledgerAddr = _predict(c3, DeploySalts.EXPOSURE_LEDGER);
        escrowAddr = _predict(c3, DeploySalts.PROPOSER_BOND_ESCROW);

        // ── Pre-flight 3 (PRE-MINT): no pointer may already name a FOREIGN ledger ──
        // Booking (registry), issuance (factory) and the exit gate (sWOOD) are one
        // mechanism split across three slots; any one naming a different ledger is
        // silently unsafe — guardians read `openExposure == 0` and walk out carrying live
        // exposure. CREATE3 makes the ledger's address known here, so the refusal lands
        // before anything is minted instead of after the wiring is attempted.
        _requireSlotFree("StakedWood.exposureLedger", ISwoodCooldown(swood).exposureLedger(), ledgerAddr);
        _requireSlotFree(
            "GuardianRegistry.exposureLedger", address(IGuardianRegistry(registry).exposureLedger()), ledgerAddr
        );
        _requireSlotFree("SyndicateFactory.exposureLedger", ISyndicateFactory(factory).exposureLedger(), ledgerAddr);
        _requireSlotFree("SyndicateFactory.bondEscrow", ISyndicateFactory(factory).bondEscrow(), escrowAddr);

        ExposureLedger ledger = ExposureLedger(
            _c3(
                c3,
                DeploySalts.EXPOSURE_LEDGER,
                abi.encodePacked(
                    type(ExposureLedger).creationCode, abi.encode(deployer, swood, RobinhoodParams.EPOCH_LENGTH)
                )
            )
        );
        // Drift guard: the cooldown pre-flights above are checked against this bound.
        require(
            ledger.challengeWindow() == RobinhoodParams.EXPECTED_CHALLENGE_WINDOW,
            "ExposureLedger default challengeWindow changed - update EXPECTED_CHALLENGE_WINDOW"
        );

        // The escrow reads `coverageFreezer()` off the ledger to decide who may forfeit a
        // bond, and the pointer is immutable — so the ledger must exist first.
        ProposerBondEscrow escrow = ProposerBondEscrow(
            _c3(
                c3,
                DeploySalts.PROPOSER_BOND_ESCROW,
                abi.encodePacked(
                    type(ProposerBondEscrow).creationCode, abi.encode(book.wood, registry, address(ledger))
                )
            )
        );

        // ── Ledger parameters. The cap truncates an overstatement above it, the haircut
        //    absorbs one below it: one control, seated in one run.
        if (ledger.woodUsdPriceX8() != book.woodPriceCapX8) ledger.setWoodUsdPrice(book.woodPriceCapX8);
        if (ledger.woodHaircutBps() != book.woodHaircutBps) ledger.setWoodHaircutBps(book.woodHaircutBps);
        // THE ONLY MARKET SOURCE. Without it every price read reverts `NoWoodPrice` and
        // nothing can be proposed, executed or challenged; pre-flight 8 proves it landed.
        if (book.woodUsdFeed != address(0) && !_woodFeedAnswers(address(ledger))) {
            ledger.setWoodFeed(book.woodUsdFeed, book.woodFeedMaxDelay);
        }
        // `feedMaxDelay` is LOAD-BEARING: the §3.3a approve quorum re-reads this feed at
        // EXECUTE time, a whole lifecycle after propose. Too short and covered proposals
        // die with `StalePrice`.
        if (!_assetFeedAnswers(address(ledger), book.usdg)) {
            ledger.setAssetFeed(book.usdg, book.usdgFeed, book.feedMaxDelay);
        }
        if (ledger.guardianRegistry() != registry) {
            _requireSlotFree("ExposureLedger.guardianRegistry", ledger.guardianRegistry(), registry);
            ledger.setGuardianRegistry(registry);
        }
        if (ledger.coveredTvlCapUsd() != book.coveredTvlCapUsd) ledger.setCoveredTvlCapUsd(book.coveredTvlCapUsd);

        // ── The four pointer slots. Proven free or already ours above, so zero means
        //    "not written yet" and anything else is this run's own work.
        if (address(IGuardianRegistry(registry).exposureLedger()) == address(0)) {
            IGuardianRegistry(registry).setExposureLedger(address(ledger));
        }
        if (ISyndicateFactory(factory).exposureLedger() == address(0)) {
            ISyndicateFactory(factory).setExposureLedger(address(ledger));
        }
        if (ISyndicateFactory(factory).bondEscrow() == address(0)) {
            ISyndicateFactory(factory).setBondEscrow(address(escrow));
        }
        // THE READ SIDE OF THE SAME POINTER: the registry BOOKS exposure into the ledger,
        // sWOOD READS it to gate `claimUnstakeGuardian`. Both must name one contract.
        if (ISwoodCooldown(swood).exposureLedger() == address(0)) {
            ISwoodCooldown(swood).setExposureLedger(address(ledger));
        }

        // ── The duration ceiling (pre-flight 6). Seated here rather than printed: a
        //    ceiling an operator is told to set afterwards is one that ships unset, and
        //    unset lets a vault owner bind approving guardians for up to 3,650 days.
        if (IProtocolConfigAdmin(book.protocolConfig).maxStrategyDuration() == 0) {
            IProtocolConfigAdmin(book.protocolConfig).setMaxStrategyDuration(book.maxStrategyDuration);
        }

        _postflight(book, ledger);
        _report(book, ledger, escrow, liveGovernors);
    }

    // ── Pre-flights (PRE-MINT: every one of these refuses before anything exists) ──

    /// @dev Returns the factory's live governor count, which shapes the printed follow-ups.
    function _preflight(PlanBBook memory book, address deployer) internal view returns (uint256 liveGovernors) {
        address swood = book.swood;

        // ── Pre-flight 1b: the slash ceiling must not clip the lock ──
        // A guardian's declared lock may equal their entire live stake and a conviction
        // burns that lock as bps of the stake basis, so a ceiling below 100% under-
        // collateralises exactly the guardians who committed the most (review N9).
        require(
            ISwoodCooldown(swood).maxSlashBps() == 10_000,
            "PRE-FLIGHT: sWOOD maxSlashBps != 10000 -- a lock may equal the whole stake and must "
            "burn in full; a lower ceiling clips the burn beneath the lock."
        );

        // ── Pre-flight 1c: the deterrence floor must be armed ──
        // `minSlashBps` is the single floor a guardian cannot declare their way under. At
        // zero a token lock buys a token penalty and approving a drain for a bribe pays.
        require(
            ISwoodCooldown(swood).minSlashBps() != 0,
            "PRE-FLIGHT: sWOOD minSlashBps == 0 -- it is the single deterrence floor under declared "
            "locks; set it by governance before deploying the ledger."
        );

        // ── Pre-flight 2: a zero covered-TVL cap is fail-closed — wired into a governor,
        //    nothing could be proposed at all.
        require(
            book.coveredTvlCapUsd != 0,
            "PRE-FLIGHT: COVERED_TVL_CAP_USD18 is 0 (fail-closed: nothing could be proposed)"
        );

        // ── Pre-flight 2b: the deployer must be able to arm the exit gate ──
        // `setExposureLedger` is `onlyOwner` and this phase CALLS it. Left to revert
        // mid-run it costs a ledger and an escrow and reports as `OwnableUnauthorizedAccount`.
        require(
            ISwoodCooldown(swood).owner() == deployer,
            "PRE-FLIGHT: broadcaster does not own STAKED_WOOD, so it cannot arm the unstake gate. "
            "Re-run with --sender set to the sWOOD owner (the same multisig that owns the registry " "and the factory)."
        );

        // ── Pre-flight 6: "no ceiling" must not be expressible through this script ──
        // `ProtocolConfig` treats 0 as unset, hence unbounded — correct where it lives,
        // wrong for a fresh deployment. Zero is a legal argument to the setter, so it is
        // refused here rather than passed through as if it were a configuration.
        require(
            book.maxStrategyDuration != 0,
            "PRE-FLIGHT: MAX_STRATEGY_DURATION is 0, which means NO protocol ceiling -- a vault "
            "owner could then bind guardians for up to 30 days per approval. Unset the variable "
            "to take the 30d default, or set a non-zero value."
        );
        require(
            book.maxStrategyDuration >= MIN_PROTOCOL_MAX_STRATEGY_DURATION,
            "PRE-FLIGHT: MAX_STRATEGY_DURATION is below ProtocolConfig's 1-day floor, which would "
            "make every vault unproposable protocol-wide. Set it to at least 1 days."
        );

        // ── Pre-flight 6b: the deployer must be able to seat that ceiling ──
        // Same argument as 2b. A handoff whose `acceptOwnership()` never ran lands here,
        // and that is the state worth naming: the address book still looks right.
        require(
            IProtocolConfigAdmin(book.protocolConfig).owner() == deployer,
            "PRE-FLIGHT: broadcaster does not own PROTOCOL_CONFIG, so it cannot seat the strategy-"
            "duration ceiling. Re-run with --sender set to the ProtocolConfig owner (if ownership "
            "was just transferred, the new owner must call acceptOwnership() first)."
        );

        // ── Pre-flight 5: live governors must not need a beacon swap they cannot survive ──
        // Plan B needs every governor to carry `_exposureLedger`/`_bondEscrow`. On a
        // pre-Plan B impl, `createSyndicate` and `pushWiring` both revert — and the beacon
        // upgrade that would fix it is FORBIDDEN here: `SyndicateGovernor`'s layout was
        // re-baselined non-append-only (GovernorLayoutPins.t.sol), so a swap on a populated
        // beacon makes every live proxy read garbage. Those syndicates need a fresh
        // factory + beacon, not an upgrade. A zero count skips the probe: nothing to corrupt.
        // Reads conservatively by design — `syndicateCount` counts every syndicate this
        // factory ever created, and a beacon shared by two factories is undetectable here.
        // Deploy one beacon per factory.
        liveGovernors = ISyndicateFactory(book.factory).syndicateCount();
        if (liveGovernors != 0) {
            require(
                _beaconServesPlanBGovernor(ISyndicateFactory(book.factory).beacon()),
                "PRE-FLIGHT: SYNDICATE_FACTORY has live governor proxies on a PRE-PLAN-B governor "
                "impl. Plan B cannot be wired into them: createSyndicate/pushWiring would revert, and "
                "upgrading the beacon is FORBIDDEN on this stack -- SyndicateGovernor's layout was "
                "re-baselined non-append-only (fresh deploys only, see GovernorLayoutPins.t.sol), so "
                "every live governor would read garbage. Deploy a FRESH SyndicateFactory + "
                "GovernorBeacon on the Plan B governor impl and run this against that factory."
            );
        }

        // ── Pre-flight 12: the WOOD/USD feed and its staleness bound move together ──
        // `setWoodFeed` enforces the pairing too, but only from inside the run, several
        // writes in. A half-edited book is a refusal that costs nothing here.
        require(
            (book.woodUsdFeed == address(0)) == (book.woodFeedMaxDelay == 0),
            "PRE-FLIGHT: WOOD_USD_FEED and WOOD_FEED_MAX_DELAY must be set together -- one without "
            "the other is a half-edited environment, and setWoodFeed would revert mid-broadcast."
        );
        require(
            book.woodUsdFeed == address(0) || book.woodUsdFeed.code.length != 0,
            "PRE-FLIGHT: WOOD_USD_FEED holds no code"
        );
        // A `WoodPoolFeed` republishes `updatedAt` only when a snapshot ROLLS, at most once
        // per window, so a bound at or below the window halts every read between rolls.
        // Probed, not typed: the feed may be a plain aggregator with no window at all.
        (bool hasWindow, bytes memory windowRet) = book.woodUsdFeed.staticcall(abi.encodeWithSignature("window()"));
        if (hasWindow && windowRet.length == 32) {
            require(
                book.woodFeedMaxDelay > abi.decode(windowRet, (uint256)) + RobinhoodParams.KEEPER_CADENCE_SLACK,
                "PRE-FLIGHT: WOOD_FEED_MAX_DELAY must EXCEED the feed's averaging window plus the "
                "keeper cadence (2h). The feed's updatedAt advances at most once per window, so a "
                "tighter bound halts proposing and executing between rolls for up to a whole window."
            );
        }
    }

    // ── Post-flights (read the wiring back; the writes above are the only source) ──

    function _postflight(PlanBBook memory book, ExposureLedger ledger) internal view {
        address swood = book.swood;

        // ── Pre-flight 3 (POST-WIRING): the gate must be live and must read THIS ledger ──
        // `claimUnstakeGuardian` FAILS OPEN on an unset pointer — necessary, because there
        // is a window at deploy and again at every UUPS upgrade where it is zero. The cost
        // is a deployment that looks healthy while guardians walk out from under a pending
        // challenge, which is what these three `==` checks convert into a refused run.
        require(
            address(IGuardianRegistry(book.registry).exposureLedger()) == address(ledger),
            "WIRING: GuardianRegistry.exposureLedger != the ledger just deployed. Approvals would "
            "be booked nowhere the exit gate can see. Re-run this script from the registry owner."
        );
        require(
            ISyndicateFactory(book.factory).exposureLedger() == address(ledger),
            "WIRING: SyndicateFactory.exposureLedger != the ledger just deployed. New syndicates "
            "would be issued against a different ledger. Re-run this script from the factory owner."
        );
        require(
            ISwoodCooldown(swood).exposureLedger() == address(ledger),
            "PRE-FLIGHT: sWOOD exposureLedger != the ledger just deployed -- the unstake gate is "
            "open, or reads a ledger holding none of this deployment's bookings. This script wires "
            "it inside the broadcast; if it did not land, re-run from the sWOOD owner."
        );

        // ── Pre-flight 6 (POST): the ceiling actually landed ──
        // A ProtocolConfig that swallows the write — a proxy on an impl without the setter,
        // a book naming some other protocol's config — leaves a healthy-looking deployment.
        require(
            IProtocolConfigAdmin(book.protocolConfig).maxStrategyDuration() != 0,
            "PRE-FLIGHT: ProtocolConfig.maxStrategyDuration is still 0 after this run seated it -- "
            "the ceiling did not land, so vault owners can bind guardians for up to 30 days per "
            "approval. Check PROTOCOL_CONFIG names this protocol's config, then re-run."
        );

        // ── Pre-flight 7 (POST): delegation must be OFF ──
        // While it is on, delegated stake is credited to a ~35-day coverage window while
        // `requestUnstakeDelegation` checks only the delegator and the unbonding pool stays
        // slashable for `coolDownPeriod` alone — a delegator can exit from under a
        // conviction heading for their delegate. The ledger's recovery argument assumes off.
        require(
            !_delegationIsOn(swood),
            "PRE-FLIGHT: sWOOD reports delegationEnabled == true, but delegation is deferred to v2 "
            "and this deployment's coverage math assumes it is off. THE DELEGATOR-WALKOUT HOLE IS "
            "OPEN: delegated stake is credited to a ~35-day coverage window while "
            "requestUnstakeDelegation checks only the delegator and the unbonding pool stays "
            "slashable for coolDownPeriod alone, so a delegator can exit from under a conviction "
            "still heading for their delegate. Call setDelegationEnabled(false), then re-run."
        );

        // ── Pre-flight 8 (POST): WOOD must actually be priceable ──
        // Two asserts, because the cap and the market source fail differently and the
        // operator's remedy differs. (a) a zero cap is not "uncapped": `_woodPrice` reverts
        // `NoWoodPrice` on it, so no bond can be priced at all.
        require(
            ledger.woodUsdPriceX8() != 0,
            "PRE-FLIGHT: ExposureLedger.woodUsdPriceX8 is 0 -- the WOOD price CAP is unset, so every "
            "price read reverts NoWoodPrice and nothing can be proposed, executed or challenged. Set "
            "WOOD_PRICE_CAP_X8 ABOVE market (it is a ceiling on manipulation, NOT a conservative "
            "price -- a cap below market binds permanently and makes the market source inert)."
        );
        // (b) the feed must be wired AND answering. A configured ceiling says nothing about
        // whether anything is priced beneath it; this calls the figure the protocol divides
        // by, which fails on every shape that matters — no feed, no completed window, a pool
        // below its depth floor, a stale reading.
        require(
            book.woodUsdFeed != address(0),
            "PRE-FLIGHT: WOOD_USD_FEED is unset. The ledger has exactly one market source, so "
            "without it every price read reverts NoWoodPrice and nothing can be proposed, executed "
            "or challenged. Deploy script/DeployWoodPoolFeed.s.sol and prime it first."
        );
        require(
            _woodFeedAnswers(address(ledger)),
            "PRE-FLIGHT: ExposureLedger.woodPriceX8() does not resolve to a non-zero price. The wired "
            "WOOD_USD_FEED is not answering: a WoodPoolFeed with no completed window yet (run the "
            "keeper for a full window BEFORE this script), a pool below MIN_WETH_RESERVE, a stale "
            "ETH/USD leg, or a reading older than WOOD_FEED_MAX_DELAY."
        );

        // ── Pre-flight 9 (POST): a real allowance must exist ──
        // The haircut is the compensating control for the two overstatements this design
        // ACCEPTS: the feed's non-contemporaneous legs and the residual crash lag. The
        // ledger DEFAULTS to 10,000 — no haircut — and its own setter accepts that value.
        require(
            ledger.woodHaircutBps() < 10_000,
            "PRE-FLIGHT: ExposureLedger.woodHaircutBps is 10000 -- that is NO haircut, which leaves "
            "ZERO allowance for the two overstatements this design accepts: the feed's stale "
            "ETH/USD leg (an ETH drawdown inside the ~10.7h heartbeat reads WOOD/USD high by roughly "
            "the ETH move, no attacker needed) and the crash lag of up to window + maxDelay. "
            "Set WOOD_HAIRCUT_BPS -- 5000 is the shipped value and absorbs a 50% overstatement."
        );
        require(
            ledger.woodHaircutBps() >= MIN_WOOD_HAIRCUT_BPS,
            "PRE-FLIGHT: ExposureLedger.woodHaircutBps is below the ledger's floor. Valuing every "
            "guardian bond under half of market is a mis-set parameter, not conservatism -- and it "
            "prices guardians out of the role. If this fires, the mirrored MIN_WOOD_HAIRCUT_BPS in "
            "this script has drifted from the ledger's."
        );
    }

    // ── Helpers ──

    /// @dev A pointer slot may be empty or already ours; a FOREIGN holder is refused rather
    ///      than repointed, because repointing is how a stale ledger survives a re-run.
    function _requireSlotFree(string memory label, address current, address want) internal pure {
        require(
            current == address(0) || current == want,
            string.concat(
                "WIRING: ",
                label,
                " already names a foreign address -- this ceremony never repoints a live slot. "
                "Clear it, or bump the CREATE3 salt namespace and redeploy."
            )
        );
    }

    /// @dev "Is the WOOD feed wired and live?" The ledger exposes no getter for the slot,
    ///      so the probe is the read it feeds; `woodPriceX8` REVERTS when nothing prices WOOD.
    function _woodFeedAnswers(address ledger) internal view returns (bool) {
        (bool ok, bytes memory ret) = ledger.staticcall(abi.encodeWithSignature("woodPriceX8()"));
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) != 0;
    }

    /// @dev Same shape for an asset feed: `coverageUsd` reverts `FeedNotConfigured` when the
    ///      slot is empty and `StalePrice` when it is wired but dead.
    function _assetFeedAnswers(address ledger, address asset) internal view returns (bool) {
        (bool ok,) = ledger.staticcall(abi.encodeWithSignature("coverageUsd(address,uint256)", asset, uint256(0)));
        return ok;
    }

    /// @dev True when `swood` answers `delegationEnabled()` with a non-zero word. A
    ///      staticcall because the current `StakedWood` has no such selector — a missing
    ///      one answers false, which is strictly stronger than a flag reading false.
    ///      Decoded as `uint256`: `abi.decode` into a `bool` reverts on a malformed word,
    ///      turning a refusal into an undecodable failure.
    function _delegationIsOn(address swood) internal view returns (bool) {
        (bool ok, bytes memory ret) = swood.staticcall(abi.encodeWithSignature("delegationEnabled()"));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (uint256)) != 0;
    }

    /// @dev True when `beacon`'s CURRENT impl carries the Plan B wiring slots. A capability
    ///      probe, not a codehash pin: any impl where `setExposureLedger`/`setBondEscrow`
    ///      land somewhere the governor reads back is fine. FAIL-CLOSED — every unknown
    ///      (no code, not a beacon, uninitialised impl) answers "not capable".
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

    function _report(PlanBBook memory book, ExposureLedger ledger, ProposerBondEscrow escrow, uint256 liveGovernors)
        internal
        view
    {
        console.log("ExposureLedger:     %s", address(ledger));
        console.log("ProposerBondEscrow: %s", address(escrow));
        console.log("ledger owner:       %s (must carry the Zodiac delay module)", ledger.owner());
        console.log("WOOD/USD feed:      %s (delay %s s)", book.woodUsdFeed, book.woodFeedMaxDelay);
        console.log("WOOD price cap (X8): %s", ledger.woodUsdPriceX8());
        console.log("WOOD haircut (bps):  %s", ledger.woodHaircutBps());
        console.log("existing syndicates on this factory: %s", liveGovernors);

        // The follow-ups differ by state and the difference is the whole of review M5:
        // the old unconditional "upgrade the beacon, then pushWiring" is correct on a fresh
        // chain and destroys a populated one.
        if (liveGovernors != 0) {
            console.log("MANUAL NEXT: factory.pushWiring(<each existing governor>) -- %s syndicates.", liveGovernors);
            console.log("  DO *NOT* UPGRADE THE GOVERNOR BEACON: the layout was re-baselined");
            console.log("  non-append-only, so every live proxy would read garbage. No upgrade is");
            console.log("  needed -- pre-flight 5 confirmed the impl already exposes the Plan B wiring.");
        }
        // Issue #43: `setTier2CallCapBps` is `onlyVaultOwner` per governor, so no ceremony
        // script can seat it; new syndicates read the inert 10_000 default until it is set.
        console.log(
            "MANUAL NEXT: each vault owner calls governor.setTier2CallCapBps(%s) (issue #43, ~2%% of TVL).",
            TIER2_CALL_CAP_BPS
        );
        console.log("  Verify with: GOVERNOR=<gov> VAULT=<vault> forge script");
        console.log("  script/CheckSyndicateParams.s.sol:CheckSyndicateParams -- it FAILS on the inert default.");
    }
}
