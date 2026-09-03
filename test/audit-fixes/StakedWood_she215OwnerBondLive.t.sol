// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "../mocks/MockGovernorMinimal.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";

/// @title StakedWood_she215OwnerBondLive
/// @notice SHE-215, sWOOD half: pins `ownerBondLive`, its two clauses, and
///         `cancelUnstakeOwner` (design: `openspec/changes/owner-bond-proposal-gate`).
contract StakedWoodShe215OwnerBondLiveTest is Test {
    StakedWood internal swood;
    ERC20Mock internal wood;
    MockGovernorMinimal internal gov;
    /// @notice A real registry, deployed only for the passthrough the governor calls.
    GuardianRegistry internal guardianRegistry;

    address internal owner = address(0xA11CE);
    address internal factory = address(0xFAC10);
    address internal alice = address(0xA11CE5);
    address internal bob = address(0xB0B);
    address internal registry = address(0x5EC0);
    address internal vault = address(0xBEEF);

    uint256 internal constant BOND = 1_000e18;
    uint256 internal constant COOLDOWN = 7 days;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        gov = new MockGovernorMinimal();
        vm.mockCall(factory, abi.encodeWithSignature("governorOf(address)"), abi.encode(address(gov)));

        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: COOLDOWN,
                    minOwnerStake: BOND,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(owner);
        swood.setRegistry(registry);

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        guardianRegistry = GuardianRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(GuardianRegistry.initialize, (owner, factory, address(swood), 1 days, 5_000))
                )
            )
        );

        wood.mint(alice, 100_000e18);
        vm.prank(alice);
        wood.approve(address(swood), type(uint256).max);
    }

    /// @notice The registry passthrough tracks the sWOOD predicate across a state change.
    function test_registryPassthrough_tracksTheSwoodPredicate() public {
        assertFalse(guardianRegistry.ownerBondLive(vault), "unbound");
        _bind();
        assertTrue(guardianRegistry.ownerBondLive(vault), "bound");
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        assertFalse(guardianRegistry.ownerBondLive(vault), "exiting");
        assertEq(
            guardianRegistry.ownerBondLive(vault), swood.ownerBondLive(vault), "the passthrough is not its own opinion"
        );
    }

    /// @dev Alice prepares and the factory binds her bond to `vault`.
    function _bind() internal {
        vm.prank(alice);
        swood.prepareOwnerStake(BOND);
        vm.prank(factory);
        swood.bindOwnerStake(alice, vault);
    }

    // =====================================================================
    // The predicate
    // =====================================================================

    /// @notice A freshly bound slot is live.
    function test_ownerBondLive_trueForAFreshlyBoundSlot() public {
        assertFalse(swood.ownerBondLive(vault), "unbound: no slot, no lane");
        _bind();
        assertTrue(swood.ownerBondLive(vault), "bound and not exiting");
    }

    /// @notice Clause two: the lane closes at the request, not at the claim.
    /// @dev    MUTATION-CHECKED: dropping the `unstakeRequestedAt == 0` clause fails here.
    function test_ownerBondLive_falseWhileTheUnstakeRequestIsPending() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        assertFalse(swood.ownerBondLive(vault), "an exit in flight is not a live bond");
        assertEq(swood.ownerStake(vault), BOND, "the WOOD is still escrowed; amount alone cannot see this");
    }

    /// @notice Clause one: a claimed bond deletes the record, so the slot is not live.
    function test_ownerBondLive_falseAfterTheBondIsClaimed() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN + 1);
        vm.prank(alice);
        swood.claimUnstakeOwner(vault);

        assertEq(swood.ownerStake(vault), 0, "sanity: the slot is emptied");
        assertFalse(swood.ownerBondLive(vault), "the grace period the natspec promised");
    }

    /// @notice Clause one, the other emptying route: `slashOwnerBond` also deletes the record.
    function test_ownerBondLive_falseAfterTheBondIsSlashed() public {
        _bind();

        vm.prank(registry);
        swood.slashOwnerBond(vault);

        assertFalse(swood.ownerBondLive(vault), "a burned bond is not a live bond");
    }

    /// @notice A `minOwnerStake == 0` onboarding vault keeps its lane on a zero-amount slot.
    /// @dev    MUTATION-CHECKED: rewriting the first clause as `s.stakedAmount != 0` fails here.
    function test_ownerBondLive_trueForAZeroBondOnboardingVault() public {
        address poorCreator = address(0xDEAD0);

        vm.prank(owner);
        swood.setMinOwnerStake(0);

        vm.prank(factory);
        swood.bindOwnerStake(poorCreator, vault);

        assertEq(swood.ownerStake(vault), 0, "sanity: zero bond, by design");
        assertTrue(swood.ownerBondLive(vault), "open onboarding keeps its lane");
    }

    // =====================================================================
    // cancelUnstakeOwner — the way back
    // =====================================================================

    /// @notice `cancelUnstakeOwner` restores the live bond and reopens the lane.
    function test_cancelUnstakeOwner_restoresTheLiveBond() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        assertFalse(swood.ownerBondLive(vault));

        vm.expectEmit(true, true, false, true);
        emit StakedWood.OwnerUnstakeCancelled(vault, alice);
        vm.prank(alice);
        swood.cancelUnstakeOwner(vault);

        assertTrue(swood.ownerBondLive(vault), "the lane reopens");
        assertEq(swood.ownerStake(vault), BOND, "and the bond never moved");
    }

    /// @notice A cancel restarts the cooldown; it keeps no credit for time already served.
    function test_cancelUnstakeOwner_thenRequestAgainRestartsTheCooldown() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN - 1);

        vm.prank(alice);
        swood.cancelUnstakeOwner(vault);
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        // `vm.getBlockTimestamp()`, not `block.timestamp`: the frame caches the
        // latter, so a second warp built on it would land where the first did.
        vm.warp(vm.getBlockTimestamp() + COOLDOWN - 1);
        vm.prank(alice);
        vm.expectRevert(StakedWood.CooldownNotElapsed.selector);
        swood.claimUnstakeOwner(vault);

        vm.warp(vm.getBlockTimestamp() + 2);
        vm.prank(alice);
        swood.claimUnstakeOwner(vault);
        assertFalse(swood.ownerBondLive(vault));
    }

    /// @notice Only the recorded owner may cancel, and only against a request that exists.
    function test_cancelUnstakeOwner_revertsForAStrangerAndForNoRequest() public {
        _bind();

        vm.prank(alice);
        vm.expectRevert(StakedWood.UnstakeNotRequested.selector);
        swood.cancelUnstakeOwner(vault);

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        vm.prank(bob);
        vm.expectRevert(StakedWood.NoActiveStake.selector);
        swood.cancelUnstakeOwner(vault);
    }

    /// @notice A slashed slot cannot be cancelled back to life.
    function test_cancelUnstakeOwner_cannotResurrectASlashedSlot() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        vm.prank(registry);
        swood.slashOwnerBond(vault);

        vm.prank(alice);
        vm.expectRevert(StakedWood.NoActiveStake.selector);
        swood.cancelUnstakeOwner(vault);
        assertFalse(swood.ownerBondLive(vault));
    }
}
