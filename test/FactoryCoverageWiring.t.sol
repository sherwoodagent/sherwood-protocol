// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {ISyndicateFactory} from "../src/interfaces/ISyndicateFactory.sol";
import {GovernorBeacon} from "../src/GovernorBeacon.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockL2Registrar} from "./mocks/MockL2Registrar.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

/// @dev A contract that answers `vault()` with a vault this factory really
///      created — the strongest forgery available to an attacker probing the
///      `pushWiring` membership check.
contract ImpostorGovernor {
    address public vault;

    constructor(address vault_) {
        vault = vault_;
    }
}

/// @notice Plan B Task 10 — factory wiring of `exposureLedger` + `bondEscrow`
///         into NEW governors (`createSyndicate`) and into ALREADY-CREATED ones
///         (`pushWiring`, closing LOW-1 / issue #19).
/// @dev Uses a real UUPS factory + real `createSyndicate`, so the onlyFactory
///      push path is genuinely exercised rather than mocked. Only the guardian
///      registry / sWOOD hops are stubbed (same fixture as SyndicateFactory.t.sol).
contract FactoryCoverageWiringTest is Test {
    SyndicateFactory public factory;
    BatchExecutorLib public executorLib;
    SyndicateVault public vaultImpl;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    MockL2Registrar public ensRegistrar;
    MockAgentRegistry public agentRegistry;

    TierRegistry public tierReg;
    ExposureLedger public ledger;
    ProposerBondEscrow public escrow;

    address public owner = makeAddr("owner");
    address public creator1 = makeAddr("creator1");
    address public creator2 = makeAddr("creator2");
    address public guardianRegistryAddr = makeAddr("guardianRegistry");
    address public swoodAddr = makeAddr("swood");

    uint256 public creator1AgentId;
    uint256 public creator2AgentId;

    /// @dev Bumped per `_createSyndicate` call so each vault gets a unique ENS label.
    uint256 private _nonce;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("Wood", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        vaultImpl = new SyndicateVault();
        ensRegistrar = new MockL2Registrar();
        agentRegistry = new MockAgentRegistry();

        ProtocolConfig protocolCfg = new ProtocolConfig(owner);
        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        GovernorBeacon beacon = new GovernorBeacon(address(govImpl), owner);

        // pashov finding #1: the tier registry is a MANDATORY `InitParams`
        // field, so a factory cannot exist without one. Deployed before the
        // factory rather than wired after it. NOTE: this is NOT `tierReg` (set
        // further down) — `pushWiring` is proved by re-pointing to a DIFFERENT
        // registry, so the two must not be the same contract.
        TierRegistry initialTierRegistry = new TierRegistry(owner);

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
                    tierRegistry: address(initialTierRegistry)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        creator1AgentId = agentRegistry.mint(creator1);
        creator2AgentId = agentRegistry.mint(creator2);

        // Registry + sWOOD are mocks here (see SyndicateFactory.t.sol): the
        // factory calls addGovernor / swood() / canCreateVault / bindOwnerStake.
        vm.mockCall(guardianRegistryAddr, abi.encodeWithSelector(IGuardianRegistry.addGovernor.selector), "");
        vm.mockCall(
            guardianRegistryAddr, abi.encodeWithSelector(IGuardianRegistry.swood.selector), abi.encode(swoodAddr)
        );
        vm.mockCall(swoodAddr, abi.encodeWithSelector(IStakedWood.canCreateVault.selector), abi.encode(true));
        vm.mockCall(swoodAddr, abi.encodeWithSelector(IStakedWood.bindOwnerStake.selector), "");
        // ExposureLedger's constructor asserts epochLength + challengeWindow
        // <= swood.coolDownPeriod() (28d + 14d = 42d here).
        vm.mockCall(swoodAddr, abi.encodeWithSignature("coolDownPeriod()"), abi.encode(uint256(45 days)));

        tierReg = new TierRegistry(owner);
        ledger = new ExposureLedger(owner, swoodAddr, 28 days);
        escrow = new ProposerBondEscrow(address(wood), guardianRegistryAddr, address(ledger));
    }

    // ── Helpers ──

    function _createSyndicate() internal returns (address gov, address vaultAddr) {
        uint256 n = ++_nonce;
        SyndicateFactory.SyndicateConfig memory cfg = SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://QmTest",
            asset: usdc,
            name: "Test Vault",
            symbol: "tVault",
            openDeposits: false,
            subdomain: string.concat("wiring-", vm.toString(n))
        });
        // Alternate creators so each ERC-8004 identity check passes.
        address creator = n % 2 == 1 ? creator1 : creator2;
        uint256 agentId = n % 2 == 1 ? creator1AgentId : creator2AgentId;
        vm.prank(creator);
        (, vaultAddr) = factory.createSyndicate(agentId, cfg);
        gov = factory.governorOf(vaultAddr);
    }

    // ── createSyndicate push ──

    /// @notice With both Plan B slots wired on the factory, a freshly created
    ///         governor comes up holding both — the onlyFactory setters have no
    ///         other caller, so this is the only proof the push landed.
    function test_createSyndicate_pushesLedgerAndEscrow() public {
        vm.prank(owner);
        factory.setExposureLedger(address(ledger));
        vm.prank(owner);
        factory.setBondEscrow(address(escrow));

        (address gov,) = _createSyndicate();

        assertEq(SyndicateGovernor(gov).exposureLedger(), address(ledger), "ledger pushed at creation");
        assertEq(SyndicateGovernor(gov).bondEscrow(), address(escrow), "escrow pushed at creation");
    }

    /// @notice Unset factory slots must SKIP the push, not write address(0) —
    ///         the governor keeps its pre-ledger / no-bond default.
    function test_createSyndicate_unsetLedgerLeavesGovernorUnwired() public {
        assertEq(factory.exposureLedger(), address(0), "factory ledger unset by default");
        assertEq(factory.bondEscrow(), address(0), "factory escrow unset by default");

        (address gov,) = _createSyndicate();

        assertEq(SyndicateGovernor(gov).exposureLedger(), address(0), "governor left unwired");
        assertEq(SyndicateGovernor(gov).bondEscrow(), address(0), "governor left unwired");
    }

    // ── pushWiring rewire path (LOW-1 / issue #19) ──

    /// @notice The LOW-1 case: a governor created BEFORE any wiring existed is
    ///         rescued by `pushWiring` for all three slots at once.
    function test_pushWiring_rewiresExistingGovernor() public {
        (address gov,) = _createSyndicate(); // created BEFORE wiring existed
        // pashov finding #1: the TIER REGISTRY can no longer be unwired at
        // creation — `createSyndicate` refuses without one — so the governor
        // comes up holding the fixture's registry. The ledger and escrow slots
        // are unaffected and still model the LOW-1 case; what this test proves
        // is that `pushWiring` RE-POINTS all three, which is unchanged.
        assertTrue(SyndicateGovernor(gov).tierRegistry() != address(0), "precondition: registry always wired");
        assertEq(SyndicateGovernor(gov).exposureLedger(), address(0), "precondition: unwired");
        assertEq(SyndicateGovernor(gov).bondEscrow(), address(0), "precondition: unwired");

        vm.startPrank(owner);
        factory.setTierRegistry(address(tierReg));
        factory.setExposureLedger(address(ledger));
        factory.setBondEscrow(address(escrow));

        vm.expectEmit(true, false, false, false, address(factory));
        emit ISyndicateFactory.WiringPushed(gov);
        factory.pushWiring(gov);
        vm.stopPrank();

        assertEq(SyndicateGovernor(gov).tierRegistry(), address(tierReg), "tier registry rewired");
        assertEq(SyndicateGovernor(gov).exposureLedger(), address(ledger), "ledger rewired");
        assertEq(SyndicateGovernor(gov).bondEscrow(), address(escrow), "escrow rewired");
    }

    /// @notice `pushWiring` can only ADD wiring, never remove it: unset factory
    ///         slots are SKIPPED, not written as zero. Documented at the
    ///         implementation but previously unpinned (review M-5). This is also
    ///         what makes the governor's `address(0)` branch unreachable from
    ///         the factory — see the RECOVERY note on
    ///         `SyndicateGovernor.setExposureLedger`.
    function test_pushWiring_cannotUnwire() public {
        vm.startPrank(owner);
        factory.setTierRegistry(address(tierReg));
        factory.setExposureLedger(address(ledger));
        factory.setBondEscrow(address(escrow));
        vm.stopPrank();

        (address gov,) = _createSyndicate(); // born fully wired
        assertEq(SyndicateGovernor(gov).exposureLedger(), address(ledger));
        assertEq(SyndicateGovernor(gov).bondEscrow(), address(escrow));

        // Clear the factory's slots, then re-push: the governor must KEEP its
        // existing wiring rather than be silently un-wired.
        vm.startPrank(owner);
        factory.setExposureLedger(address(0));
        factory.setBondEscrow(address(0));
        factory.pushWiring(gov);
        vm.stopPrank();

        assertEq(SyndicateGovernor(gov).exposureLedger(), address(ledger), "ledger must survive a zero push");
        assertEq(SyndicateGovernor(gov).bondEscrow(), address(escrow), "escrow must survive a zero push");
        assertEq(SyndicateGovernor(gov).tierRegistry(), address(tierReg), "tier registry untouched");
    }

    /// @notice Membership is mandatory: an address this factory never deployed
    ///         cannot be rewired, so the owner cannot drive arbitrary
    ///         `setTierRegistry` / `setExposureLedger` calls into foreign
    ///         contracts through the factory.
    function test_pushWiring_foreignGovernorReverts() public {
        vm.prank(owner);
        vm.expectRevert(ISyndicateFactory.NotFactoryGovernor.selector);
        factory.pushWiring(makeAddr("foreign"));
    }

    /// @notice A contract that fakes `vault()` with a REAL factory vault still
    ///         fails: the check is a round trip, and `_governorOf[vault]` names
    ///         the genuine governor, never the impostor.
    function test_pushWiring_impostorGovernorReverts() public {
        (address realGov, address vaultAddr) = _createSyndicate();
        ImpostorGovernor impostor = new ImpostorGovernor(vaultAddr);

        assertTrue(factory.isFactoryGovernor(realGov), "real governor is a member");
        assertFalse(factory.isFactoryGovernor(address(impostor)), "impostor is not");

        vm.prank(owner);
        vm.expectRevert(ISyndicateFactory.NotFactoryGovernor.selector);
        factory.pushWiring(address(impostor));
    }

    /// @notice Rewiring is an owner action — anyone else is rejected before the
    ///         membership check runs.
    function test_pushWiring_ownerOnly() public {
        (address gov,) = _createSyndicate();

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        factory.pushWiring(gov);
    }

    // ── setters ──

    /// @notice Both new setters are owner-gated, exactly like `setTierRegistry`.
    function test_setters_ownerOnly() public {
        address rando = makeAddr("rando");

        vm.prank(rando);
        vm.expectRevert();
        factory.setExposureLedger(address(ledger));

        vm.prank(rando);
        vm.expectRevert();
        factory.setBondEscrow(address(escrow));

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, false, address(factory));
        emit ISyndicateFactory.ExposureLedgerSet(address(0), address(ledger));
        factory.setExposureLedger(address(ledger));

        vm.expectEmit(true, true, false, false, address(factory));
        emit ISyndicateFactory.BondEscrowSet(address(0), address(escrow));
        factory.setBondEscrow(address(escrow));
        vm.stopPrank();

        assertEq(factory.exposureLedger(), address(ledger));
        assertEq(factory.bondEscrow(), address(escrow));
    }
}
