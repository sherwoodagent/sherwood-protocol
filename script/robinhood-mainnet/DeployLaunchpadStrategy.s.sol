// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {LaunchpadStrategy} from "../../src/strategies/LaunchpadStrategy.sol";
import {SushiLaunchAdapter} from "../../src/adapters/SushiLaunchAdapter.sol";
import {StonkLaunchAdapter} from "../../src/adapters/StonkLaunchAdapter.sol";
import {PonsLaunchAdapter} from "../../src/adapters/PonsLaunchAdapter.sol";
import {ISushiLaunchpad} from "../../src/vendor/sushi/ISushiLaunchpad.sol";
import {IPonsLaunchFactory, IPonsLaunchLocker} from "../../src/vendor/pons/IPonsLaunch.sol";
import {IStonkSafeLaunchpadV2} from "../../src/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";
import {ITierRegistry} from "../../src/interfaces/ITierRegistry.sol";

/**
 * @notice Deploy the LaunchpadStrategy template with ALL THREE launch
 *         adapters — SushiLaunchAdapter, StonkLaunchAdapter and
 *         PonsLaunchAdapter — to Robinhood Chain mainnet (chain 4663).
 *
 *   MAINNET-ONLY BY CONSTRUCTION. Both venues exist on 4663 and nowhere else —
 *   `cast code` against the testnet (46630) Sushi address returns empty — so
 *   the testnet ceremony SKIPS this script entirely rather than deploying a
 *   template whose every clone would revert at init. Fork rehearsal happens on
 *   a 4663 fork via ROBINHOOD_FORK_CHAIN_ID.
 *
 *   WHY EVERY ADAPTER IN ONE SCRIPT: they are implementations of one
 *   interface serving one template, and an agent picks between them per
 *   proposal. Deploying them apart would let the template ship with only one
 *   venue certified, which reads to an agent as "the other pairs are broken"
 *   rather than "not yet approved".
 *
 *   THE PONS ADAPTER IS OPTIONAL HERE, and deliberately so. It deploys only
 *   when `chains/{id}.json` carries `PONS_LAUNCH_FACTORY_V2` and
 *   `PONS_LAUNCH_LOCKER_V2`; a book without them skips it with a printed note
 *   rather than aborting a ceremony whose other two venues are ready. Note
 *   also that the Pons venue is CLOSED on 4663 today — `launchEnabled()` is
 *   false and the whitelist is empty — so a deployed Pons adapter is INERT
 *   until Pons acts. The runbook prints exactly what to ask them for.
 *
 *   Prerequisites:
 *     - Core stack deployed (Deploy.s.sol) and StrategyFactory deployed.
 *     - UniswapSwapAdapter deployed (DeployPortfolioStrategy) — the template
 *       routes its asset->quote leg through an allowlisted `ISwapAdapter`.
 *     - chains/4663.json seeded with SUSHI_LAUNCHPAD_V1. Resolved venue
 *       addresses and their identity evidence live in addresses/4663.json.
 *
 *   Post-deploy, the REGISTRY OWNER must, and the runbook below prints it:
 *     - `setAdapterAllowed` + tier certification for EVERY adapter this run
 *       deployed (Gate A + Gate B, docs/adapter-onboarding-checklist.md).
 *     - `StrategyFactory.setTemplateApproval(LAUNCHPAD_TEMPLATE, true)`.
 *
 *   NO COUNTERPARTY ALLOWANCES ARE NEEDED for these venues, and that is a real
 *   difference rather than an omission: each adapter pins its venue in
 *   IMMUTABLES that the codehash gate already covers, whereas
 *   `ConcentratedLiquidityStrategy` takes its venue addresses from PROPOSER
 *   input and must allowlist them. A live end-to-end run confirmed launches
 *   execute with none set, so instructing the owner to set them would be
 *   ceremony that no code reads.
 *
 *   Record the printed `padSetHash` with the certification: the codehash gate
 *   pins the Stonk adapter's CODE, and that hash is the only on-chain witness
 *   of the lane CONFIGURATION the code was certified against.
 *
 *   Usage:
 *     forge script script/robinhood-mainnet/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 */
contract DeployLaunchpadStrategy is ScriptBase {
    /// @dev Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170).
    uint256 constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    function run() external {
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 4663 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"
        );

        address launchpad = _readAddress("SUSHI_LAUNCHPAD_V1");
        address weth = _readAddress("WETH");
        _assertIsSushiLaunchpad(launchpad, weth);

        // TOLERANT reads: the Pons keys are newer than this script's other
        // dependencies, and a book that predates them must skip the third
        // adapter rather than abort a ceremony whose two ready venues would
        // otherwise ship. `_assertIsPonsFactory` is what makes the skip safe to
        // be tolerant about — anything PRESENT is verified in full.
        address ponsFactory = _optionalAddress("PONS_LAUNCH_FACTORY_V2");
        address ponsLocker = _optionalAddress("PONS_LAUNCH_LOCKER_V2");
        if (ponsFactory == address(0) || ponsLocker == address(0)) {
            console.log("PONS_LAUNCH_FACTORY_V2 / PONS_LAUNCH_LOCKER_V2 absent - SKIPPING PonsLaunchAdapter.");
            console.log("  Seed both keys in chains/%s.json and re-run to deploy it.", vm.toString(block.chainid));
            ponsFactory = address(0);
        } else {
            _assertIsPonsFactory(ponsFactory, ponsLocker, weth);
        }

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood Chain (chain ID 4663)");

        SushiLaunchAdapter adapter = new SushiLaunchAdapter(launchpad);
        (address[] memory quotes, address[] memory pads) = _stonkLaneSet();
        StonkLaunchAdapter stonkAdapter = new StonkLaunchAdapter(quotes, pads, _readAddress("SAFE_LAUNCH_LENS_V2"));
        address ponsAdapter = ponsFactory == address(0) ? address(0) : address(new PonsLaunchAdapter(ponsFactory, weth));
        LaunchpadStrategy template = new LaunchpadStrategy();

        vm.stopBroadcast();

        uint256 size = address(template).code.length;
        console.log("Template runtime size:", size);
        require(size <= ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");

        _patchAddress("SUSHI_LAUNCH_ADAPTER", address(adapter));
        _patchAddress("STONK_LAUNCH_ADAPTER", address(stonkAdapter));
        if (ponsAdapter != address(0)) _patchAddress("PONS_LAUNCH_ADAPTER", ponsAdapter);
        _patchAddress("LAUNCHPAD_TEMPLATE", address(template));
        console.log("SushiLaunchAdapter:   ", address(adapter));
        console.log("StonkLaunchAdapter:   ", address(stonkAdapter));
        console.log("PonsLaunchAdapter:    ", ponsAdapter);
        console.log("LaunchpadStrategy:    ", address(template));
        console.log("StonkLaunchAdapter padSetHash:");
        console.logBytes32(stonkAdapter.padSetHash());

        _printRegistryRunbook(
            address(adapter), address(stonkAdapter), ponsAdapter, launchpad, ponsFactory, address(template)
        );
    }

    /// @dev The eight V2 (mint-launch) lanes, read from the address book.
    ///
    ///      MINT PADS ONLY. The V3 pads exist for EXTERNAL tokens — a launch
    ///      that brings its own ERC-20 — and this template always mints, so
    ///      serving a V3 lane would be dead configuration that still widened
    ///      the certified surface. A future BYO-token template gets its own
    ///      implementation and its own certification, which is exactly the
    ///      granularity `padSetHash` is designed to make checkable.
    ///
    ///      WHAT ACTUALLY CATCHES A MIS-FILED PAD, stated precisely because the
    ///      obvious answer is wrong. Since this function DERIVES `quotes[i]`
    ///      from `pads[i].quote()`, the adapter constructor's `PadQuoteMismatch`
    ///      compares a value against itself and can never fire from here. The
    ///      guard that does bite is `DuplicateQuote`: a pad filed under the
    ///      wrong lane key reports the quote of its REAL lane, collides with
    ///      that lane's own entry, and aborts the deploy. That is not
    ///      theoretical — it is how a transcribed USDG address was caught
    ///      during this change's address-book work.
    ///
    ///      `DuplicateQuote` only fires on a COLLISION, though, and a V3 pad
    ///      reports the same `quote()` as its V2 sibling — so a V3 pad filed
    ///      under a V2 key collides with nothing and would sail through, giving
    ///      this always-minting template a lane pointed at a bring-your-own-
    ///      token pad it can never use. Codehashes cannot separate the families
    ///      (every pad's differs, since its lane is an immutable), so the check
    ///      below is explicit: no chosen pad may be any V3 pad the book knows.
    function _stonkLaneSet() internal view returns (address[] memory quotes, address[] memory pads) {
        string[8] memory lanes = ["WETH", "STONK", "USDG", "GME", "NVDA", "AAPL", "SPCX", "USO"];
        quotes = new address[](8);
        pads = new address[](8);
        for (uint256 i; i < 8; ++i) {
            pads[i] = _readAddress(string.concat("STONK_SAFE_LAUNCHPAD_V2_", lanes[i]));
            // The pad is the authority on its own lane; the book only says
            // WHICH pad. Reading the quote off the pad keeps the two from
            // drifting.
            quotes[i] = IStonkSafeLaunchpadV2(pads[i]).quote();
            require(quotes[i] != address(0), "stonk pad reports no quote token");
        }
        _requireNoV3Pads(pads, lanes);
    }

    /// @dev Refuse any pad that the address book files as a V3 (external-token)
    ///      pad. See `_stonkLaneSet` for why `DuplicateQuote` cannot cover this
    ///      case. Compares against every V3 lane, not just the matching one, so
    ///      a V3 pad filed under a DIFFERENT lane's V2 key is caught too.
    function _requireNoV3Pads(address[] memory pads, string[8] memory lanes) internal view {
        for (uint256 j; j < 8; ++j) {
            address v3 = _optionalAddress(string.concat("STONK_SAFE_LAUNCHPAD_V3_", lanes[j]));
            if (v3 == address(0)) continue;
            for (uint256 i; i < 8; ++i) {
                require(pads[i] != v3, "a V3 (external-token) pad is filed under a V2 lane key");
            }
        }
    }

    /// @dev IDENTITY, NOT PRESENCE — the assertion this chain specifically
    ///      requires. `addresses/4663.json` records the hazard in full: the
    ///      canonical Uniswap mainnet addresses each hold ~2110 bytes of an
    ///      unrelated contract here, so `code.length != 0` passes on the WRONG
    ///      address and every later call fails in a way that reads as a bug in
    ///      our own code. A launchpad that is merely codeful would be approved,
    ///      the ceremony would complete, agents would write proposals, and each
    ///      one would revert at clone-init a governance cycle later.
    ///
    ///      The round trip below is what makes this cheap to check and hard to
    ///      fake: the venue names its own WETH, factory and position manager,
    ///      the position manager names a factory back, and the two must agree.
    ///      A squatter would have to reproduce the whole graph.
    function _assertIsSushiLaunchpad(address launchpad, address weth) internal view {
        require(launchpad != address(0), "SUSHI_LAUNCHPAD_V1 unset");
        require(launchpad.code.length != 0, "SUSHI_LAUNCHPAD_V1 holds no code");

        // READ THE FIRST HOP DEFENSIVELY, so the squatter case produces a
        // SENTENCE rather than a panic. A codeful-but-unrelated address (the
        // hazard `addresses/4663.json` records for this chain) has no `WETH()`,
        // and a typed call there aborts on an ABI-decode panic with no reason
        // string — an operator sees an opaque revert instead of being told the
        // address is not a launchpad. Every later hop is typed, because by then
        // the target has answered one launchpad-shaped question correctly.
        (bool ok, bytes memory ret) = launchpad.staticcall(abi.encodeCall(ISushiLaunchpad.WETH, ()));
        require(ok && ret.length == 32, "SUSHI_LAUNCHPAD_V1 does not answer WETH() - not a launchpad");
        require(abi.decode(ret, (address)) == weth, "launchpad WETH() disagrees with the address book");

        ISushiLaunchpad pad = ISushiLaunchpad(launchpad);

        address v3Factory = _readAddress("SUSHI_V3_FACTORY");
        address positionManager = _readAddress("SUSHI_V3_POSITION_MANAGER");
        require(pad.v3Factory() == v3Factory, "launchpad v3Factory() disagrees with SUSHI_V3_FACTORY");
        require(
            pad.positionManager() == positionManager,
            "launchpad positionManager() disagrees with SUSHI_V3_POSITION_MANAGER"
        );
        require(v3Factory.code.length != 0, "SUSHI_V3_FACTORY holds no code");
        require(positionManager.code.length != 0, "SUSHI_V3_POSITION_MANAGER holds no code");

        // The launchpad must still be able to price SOMETHING, or every launch
        // reverts `UnsupportedQuoteToken`. WETH is the lane we know is live;
        // WOOD is deliberately NOT required here (see the runbook note).
        require(pad.quoteTokenPriceFeed(weth) != address(0), "launchpad has no WETH quote feed");
    }

    /// @dev IDENTITY, NOT PRESENCE, for the Pons venue — the same hazard
    ///      `_assertIsSushiLaunchpad` exists for, answered with the graph this
    ///      venue makes available. Pons is TWO contracts that name each other,
    ///      so the round trip is cheap to check and hard to fake: the factory
    ///      must name the book's locker, and that locker must name the factory
    ///      back. A squatter would have to reproduce both halves.
    ///
    ///      THE CONFIG CHECK IS NOT DECORATION. `PonsLaunchAdapter`'s
    ///      constructor refuses a WETH that is not the `pairToken` of some
    ///      ENABLED launch config, so a venue with no live WETH pairing makes
    ///      the deploy revert with a constructor error instead of a sentence.
    ///      Asserting it here turns that into a legible failure, and also
    ///      catches the case that matters operationally: a venue that has
    ///      disabled the only pairing the template can use.
    function _assertIsPonsFactory(address ponsFactory, address ponsLocker, address weth) internal view {
        require(ponsFactory.code.length != 0, "PONS_LAUNCH_FACTORY_V2 holds no code");
        require(ponsLocker.code.length != 0, "PONS_LAUNCH_LOCKER_V2 holds no code");

        // READ THE FIRST HOP DEFENSIVELY, so the squatter case produces a
        // SENTENCE rather than a panic. A codeful-but-unrelated address has no
        // `locker()`, and a typed call there aborts on an ABI-decode panic with
        // no reason string. Every later hop is typed, because by then the
        // target has answered one Pons-shaped question correctly.
        (bool ok, bytes memory ret) = ponsFactory.staticcall(abi.encodeCall(IPonsLaunchFactory.locker, ()));
        require(ok && ret.length == 32, "PONS_LAUNCH_FACTORY_V2 does not answer locker() - not a Pons factory");
        require(abi.decode(ret, (address)) == ponsLocker, "factory locker() disagrees with PONS_LAUNCH_LOCKER_V2");
        require(
            IPonsLaunchLocker(ponsLocker).factory() == ponsFactory,
            "locker factory() disagrees with PONS_LAUNCH_FACTORY_V2"
        );

        IPonsLaunchFactory pons = IPonsLaunchFactory(ponsFactory);
        require(pons.launchConfigCount() != 0, "Pons factory has no launch configs");
        require(pons.dexConfigCount() != 0, "Pons factory has no dex configs");
        IPonsLaunchFactory.LaunchConfig memory config = pons.getLaunchConfig(0);
        require(config.pairToken == weth, "Pons launch config 0 does not pair against WETH");
        require(config.enabled, "Pons launch config 0 is disabled");
    }

    /// @dev Printed, not executed: these are REGISTRY-OWNER actions and the
    ///      deployer is not the owner on mainnet. `DeployConcentratedLiquidity
    ///      Strategy` asserts its counterparty precondition instead, because
    ///      that template is INERT without it — every clone reverts at init.
    ///      This one is different in a way worth stating: the adapter allowlist
    ///      is checked at clone-init too, so the same inertness applies, but
    ///      the registry writes here are for a template that does not exist
    ///      until this very script runs. Asserting a precondition about an
    ///      address the script itself is minting is impossible, so the runbook
    ///      is the honest form and the post-deploy reads below are how it is
    ///      verified.
    function _printRegistryRunbook(
        address adapter,
        address stonkAdapter,
        address ponsAdapter,
        address launchpad,
        address ponsFactory,
        address template
    ) internal view {
        // TOLERANT read: this script can legitimately run on a fork whose book
        // predates the core deploy, and a mandatory read would revert the whole
        // ceremony over a runbook printout.
        address registry = _optionalAddress("TIER_REGISTRY");
        console.log("");
        console.log("== REGISTRY OWNER RUNBOOK (not executed by this script) ==");
        console.log("1. TierRegistry.setAdapterAllowed(adapter, true)      ", adapter);
        console.log("2. Tier certification for that adapter (Gate A)       ", adapter);
        console.log("3. TierRegistry.setAdapterAllowed(stonkAdapter, true) ", stonkAdapter);
        console.log("4. Tier certification for that adapter (Gate A)       ", stonkAdapter);
        if (ponsAdapter != address(0)) {
            console.log("5. TierRegistry.setAdapterAllowed(ponsAdapter, true) ", ponsAdapter);
            console.log("6. Tier certification for that adapter (Gate A)      ", ponsAdapter);
        }
        // Numbered around the optional block above, so a skipped Pons deploy
        // does not leave a gap an operator reads as a missing step.
        console.log(
            ponsAdapter == address(0)
                ? "5. StrategyFactory.setTemplateApproval(template, true)"
                : "7. StrategyFactory.setTemplateApproval(template, true)",
            template
        );
        console.log("");
        console.log("NO counterparty allowances are needed for these venues. Each adapter");
        console.log("pins its venue in IMMUTABLES the codehash gate already covers, unlike a");
        console.log("template that takes venue addresses from proposer input. A live e2e run");
        console.log("confirmed launches execute with none set - listing them here would be");
        console.log("ceremony that no code reads. Venue:", launchpad);
        console.log("");
        console.log("== POST-DEPLOY VALIDATION READS ==");
        if (registry != address(0)) {
            console.log(
                "tierRegistry.isAdapterAllowed(adapter):     ", ITierRegistry(registry).isAdapterAllowed(adapter)
            );
            console.log(
                "tierRegistry.isAdapterAllowed(stonkAdapter):", ITierRegistry(registry).isAdapterAllowed(stonkAdapter)
            );
            if (ponsAdapter != address(0)) {
                console.log(
                    "tierRegistry.isAdapterAllowed(ponsAdapter): ",
                    ITierRegistry(registry).isAdapterAllowed(ponsAdapter)
                );
            }
        } else {
            console.log("TIER_REGISTRY unset in the address book - verify the two reads by hand");
        }
        console.log("");
        console.log("NOTE: quoteTokenPriceFeed(WOOD) is NOT required for this deploy.");
        console.log("      WOOD-paired launches revert UnsupportedQuoteToken until the");
        console.log("      Sushi owner registers a WOOD/USD aggregator; every other");
        console.log("      supported lane (WETH, USDG, stock tokens) works meanwhile,");
        console.log("      and the adapter needs no change when that feed lands.");

        if (ponsAdapter == address(0)) return;
        console.log("");
        console.log("***********************************************************************");
        console.log("*  ACTION REQUIRED AT PONS - THE PONS ADAPTER IS INERT UNTIL THEY ACT  *");
        console.log("***********************************************************************");
        console.log("PonsLaunchFactory.launchEnabled() is FALSE and the whitelist is empty,");
        console.log("so EVERY launch through this adapter reverts NotWhitelisted() at the");
        console.log("venue. Registry certification does NOT lift this - only Pons can.");
        console.log("");
        console.log("Give Pons THIS address to whitelist:");
        console.log("  PonsLaunchAdapter:", ponsAdapter);
        console.log("Either of these un-blocks it, from the Pons factory OWNER:");
        console.log("  setWhitelistedLauncher(<adapter above>, true)   <-- preferred, scoped");
        console.log("  setLaunchEnabled(true)                          <-- opens it publicly");
        console.log("Verify with:");
        console.log("  cast call <factory> 'whitelistedLaunchers(address)(bool)' <adapter>");
        console.log("The whitelist is PER-ADDRESS, which is why this adapter is a singleton:");
        console.log("a per-launch clone would need a new Pons approval for every fund.");
        console.log("Re-run the certification only after the whitelist read returns true.");
    }
}
