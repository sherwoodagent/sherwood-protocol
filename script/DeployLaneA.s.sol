// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Erc20SpotAdapter} from "../src/pricing/Erc20SpotAdapter.sol";
import {MorphoSupplyAdapter} from "../src/pricing/MorphoSupplyAdapter.sol";
import {PositionKinds} from "../src/libraries/PositionKinds.sol";

/// @dev Narrow admin surface of the PriceRouter this script wires. The concrete
///      `PriceRouter` is UUPS-proxied and already deployed; pulling it in here
///      would drag the whole upgradeable stack into a wiring script for six
///      calls (same reasoning as `DeployPlanD`'s local interfaces).
interface IPriceRouterAdmin {
    function owner() external view returns (address);
    function adapterOf(bytes32 kind) external view returns (address);
    function haircutBps(bytes32 kind) external view returns (uint16);
    function instantCap(bytes32 kind) external view returns (uint256);
    function laneAEnabled(bytes32 kind) external view returns (bool);
    function registerAdapter(bytes32 kind, address adapter) external;
    function setInstantCap(bytes32 kind, uint256 cap) external;
    function setLaneAEnabled(bytes32 kind, bool enabled) external;
}

/// @dev The vault surface Lane A wiring touches: the instant-exit fee (G1) and
///      the two reads that gate it (owner authority, numeraire binding).
interface ILaneAVault {
    function owner() external view returns (address);
    function asset() external view returns (address);
    function instantExitFeeBps() external view returns (uint16);
    function setInstantExitFeeBps(uint16 bps) external;
}

/// @dev Local mirror of `PortfolioStrategy.TokenAllocation` for the optional
///      strategy-coverage cross-check (`checkStrategyCoverage`). The strategy's
///      `_feedIds` are internal, so feed IDENTITY cannot be cross-checked
///      on-chain — only registry COVERAGE can (see design risk table: drift
///      between the two registries degrades to Lane B, never misprices).
struct TokenAllocationView {
    address token;
    uint256 targetWeightBps;
    uint256 tokenAmount;
    uint256 investedAmount;
}

interface IPortfolioAllocations {
    function getAllocations() external view returns (TokenAllocationView[] memory);
}

/**
 * @title  DeployLaneA
 * @notice Lane A enablement wiring against an EXISTING deployment's PriceRouter
 *         (openspec change `lane-a-enablement`, task 5.1; parameters from
 *         `openspec/changes/lane-a-enablement/analysis/lane-a-parameters.md`).
 *         Order (security-relevant, per the change's migration plan):
 *           1. pre-flights — fail BEFORE anything is deployed (G1–G4 below)
 *           2. deploy `Erc20SpotAdapter` (numeraire = the vaults' asset) and
 *              `MorphoSupplyAdapter` (canonical Morpho pinned immutable)
 *           3. seed the spot adapter's feed registry from the parameter table
 *              (feed, maxAge, per-token cap, divergence pool + bound)
 *           4. register both kinds on the router, set the per-kind instant caps
 *           5. set `instantExitFeeBps = 200` on every target vault (G1)
 *           6. `setLaneAEnabled` LAST — the activation switch, gated behind an
 *              explicit config flag that DEFAULTS TO FALSE. Everything before
 *              it is inert: the router fails closed until the kind is enabled.
 *
 * @dev PRE-FLIGHT G1 (fee before enablement): `SyndicateVault.instantExitFeeBps`
 *      storage-defaults to 0 and no other deploy path sets it. At fee 0, any
 *      resting oracle-vs-pool basis (measured ~40bps on TSLA at the analysis
 *      snapshot) is a riskless arbitrage against remaining LPs at every exit
 *      size. This script sets the fee on every deployer-owned target vault
 *      inside the broadcast; for a vault it does NOT own it prints the exact
 *      calldata for the owner and — when `enableLaneA` is requested — REFUSES
 *      unless the fee already reads 200 on-chain. Lane A must never be enabled
 *      while any target vault's fee is below 200.
 * @dev PRE-FLIGHT G2 (haircut stays 0): `PriceRouter.setHaircutBps`'s natspec
 *      (src/pricing/PriceRouter.sol:137-155) documents the one-sided asymmetry:
 *      the haircut marks the single `totalAssets()` BOTH directions consume, so
 *      on deposit the vault mints against understated NAV. Adversary: a Lane A
 *      depositor on a haircut kind receives more shares than the position is
 *      worth — a deposit-side wealth transfer from existing holders. The
 *      haircut is also monotone-increasing (`HaircutCannotDecrease`): a nonzero
 *      value is a ONE-WAY DOOR, so this script refuses rather than "fixes" —
 *      there is no fixing it.
 * @dev PRE-FLIGHT G3 (staleness bound): every registered `maxAge` must be at
 *      most 24h — the equity feeds' heartbeat. A larger bound would leave Lane A
 *      open on marks the market has abandoned for longer than a full heartbeat.
 * @dev PRE-FLIGHT G4 (divergence gate mandatory): every seeded token must carry
 *      a nonzero reference pool and a divergence bound of at most 100bps. The
 *      24/5 equity feeds hold their last price over weekends while DEX pools
 *      keep trading, and the 200bps fee ceiling cannot cover a stale-mark
 *      regime (analysis §4: at b >= 200bps no exit size is safe). An entry
 *      without a gate is an entry that harvests remaining LPs every weekend.
 * @dev PRE-FLIGHT (no silent adapter replacement): both kind slots on the
 *      router must be UNSET. `registerAdapter` overwrites silently, so a re-run
 *      would swap a live, audited adapter for a fresh one mid-flight. Replace
 *      adapters via a deliberate governance action, not by re-running wiring.
 *
 *      Ownership: the broadcaster must own the PriceRouter (all router calls
 *      are `onlyOwner`). The spot adapter is deployed with the broadcaster as
 *      owner so the registry can be seeded in the same broadcast — hand it off
 *      to governance afterwards (MANUAL step printed at the end).
 *
 *      AAPL: the analysis lists only a Uniswap v4 pool for AAPL/USDG, and the
 *      adapter's divergence gate reads v3-style `slot0()` — v4 pools live
 *      inside the PoolManager and expose no per-pool contract. AAPL is
 *      therefore EXCLUDED from the default table until a v3-style AAPL/USDG
 *      reference pool is supplied via `AAPL_REFERENCE_POOL` (G4 refuses an
 *      ungated equity entry). AMD is excluded outright (analysis §1: total
 *      executable depth under $10k; never clears the fee wedge).
 *
 *   Environment (run() — the env adapter; `deploy()` takes the config directly
 *   so tests never touch the shared process environment, same split as
 *   `DeployPlanB`/`DeployPlanD`):
 *     PRICE_ROUTER            — the deployment's PriceRouter proxy.
 *     LANE_A_VAULTS           — comma-separated target vaults (fee = 200 each).
 *     AAPL_REFERENCE_POOL     — optional v3-style AAPL/USDG pool; unset drops AAPL.
 *     ENABLE_LANE_A           — optional, DEFAULTS FALSE; true flips the switch.
 *     ROBINHOOD_FORK_CHAIN_ID — optional fork chain id (e.g. 9994663).
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployLaneA.s.sol:DeployLaneA --rpc-url <rpc> -vvvv
 */
contract DeployLaneA is Script {
    // ── Gate constants (analysis §5, design D9) ──

    /// @notice G1: the instant-exit fee, at the vault's hard cap
    ///         (`MAX_INSTANT_EXIT_FEE_BPS`). The analysis' adversary model is
    ///         only safe at this ceiling.
    uint16 public constant INSTANT_EXIT_FEE_BPS = 200;
    /// @notice G3: staleness bound ceiling — the equity feeds' 24h heartbeat.
    uint256 public constant MAX_FEED_AGE = 24 hours;
    /// @notice G4: divergence-gate ceiling. The analysis' b = 100bps row is the
    ///         binding design point for every per-token cap.
    uint256 public constant MAX_DIVERGENCE_BPS = 100;

    // ── Robinhood Chain mainnet (4663) parameter table (analysis §8) ──

    uint256 public constant ROBINHOOD_CHAINID = 4663;

    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;

    address public constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address public constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address public constant NVDA_USDG_V3_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    uint256 public constant NVDA_CAP = 100_000e6;

    address public constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address public constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    uint256 public constant AAPL_CAP = 25_000e6;

    address public constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address public constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address public constant TSLA_USDG_V3_POOL = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3;
    uint256 public constant TSLA_CAP = 7_500e6;

    /// @notice Feed heartbeat (24h) — the registered `maxAge` for every token.
    uint256 public constant FEED_MAX_AGE = 86_400;
    /// @notice Router-level per-kind cap for `ERC20_SPOT`: the LARGEST
    ///         per-token cap, valid ONLY because the adapter enforces the
    ///         per-token caps itself (analysis §8 router-mechanics caveat).
    uint256 public constant INSTANT_CAP_ERC20_SPOT = 100_000e6;
    /// @notice Router-level cap for `MORPHO_BLUE_SUPPLY` — an operational
    ///         bound, not an arbitrage bound (valuation is share->asset at par;
    ///         under-delivery reverts same-tx via the vault's balance check).
    uint256 public constant INSTANT_CAP_MORPHO_SUPPLY = 250_000e6;

    // ── Config ──

    /// @notice One row of the spot adapter's parameter table.
    struct TokenEntry {
        address token;
        address aggregator;
        uint256 maxAge;
        uint256 capAssets;
        address referencePool;
        uint256 maxDivergenceBps;
    }

    /// @notice Everything `deploy()` acts on. `run()` is the env adapter that
    ///         builds this from the environment; tests construct it directly.
    struct Config {
        address router;
        address morpho;
        address numeraire;
        TokenEntry[] entries;
        address[] vaults;
        uint256 instantCapSpot;
        uint256 instantCapMorpho;
        bool enableLaneA;
    }

    function run() external {
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == ROBINHOOD_CHAINID || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: DeployLaneA's default table is Robinhood mainnet (4663) or its configured fork"
        );

        address aaplPool = vm.envOr("AAPL_REFERENCE_POOL", address(0));
        if (aaplPool == address(0)) {
            console.log("NOTE: AAPL_REFERENCE_POOL unset - AAPL is EXCLUDED from the seeded table.");
            console.log("  The analysis lists only a v4 AAPL/USDG pool and the adapter's divergence");
            console.log("  gate needs a v3-style slot0() pool (G4 refuses ungated equity entries).");
        }

        deploy(
            defaultRobinhoodConfig(
                vm.envAddress("PRICE_ROUTER"),
                vm.envOr("LANE_A_VAULTS", ",", new address[](0)),
                aaplPool,
                vm.envOr("ENABLE_LANE_A", false)
            )
        );
    }

    /// @notice The analysis §8 parameter table, encoded. AAPL is included only
    ///         when a v3-style reference pool is supplied (see contract natspec);
    ///         AMD is excluded outright.
    function defaultRobinhoodConfig(address router, address[] memory vaults, address aaplReferencePool, bool enable)
        public
        pure
        returns (Config memory cfg)
    {
        bool withAapl = aaplReferencePool != address(0);
        TokenEntry[] memory entries = new TokenEntry[](withAapl ? 3 : 2);
        entries[0] = TokenEntry({
            token: NVDA,
            aggregator: NVDA_FEED,
            maxAge: FEED_MAX_AGE,
            capAssets: NVDA_CAP,
            referencePool: NVDA_USDG_V3_POOL,
            maxDivergenceBps: MAX_DIVERGENCE_BPS
        });
        entries[1] = TokenEntry({
            token: TSLA,
            aggregator: TSLA_FEED,
            maxAge: FEED_MAX_AGE,
            capAssets: TSLA_CAP,
            referencePool: TSLA_USDG_V3_POOL,
            maxDivergenceBps: MAX_DIVERGENCE_BPS
        });
        if (withAapl) {
            entries[2] = TokenEntry({
                token: AAPL,
                aggregator: AAPL_FEED,
                maxAge: FEED_MAX_AGE,
                capAssets: AAPL_CAP,
                referencePool: aaplReferencePool,
                maxDivergenceBps: MAX_DIVERGENCE_BPS
            });
        }
        cfg = Config({
            router: router,
            morpho: MORPHO_BLUE,
            numeraire: USDG,
            entries: entries,
            vaults: vaults,
            instantCapSpot: INSTANT_CAP_ERC20_SPOT,
            instantCapMorpho: INSTANT_CAP_MORPHO_SUPPLY,
            enableLaneA: enable
        });
    }

    /// @notice Every pre-flight, deploy, wiring and post-condition step. Public
    ///         so the wiring tests can drive the real thing without touching
    ///         the process environment — see `Config`.
    function deploy(Config memory cfg) public {
        address deployer = msg.sender;

        // ── Pre-flight: shape ──
        require(cfg.router != address(0) && cfg.morpho != address(0) && cfg.numeraire != address(0), "zero address");
        require(cfg.entries.length != 0, "PRE-FLIGHT: empty parameter table - nothing to wire");
        require(
            cfg.morpho.code.length != 0, "PRE-FLIGHT: MORPHO has no code on this chain - wrong chain or wrong address"
        );

        // ── Pre-flight: authority (every router call below is onlyOwner) ──
        require(
            IPriceRouterAdmin(cfg.router).owner() == deployer,
            "PRE-FLIGHT: broadcaster is not PriceRouter.owner - run from the router owner "
            "(or hand the router to the deployer first)"
        );

        // ── Pre-flight G2: haircut must be 0 on both Lane-A kinds ──
        checkHaircutsZero(cfg.router);

        // ── Pre-flight: never silently replace a live adapter ──
        require(
            IPriceRouterAdmin(cfg.router).adapterOf(PositionKinds.ERC20_SPOT) == address(0),
            "PRE-FLIGHT: ERC20_SPOT adapter already registered. registerAdapter overwrites "
            "silently - replace a live adapter by deliberate governance action, not by re-running wiring."
        );
        require(
            IPriceRouterAdmin(cfg.router).adapterOf(PositionKinds.MORPHO_BLUE_SUPPLY) == address(0),
            "PRE-FLIGHT: MORPHO_BLUE_SUPPLY adapter already registered. registerAdapter overwrites "
            "silently - replace a live adapter by deliberate governance action, not by re-running wiring."
        );

        // ── Pre-flight G1a: enabling requires a non-empty target-vault list ──
        // The G1 fee gate below iterates `cfg.vaults`; an empty list (the
        // default when LANE_A_VAULTS is unset) would make it vacuous while the
        // switch it guards is protocol-global (per-kind on the shared router),
        // enabling Lane A for every vault at a zero instant-exit fee.
        require(
            !cfg.enableLaneA || cfg.vaults.length != 0,
            "PRE-FLIGHT G1: cannot enable Lane A with an empty target-vault list - "
            "every consuming vault's instantExitFeeBps must be proven == 200 first"
        );

        // ── Pre-flight G1b: neither kind may already be Lane-A-enabled ──
        // Activation must happen via `setLaneAEnabled` LAST. If a kind is
        // already enabled, `registerAdapter` becomes the activation event and
        // goes live several transactions before instantCap/haircut/fee land -
        // an uncapped, untolled window. Fail closed.
        require(
            !IPriceRouterAdmin(cfg.router).laneAEnabled(PositionKinds.ERC20_SPOT)
                && !IPriceRouterAdmin(cfg.router).laneAEnabled(PositionKinds.MORPHO_BLUE_SUPPLY),
            "PRE-FLIGHT G1: a Lane-A kind is already enabled - registerAdapter would activate "
            "before caps/fees land. Disable the kind before re-wiring."
        );

        // ── Pre-flight G3 + G4: parameter-table validation ──
        uint256 maxEntryCap;
        for (uint256 i; i < cfg.entries.length; ++i) {
            TokenEntry memory e = cfg.entries[i];
            require(e.token != address(0) && e.aggregator != address(0), "PRE-FLIGHT: zero token/aggregator entry");
            require(e.capAssets != 0, "PRE-FLIGHT: zero per-token cap - exclude the token instead");
            require(
                e.maxAge <= MAX_FEED_AGE,
                "PRE-FLIGHT G3: maxAge above the 24h feed heartbeat - Lane A would stay open on "
                "marks the market abandoned a full heartbeat ago"
            );
            require(
                e.referencePool != address(0),
                "PRE-FLIGHT G4: entry without a divergence reference pool. 24/5 equity feeds hold "
                "last price over weekends while pools trade; the 200bps fee ceiling cannot cover a "
                "stale-mark regime - an ungated entry harvests remaining LPs every weekend."
            );
            require(
                e.maxDivergenceBps != 0 && e.maxDivergenceBps <= MAX_DIVERGENCE_BPS,
                "PRE-FLIGHT G4: divergence bound outside (0, 100] bps - the per-token caps were "
                "derived at the b = 100bps design point and are unsafe beyond it"
            );
            if (e.capAssets > maxEntryCap) maxEntryCap = e.capAssets;
        }
        require(
            cfg.instantCapSpot != 0 && cfg.instantCapMorpho != 0,
            "PRE-FLIGHT: zero router instantCap means UNLIMITED on the router - never wire that"
        );
        require(
            cfg.instantCapSpot >= maxEntryCap,
            "PRE-FLIGHT: router ERC20_SPOT cap below a seeded per-token cap - that token's cap "
            "would be unreachable; the router cap is the outer backstop (largest per-token cap)"
        );

        // ── Pre-flight G1 + numeraire binding, per target vault ──
        bool[] memory deployerOwned = new bool[](cfg.vaults.length);
        for (uint256 i; i < cfg.vaults.length; ++i) {
            ILaneAVault v = ILaneAVault(cfg.vaults[i]);
            require(
                v.asset() == cfg.numeraire,
                "PRE-FLIGHT: vault asset != adapter numeraire - the adapter's numeraire binding "
                "would fail closed and this vault's Lane A would silently never open"
            );
            deployerOwned[i] = v.owner() == deployer;
            if (!deployerOwned[i] && cfg.enableLaneA) {
                require(
                    v.instantExitFeeBps() == INSTANT_EXIT_FEE_BPS,
                    "PRE-FLIGHT G1: cannot enable Lane A - a target vault is not deployer-owned and "
                    "its instantExitFeeBps != 200. At fee 0 every instant exit is riskless arbitrage "
                    "against remaining LPs. Have the vault owner call setInstantExitFeeBps(200) "
                    "(calldata printed by a fee-only run of this script), then re-run."
                );
            }
        }

        console.log("deployer / adapter owner:  %s", deployer);
        console.log("router:                    %s", cfg.router);
        console.log("numeraire:                 %s", cfg.numeraire);
        console.log("seeded tokens:             %s", cfg.entries.length);
        console.log("enable Lane A this run:    %s", cfg.enableLaneA);

        vm.startBroadcast();

        // Adapters first: inert until registered, registered inert until enabled.
        Erc20SpotAdapter spot = new Erc20SpotAdapter(deployer, cfg.numeraire);
        MorphoSupplyAdapter morphoAdapter = new MorphoSupplyAdapter(cfg.morpho);

        // Seed the parameter table. `setFeed` is loud: it live-probes the
        // aggregator and the reference pool's pair + slot0 shape, so a wrong
        // address fails HERE, not as a silent Lane B degrade later.
        for (uint256 i; i < cfg.entries.length; ++i) {
            TokenEntry memory e = cfg.entries[i];
            spot.setFeed(e.token, e.aggregator, e.maxAge, e.capAssets, e.referencePool, e.maxDivergenceBps);
        }

        IPriceRouterAdmin router = IPriceRouterAdmin(cfg.router);
        router.registerAdapter(PositionKinds.ERC20_SPOT, address(spot));
        router.registerAdapter(PositionKinds.MORPHO_BLUE_SUPPLY, address(morphoAdapter));
        router.setInstantCap(PositionKinds.ERC20_SPOT, cfg.instantCapSpot);
        router.setInstantCap(PositionKinds.MORPHO_BLUE_SUPPLY, cfg.instantCapMorpho);

        // G1: the fee precedes the switch, always.
        for (uint256 i; i < cfg.vaults.length; ++i) {
            if (deployerOwned[i]) ILaneAVault(cfg.vaults[i]).setInstantExitFeeBps(INSTANT_EXIT_FEE_BPS);
        }

        if (cfg.enableLaneA) {
            // Re-assert G1 and G2 against LIVE state immediately before the
            // switch: everything above proved config; this proves chain.
            checkHaircutsZero(cfg.router);
            for (uint256 i; i < cfg.vaults.length; ++i) {
                require(
                    ILaneAVault(cfg.vaults[i]).instantExitFeeBps() == INSTANT_EXIT_FEE_BPS,
                    "G1: a target vault's instantExitFeeBps is not 200 at the enablement step"
                );
            }
            // LAST. The activation switch flips only after every parameter,
            // fee and guard above it is in place.
            router.setLaneAEnabled(PositionKinds.ERC20_SPOT, true);
            router.setLaneAEnabled(PositionKinds.MORPHO_BLUE_SUPPLY, true);
        }

        vm.stopBroadcast();

        // ── Post-conditions: prove the wiring landed, don't trust the setters ──
        require(router.adapterOf(PositionKinds.ERC20_SPOT) == address(spot), "wiring: ERC20_SPOT adapter");
        require(router.adapterOf(PositionKinds.MORPHO_BLUE_SUPPLY) == address(morphoAdapter), "wiring: MORPHO adapter");
        require(router.instantCap(PositionKinds.ERC20_SPOT) == cfg.instantCapSpot, "wiring: spot instantCap");
        require(router.instantCap(PositionKinds.MORPHO_BLUE_SUPPLY) == cfg.instantCapMorpho, "wiring: morpho cap");
        require(router.laneAEnabled(PositionKinds.ERC20_SPOT) == cfg.enableLaneA, "wiring: spot laneAEnabled");
        require(router.laneAEnabled(PositionKinds.MORPHO_BLUE_SUPPLY) == cfg.enableLaneA, "wiring: morpho laneAEnabled");
        require(address(morphoAdapter.morpho()) == cfg.morpho, "wiring: canonical morpho");
        require(spot.numeraire() == cfg.numeraire, "wiring: numeraire");
        for (uint256 i; i < cfg.entries.length; ++i) {
            TokenEntry memory e = cfg.entries[i];
            (address agg, uint48 maxAge,,, uint16 divBps, address pool, uint96 cap) = spot.feedOf(e.token);
            require(agg == e.aggregator, "wiring: feed aggregator");
            require(maxAge == e.maxAge, "wiring: feed maxAge");
            require(cap == e.capAssets, "wiring: per-token cap");
            require(pool == e.referencePool, "wiring: reference pool");
            require(divBps == e.maxDivergenceBps, "wiring: divergence bound");
        }
        for (uint256 i; i < cfg.vaults.length; ++i) {
            if (deployerOwned[i]) {
                require(
                    ILaneAVault(cfg.vaults[i]).instantExitFeeBps() == INSTANT_EXIT_FEE_BPS, "wiring: instant exit fee"
                );
            }
        }

        console.log("Erc20SpotAdapter:    %s", address(spot));
        console.log("MorphoSupplyAdapter: %s", address(morphoAdapter));

        // Foreign-owned vaults: hand the owner the exact transaction (G1).
        for (uint256 i; i < cfg.vaults.length; ++i) {
            if (!deployerOwned[i]) {
                address v = cfg.vaults[i];
                console.log("MANUAL (G1): vault %s is owned by %s, not the deployer.", v, ILaneAVault(v).owner());
                console.log("  The owner MUST call setInstantExitFeeBps(200) BEFORE Lane A is enabled:");
                console.log("  target:   %s", v);
                console.log(
                    "  calldata: %s", vm.toString(abi.encodeCall(ILaneAVault.setInstantExitFeeBps, (uint16(200))))
                );
            }
        }

        if (!cfg.enableLaneA) {
            console.log("Lane A NOT enabled (ENABLE_LANE_A defaults false). To activate, re-check the");
            console.log("  runbook preconditions (docs/lane-a-runbook.md) then flip the switch:");
            console.log("  setLaneAEnabled(ERC20_SPOT, true) + setLaneAEnabled(MORPHO_BLUE_SUPPLY, true)");
            console.log("  from the router owner - a re-run of this script refuses to redeploy live");
            console.log("  adapters, so flip the switch directly.");
        }
        console.log("MANUAL NEXT: hand Erc20SpotAdapter ownership to governance (transferOwnership) -");
        console.log("  the feed registry is a pricing-of-record control surface.");
        console.log("MANUAL NEXT: re-measure DEX depth DURING MARKET HOURS before the mainnet parameter");
        console.log("  tx - the analysis snapshot (block 25,280,017) was a Saturday; caps derived from");
        console.log("  it are conservative but must be re-confirmed (analysis 'Known gaps' (2)).");
        console.log("MANUAL NEXT: Lane-A portfolio strategies must init with maxSlippageBps = 150 (R2) -");
        console.log("  a strategy-init parameter this script cannot set; enforce at proposal review.");
    }

    // ── Reusable guards (public so the wiring tests exercise the real logic) ──

    /// @notice PRE-FLIGHT G2. Reverts unless `haircutBps == 0` for BOTH Lane-A
    ///         kinds. Adversary: the router's haircut marks the single
    ///         `totalAssets()` both deposit and redeem consume
    ///         (src/pricing/PriceRouter.sol:137-155) — on a Lane-A-enabled kind
    ///         a nonzero haircut mints deposits against understated NAV, a
    ///         wealth transfer from existing holders to Lane A depositors. And
    ///         because the setter is monotone-increasing, a nonzero haircut
    ///         CANNOT be walked back: refuse, never "temporarily" accept.
    function checkHaircutsZero(address router) public view {
        require(
            IPriceRouterAdmin(router).haircutBps(PositionKinds.ERC20_SPOT) == 0,
            "PRE-FLIGHT G2: nonzero haircutBps on ERC20_SPOT. A haircut on a Lane-A-enabled kind "
            "mints deposits against understated NAV (deposit-side wealth transfer, "
            "PriceRouter.sol:137-155), and the setter is one-way (HaircutCannotDecrease): this "
            "kind must NOT be Lane-A-enabled until the two-sided-quote router change ships."
        );
        require(
            IPriceRouterAdmin(router).haircutBps(PositionKinds.MORPHO_BLUE_SUPPLY) == 0,
            "PRE-FLIGHT G2: nonzero haircutBps on MORPHO_BLUE_SUPPLY. A haircut on a Lane-A-enabled "
            "kind mints deposits against understated NAV (deposit-side wealth transfer, "
            "PriceRouter.sol:137-155), and the setter is one-way (HaircutCannotDecrease): this "
            "kind must NOT be Lane-A-enabled until the two-sided-quote router change ships."
        );
    }

    /// @notice Cross-check a live PortfolioStrategy's basket against the spot
    ///         adapter's registry: every basket token must be registered (or be
    ///         the numeraire itself). Run this per strategy at proposal review —
    ///         strategies are per-proposal, so they cannot be checked at wiring
    ///         time. NOTE the limit: the strategy's own feed bindings
    ///         (`_feedIds`) are internal state with no getter, so feed IDENTITY
    ///         cannot be verified on-chain — only registry coverage. Identity
    ///         drift is fail-safe regardless: it degrades the vault to Lane B,
    ///         it never misprices (design risk table).
    function checkStrategyCoverage(address spotAdapter, address strategy) public view {
        Erc20SpotAdapter spot = Erc20SpotAdapter(spotAdapter);
        TokenAllocationView[] memory allocs = IPortfolioAllocations(strategy).getAllocations();
        require(allocs.length != 0, "strategy has no allocations");
        for (uint256 i; i < allocs.length; ++i) {
            address token = allocs[i].token;
            if (token == spot.numeraire()) continue; // priced at par, no entry needed
            (address agg,,,,,,) = spot.feedOf(token);
            require(
                agg != address(0),
                "COVERAGE: basket token not in the spot adapter registry - this strategy's Lane A "
                "will never open (fail-closed registry miss); register the token or amend the basket"
            );
        }
    }
}
