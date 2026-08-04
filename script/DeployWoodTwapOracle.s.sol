// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {WoodTwapOracle, IUniswapV2PairMinimal, IAggregatorMinimal} from "../src/pricing/WoodTwapOracle.sol";

/**
 * @title  DeployWoodTwapOracle
 * @notice Deploys the `WoodTwapOracle` that `ExposureLedger` prices WOOD against.
 *         Runs BEFORE `DeployPlanB`, whose pre-flight 8 refuses a ledger with no
 *         live WOOD price source.
 *
 *         THERE IS NO CHAINLINK WOOD/USD FEED ON CHAIN 4663, AND THIS CONTRACT IS
 *         WHY THAT IS SURVIVABLE. It needs no such feed: it reads WOOD priced in
 *         ETH straight off the Uniswap-V2 `WOOD/WETH` pair's own cumulative-price
 *         accumulators, then converts to USD through the chain's ETH/USD
 *         Chainlink feed. The only Chainlink dependency is the ETH leg.
 *
 *   Ceremony position (openspec/specs/deployment-docs/spec.md):
 *     core (3 phases) -> THIS -> run the keeper until `consult()` answers -> DeployPlanB
 *
 *   Address book (read from chains/{chainId}.json, each overridable by an env var
 *   of the same name):
 *     WOOD_WETH_V2_PAIR       — the V2 pair holding exactly {WOOD, WETH}
 *     WOOD_TOKEN, WETH
 *     CHAINLINK_ETH_USD_FEED  — the ETH leg
 *
 *   Environment:
 *     TWAP_WINDOW           — averaging window (default 1h = MIN_TWAP_WINDOW)
 *     MAX_TWAP_AGE          — staleness bound on the newest snapshot (default 6h)
 *     ETH_USD_MAX_DELAY     — staleness bound on the ETH leg (default 24h)
 *     OWNER_MULTISIG        — final oracle owner. Required unless SKIP_MULTISIG_HANDOFF.
 *     SKIP_MULTISIG_HANDOFF — "true" to own from the deployer (fork/beta only).
 *
 *   Usage:
 *     forge script script/DeployWoodTwapOracle.s.sol:DeployWoodTwapOracle \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast --slow
 *
 * @dev OWNED AT BIRTH, NOT HANDED OFF. Every parameter is seated in the
 *      constructor and the owner-only surface is three re-tuning setters, so
 *      there is no wiring step the deployer has to perform afterwards. Passing
 *      the final owner as `initialOwner` therefore beats deploy-then-transfer:
 *      it removes the window in which the deployer could re-tune, and the
 *      oracle is plain `Ownable`, so a transfer would land in one step with no
 *      `acceptOwnership` receipt to prove it happened.
 */
contract DeployWoodTwapOracle is ScriptBase {
    /// @dev `MIN_TWAP_WINDOW`. Short ON PURPOSE — see the `MAX_ETH_USD_DELAY_LIMIT`
    ///      reasoning on the contract: coupling the window to the ETH leg's
    ///      heartbeat would force a ~12h window, and half a day of blindness to a
    ///      WOOD crash is worse than the staleness overstatement it would remove.
    uint256 constant DEFAULT_TWAP_WINDOW = 1 hours;
    /// @dev Six hours of slack over the window. This is the number the KEEPER
    ///      CADENCE must beat: snapshots older than this make `consult()` report
    ///      unavailable, which on a chain with no WOOD feed is `NoWoodPrice`.
    uint256 constant DEFAULT_MAX_TWAP_AGE = 6 hours;
    /// @dev `MAX_ETH_USD_DELAY_LIMIT`. The live 4663 ETH/USD feed was measured
    ///      ~10.7h old while perfectly healthy, so anything tighter would make
    ///      the ordinary case look degraded.
    uint256 constant DEFAULT_ETH_USD_MAX_DELAY = 1 days;

    /// @dev Mirrors `WoodTwapOracle.MAX_IDLE_SPAN_DIVISOR`. Duplicated rather
    ///      than read off the not-yet-deployed contract, since the whole point of
    ///      the check is to run BEFORE anything is deployed.
    uint256 constant MAX_IDLE_SPAN_DIVISOR = 20;

    struct Params {
        address pair;
        address wood;
        address weth;
        address ethUsdFeed;
        uint256 twapWindow;
        uint256 maxTwapAge;
        uint256 ethUsdMaxDelay;
        address owner;
    }

    /// @notice Thin env adapter. `deploy()` takes the params as an argument so
    ///         the tests never touch `vm.setEnv` — that writes one shared mutable
    ///         process global which forge does not roll back between tests and
    ///         which every parallel suite races. Same split, and the same reason,
    ///         as `DeployPlanB.AddressBook`.
    function run() external {
        bool skipHandoff = vm.envOr("SKIP_MULTISIG_HANDOFF", false);
        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (!skipHandoff) {
            require(ownerMultisig != address(0), "OWNER_MULTISIG required (or set SKIP_MULTISIG_HANDOFF=true)");
            require(ownerMultisig.code.length > 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
        }

        deploy(
            Params({
                pair: vm.envOr("WOOD_WETH_V2_PAIR", _readAddress("WOOD_WETH_V2_PAIR")),
                wood: vm.envOr("WOOD_TOKEN", _readAddress("WOOD_TOKEN")),
                weth: vm.envOr("WETH", _readAddress("WETH")),
                ethUsdFeed: vm.envOr("CHAINLINK_ETH_USD_FEED", _readAddress("CHAINLINK_ETH_USD_FEED")),
                twapWindow: vm.envOr("TWAP_WINDOW", DEFAULT_TWAP_WINDOW),
                maxTwapAge: vm.envOr("MAX_TWAP_AGE", DEFAULT_MAX_TWAP_AGE),
                ethUsdMaxDelay: vm.envOr("ETH_USD_MAX_DELAY", DEFAULT_ETH_USD_MAX_DELAY),
                // Deploying straight to the final owner — see the contract natspec.
                owner: skipHandoff ? msg.sender : ownerMultisig
            })
        );

        _patchAddress("WOOD_TWAP_ORACLE", address(_deployed));
    }

    /// @dev Set by `deploy()` so `run()` can persist it. `deploy()` deliberately
    ///      returns the oracle instead of writing the address book itself: a test
    ///      calling it would otherwise write a junk `chains/31337.json` on every
    ///      run. Same split, and the same reason, as `DeploySherwood.deployCore`.
    WoodTwapOracle internal _deployed;

    /// @notice Pre-flights, deploy, first snapshot. Public so the tests can drive
    ///         the real thing without the process environment. Does NOT persist
    ///         to chains/{chainId}.json — `run()` does that.
    function deploy(Params memory p) public returns (WoodTwapOracle oracle) {
        _preflight(p);

        vm.startBroadcast();
        oracle = new WoodTwapOracle(
            p.owner, p.pair, p.wood, p.weth, p.ethUsdFeed, p.twapWindow, p.maxTwapAge, p.ethUsdMaxDelay
        );
        // LAY THE FIRST OBSERVATION HERE. `update()` is permissionless and the
        // first call only ever records a baseline (`latest.timestamp == 0` takes
        // the early-return branch), so it costs one call and saves the operator a
        // step they would otherwise have to know about. `consult()` still needs a
        // SECOND snapshot a full `twapWindow` later, which is the keeper's job.
        oracle.update();
        vm.stopBroadcast();

        require(oracle.validatePair(), "post-deploy: validatePair() false");
        _deployed = oracle;

        console.log("WoodTwapOracle:  %s", address(oracle));
        console.log("owner:           %s", oracle.owner());
        console.log("pair:            %s", p.pair);
        console.log("twapWindow (s):  %s", p.twapWindow);
        console.log("maxTwapAge (s):  %s", p.maxTwapAge);

        // INSTANTANEOUS SPOT, FOR SIZING THE CAP ONLY. This is NOT the oracle's
        // answer and must never be used as one — it is the manipulable quantity
        // the averaging exists to defeat. It is printed because the operator's
        // next decision is `WOOD_PRICE_CAP_X8`, which the runbook requires to sit
        // 1.25-2x ABOVE market, and a cap seeded from nothing is the one
        // misconfiguration that pins every guardian bond.
        uint256 spotX8 = _spotWoodUsdX8(p);
        console.log("spot WOOD/USD x8 (cap-sizing only, NOT a price): %s", spotX8);
        console.log("suggested WOOD_PRICE_CAP_X8 band 1.25-2x: %s .. %s", (spotX8 * 125) / 100, spotX8 * 2);

        console.log("\nNEXT, IN ORDER:");
        console.log("  1. Run the keeper: WoodTwapOracle.update(), permissionless, on a");
        console.log("     schedule SHORTER than maxTwapAge above. A failing keeper is how");
        console.log("     this oracle goes stale, and a stale oracle with no Chainlink WOOD");
        console.log("     feed is NoWoodPrice: nothing proposes, nothing executes.");
        console.log("  2. Wait for consult() to answer (needs a second snapshot one full");
        console.log("     twapWindow after the baseline this script just recorded).");
        console.log("  3. DeployPlanB with WOOD_TWAP_ORACLE=<above>. Its pre-flight 8 is");
        console.log("     what actually enforces step 2.");
    }

    // ── Pre-flights (all PRE-broadcast: fail before anything is deployed) ──

    function _preflight(Params memory p) internal view {
        require(p.pair != address(0), "PRE-FLIGHT: WOOD_WETH_V2_PAIR unset");
        require(p.wood != address(0), "PRE-FLIGHT: WOOD_TOKEN unset");
        require(p.weth != address(0), "PRE-FLIGHT: WETH unset");
        require(p.ethUsdFeed != address(0), "PRE-FLIGHT: CHAINLINK_ETH_USD_FEED unset");

        // The constructor checks `maxTwapAge` BEFORE `twapWindow` precisely
        // because the cross-constraint is read against the not-yet-seated value
        // (see its ORDER IS LOAD-BEARING comment). Checking it here too costs
        // nothing and turns an opaque `InvalidParameter()` into a sentence.
        require(p.twapWindow >= 1 hours, "PRE-FLIGHT: TWAP_WINDOW below MIN_TWAP_WINDOW (1h)");
        require(p.twapWindow <= p.maxTwapAge, "PRE-FLIGHT: TWAP_WINDOW exceeds MAX_TWAP_AGE");
        require(p.maxTwapAge <= 1 days, "PRE-FLIGHT: MAX_TWAP_AGE above MAX_SNAPSHOT_AGE_LIMIT (24h)");
        require(p.ethUsdMaxDelay != 0, "PRE-FLIGHT: ETH_USD_MAX_DELAY zero");
        require(p.ethUsdMaxDelay <= 1 days, "PRE-FLIGHT: ETH_USD_MAX_DELAY above MAX_ETH_USD_DELAY_LIMIT (24h)");

        _preflightPair(p);
        _preflightEthLeg(p);
    }

    /// @dev THE PAIR MUST HOLD EXACTLY {WOOD, WETH}, and the constructor already
    ///      refuses otherwise — but with a bare `PairNotUsable()`, which reads
    ///      identically whether the address is the wrong pool, an untraded shell,
    ///      or a pair of the right shape holding unrelated tokens. Naming which
    ///      one it is here is the whole value of duplicating the check.
    function _preflightPair(Params memory p) internal view {
        address t0 = IUniswapV2PairMinimal(p.pair).token0();
        address t1 = IUniswapV2PairMinimal(p.pair).token1();
        require(
            (t0 == p.wood && t1 == p.weth) || (t0 == p.weth && t1 == p.wood),
            "PRE-FLIGHT: pair does not hold exactly {WOOD, WETH}"
        );

        (uint112 r0, uint112 r1, uint32 last) = IUniswapV2PairMinimal(p.pair).getReserves();
        require(r0 != 0 && r1 != 0, "PRE-FLIGHT: pair has a zero reserve");

        // WOOD AND WETH MUST SHARE A DECIMALS COUNT. `consult()` multiplies the
        // pair's raw UQ112x112 ratio by ETH/USD with no decimals normalisation
        // anywhere, so the answer is only a real price when the two tokens are
        // scaled alike. Both are 18 on chain 4663 and nothing in the oracle
        // asserts it, which makes this the cheapest place to pin the assumption.
        require(
            IERC20Metadata(p.wood).decimals() == IERC20Metadata(p.weth).decimals(),
            "PRE-FLIGHT: WOOD and WETH decimals differ - the oracle does not normalise them"
        );

        // THE IDLE GUARD, AND THE REASON THIS PRE-FLIGHT EXISTS AT ALL.
        // `validatePair()` passes on a pool that has not traded in weeks, so the
        // constructor accepts one happily — and then `update()` silently no-ops
        // forever, because `_currentCumulative` refuses to extrapolate across an
        // idle span of more than `twapWindow / MAX_IDLE_SPAN_DIVISOR`. The
        // deployment looks clean and the oracle never primes.
        //
        // THIS IS THE DOMINANT FAILURE ON A FORK. A forked chain stops trading at
        // the fork point, so `idle` grows without bound from the moment the vnet
        // is minted, and no amount of keeper activity can prime the oracle there.
        // On mainnet the pair trades continuously (measured: 10s idle), so this
        // check is near-free in production and decisive on a vnet.
        uint256 idle = block.timestamp > last ? block.timestamp - uint256(last) : 0;
        require(
            idle * MAX_IDLE_SPAN_DIVISOR <= p.twapWindow,
            "PRE-FLIGHT: pair too idle for this TWAP_WINDOW - update() would no-op forever. "
            "The pool must trade at least every twapWindow/20 seconds. On a fork/vnet the pool "
            "does not trade at all: generate swaps, or wire a Chainlink WOOD feed instead."
        );
    }

    /// @dev THE ETH LEG IS NOT CHECKED BY THE CONSTRUCTOR, which reads only
    ///      `decimals()`. An oracle deployed against a dead or negative feed
    ///      constructs fine and then reports unavailable from `consult()` for a
    ///      reason nothing on-chain explains.
    function _preflightEthLeg(Params memory p) internal view {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(p.ethUsdFeed).latestRoundData();
        require(answer > 0, "PRE-FLIGHT: ETH/USD feed answer is not positive");
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        require(age <= p.ethUsdMaxDelay, "PRE-FLIGHT: ETH/USD feed is already staler than ETH_USD_MAX_DELAY");
    }

    // ── Helpers ──

    /// @dev Instantaneous spot, 8 decimals. Both tokens share a decimals count
    ///      (asserted in `_preflightPair`), so the reserve ratio needs no scaling
    ///      and only the feed's own decimals have to be normalised.
    function _spotWoodUsdX8(Params memory p) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(p.pair).getReserves();
        bool woodIsToken0 = IUniswapV2PairMinimal(p.pair).token0() == p.wood;
        uint256 woodReserve = woodIsToken0 ? uint256(r0) : uint256(r1);
        uint256 wethReserve = woodIsToken0 ? uint256(r1) : uint256(r0);

        (, int256 answer,,,) = IAggregatorMinimal(p.ethUsdFeed).latestRoundData();
        uint8 dec = IAggregatorMinimal(p.ethUsdFeed).decimals();
        // `answer > 0` is asserted in `_preflightEthLeg`, so the cast cannot
        // change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(answer);
        uint256 ethUsdX8 = dec >= 8 ? raw / (10 ** (uint256(dec) - 8)) : raw * (10 ** (8 - uint256(dec)));

        return (wethReserve * ethUsdX8) / woodReserve;
    }
}
