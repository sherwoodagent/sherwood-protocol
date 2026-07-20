// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {StakedWood} from "../../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

import {DelegationHandler} from "./handlers/DelegationHandler.sol";

/// @title DelegationInvariantsTest
/// @notice V1.5 Phase 4 — asserts the delegation-side conservation
///         invariants under bounded stateful fuzzing.
///
///         Post-split (Task 7.1): guardian staking, delegation, and commission
///         moved to `StakedWood`. The harness targets a `StakedWood` proxy
///         directly — the registry no longer custodies WOOD or tracks
///         delegation accounting.
///
///         Closed invariants:
///         - INV-V1.5-1  per-delegate accounting: `delegatedInbound(delegate)`
///                       exactly equals the sum of `delegationOf(d, delegate)`
///                       across all delegators.
///         - INV-V1.5-1g global accounting: `totalDelegatedStake` equals the
///                       sum of `delegatedInbound(g)` across all delegates.
///         - INV-V1.5-4  WOOD custody: sWOOD's WOOD balance >=
///                       `totalGuardianStake + totalDelegatedStake +
///                        pendingBurn + preparedStakes`.
///         - INV-V1.5-5  commission bounds: for all guardians,
///                       `commissionOf(g) <= MAX_COMMISSION_BPS`.
contract DelegationInvariantsTest is StdInvariant, Test {
    StakedWood public swood;
    ERC20Mock public wood;
    DelegationHandler public handler;

    address public owner = makeAddr("owner");
    address public mockGovernor = makeAddr("mockGovernor");
    address public mockFactory = makeAddr("mockFactory");

    uint256 constant MIN_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 7 days;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);

        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: mockFactory,
                    minGuardianStake: MIN_STAKE,
                    coolDownPeriod: COOL_DOWN,
                    minOwnerStake: MIN_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        // Delegation defaults off at deploy — enable it for the fuzz surface.
        vm.prank(owner);
        swood.setDelegationEnabled(true);

        handler = new DelegationHandler(swood, wood, owner);

        targetContract(address(handler));

        // Restrict to the handler's bounded action surface.
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = DelegationHandler.stake.selector;
        selectors[1] = DelegationHandler.requestUnstake.selector;
        selectors[2] = DelegationHandler.cancelUnstake.selector;
        selectors[3] = DelegationHandler.claimUnstake.selector;
        selectors[4] = DelegationHandler.delegateStake.selector;
        selectors[5] = DelegationHandler.requestUnstakeDelegation.selector;
        selectors[6] = DelegationHandler.cancelUnstakeDelegation.selector;
        selectors[7] = DelegationHandler.claimUnstakeDelegation.selector;
        selectors[8] = DelegationHandler.setCommission.selector;
        selectors[9] = DelegationHandler.warp.selector;
        selectors[10] = DelegationHandler.stake.selector; // keep stake dominant
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INV-V1.5-1 per delegate: `delegatedInbound(g)` must equal
    ///         `sum(delegationOf(d, g))` across all delegators `d`.
    function invariant_delegatedInbound_equalsSumOfDelegations() public view {
        address[] memory gs = handler.getGuardians();
        address[] memory ds = handler.getDelegators();
        for (uint256 i = 0; i < gs.length; i++) {
            uint256 sum;
            for (uint256 j = 0; j < ds.length; j++) {
                sum += swood.delegationOf(ds[j], gs[i]);
            }
            assertEq(swood.delegatedInbound(gs[i]), sum, "INV-V1.5-1: inbound != sum(delegations) for this delegate");
        }
    }

    /// @notice INV-V1.5-1 global: `totalDelegatedStake` must equal the sum of
    ///         `delegatedInbound(g)` across all delegates.
    function invariant_totalDelegatedStake_equalsSumOfInbound() public view {
        address[] memory gs = handler.getGuardians();
        uint256 sum;
        for (uint256 i = 0; i < gs.length; i++) {
            sum += swood.delegatedInbound(gs[i]);
        }
        assertEq(swood.totalDelegatedStake(), sum, "INV-V1.5-1g: totalDelegatedStake != sum(inbound)");
    }

    /// @notice Sherlock #39 / Run-1 #22: `totalActiveDelegatedStake` must
    ///         equal the sum of `delegatedInbound(g)` (== `poolTokens[g]`)
    ///         across CURRENTLY-ACTIVE delegates only. Validates that the
    ///         per-mutation checkpoint maintenance in `StakedWoodDelegation`
    ///         + `StakedWood` covers every transition site (active↔inactive
    ///         transitions, pool mutations, slash). If any handler call
    ///         leaves the active total stale, this invariant trips.
    function invariant_totalActiveDelegated_equalsSumOfActiveInbound() public view {
        address[] memory gs = handler.getGuardians();
        uint256 sum;
        for (uint256 i = 0; i < gs.length; i++) {
            if (swood.isActiveGuardian(gs[i])) {
                sum += swood.delegatedInbound(gs[i]);
            }
        }
        assertEq(
            swood.totalActiveDelegatedStake(), sum, "INV-Sherlock-39: totalActiveDelegatedStake != sum(active inbound)"
        );
    }

    /// @notice INV-V1.5-4 WOOD custody: sWOOD's WOOD balance must cover every
    ///         obligation it tracks — guardian stake + delegated stake +
    ///         prepared stakes (owner) + pending burn. Donations above this
    ///         are fine.
    function invariant_woodCustody_balanceCoversObligations() public view {
        address[] memory gs = handler.getGuardians();
        address[] memory ds = handler.getDelegators();

        uint256 obligations = swood.totalGuardianStake() + swood.totalDelegatedStake() + swood.pendingBurn();

        // Prepared owner stakes — delegators could in principle have called
        // `prepareOwnerStake`; handler doesn't drive that path, but we include
        // the term defensively.
        for (uint256 i = 0; i < gs.length; i++) {
            obligations += swood.preparedStakeOf(gs[i]);
        }
        for (uint256 i = 0; i < ds.length; i++) {
            obligations += swood.preparedStakeOf(ds[i]);
        }

        uint256 bal = wood.balanceOf(address(swood));
        assertGe(bal, obligations, "INV-V1.5-4: sWOOD WOOD balance < obligations");
    }

    /// @notice INV-V1.5-5 commission bounds: `commissionOf(g) <= MAX_COMMISSION_BPS`
    ///         for every guardian the handler interacts with.
    function invariant_commission_withinBounds() public view {
        address[] memory gs = handler.getGuardians();
        uint256 max = swood.MAX_COMMISSION_BPS();
        for (uint256 i = 0; i < gs.length; i++) {
            assertLe(swood.commissionOf(gs[i]), max, "INV-V1.5-5: commission exceeds max");
        }
    }
}
