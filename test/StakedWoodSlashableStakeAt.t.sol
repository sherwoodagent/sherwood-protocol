// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @notice Issue #35 — `StakedWood.slashableStakeAt` is the shared basis
///         `_slashOne` sizes a verdict slash from
///         (`min(max(liability at anchor, votableStake at anchor), liveStake)`).
///         These tests exercise the view against the REAL `slashVerdict` path
///         (the same path `ChallengeGame` drives), proving the view and the
///         slash cannot drift apart because they share one implementation
///         (`_slashableAt`).
contract StakedWoodSlashableStakeAtTest is Test {
    StakedWood swood;
    ERC20Mock wood;

    address owner = address(0xA11CE);
    address factory = address(0xFAC10);
    address slasher = address(0x51A5EA);
    address alice = address(0xA11CE5);

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    // 10_000 (100%) so the "100% severity" spec scenario is
                    // literal rather than clamped.
                    maxSlashBps: 10_000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);

        wood.mint(alice, 1_000_000e18);
        vm.prank(alice);
        wood.approve(address(swood), type(uint256).max);
    }

    function _slashVerdict(bytes32 caseKey, uint256 openedAt, address guardian, uint256 bps)
        internal
        returns (uint256)
    {
        address[] memory approvers = new address[](1);
        approvers[0] = guardian;
        uint256[] memory bpsPer = new uint256[](1);
        bpsPer[0] = bps;
        vm.prank(slasher);
        return swood.slashVerdict(caseKey, openedAt, approvers, bpsPer);
    }

    /// @notice Spec scenario "View agrees with the verdict slash": a verdict
    ///         slash at 100% severity, anchored at a past instant, recovers
    ///         exactly what `slashableStakeAt` returned for that anchor
    ///         immediately before the slash.
    function test_slashableStakeAt_agreesWithVerdictSlash_at100PctSeverity() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 1);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 anchor = vm.getBlockTimestamp();

        uint256 basis = swood.slashableStakeAt(alice, anchor);
        assertEq(basis, 10_000e18, "basis = full stake, snap == live");

        uint256 recovered = _slashVerdict(bytes32(uint256(1)), anchor, alice, 10_000);
        assertEq(recovered, basis, "100% severity recovers exactly the pre-slash view");
        assertEq(swood.guardianStake(alice), 0, "fully slashed");
    }

    /// @notice Spec scenario "Post-anchor top-up excluded": a guardian who
    ///         tops up stake AFTER the anchor is not counted when the view is
    ///         queried AT that anchor — the top-up is unreachable coverage,
    ///         issue #35's core defect.
    function test_slashableStakeAt_excludesPostAnchorTopUp() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 1);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 anchor = vm.getBlockTimestamp();

        // Top-up AFTER the anchor.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        swood.stakeAsGuardian(20_000e18, 1);
        assertEq(swood.guardianStake(alice), 30_000e18, "live stake includes the top-up");

        // The anchored view excludes it.
        assertEq(swood.slashableStakeAt(alice, anchor), 10_000e18, "anchor excludes the top-up");

        // And a verdict anchored there can only ever recover the pre-top-up
        // amount, never the inflated live balance.
        uint256 recovered = _slashVerdict(bytes32(uint256(2)), anchor, alice, 10_000);
        assertEq(recovered, 10_000e18, "verdict recovers only the at-anchor basis");
        assertEq(swood.guardianStake(alice), 20_000e18, "the top-up tranche survives the conviction");
    }

    /// @notice Spec scenario "Unstake request does not zero the basis": a
    ///         guardian who requests unstake AFTER the anchor still reports
    ///         the at-anchor stake when queried at that (earlier) anchor —
    ///         `requestUnstakeGuardian` zeros the VOTABLE checkpoint but never
    ///         touches the liability trace, and live stake is untouched until
    ///         the cooldown-gated claim. This is the guard against an approver
    ///         pre-positioning an exit to defeat its own conviction.
    function test_slashableStakeAt_unstakeRequestDoesNotZeroBasis() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 1);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 anchor = vm.getBlockTimestamp();

        // Guardian requests unstake AFTER the anchor: votable checkpoint
        // zeroes, liability trace does not, live stake is untouched pending
        // the cooldown claim.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        swood.requestUnstakeGuardian();
        assertEq(swood.guardianStake(alice), 10_000e18, "live stake untouched by the request itself");

        assertEq(swood.slashableStakeAt(alice, anchor), 10_000e18, "at-anchor basis survives the later unstake request");

        uint256 recovered = _slashVerdict(bytes32(uint256(3)), anchor, alice, 10_000);
        assertEq(recovered, 10_000e18, "verdict still recovers the full at-anchor stake during cooldown");
    }

    /// @notice A future-dated anchor reverts `VerdictNotPast`, mirroring
    ///         `slashVerdict`'s own guard — an honest caller never anchors a
    ///         verdict at an instant that has not happened yet.
    function test_slashableStakeAt_futureAnchorReverts() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 1);

        vm.expectRevert(StakedWood.VerdictNotPast.selector);
        swood.slashableStakeAt(alice, vm.getBlockTimestamp() + 1);
    }
}
