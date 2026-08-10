// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {GovernorBeacon} from "../src/GovernorBeacon.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {VaultWithdrawalQueue} from "../src/queue/VaultWithdrawalQueue.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockL2Registrar} from "./mocks/MockL2Registrar.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {FeeConstants} from "../src/FeeConstants.sol";

contract SyndicateFactoryTest is Test {
    SyndicateFactory public factory;
    BatchExecutorLib public executorLib;
    SyndicateVault public vaultImpl;
    ERC20Mock public usdc;
    MockL2Registrar public ensRegistrar;
    MockAgentRegistry public agentRegistry;

    address public owner = makeAddr("owner");
    address public creator1 = makeAddr("creator1");
    address public creator2 = makeAddr("creator2");
    address public governorAddr = makeAddr("governor");
    address public guardianRegistryAddr = makeAddr("guardianRegistry");
    // Post-split: the factory resolves sWOOD via `registry.swood()` then calls
    // `canCreateVault` / `bindOwnerStake` on sWOOD. Mock both indirections.
    address public swoodAddr = makeAddr("swood");
    /// @dev Mandatory `InitParams.tierRegistry` (pashov finding #1). Held as a
    ///      field so the re-init negative tests can reuse it.
    TierRegistry public tierRegistryFixture;

    uint256 public creator1AgentId;
    uint256 public creator2AgentId;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        vaultImpl = new SyndicateVault();
        ensRegistrar = new MockL2Registrar();
        agentRegistry = new MockAgentRegistry();

        // Per-vault governor: the factory deploys a BeaconProxy governor per
        // vault at createSyndicate, so wire a real beacon + ProtocolConfig.
        ProtocolConfig protocolCfg = new ProtocolConfig(owner);
        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        GovernorBeacon beacon = new GovernorBeacon(address(govImpl), owner);

        // Mandatory `InitParams` field (pashov finding #1).
        tierRegistryFixture = new TierRegistry(owner);

        // Deploy factory as UUPS proxy
        SyndicateFactory factoryImpl = new SyndicateFactory();
        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    ensRegistrar: address(ensRegistrar),
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(protocolCfg),
                    managementFeeBps: 50,
                    guardianRegistry: guardianRegistryAddr,
                    tierRegistry: address(tierRegistryFixture)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        // Mint ERC-8004 identity NFTs for creators
        creator1AgentId = agentRegistry.mint(creator1);
        creator2AgentId = agentRegistry.mint(creator2);

        // The factory calls `registry.addGovernor(govProxy)` inside createSyndicate;
        // the registry is a mock here, so stub it. The per-vault governor is
        // deployed for real and answers getActiveProposal()/openProposalCount()
        // itself (0 when idle), so no governor mocks are needed.
        vm.mockCall(guardianRegistryAddr, abi.encodeWithSelector(IGuardianRegistry.addGovernor.selector), "");
        // Task 26 + sWOOD split: the factory reads `registry.swood()` then
        // calls `canCreateVault` / `bindOwnerStake` on sWOOD. Mock the
        // registry → sWOOD hop plus the two sWOOD calls.
        vm.mockCall(
            guardianRegistryAddr, abi.encodeWithSelector(IGuardianRegistry.swood.selector), abi.encode(swoodAddr)
        );
        vm.mockCall(swoodAddr, abi.encodeWithSelector(IStakedWood.canCreateVault.selector), abi.encode(true));
        vm.mockCall(swoodAddr, abi.encodeWithSelector(IStakedWood.bindOwnerStake.selector), "");
    }

    function _defaultConfig() internal view returns (SyndicateFactory.SyndicateConfig memory) {
        return SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://QmTest",
            asset: usdc,
            name: "Test Vault",
            symbol: "tVault",
            openDeposits: false,
            subdomain: "test-syndicate"
        });
    }

    function _configWithSubdomain(string memory subdomain_)
        internal
        view
        returns (SyndicateFactory.SyndicateConfig memory)
    {
        SyndicateFactory.SyndicateConfig memory cfg = _defaultConfig();
        cfg.subdomain = subdomain_;
        return cfg;
    }

    // ==================== CREATION ====================

    function test_createSyndicate() public {
        vm.prank(creator1);
        (uint256 id, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        assertEq(id, 1);
        assertTrue(vaultAddr != address(0));

        // Verify vault is initialized
        SyndicateVault vault = SyndicateVault(payable(vaultAddr));
        assertEq(vault.name(), "Test Vault");
        assertEq(vault.symbol(), "tVault");
        assertEq(vault.owner(), creator1);
        assertEq(address(vault.asset()), address(usdc));
        // _executorImpl getter was dropped to free EIP-170 budget; verifying
        // the slot via vm.load is sufficient for this round-trip check.
        assertEq(address(uint160(uint256(vm.load(address(vault), bytes32(uint256(3)))))), address(executorLib));
    }

    /// @notice A freshly created vault's governor starts at the advertised 20%
    ///         headline, not at the 30% protocol ceiling. The settle-time clamp
    ///         resolves an over-ceiling rate silently, so a permissive default
    ///         would let an owner quietly charge above the headline; this must
    ///         fail closed instead. Leaving it at the old 1500 would be the
    ///         opposite failure — every new vault silently clamped below the
    ///         headline at settle.
    function test_createSyndicate_governorDefaultsToTheHeadlinePerformanceFeeCeiling() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        ISyndicateGovernor governor = ISyndicateGovernor(factory.governorOf(vaultAddr));
        uint256 perVaultCeiling = governor.getGovernorParams().maxPerformanceFeeBps;

        assertEq(
            perVaultCeiling, FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS, "new vault should start at the headline"
        );
        assertEq(perVaultCeiling, 2000, "the headline is 20%");
        assertLt(perVaultCeiling, FeeConstants.MAX_PERFORMANCE_FEE_BPS, "the default must sit below the ceiling");
    }

    /// @notice F4 — a reverting registrar `available()` view must NOT brick
    ///         vault creation. PR #359 #7 wrapped `register()` in try/catch but
    ///         left the `available()` pre-check unguarded, so a paused / non-
    ///         conforming registrar still reverted the whole `createSyndicate`.
    ///         The syndicate must come up ENS-less instead.
    function test_createSyndicate_succeedsWhenRegistrarAvailableReverts() public {
        ensRegistrar.setRevertOnAvailable(true);

        vm.prank(creator1);
        (uint256 id, address vaultAddr) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("ens-fault"));

        assertEq(id, 1, "syndicate still created");
        assertTrue(vaultAddr != address(0), "vault created despite reverting registrar available()");
        assertFalse(ensRegistrar.isRegistered("ens-fault"), "ENS skipped when available() faults");
    }

    function test_createSyndicate_notAgentOwner_reverts() public {
        // creator2 tries to use creator1's agent ID
        vm.prank(creator2);
        vm.expectRevert(SyndicateFactory.NotAgentOwner.selector);
        factory.createSyndicate(creator1AgentId, _defaultConfig());
    }

    /// @notice The factory's `canCreateVault` gate reverts `PreparedStakeNotFound`
    ///         when sWOOD reports the creator is ineligible (e.g. `minOwnerStake
    ///         > 0` and they never prepared). This fires BEFORE `bindOwnerStake`,
    ///         so the zero-bond relaxation inside `bindOwnerStake` does not weaken
    ///         the bonded-onboarding path.
    function test_createSyndicate_revertsWhenNoPreparedStake() public {
        // Override the setUp mock: sWOOD says this creator cannot create.
        vm.mockCall(swoodAddr, abi.encodeWithSelector(IStakedWood.canCreateVault.selector), abi.encode(false));

        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.PreparedStakeNotFound.selector);
        factory.createSyndicate(creator1AgentId, _defaultConfig());
    }

    function test_createSyndicate_registryTracking() public {
        vm.prank(creator1);
        (uint256 id1, address vault1) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        assertEq(factory.syndicateCount(), 1);
        assertEq(factory.vaultToSyndicate(vault1), id1);

        (uint256 storedId, address storedVault, address storedCreator,,,, string memory storedSubdomain) =
            factory.syndicates(id1);
        assertEq(storedId, id1);
        assertEq(storedVault, vault1);
        assertEq(storedCreator, creator1);
        assertEq(storedSubdomain, "test-syndicate");
    }

    function test_createMultipleSyndicates() public {
        vm.prank(creator1);
        (uint256 id1, address vault1) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("syndicate-one"));

        vm.prank(creator2);
        (uint256 id2, address vault2) = factory.createSyndicate(creator2AgentId, _configWithSubdomain("syndicate-two"));

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertTrue(vault1 != vault2);
        assertEq(factory.syndicateCount(), 2);

        // Both share same executor lib
        // _executorImpl slot 3 — getter was dropped to free EIP-170 budget.
        assertEq(address(uint160(uint256(vm.load(vault1, bytes32(uint256(3)))))), address(executorLib));
        assertEq(address(uint160(uint256(vm.load(vault2, bytes32(uint256(3)))))), address(executorLib));
    }

    function test_syndicateVaultIsFullyFunctional() public {
        // Create syndicate
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());
        SyndicateVault vault = SyndicateVault(payable(vaultAddr));

        // Register agent (mint agent NFT for the agent address)
        address agent = makeAddr("agent");
        uint256 agentNftId = agentRegistry.mint(agent);
        vm.prank(creator1);
        vault.registerAgent(agentNftId, agent);

        // Approve LP as depositor (vault has openDeposits=false)
        address lp = makeAddr("lp");
        vm.prank(creator1);
        vault.approveDepositor(lp);

        // LP deposits
        usdc.mint(lp, 50_000e6);
        vm.startPrank(lp);
        usdc.approve(vaultAddr, 50_000e6);
        vault.deposit(50_000e6, lp);
        vm.stopPrank();

        // The fixture now wires a real TierRegistry (pashov finding #1), so the
        // vault's spender gate is LIVE rather than skipped — allowlist the
        // approve target the way a real deployment would.
        address _owner = factory.owner();
        TierRegistry _reg = TierRegistry(factory.tierRegistry());
        address _protocolSpender = makeAddr("protocol");
        vm.prank(_owner);
        _reg.setAdapterAllowed(_protocolSpender, true);

        // Governor executes batch (strategy-style approve — onlyGovernor after V-C3)
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (makeAddr("protocol"), 1_000e6)), value: 0
        });

        vm.prank(factory.governorOf(vaultAddr));
        vault.executeGovernorBatch(calls, new uint256[](0), type(uint256).max);

        // Verify: vault set the approval (delegatecall)
        assertEq(usdc.allowance(vaultAddr, makeAddr("protocol")), 1_000e6);
    }

    function test_storageIsolation() public {
        // Create two syndicates
        vm.prank(creator1);
        (, address vault1Addr) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("vault-alpha"));
        vm.prank(creator2);
        (, address vault2Addr) = factory.createSyndicate(creator2AgentId, _configWithSubdomain("vault-beta"));

        SyndicateVault vault1 = SyndicateVault(payable(vault1Addr));
        SyndicateVault vault2 = SyndicateVault(payable(vault2Addr));

        // Register different agents on each (mint NFTs for agents)
        address agent1 = makeAddr("agent1");
        address agent2 = makeAddr("agent2");
        uint256 agent1NftId = agentRegistry.mint(agent1);
        uint256 agent2NftId = agentRegistry.mint(agent2);

        vm.prank(creator1);
        vault1.registerAgent(agent1NftId, agent1);
        vm.prank(creator2);
        vault2.registerAgent(agent2NftId, agent2);

        // Agent1 is only on vault1
        assertTrue(vault1.isAgent(agent1));
        assertFalse(vault2.isAgent(agent1));

        // Agent2 is only on vault2
        assertFalse(vault1.isAgent(agent2));
        assertTrue(vault2.isAgent(agent2));
    }

    // ==================== ENS SUBDOMAINS ====================

    function test_createSyndicate_registersENS() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("alpha-seekers"));

        // Verify the registrar received the correct label + vault address
        assertTrue(ensRegistrar.isRegistered("alpha-seekers"));
        assertEq(ensRegistrar.getOwner("alpha-seekers"), vaultAddr);
    }

    function test_createSyndicate_duplicateName_reverts() public {
        vm.prank(creator1);
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("taken-name"));

        vm.prank(creator2);
        vm.expectRevert(SyndicateFactory.SubdomainTaken.selector);
        factory.createSyndicate(creator2AgentId, _configWithSubdomain("taken-name"));
    }

    function test_createSyndicate_nameTooShort_reverts() public {
        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.SubdomainTooShort.selector);
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("ab"));
    }

    function test_subdomainToSyndicate() public {
        vm.prank(creator1);
        (uint256 id,) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("my-fund"));

        assertEq(factory.subdomainToSyndicate("my-fund"), id);
        assertEq(factory.subdomainToSyndicate("nonexistent"), 0);
    }

    function test_isSubdomainAvailable() public {
        assertTrue(factory.isSubdomainAvailable("new-fund"));

        vm.prank(creator1);
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("new-fund"));

        assertFalse(factory.isSubdomainAvailable("new-fund"));
    }

    function test_isSubdomainAvailable_tooShort() public view {
        assertFalse(factory.isSubdomainAvailable("ab"));
    }

    // ==================== METADATA ====================

    function test_updateMetadata() public {
        vm.prank(creator1);
        (uint256 id,) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        vm.prank(creator1);
        factory.updateMetadata(id, "ipfs://QmUpdated");

        (,,, string memory uri,,,) = factory.syndicates(id);
        assertEq(uri, "ipfs://QmUpdated");
    }

    function test_updateMetadata_notCreator_reverts() public {
        vm.prank(creator1);
        (uint256 id,) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        vm.prank(creator2);
        vm.expectRevert(SyndicateFactory.NotCreator.selector);
        factory.updateMetadata(id, "ipfs://QmHack");
    }

    // ==================== DEACTIVATION ====================

    function test_deactivate() public {
        vm.prank(creator1);
        (uint256 id,) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        vm.prank(creator1);
        factory.deactivate(id);

        (,,,,, bool active,) = factory.syndicates(id);
        assertFalse(active);
    }

    function test_deactivate_notCreator_reverts() public {
        vm.prank(creator1);
        (uint256 id,) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        vm.prank(creator2);
        vm.expectRevert(SyndicateFactory.NotCreator.selector);
        factory.deactivate(id);
    }

    function test_getActiveSyndicates() public {
        vm.startPrank(creator1);
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-aaa"));
        (uint256 id2,) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-bbb"));
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-ccc"));

        // Deactivate #2
        factory.deactivate(id2);
        vm.stopPrank();

        (SyndicateFactory.Syndicate[] memory active, uint256 total) = factory.getActiveSyndicates(0, 100);
        assertEq(active.length, 2);
        assertEq(total, 2);
    }

    function test_getActiveSyndicates_pagination() public {
        // Create 5 syndicates, deactivate #3
        vm.startPrank(creator1);
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-001"));
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-002"));
        (uint256 id3,) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-003"));
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-004"));
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-005"));
        factory.deactivate(id3);
        vm.stopPrank();

        // 4 active syndicates total

        // Page 1: offset=0, limit=2
        (SyndicateFactory.Syndicate[] memory page1, uint256 total1) = factory.getActiveSyndicates(0, 2);
        assertEq(page1.length, 2);
        assertEq(total1, 4);

        // Page 2: offset=2, limit=2
        (SyndicateFactory.Syndicate[] memory page2, uint256 total2) = factory.getActiveSyndicates(2, 2);
        assertEq(page2.length, 2);
        assertEq(total2, 4);

        // Page 3: offset=4, limit=2 — beyond total
        (SyndicateFactory.Syndicate[] memory page3, uint256 total3) = factory.getActiveSyndicates(4, 2);
        assertEq(page3.length, 0);
        assertEq(total3, 4);

        // Limit larger than remaining
        (SyndicateFactory.Syndicate[] memory big, uint256 totalBig) = factory.getActiveSyndicates(1, 100);
        assertEq(big.length, 3);
        assertEq(totalBig, 4);
    }

    function test_getActiveSyndicates_offsetBeyondTotal() public {
        vm.startPrank(creator1);
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-only"));
        vm.stopPrank();

        (SyndicateFactory.Syndicate[] memory result, uint256 total) = factory.getActiveSyndicates(5, 10);
        assertEq(result.length, 0);
        assertEq(total, 1);
    }

    function test_getAllActiveSyndicates() public {
        vm.startPrank(creator1);
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-aaa"));
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("fund-bbb"));
        vm.stopPrank();

        SyndicateFactory.Syndicate[] memory all = factory.getAllActiveSyndicates();
        assertEq(all.length, 2);
    }

    // ==================== CREATION FEE ====================

    function test_creationFee_blocksWithoutPayment() public {
        // Owner sets creation fee
        vm.prank(owner);
        factory.setCreationFee(address(usdc), 100e6, owner);

        // Creator tries without approval → reverts
        vm.prank(creator1);
        vm.expectRevert();
        factory.createSyndicate(creator1AgentId, _defaultConfig());
    }

    function test_creationFee_collectsPayment() public {
        vm.prank(owner);
        factory.setCreationFee(address(usdc), 100e6, owner);

        // Fund creator and approve
        usdc.mint(creator1, 100e6);
        vm.startPrank(creator1);
        usdc.approve(address(factory), 100e6);
        (uint256 id, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());
        vm.stopPrank();

        assertEq(id, 1);
        assertTrue(vaultAddr != address(0));
        assertEq(usdc.balanceOf(owner), 100e6); // fee recipient got paid
        assertEq(usdc.balanceOf(creator1), 0); // creator paid
    }

    function test_creationFee_freeWhenZero() public {
        // Default: no fee set, creation works
        vm.prank(creator1);
        (uint256 id,) = factory.createSyndicate(creator1AgentId, _defaultConfig());
        assertEq(id, 1);
    }

    function test_creationFee_onlyOwner() public {
        vm.prank(creator1);
        vm.expectRevert();
        factory.setCreationFee(address(usdc), 100e6, owner);
    }

    // ==================== V-H1: ATOMIC PROXY INITIALIZE ====================

    /// @notice V-H1 regression: deploying the factory proxy with atomic init data
    ///         (ERC1967Proxy(impl, encodedInitCall)) is the ONLY path our deploy
    ///         scripts use. This test asserts that once the proxy is deployed
    ///         atomically, `initialize` can never be called a second time — so
    ///         no attacker can front-run the owner slot even if they watch the
    ///         proxy creation tx.
    /// @dev    Under a non-atomic deploy (empty init data), any caller could
    ///         initialize the proxy first. Our scripts never do this; see
    ///         `contracts/script/Deploy.s.sol`, `script/testnet/Deploy.s.sol`,
    ///         `script/robinhood-testnet/Deploy.s.sol` — each encodes the init
    ///         call into the proxy constructor as a single tx.
    function test_factoryInitialize_atomicProxy_cannotBeReinitialized() public {
        // The `factory` in setUp was deployed via atomic init. Attempt to
        // re-initialize as an attacker — must revert with OZ's InvalidInitialization.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(); // Initializable: contract is already initialized
        factory.initialize(
            SyndicateFactory.InitParams({
                owner: attacker,
                executorImpl: address(executorLib),
                vaultImpl: address(vaultImpl),
                ensRegistrar: address(ensRegistrar),
                agentRegistry: address(agentRegistry),
                beacon: governorAddr,
                protocolConfig: governorAddr,
                managementFeeBps: 50,
                guardianRegistry: guardianRegistryAddr,
                tierRegistry: address(tierRegistryFixture)
            })
        );

        // Owner slot untouched by the reinit attempt.
        assertEq(factory.owner(), owner);
    }

    /// @notice V-H1 regression: the implementation contract itself has
    ///         `_disableInitializers()` in its constructor, so `initialize`
    ///         on the raw impl reverts regardless of who calls it.
    function test_factoryInitialize_implementation_initializersDisabled() public {
        SyndicateFactory rawImpl = new SyndicateFactory();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(); // InvalidInitialization
        rawImpl.initialize(
            SyndicateFactory.InitParams({
                owner: attacker,
                executorImpl: address(executorLib),
                vaultImpl: address(vaultImpl),
                ensRegistrar: address(ensRegistrar),
                agentRegistry: address(agentRegistry),
                beacon: governorAddr,
                protocolConfig: governorAddr,
                managementFeeBps: 50,
                guardianRegistry: guardianRegistryAddr,
                tierRegistry: address(tierRegistryFixture)
            })
        );
    }

    // ==================== V-H3: upgradeVault expectedImpl ====================

    /// @notice V-H3 regression: if the factory owner calls `setVaultImpl`
    ///         between the creator observing `vaultImpl` and calling
    ///         `upgradeVault`, the creator must not end up on a different
    ///         impl than they expected.
    function test_upgradeVault_revertsIfImplChanged() public {
        // Create syndicate
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        // Owner enables upgrades and snapshots the current impl.
        vm.prank(owner);
        factory.setUpgradesEnabled(true);
        address expected = factory.vaultImpl();

        // Owner rotates the vault impl (front-run scenario).
        SyndicateVault newImpl = new SyndicateVault();
        vm.prank(owner);
        factory.setVaultImpl(address(newImpl));

        // Creator calls upgradeVault with the previously-observed impl -> revert.
        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.VaultImplMismatch.selector);
        factory.upgradeVault(vaultAddr, expected);
    }

    /// @notice V-H3 positive path: upgradeVault succeeds when expectedImpl
    ///         matches the factory's current vaultImpl.
    function test_upgradeVault_succeedsWithCurrentImpl() public {
        // Create syndicate
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        // Enable upgrades, rotate to a new impl
        vm.prank(owner);
        factory.setUpgradesEnabled(true);
        SyndicateVault newImpl = new SyndicateVault();
        vm.prank(owner);
        factory.setVaultImpl(address(newImpl));

        // Creator passes the now-current impl -> succeeds.
        vm.prank(creator1);
        factory.upgradeVault(vaultAddr, address(newImpl));
    }

    // ==================== V-H2: GOVERNOR IS SET-ONCE ====================

    /// @notice V-H2 regression: `setGovernor` was removed. The selector must
    ///         not exist on the factory — any low-level call reverts with
    ///         empty return data. This guarantees the factory owner can
    ///         never instantly rewire every registered vault's governor.
    function test_setGovernor_removed() public {
        // setGovernor(address) selector: keccak256("setGovernor(address)")[:4]
        bytes4 sel = bytes4(keccak256("setGovernor(address)"));

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        (bool okAttacker, bytes memory retAttacker) =
            address(factory).call(abi.encodeWithSelector(sel, makeAddr("newGovernor")));
        assertFalse(okAttacker, "setGovernor must not exist (attacker)");
        assertEq(retAttacker.length, 0, "expected empty revert data (fn does not exist)");

        // Even the owner cannot call it.
        vm.prank(owner);
        (bool okOwner, bytes memory retOwner) =
            address(factory).call(abi.encodeWithSelector(sel, makeAddr("newGovernor")));
        assertFalse(okOwner, "setGovernor must not exist (owner)");
        assertEq(retOwner.length, 0, "expected empty revert data (fn does not exist)");

        // Per-vault model: the factory has no governor slot at all (governors
        // are per-vault BeaconProxies). The selector-absence checks above are
        // the regression guard; nothing further to assert here.
    }

    // ==================== V-M7: SyndicateConfig validation ====================

    /// @notice V-M7 regression: `createSyndicate` must reject a config whose
    ///         `asset` is zero before any side effects (stake bind, ENS
    ///         register, vault deploy). Consolidated under
    ///         `InvalidSyndicateConfig`.
    function test_createSyndicate_revertsIfAssetZero() public {
        SyndicateFactory.SyndicateConfig memory cfg = _defaultConfig();
        cfg.asset = ERC20Mock(address(0));

        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.InvalidSyndicateConfig.selector);
        factory.createSyndicate(creator1AgentId, cfg);
    }

    /// @notice V-M7: empty vault token name is rejected.
    function test_createSyndicate_revertsIfNameEmpty() public {
        SyndicateFactory.SyndicateConfig memory cfg = _defaultConfig();
        cfg.name = "";

        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.InvalidSyndicateConfig.selector);
        factory.createSyndicate(creator1AgentId, cfg);
    }

    /// @notice V-M7: empty vault token symbol is rejected.
    function test_createSyndicate_revertsIfSymbolEmpty() public {
        SyndicateFactory.SyndicateConfig memory cfg = _defaultConfig();
        cfg.symbol = "";

        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.InvalidSyndicateConfig.selector);
        factory.createSyndicate(creator1AgentId, cfg);
    }

    /// @notice V-M7: empty subdomain is rejected with `InvalidSyndicateConfig`
    ///         (the existing `SubdomainTooShort` guard is checked later; the
    ///         zero-length case is caught first by the consolidated V-M7
    ///         check, which is what we want to assert here).
    function test_createSyndicate_revertsIfSubdomainEmpty() public {
        SyndicateFactory.SyndicateConfig memory cfg = _defaultConfig();
        cfg.subdomain = "";

        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.InvalidSyndicateConfig.selector);
        factory.createSyndicate(creator1AgentId, cfg);
    }

    /// @notice V-M7: empty metadataURI is rejected — a deployed vault with
    ///         no IPFS pointer is not a real syndicate.
    function test_createSyndicate_revertsIfMetadataUriEmpty() public {
        SyndicateFactory.SyndicateConfig memory cfg = _defaultConfig();
        cfg.metadataURI = "";

        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.InvalidSyndicateConfig.selector);
        factory.createSyndicate(creator1AgentId, cfg);
    }

    // ==================== V-C4: EnumerableSet pagination ====================

    /// @notice V-C4 regression: getActiveSyndicates is backed by an
    ///         EnumerableSet so reads are O(limit) instead of O(syndicateCount),
    ///         the per-call limit is hard-capped at MAX_PAGE_LIMIT, and
    ///         deactivated syndicates do not appear in the active set.
    function test_getActiveSyndicates_paginated() public {
        // Create 150 syndicates with unique subdomains
        vm.startPrank(creator1);
        for (uint256 i = 0; i < 150; i++) {
            factory.createSyndicate(creator1AgentId, _configWithSubdomain(string.concat("fund-", vm.toString(i))));
        }

        // Deactivate a handful (ids 10, 50, 100 — 1-indexed).
        factory.deactivate(10);
        factory.deactivate(50);
        factory.deactivate(100);
        vm.stopPrank();

        // 147 active total.
        (, uint256 total) = factory.getActiveSyndicates(0, 1);
        assertEq(total, 147, "total should reflect deactivations");

        // Hard cap: request 200, get at most MAX_PAGE_LIMIT (100).
        (SyndicateFactory.Syndicate[] memory firstPage, uint256 total2) = factory.getActiveSyndicates(0, 200);
        assertEq(firstPage.length, 100, "limit clamped to MAX_PAGE_LIMIT");
        assertEq(total2, 147);

        // No deactivated syndicate appears in the page.
        for (uint256 i = 0; i < firstPage.length; i++) {
            assertTrue(firstPage[i].active, "only active syndicates should be returned");
            assertTrue(
                firstPage[i].id != 10 && firstPage[i].id != 50 && firstPage[i].id != 100,
                "deactivated id leaked into results"
            );
        }

        // Second page (offset 100). 47 remaining.
        (SyndicateFactory.Syndicate[] memory secondPage,) = factory.getActiveSyndicates(100, 100);
        assertEq(secondPage.length, 47, "remaining rows after offset");

        // Offset beyond total returns empty.
        (SyndicateFactory.Syndicate[] memory empty,) = factory.getActiveSyndicates(200, 10);
        assertEq(empty.length, 0);

        // getAllActiveSyndicates also clamps to MAX_PAGE_LIMIT.
        SyndicateFactory.Syndicate[] memory all = factory.getAllActiveSyndicates();
        assertEq(all.length, 100, "getAllActiveSyndicates clamped to MAX_PAGE_LIMIT");
    }

    // ==================== Task 6: WITHDRAWAL QUEUE DEPLOY + BIND ====================

    /// @notice Task 6: factory must deploy a `VaultWithdrawalQueue` per vault and
    ///         bind it via `setWithdrawalQueue` atomically inside `createSyndicate`.
    function test_createSyndicate_deploysAndBindsWithdrawalQueue() public {
        vm.prank(creator1);
        (, address syndicateVault) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        address q = SyndicateVault(payable(syndicateVault)).withdrawalQueue();
        assertTrue(q != address(0), "queue not bound");
        assertEq(VaultWithdrawalQueue(q).vault(), syndicateVault, "queue's vault mismatch");
    }

    // ==================== setEnsRegistrar ====================

    event EnsRegistrarUpdated(address indexed oldRegistrar, address indexed newRegistrar);

    /// @notice Owner can repoint the ENS registrar; future syndicates use the new one.
    ///         Recovery path for the Base mainnet deploy where `ensRegistrar` was
    ///         initialized to `address(0)` and every syndicate created since then
    ///         silently skipped ENS registration.
    function test_setEnsRegistrar_ownerRepointsRegistrar() public {
        address oldRegistrar = address(ensRegistrar);
        MockL2Registrar newRegistrar = new MockL2Registrar();

        vm.expectEmit(true, true, false, true);
        emit EnsRegistrarUpdated(oldRegistrar, address(newRegistrar));

        vm.prank(owner);
        factory.setEnsRegistrar(address(newRegistrar));

        assertEq(address(factory.ensRegistrar()), address(newRegistrar), "ensRegistrar not updated");
    }

    /// @notice Owner can clear the registrar by setting to zero — disables ENS
    ///         registration for future syndicates without breaking creation.
    ///         (createSyndicate's `address(0)` guard already covers this case.)
    function test_setEnsRegistrar_zeroAddressDisablesEns() public {
        vm.prank(owner);
        factory.setEnsRegistrar(address(0));

        assertEq(address(factory.ensRegistrar()), address(0));

        // createSyndicate still succeeds — the ENS register call is guarded.
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());
        assertTrue(vaultAddr != address(0));
    }

    /// @notice Non-owner cannot change the registrar.
    function test_setEnsRegistrar_revertsForNonOwner() public {
        vm.prank(creator1);
        vm.expectRevert();
        factory.setEnsRegistrar(makeAddr("rogueRegistrar"));
    }

    /// @notice After repointing, new syndicates register against the new registrar.
    function test_setEnsRegistrar_futureSyndicatesUseNewRegistrar() public {
        MockL2Registrar newRegistrar = new MockL2Registrar();
        vm.prank(owner);
        factory.setEnsRegistrar(address(newRegistrar));

        vm.prank(creator1);
        SyndicateFactory.SyndicateConfig memory cfg = _defaultConfig();
        cfg.subdomain = "fresh-after-repoint";
        factory.createSyndicate(creator1AgentId, cfg);

        // The MockL2Registrar tracks calls; new registrar should have been hit,
        // old one untouched for this subdomain.
        assertTrue(newRegistrar.isRegistered("fresh-after-repoint"), "new registrar missed");
        assertFalse(ensRegistrar.isRegistered("fresh-after-repoint"), "old registrar called");
    }

    // ==================== Task 22: per-vault governor wiring ====================

    /// @notice Every createSyndicate deploys its own BeaconProxy governor —
    ///         two vaults must get two distinct, non-zero governors.
    function test_createSyndicateDeploysDistinctGovernors() public {
        vm.prank(creator1);
        (, address vaultA) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("vault-aaa"));
        vm.prank(creator2);
        (, address vaultB) = factory.createSyndicate(creator2AgentId, _configWithSubdomain("vault-bbb"));

        address govA = factory.governorOf(vaultA);
        address govB = factory.governorOf(vaultB);
        assertTrue(govA != address(0), "vault A governor deployed");
        assertTrue(govB != address(0), "vault B governor deployed");
        assertTrue(govA != govB, "governors are per-vault, not shared");
    }

    /// @notice governorOf(vault) is populated at create; the vault resolves the
    ///         same governor through its factory, and the governor knows its vault.
    function test_governorOfPopulated() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("vault-wire"));

        address gov = factory.governorOf(vaultAddr);
        assertTrue(gov != address(0), "governorOf populated");
        // Vault resolves its governor via factory.governorOf (no local slot).
        assertEq(SyndicateVault(payable(vaultAddr)).governor(), gov, "vault resolves the same governor");
        // Governor is bound to this exact vault (propose() gate).
        assertEq(SyndicateGovernor(gov).vault(), vaultAddr, "governor bound to its vault");
        // And it is authorized on the registry mock (addGovernor was called) —
        // asserted implicitly by the mocked registry accepting the call in setUp.
    }

    /// @notice pashov finding #1 (THE live route) — a vault must not be
    ///         CREATABLE without a TierRegistry.
    /// @dev    `createSyndicate` SKIPPED the wiring when the factory's own
    ///         pointer was unset, rather than refusing, so every vault created
    ///         in that window was permanently registry-less. In that state
    ///         `SyndicateVault._guardBatchCalls` resolves no registry and
    ///         RETURNS, skipping the callee allowlist, the spender/recipient
    ///         gate and the `UnrecognizedAssetSelector` branch — after which one
    ///         instruction, `asset.approve(attacker, max)`, moves zero balance
    ///         (so every meter reads zero) and licenses an unbounded pull in a
    ///         LATER transaction.
    ///
    ///         Closes the STATE, not the symptom — the vault's runtime guard is
    ///         deliberately untouched. This was the only LIVE route to
    ///         `_tierRegistry == 0`: `setTierRegistry` is `onlyFactory` and both
    ///         factory call sites already filtered zero, so the governor-side
    ///         check is defence-in-depth, not a second open door.
    function test_createSyndicate_refusesWhileFactoryHasNoRegistry() public {
        // setUp wires one, so reproduce the unwired state explicitly. Zero is
        // legal on the FACTORY setter on purpose — it blocks new syndicates.
        vm.prank(owner);
        factory.setTierRegistry(address(0));
        assertEq(factory.tierRegistry(), address(0), "precondition: factory has no registry");

        vm.prank(creator1);
        vm.expectRevert(SyndicateFactory.TierRegistryNotWired.selector);
        factory.createSyndicate(creator1AgentId, _configWithSubdomain("no-registry"));
    }

    /// @notice pashov finding #1, defence-in-depth — a wired registry must not
    ///         be REMOVABLE. `setTierRegistry(address(0))` was explicitly legal
    ///         and its natspec called it "the safe default"; it would re-open
    ///         the batch gate for every subsequent proposal on that governor.
    /// @dev    Unreachable from the factory today; pins the guard against a
    ///         future upgrade that stops filtering zero. The factory's and the
    ///         governor's `TierRegistryNotWired` share a selector, so this
    ///         cannot prove WHICH reverted — the pranked caller
    ///         (`address(factory)`) is what rules out an auth revert.
    function test_setTierRegistry_rejectsZero() public {
        TierRegistry reg = new TierRegistry(owner);
        vm.prank(owner);
        factory.setTierRegistry(address(reg));

        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("wired"));
        address gov = factory.governorOf(vaultAddr);
        assertEq(SyndicateGovernor(gov).tierRegistry(), address(reg), "precondition: governor is wired");

        vm.prank(address(factory));
        vm.expectRevert(ISyndicateGovernor.TierRegistryNotWired.selector);
        SyndicateGovernor(gov).setTierRegistry(address(0));

        // Same branch refuses codeless: an EOA passes every zero-check, then
        // bricks the vault's typed `isCallableTarget` call.
        vm.prank(address(factory));
        vm.expectRevert(ISyndicateGovernor.TierRegistryNotWired.selector);
        SyndicateGovernor(gov).setTierRegistry(makeAddr("eoaRegistry"));

        assertEq(SyndicateGovernor(gov).tierRegistry(), address(reg), "registry unchanged after both refusals");
    }

    /// @notice pashov finding #1, structural — a factory cannot be initialized
    ///         without a real tier registry, so the live-but-unwired state has
    ///         no window rather than being merely fail-closed.
    /// @dev    `tierRegistry` used to be absent from `InitParams`, leaving a gap
    ///         between `initialize` and `setTierRegistry`. Covers both rejected
    ///         shapes: zero and codeless.
    function test_factoryInitialize_requiresRealTierRegistry() public {
        SyndicateFactory freshImpl = new SyndicateFactory();
        TierRegistry reg = new TierRegistry(owner);

        // HOISTED: the helper reads `factory.beacon()` / `.protocolConfig()`.
        // In argument position those are evaluated first and eat the one-shot
        // `vm.expectRevert`, leaving the create unarmed.
        bytes memory initZero = _factoryInitDataWithTierRegistry(address(0));
        bytes memory initEoa = _factoryInitDataWithTierRegistry(makeAddr("eoaRegistry"));
        bytes memory initReal = _factoryInitDataWithTierRegistry(address(reg));

        vm.expectRevert(SyndicateFactory.TierRegistryNotWired.selector);
        new ERC1967Proxy(address(freshImpl), initZero);

        vm.expectRevert(SyndicateFactory.TierRegistryNotWired.selector);
        new ERC1967Proxy(address(freshImpl), initEoa);

        // The positive case: a real registry initializes and lands in storage.
        SyndicateFactory fresh = SyndicateFactory(address(new ERC1967Proxy(address(freshImpl), initReal)));
        assertEq(fresh.tierRegistry(), address(reg), "registry stored at init");
    }

    /// @dev Factory `InitParams` with every field but `tierRegistry` fixed, so
    ///      the test above varies exactly one axis.
    function _factoryInitDataWithTierRegistry(address reg) internal view returns (bytes memory) {
        return abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    ensRegistrar: address(ensRegistrar),
                    agentRegistry: address(agentRegistry),
                    beacon: factory.beacon(),
                    protocolConfig: factory.protocolConfig(),
                    managementFeeBps: 50,
                    guardianRegistry: guardianRegistryAddr,
                    tierRegistry: reg
                }))
        );
    }

    /// @notice The factory-side setter rejects a codeless registry but still
    ///         accepts `address(0)`.
    /// @dev    Asymmetric on purpose: zero is a fail-CLOSED kill switch on new
    ///         syndicates and cannot un-wire an existing governor, whereas an
    ///         EOA would be pushed into every later governor and brick it.
    function test_setTierRegistry_factoryRejectsCodelessButAllowsZero() public {
        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.TierRegistryNotWired.selector);
        factory.setTierRegistry(makeAddr("eoaRegistry"));

        vm.prank(owner);
        factory.setTierRegistry(address(0));
        assertEq(factory.tierRegistry(), address(0), "zero is a legal kill switch on the factory side");
    }

    /// @notice Task 7 wiring: when the factory owner sets a non-zero
    ///         tierRegistry, `createSyndicate` must push it into the fresh
    ///         per-vault governor (the onlyFactory `setTierRegistry` path).
    ///         This is the only end-to-end proof of the push itself.
    function test_createSyndicate_pushesTierRegistryToGovernor() public {
        TierRegistry tierRegistry = new TierRegistry(owner);

        // Baseline REWRITTEN for pashov finding #1: a governor can no longer
        // come up tier-registry-less, because `createSyndicate` refuses while
        // the factory has none. What this test still proves is the PUSH — that
        // whatever the factory holds reaches the fresh governor — so the
        // baseline is now "the setUp registry", not "address(0)".
        vm.prank(creator1);
        (, address vaultDefault) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("tier-default"));
        assertEq(
            SyndicateGovernor(factory.governorOf(vaultDefault)).tierRegistry(),
            factory.tierRegistry(),
            "governor picks up whatever the factory holds"
        );

        // Owner wires the registry; only governors created AFTER pick it up.
        vm.prank(owner);
        factory.setTierRegistry(address(tierRegistry));
        assertEq(factory.tierRegistry(), address(tierRegistry), "factory stored the registry");

        vm.prank(creator2);
        (, address vaultWired) = factory.createSyndicate(creator2AgentId, _configWithSubdomain("tier-wired"));
        assertEq(
            SyndicateGovernor(factory.governorOf(vaultWired)).tierRegistry(),
            address(tierRegistry),
            "createSyndicate pushed the registry into the new governor"
        );
    }

    /// @notice setParamsOverride: factory-owner rescue path — bypasses the
    ///         governor's whenNoActiveProposal freeze but NOT the bounds; and
    ///         only the factory owner can call it.
    function test_setParamsOverrideBypassesFreezeButEnforcesBounds() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _configWithSubdomain("vault-ovr"));
        SyndicateGovernor gov = SyndicateGovernor(factory.governorOf(vaultAddr));

        ISyndicateGovernor.GovernorParams memory p = gov.getGovernorParams();

        // Owner path works (no proposal open — plain call).
        p.votingPeriod = 48 hours;
        vm.prank(owner);
        factory.setParamsOverride(vaultAddr, p);
        assertEq(gov.getGovernorParams().votingPeriod, 48 hours, "override applied");

        // Bounds still bite (I2): the rescue path is bounds-checked for EVERY
        // param, including collaborationWindow + maxCoProposers which the plain
        // setters bound but _validateParamBounds previously omitted.
        p.votingPeriod = 1 hours;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidVotingPeriod.selector);
        factory.setParamsOverride(vaultAddr, p);

        p = gov.getGovernorParams();
        p.collaborationWindow = 8 days; // > MAX_COLLABORATION_WINDOW (7 days)
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidCollaborationWindow.selector);
        factory.setParamsOverride(vaultAddr, p);

        p = gov.getGovernorParams();
        p.maxCoProposers = 11; // > ABSOLUTE_MAX_CO_PROPOSERS (10)
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidMaxCoProposers.selector);
        factory.setParamsOverride(vaultAddr, p);

        // Strangers rejected by the factory's onlyOwner.
        p.votingPeriod = 48 hours;
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        factory.setParamsOverride(vaultAddr, p);

        // Unknown vault rejected.
        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.VaultNotDeployed.selector);
        factory.setParamsOverride(makeAddr("noVault"), p);
    }

    // ==================== ISSUE #43: EXECUTOR MIGRATION ====================

    /// @dev `_expectedExecutorCodehash` — verified via `forge inspect
    ///      SyndicateVault storageLayout` (base-contract inheritance shifts
    ///      slots, so this is NOT the same as counting declared variables in
    ///      SyndicateVault.sol alone). `_executorImpl` is slot 3 (already
    ///      used elsewhere in this file).
    uint256 constant EXPECTED_EXECUTOR_CODEHASH_SLOT = 9;

    function test_setExecutorImpl_onlyOwner() public {
        BatchExecutorLib newLib = new BatchExecutorLib();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        factory.setExecutorImpl(address(newLib));
    }

    function test_setExecutorImpl_zeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.InvalidExecutorImpl.selector);
        factory.setExecutorImpl(address(0));
    }

    /// @notice `setExecutorImpl` only affects NEW syndicates — an
    ///         already-deployed vault keeps its original executor until
    ///         `pushExecutor` re-points it individually.
    function test_setExecutorImpl_onlyAffectsNewSyndicates() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        BatchExecutorLib newLib = new BatchExecutorLib();
        vm.prank(owner);
        factory.setExecutorImpl(address(newLib));
        assertEq(factory.executorImpl(), address(newLib));

        // The EXISTING vault is untouched.
        assertEq(address(uint160(uint256(vm.load(vaultAddr, bytes32(uint256(3)))))), address(executorLib));

        // A NEW syndicate picks up the new lib.
        vm.prank(creator2);
        (, address vaultAddr2) = factory.createSyndicate(creator2AgentId, _configWithSubdomain("second-syndicate"));
        assertEq(address(uint160(uint256(vm.load(vaultAddr2, bytes32(uint256(3)))))), address(newLib));
    }

    function test_pushExecutor_onlyOwner() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        factory.pushExecutor(vaultAddr);
    }

    function test_pushExecutor_revertsIfVaultNotFactoryDeployed() public {
        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.VaultNotDeployed.selector);
        factory.pushExecutor(makeAddr("notAVault"));
    }

    /// @notice The migration primitive itself: re-points the vault's executor
    ///         address AND re-stamps its expected codehash atomically.
    function test_pushExecutor_repointsAddressAndCodehashAtomically() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());

        BatchExecutorLib newLib = new BatchExecutorLib();
        vm.prank(owner);
        factory.setExecutorImpl(address(newLib));

        vm.prank(owner);
        factory.pushExecutor(vaultAddr);

        assertEq(
            address(uint160(uint256(vm.load(vaultAddr, bytes32(uint256(3)))))), address(newLib), "address re-pointed"
        );
        assertEq(
            vm.load(vaultAddr, bytes32(EXPECTED_EXECUTOR_CODEHASH_SLOT)),
            bytes32(address(newLib).codehash),
            "codehash re-stamped to match"
        );
    }

    /// @notice Lifecycle-gated: `pushExecutor` reverts while the vault's
    ///         governor reports an active OR merely open proposal — re-pointing
    ///         mid-proposal would swap the metering library out from under
    ///         stored, coverage-priced calls. Mirrors `rotateOwner`'s gates.
    function test_pushExecutor_revertsWhileActiveProposal() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());
        address gov = factory.governorOf(vaultAddr);
        vm.mockCall(gov, abi.encodeWithSelector(ISyndicateGovernor.getActiveProposal.selector), abi.encode(uint256(42)));
        vm.mockCall(gov, abi.encodeWithSelector(ISyndicateGovernor.openProposalCount.selector), abi.encode(uint256(0)));

        BatchExecutorLib newLib = new BatchExecutorLib();
        vm.prank(owner);
        factory.setExecutorImpl(address(newLib));

        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.ProposalActive.selector);
        factory.pushExecutor(vaultAddr);

        // Untouched.
        assertEq(address(uint160(uint256(vm.load(vaultAddr, bytes32(uint256(3)))))), address(executorLib));
    }

    function test_pushExecutor_revertsWhileOpenProposalCount() public {
        vm.prank(creator1);
        (, address vaultAddr) = factory.createSyndicate(creator1AgentId, _defaultConfig());
        address gov = factory.governorOf(vaultAddr);
        vm.mockCall(gov, abi.encodeWithSelector(ISyndicateGovernor.getActiveProposal.selector), abi.encode(uint256(0)));
        vm.mockCall(gov, abi.encodeWithSelector(ISyndicateGovernor.openProposalCount.selector), abi.encode(uint256(1)));

        BatchExecutorLib newLib = new BatchExecutorLib();
        vm.prank(owner);
        factory.setExecutorImpl(address(newLib));

        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.ProposalsOpen.selector);
        factory.pushExecutor(vaultAddr);

        assertEq(address(uint160(uint256(vm.load(vaultAddr, bytes32(uint256(3)))))), address(executorLib));
    }
}
