// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeploySherwood} from "../../script/Deploy.s.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";

/// @dev `_seedTierRegistry` and its three helpers are `internal` on the deploy
///      script, which is where they belong — this only lifts them into reach.
contract SeedHarness is DeploySherwood {
    function exposed_seedTierRegistry(address deployer, address tierRegistry) external {
        _seedTierRegistry(deployer, tierRegistry);
    }
}

/// @title Deploy.s.sol — the TierRegistry launch set
///
/// @notice Every strategy template refuses to initialize against an unattested
///         dependency, and a freshly-constructed `TierRegistry` attests nothing.
///         So a protocol deployed without this seeding step is complete,
///         validated, handed to the multisig — and cannot run a single
///         strategy. The first proposal reverts a governance cycle later with
///         `PriceSourceNotAllowed` / `MorphoNotAllowed` / `CounterpartyNotAllowed`,
///         each of which names a ROLE rather than the missing deploy step.
///
/// @dev    These attestations are `onlyOwner`, so they are only writable in the
///         window before the multisig handoff. That ordering is the thing most
///         at risk from a later refactor — `test_seed_isSkippedOnceOwnershipHasMoved`
///         is what fails if the seed call migrates below the handoff.
///
///         Fixed to chain 4663 on purpose: the seeding walks `chains/4663.json`,
///         so this reads the REAL Robinhood address book rather than a staged
///         fixture, and a key renamed or dropped there breaks this test.
contract DeployTierRegistrySeedTest is Test {
    SeedHarness internal harness;
    TierRegistry internal registry;

    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");

    // Verified live on Robinhood Chain mainnet; mirrors chains/4663.json.
    address constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant UNISWAP_V3_POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant CHAINLINK_TSLA_USD_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant CHAINLINK_ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    function setUp() public {
        vm.chainId(4663);
        harness = new SeedHarness();
        // The registry's owner must be whoever actually makes the nested
        // `setAdapterAllowed` call. Under `vm.broadcast` that is the deployer
        // EOA; in this harness it is the harness contract. Pranking the entry
        // call would NOT carry into the nested one, so the owner is bound to
        // the harness and `deployer` below is its stand-in.
        deployer = address(harness);
        registry = new TierRegistry(deployer);
    }

    function _seed() internal {
        harness.exposed_seedTierRegistry(deployer, address(registry));
    }

    // ── The three dependency axes, one test each ──

    /// @dev `ConcentratedLiquidityStrategy._initialize` binds all three through
    ///      `_requireAllowedCounterparty`. The deploy script only ever asserted
    ///      the factory, so the position manager and Morpho were the two that
    ///      would have failed at clone-init with the ceremony already complete.
    function test_seed_attestsEveryCounterpartyTheCLTemplateBinds() public {
        assertFalse(registry.isCounterpartyAllowed(UNISWAP_V3_FACTORY), "factory attested before seeding");
        assertFalse(registry.isCounterpartyAllowed(UNISWAP_V3_POSITION_MANAGER), "posm attested before seeding");
        assertFalse(registry.isCounterpartyAllowed(MORPHO_BLUE), "morpho attested before seeding");

        _seed();

        assertTrue(registry.isCounterpartyAllowed(UNISWAP_V3_FACTORY), "uniswap v3 factory not attested");
        assertTrue(registry.isCounterpartyAllowed(UNISWAP_V3_POSITION_MANAGER), "position manager not attested");
        assertTrue(registry.isCounterpartyAllowed(MORPHO_BLUE), "morpho not attested as counterparty");
    }

    /// @dev Morpho needs BOTH axes and they are different questions:
    ///      `isCounterpartyAllowed` says a template may bind it,
    ///      `isAdapterAllowed` says vault funds may be spent into it.
    ///      `MorphoSupplyStrategy._requireAllowedMorpho` reads the adapter axis.
    function test_seed_attestsMorphoOnTheAdapterAxisToo() public {
        assertFalse(registry.isAdapterAllowed(MORPHO_BLUE), "morpho adapter-attested before seeding");
        _seed();
        assertTrue(registry.isAdapterAllowed(MORPHO_BLUE), "morpho not attested as adapter");
    }

    /// @dev The encoding is the whole test. `PortfolioStrategy._initialize`
    ///      normalizes a push feed to the BARE aggregator address widened to
    ///      bytes32 — max-age stripped — before calling
    ///      `_requirePairedPriceSource`. An attestation stored under any other
    ///      encoding is never consulted, so the seeding would look complete on
    ///      chain and still leave every Portfolio clone reverting.
    function test_seed_pairsFeedsUnderTheEncodingTheStrategyActuallyQueries() public {
        _seed();

        assertTrue(registry.isAdapterAllowed(CHAINLINK_TSLA_USD_FEED), "TSLA feed not allowlisted");
        assertTrue(
            registry.isPriceSourceForToken(TSLA, bytes32(uint256(uint160(CHAINLINK_TSLA_USD_FEED)))),
            "TSLA feed not paired to TSLA under the bare-address encoding"
        );

        // A packed max-age is a DIFFERENT bytes32 and must not be what got
        // stored — this is the mutant the encoding comment warns about.
        bytes32 packed = bytes32((uint256(6 hours) << 160) | uint256(uint160(CHAINLINK_TSLA_USD_FEED)));
        assertFalse(registry.isPriceSourceForToken(TSLA, packed), "attestation stored under a packed-age encoding");
    }

    /// @dev ETH is the one symbol whose feed does not price a token of the same
    ///      name — the book's token key is WETH. A naive `symbol -> symbol`
    ///      lookup silently drops this pairing, and WETH is the asset most
    ///      Portfolio baskets route through.
    function test_seed_pairsTheEthFeedToWrappedEth() public {
        _seed();
        assertTrue(
            registry.isPriceSourceForToken(WETH, bytes32(uint256(uint160(CHAINLINK_ETH_USD_FEED)))),
            "ETH/USD feed not paired to WETH"
        );
    }

    // ── The ordering constraint ──

    /// @dev The seed writes are `onlyOwner`. If a refactor moves the call below
    ///      `_handoffOwnership`, every write reverts — so the script checks
    ///      ownership first and degrades to a runbook line instead of aborting
    ///      a deploy that has already broadcast. This pins that it NOTICES,
    ///      rather than seeding into a registry it no longer controls.
    function test_seed_isSkippedOnceOwnershipHasMoved() public {
        vm.prank(deployer);
        registry.transferOwnership(multisig);
        vm.prank(multisig);
        registry.acceptOwnership();

        // Must not revert — a post-handoff deploy still completes.
        _seed();

        assertFalse(registry.isCounterpartyAllowed(UNISWAP_V3_FACTORY), "seeded a registry it no longer owns");
        assertFalse(registry.isAdapterAllowed(MORPHO_BLUE), "seeded a registry it no longer owns");
    }

    /// @dev Ownable2Step: `transferOwnership` alone only sets `pendingOwner`,
    ///      so the deployer is still owner and seeding still works. This is
    ///      what makes the documented runbook order legal — core deploy, then
    ///      the strategy scripts seeding their own freshly-minted addresses,
    ///      and only then the multisig's `acceptOwnership()`.
    function test_seed_stillWorksWhileTheHandoffIsMerelyPending() public {
        vm.prank(deployer);
        registry.transferOwnership(multisig);

        _seed();

        assertEq(registry.pendingOwner(), multisig, "handoff not pending");
        assertEq(registry.owner(), deployer, "handoff completed without acceptOwnership");
        assertTrue(registry.isCounterpartyAllowed(UNISWAP_V3_FACTORY), "pending handoff blocked seeding");
    }

    // ── Chains without the entries ──

    /// @dev The address book is a different shape on every chain. A chain with
    ///      no book at all must not abort the deploy — it gets no attestations
    ///      and says so.
    function test_seed_isInertOnAChainWithNoAddressBook() public {
        vm.chainId(31337);
        _seed();
        assertFalse(registry.isCounterpartyAllowed(UNISWAP_V3_FACTORY), "attested from a nonexistent book");
        assertFalse(registry.isAdapterAllowed(MORPHO_BLUE), "attested from a nonexistent book");
    }
}
