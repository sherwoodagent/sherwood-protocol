// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TierRegistry} from "src/TierRegistry.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Regression test for audit issue #181 finding #3 (bond-token
///         identity): `certify` pulls a submitter bond in the token PINNED at
///         proposal time (`PendingCertification.bondToken`, audit finding
///         #1), but `claimSubmitterBond` used to refund with the LIVE `wood`
///         state variable instead of anything recorded on the bond itself.
///         `setWood`'s only guard (`totalBondedWood != 0`) reads 0 for the
///         entire propose -> certify window, so a `setWood` call between two
///         certifications under two different tokens let the FIRST claimant
///         drain the SECOND submitter's collateral out of a shared token
///         balance.
///
///         Cross-drain scenario exercised here: propose+certify A under
///         TokenA, swap `wood` to TokenB (legal mid-window because
///         `totalBondedWood` is still 0 -- the certification is only
///         PENDING, not yet bonded), certify A, propose+certify B under
///         TokenB, demote A, claim A. The fix (`SubmitterBond.token`, pinned
///         at `certify` time exactly like `PendingCertification.bondToken`)
///         must make the claim pay out TokenA -- never TokenB, and never
///         revert.
///
///         Against the OLD code (`wood.safeTransfer(b.submitter, b.amount)`
///         in `claimSubmitterBond`), this test fails two ways at once: the
///         claim call transfers `BOND` of TokenB (the CURRENT `wood`, which
///         is submitter B's collateral) to submitter A instead of TokenA,
///         so `tokenA.balanceOf(submitterA)` stays short by `BOND` and
///         `tokenB.balanceOf(submitterA)` is wrongly nonzero.
contract TierRegistry_bondTokenIdentityTest is Test {
    TierRegistry internal reg;
    address internal owner = makeAddr("owner");
    address internal target;

    bytes4 internal constant SEL_A = bytes4(0xaaaaaaaa);
    bytes4 internal constant SEL_B = bytes4(0xbbbbbbbb);

    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    address internal submitterA = makeAddr("submitterA");
    address internal submitterB = makeAddr("submitterB");

    uint256 internal constant BOND = 10_000e18;

    function setUp() public {
        reg = new TierRegistry(owner);
        // separate deployed contract as certification target (etch-safe:
        // never etch the registry under test)
        target = address(new TierRegistry(owner));

        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();

        tokenA.mint(submitterA, 100_000e18);
        tokenB.mint(submitterB, 100_000e18);

        vm.prank(submitterA);
        tokenA.approve(address(reg), type(uint256).max);
        vm.prank(submitterB);
        tokenB.approve(address(reg), type(uint256).max);

        vm.startPrank(owner);
        reg.setWood(address(tokenA));
        reg.setSubmitterBondWood(BOND);
        vm.stopPrank();
    }

    function test_crossTokenDrain_claimPaysOriginalToken_notLiveWoodOrOtherSubmittersCollateral() public {
        // Propose A under TokenA (pins bondToken = TokenA on the pending
        // record, audit finding #1) but do NOT certify yet -- totalBondedWood
        // is still 0, so setWood's only guard (`BondsOutstanding`) is silent
        // about this pending certification.
        vm.prank(owner);
        reg.proposeCertification(target, SEL_A, 1, 500, submitterA, target.codehash);

        // Swap wood to TokenB mid-window: legal today (BondsOutstanding
        // reads 0), and by design must not affect A's already-pinned pull
        // token.
        vm.prank(owner);
        reg.setWood(address(tokenB));

        // Execute A's certification: still pulls TokenA (pinned at propose
        // time), regardless of `wood` now pointing at TokenB.
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.prank(submitterA);
        reg.certify(target, SEL_A);
        assertEq(tokenA.balanceOf(address(reg)), BOND, "bond A locked in TokenA");
        assertEq(tokenA.balanceOf(submitterA), 90_000e18, "submitter A paid the bond in TokenA");

        // Propose + certify B while `wood` is TokenB: pins and pulls TokenB.
        vm.prank(owner);
        reg.proposeCertification(target, SEL_B, 1, 500, submitterB, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.prank(submitterB);
        reg.certify(target, SEL_B);
        assertEq(tokenB.balanceOf(address(reg)), BOND, "bond B locked in TokenB");

        // Demote A and let its release timelock elapse.
        vm.prank(owner);
        reg.demote(target, SEL_A);
        vm.warp(vm.getBlockTimestamp() + reg.bondReleaseDelay());

        // Claim A: must pay submitter A in TokenA (the token bond A was
        // actually pulled in), must NOT touch submitter B's TokenB
        // collateral, and must NOT revert.
        reg.claimSubmitterBond(target, SEL_A);

        assertEq(tokenA.balanceOf(submitterA), 100_000e18, "submitter A must be refunded in TokenA in full");
        assertEq(tokenB.balanceOf(submitterA), 0, "submitter A must never receive submitter B's TokenB collateral");
        assertEq(tokenA.balanceOf(address(reg)), 0, "TokenA bond fully released");
        assertEq(tokenB.balanceOf(address(reg)), BOND, "submitter B's TokenB bond must remain untouched");
    }
}
