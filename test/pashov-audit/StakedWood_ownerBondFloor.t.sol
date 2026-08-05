// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/**
 * @title StakedWood_ownerBondFloorTest
 * @notice pashov 2026-08 finding 22, sWOOD half.
 *
 *         Two gaps, one number.
 *
 *         (1) `initialize` validated `minSlashBps` / `maxSlashBps` /
 *             `ageFloorBps` / `maturationPeriod` but NOT `minOwnerStake`, while
 *             `setMinOwnerStake` has always rejected any nonzero value under
 *             1_000 WOOD. A deploy could therefore seat a token-dust creation
 *             floor that no later setter would ever accept.
 *
 *         (2) `requiredOwnerBond` returned the protocol-wide `minOwnerStake`
 *             verbatim, so under the documented `minOwnerStake == 0`
 *             open-onboarding sentinel the emergency-settle gate
 *             (`ownerStake(vault) < requiredOwnerBond(vault)`) evaluated
 *             `0 < 0` — false — and passed with nothing bonded. The bond it
 *             gates is the deterrent behind `finalizeEmergencySettle`, which
 *             runs owner-supplied calldata with per-call metering OFF.
 *
 *         The sentinel itself is NOT removed: it governs vault CREATION, which
 *             `bindOwnerStake` / `prepareOwnerStake` / `canCreateVault` still
 *             read off `minOwnerStake` directly. See the zero-bond onboarding
 *             section of `test/StakedWood.t.sol`, which still pins that half.
 */
contract StakedWood_ownerBondFloorTest is Test {
    ERC20Mock wood;
    StakedWood impl;

    address owner = address(0xA11CE);
    address factory = address(0xFAC10);

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        impl = new StakedWood();
    }

    function _params(uint256 minOwnerStake_) internal view returns (StakedWood.InitParams memory) {
        return StakedWood.InitParams({
            owner: owner,
            wood: address(wood),
            factory: factory,
            minGuardianStake: 10_000e18,
            coolDownPeriod: 7 days,
            minOwnerStake: minOwnerStake_,
            minSlashBps: 1000,
            maxSlashBps: 9999,
            ageFloorBps: 2500,
            maturationPeriod: 30 days
        });
    }

    function _deploy(uint256 minOwnerStake_) internal returns (StakedWood) {
        bytes memory initData = abi.encodeCall(StakedWood.initialize, (_params(minOwnerStake_)));
        return StakedWood(address(new ERC1967Proxy(address(impl), initData)));
    }

    // ── (1) initialize now applies the same admission rule as the setter ──

    function test_initialize_rejectsNonzeroDustMinOwnerStake() public {
        bytes memory initData = abi.encodeCall(StakedWood.initialize, (_params(999e18)));
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_rejectsOneWeiMinOwnerStake() public {
        bytes memory initData = abi.encodeCall(StakedWood.initialize, (_params(1)));
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @notice The sentinel survives: `0` is still a legal deploy-time value,
    ///         exactly as `setMinOwnerStake(0)` is still a legal setter call.
    function test_initialize_acceptsZeroSentinel() public {
        StakedWood s = _deploy(0);
        assertEq(s.minOwnerStake(), 0);
    }

    function test_initialize_acceptsExactlyTheFloor() public {
        StakedWood s = _deploy(1_000e18);
        assertEq(s.minOwnerStake(), s.MIN_OWNER_BOND_FLOOR());
    }

    /// @notice The one number, in one place: the constant the setter has always
    ///         enforced is the constant `initialize` now enforces.
    function test_floorConstantMatchesTheSetterRule() public {
        StakedWood s = _deploy(10_000e18);
        uint256 floor = s.MIN_OWNER_BOND_FLOOR();
        assertEq(floor, 1_000e18);

        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        s.setMinOwnerStake(floor - 1);

        vm.prank(owner);
        s.setMinOwnerStake(floor);
        assertEq(s.minOwnerStake(), floor);
    }

    // ── (2) requiredOwnerBond no longer follows the sentinel to zero ──

    /// @notice THE FINDING. Under open onboarding the emergency-settle
    ///         requirement must not collapse to zero, or the gate passes with no
    ///         bond posted and the slash that backs it is a no-op.
    function test_requiredOwnerBond_floorsUnderTheZeroSentinel() public {
        StakedWood s = _deploy(0);
        address vault = address(0xBEEF);

        assertEq(s.minOwnerStake(), 0, "creation floor is the sentinel");
        assertEq(s.requiredOwnerBond(vault), s.MIN_OWNER_BOND_FLOOR(), "emergency bond does not follow it down");
        // The exact boolean `GovernorEmergency.emergencySettleWithCalls` evaluates.
        assertTrue(s.ownerStake(vault) < s.requiredOwnerBond(vault), "unbonded vault fails the gate");
    }

    /// @notice Above the floor the bond tracks `minOwnerStake` unchanged — the
    ///         floor is a floor, not a cap or a replacement.
    function test_requiredOwnerBond_tracksMinOwnerStakeAboveTheFloor() public {
        StakedWood s = _deploy(10_000e18);
        address vault = address(0xBEEF);
        assertEq(s.requiredOwnerBond(vault), 10_000e18);

        vm.prank(owner);
        s.setMinOwnerStake(50_000e18);
        assertEq(s.requiredOwnerBond(vault), 50_000e18);
    }

    /// @notice `requiredOwnerBond` ignores its `vault` argument (no TVL scaling
    ///         in V1) — pinned so a future scaling change is a deliberate one.
    function test_requiredOwnerBond_isVaultIndependentInV1() public {
        StakedWood s = _deploy(10_000e18);
        assertEq(s.requiredOwnerBond(address(0)), s.requiredOwnerBond(address(0xBEEF)));
    }
}
