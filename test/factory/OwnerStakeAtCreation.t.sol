// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockL2Registrar} from "../mocks/MockL2Registrar.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @title OwnerStakeAtCreation.t
/// @notice Tests for Task 26: factory creation gates on prepared owner stake,
///         binds the stake atomically, and rotateOwner retransfers the slot.
contract OwnerStakeAtCreationTest is Test {
    SyndicateFactory public factory;
    SyndicateVault public vaultImpl;
    GuardianRegistry public registry;
    StakedWood public swood;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    MockAgentRegistry public agentRegistry;
    MockL2Registrar public ensRegistrar;

    address public owner = makeAddr("factoryOwner");
    address public creator = makeAddr("creator");
    address public newOwner = makeAddr("newOwner");
    address public random = makeAddr("random");
    uint256 public creatorAgentId;
    uint256 public newOwnerAgentId;

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        vaultImpl = new SyndicateVault();
        agentRegistry = new MockAgentRegistry();
        ensRegistrar = new MockL2Registrar();

        creatorAgentId = agentRegistry.mint(creator);
        newOwnerAgentId = agentRegistry.mint(newOwner);

        // sWOOD + Governor + Factory + Registry — circular init deps resolved
        // by predicting proxy addresses via `vm.computeCreateAddress`.
        // From `baseNonce`: swoodImpl (+0), swoodProxy (+1), govImpl (+2),
        // beacon (+3), factoryImpl (+4), regImpl (+5), regProxy (+6),
        // factoryProxy (+7).
        ProtocolConfig _hoistedPC = new ProtocolConfig(owner);
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 6);
        address predictedFactoryProxy = vm.computeCreateAddress(address(this), baseNonce + 7);

        // sWOOD — sole WOOD custodian post-split.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: predictedFactoryProxy,
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: 7 days,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        // GovernorBeacon (nonce +3, preserving the prediction plan). The factory
        // clones a per-vault BeaconProxy governor at createSyndicate and
        // authorizes it on the registry itself — no standalone governor here.
        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        GovernorBeacon beacon = new GovernorBeacon(address(govImpl), owner);

        // Factory + registry — registry needs factory address, factory needs
        // registry address. Deploy in order matching the nonce plan above.
        SyndicateFactory factoryImpl = new SyndicateFactory();
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, predictedFactoryProxy, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        require(address(registry) == predictedRegistryProxy, "registry address prediction mismatch");

        // Resolve the registry ↔ sWOOD circular dependency.
        vm.prank(owner);
        swood.setRegistry(address(registry));

        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    ensRegistrar: address(ensRegistrar),
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(_hoistedPC),
                    managementFeeBps: 50,
                    guardianRegistry: address(registry)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));
        require(address(factory) == predictedFactoryProxy, "factory address prediction mismatch");

        // Hand the governor's addVault gate to the factory.
        // V1.5: setFactory applies immediately.
        // governor.setFactory removed in per-vault design

        // Fund creator with WOOD so they can prepare owner stake.
        wood.mint(creator, 100_000e18);
        wood.mint(newOwner, 100_000e18);
    }

    function _cfg(string memory sub) internal view returns (SyndicateFactory.SyndicateConfig memory) {
        return SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://test",
            asset: usdc,
            name: "Test Vault",
            symbol: "tVault",
            openDeposits: false,
            subdomain: sub
        });
    }

    function _prepareStake(address who) internal {
        vm.prank(who);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(who);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
    }

    // ──────────────────────────────────────────────────────────────
    // createSyndicate gates on prepared stake
    // ──────────────────────────────────────────────────────────────

    function test_createSyndicate_revertsIfNoPreparedStake() public {
        vm.prank(creator);
        vm.expectRevert(SyndicateFactory.PreparedStakeNotFound.selector);
        factory.createSyndicate(creatorAgentId, _cfg("no-stake"));
    }

    function test_createSyndicate_bindsPreparedStakeAtomic() public {
        _prepareStake(creator);
        assertTrue(swood.canCreateVault(creator));

        vm.prank(creator);
        (uint256 id, address vault) = factory.createSyndicate(creatorAgentId, _cfg("my-fund"));

        assertEq(id, 1);
        assertTrue(vault != address(0));
        assertTrue((registry.ownerStake(vault) > 0), "owner stake bound to vault");
        assertEq(registry.ownerStake(vault), MIN_OWNER_STAKE);
        assertFalse(swood.canCreateVault(creator), "prepared stake consumed");
    }

    function test_createSyndicate_bindFailureRevertsEntireTx() public {
        _prepareStake(creator);

        // First creation consumes the prepared stake.
        vm.prank(creator);
        factory.createSyndicate(creatorAgentId, _cfg("first"));

        // Second creation: no fresh prepared stake → canCreateVault is false,
        // whole tx reverts at the gate before any side effects (atomic revert).
        vm.prank(creator);
        vm.expectRevert(SyndicateFactory.PreparedStakeNotFound.selector);
        factory.createSyndicate(creatorAgentId, _cfg("second"));
    }

    // ──────────────────────────────────────────────────────────────
    // rotateOwner
    // ──────────────────────────────────────────────────────────────

    function _createAndUnstake() internal returns (address vault) {
        _prepareStake(creator);
        vm.prank(creator);
        (, vault) = factory.createSyndicate(creatorAgentId, _cfg("rotate-fund"));

        // Creator requests and claims the owner unstake so hasOwnerStake == false.
        vm.prank(creator);
        swood.requestUnstakeOwner(vault);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(creator);
        swood.claimUnstakeOwner(vault);
        assertFalse((swood.ownerStake(vault) > 0));
    }

    /// @notice Sherlock #32: rotateOwner is now gated to vault owner /
    ///         original creator (was previously factory `onlyOwner`).
    function test_rotateOwner_rejectsNonOwnerNonCreator() public {
        address vault = _createAndUnstake();
        _prepareStake(newOwner);

        vm.prank(random);
        vm.expectRevert(SyndicateFactory.NotVaultOwnerOrCreator.selector);
        factory.rotateOwner(vault, newOwner);
    }

    /// @notice Sherlock #32 — factory owner can NOT rotate without the
    ///         current vault owner's consent.
    function test_rotateOwner_rejectsFactoryOwner() public {
        address vault = _createAndUnstake();
        _prepareStake(newOwner);

        vm.prank(owner); // factory owner — pre-fix this was the auth path
        vm.expectRevert(SyndicateFactory.NotVaultOwnerOrCreator.selector);
        factory.rotateOwner(vault, newOwner);
    }

    function test_rotateOwner_revertsIfOldOwnerStillStaked() public {
        _prepareStake(creator);
        vm.prank(creator);
        (, address vault) = factory.createSyndicate(creatorAgentId, _cfg("still-staked"));

        _prepareStake(newOwner);
        vm.prank(creator);
        vm.expectRevert(SyndicateFactory.VaultStillStaked.selector);
        factory.rotateOwner(vault, newOwner);
    }

    // Removed: `test_rotateOwner_revertsOnRegistryMismatch`. In the per-vault
    // governor model the factory deploys each vault's governor pointing at its
    // own `guardianRegistry`, so a factory↔governor registry mismatch cannot
    // occur — the `RegistryMismatch` guard (and error) were removed from
    // `rotateOwner`. There is no longer a scenario to exercise.

    function test_rotateOwner_happyPath_transfersVaultAndSlot() public {
        address vault = _createAndUnstake();
        _prepareStake(newOwner);

        vm.prank(creator);
        factory.rotateOwner(vault, newOwner);

        assertEq(SyndicateVault(payable(vault)).owner(), newOwner, "vault ownership rotated");
        assertTrue((registry.ownerStake(vault) > 0), "new owner stake bound");
        assertEq(registry.ownerStake(vault), MIN_OWNER_STAKE);
        // Creator record updated so downstream NotCreator gates follow the new owner.
        (,, address recordedCreator,,,,) = factory.syndicates(factory.vaultToSyndicate(vault));
        assertEq(recordedCreator, newOwner);
    }
}
