// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LowerTimingFloors} from "script/robinhood-mainnet/LowerTimingFloors.s.sol";
import {RobinhoodParams} from "script/robinhood-mainnet/RobinhoodParams.sol";
import {DeploySalts} from "script/DeploySalts.sol";
import {Create3Factory} from "script/utils/Create3Factory.sol";
import {Create3} from "script/utils/Create3.sol";
import {SyndicateGovernor} from "src/SyndicateGovernor.sol";
import {GuardianRegistry} from "src/GuardianRegistry.sol";
import {IGuardianRegistry} from "src/interfaces/IGuardianRegistry.sol";
import {GovernorBeacon} from "src/GovernorBeacon.sol";

/// @dev The one sWOOD read `setReviewPeriod` makes.
contract SwoodCooldownStub {
    function coolDownPeriod() external pure returns (uint256) {
        return 7 days;
    }
}

contract LowerTimingFloorsTest is Test {
    uint256 internal constant OLD_VOTING_FLOOR = 1 hours;
    uint256 internal constant OLD_REVIEW_FLOOR = 6 hours;
    uint256 internal constant LIVE_REVIEW_PERIOD = 6 hours;
    uint256 internal constant NEW_FLOOR = 30 minutes;
    address internal constant REG_FACTORY = address(0xFAC10);

    LowerTimingFloors internal script;
    GovernorBeacon internal beacon;
    GuardianRegistry internal registry;
    SwoodCooldownStub internal swood;
    address internal govImpl;
    address internal regImpl;
    LowerTimingFloors.Targets internal t;

    function setUp() public {
        script = new LowerTimingFloors();
        swood = new SwoodCooldownStub();

        // The live state: 1h/1h governor floors behind the beacon, a 6h review floor behind the
        // registry proxy, both owned by the script (its own calls are the owner's under broadcast).
        address oldGov = address(new SyndicateGovernor(OLD_VOTING_FLOOR, RobinhoodParams.MIN_COOLDOWN_PERIOD));
        beacon = new GovernorBeacon(oldGov, address(script));
        GuardianRegistry oldReg = new GuardianRegistry(OLD_REVIEW_FLOOR);
        registry = GuardianRegistry(
            address(
                new ERC1967Proxy(
                    address(oldReg),
                    abi.encodeCall(
                        GuardianRegistry.initialize,
                        (address(script), REG_FACTORY, address(swood), LIVE_REVIEW_PERIOD, 3000)
                    )
                )
            )
        );

        govImpl = address(new SyndicateGovernor(RobinhoodParams.MIN_VOTING_PERIOD, RobinhoodParams.MIN_COOLDOWN_PERIOD));
        regImpl = address(new GuardianRegistry(RobinhoodParams.MIN_REVIEW_PERIOD));
        t = LowerTimingFloors.Targets({beacon: address(beacon), registry: address(registry)});
    }

    // ── Parameters ──

    /// @notice Both booked floors are 30 minutes; the cooldown floor is untouched.
    function test_params_bookThirtyMinuteFloors() public pure {
        assertEq(RobinhoodParams.MIN_VOTING_PERIOD, NEW_FLOOR);
        assertEq(RobinhoodParams.MIN_REVIEW_PERIOD, NEW_FLOOR);
        assertEq(RobinhoodParams.MIN_COOLDOWN_PERIOD, 1 hours);
    }

    // ── upgrade ──

    /// @notice The floors move to 30 minutes through both proxies and the registry's storage stays.
    function test_upgrade_seatsTheFloorsAndKeepsStorage() public {
        // Control: the live floor refuses a 30-minute review period before the upgrade.
        vm.prank(address(script));
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        registry.setReviewPeriod(NEW_FLOOR);

        script.upgrade(t, govImpl, regImpl);

        assertEq(beacon.implementation(), govImpl);
        assertEq(SyndicateGovernor(beacon.implementation()).MIN_VOTING_PERIOD(), NEW_FLOOR);
        assertEq(registry.minReviewPeriod(), NEW_FLOOR);
        assertEq(registry.reviewPeriod(), LIVE_REVIEW_PERIOD, "operating value untouched");
        assertEq(registry.blockQuorumBps(), 3000);
        assertEq(registry.owner(), address(script));
        assertEq(registry.factory(), REG_FACTORY);
        assertEq(address(registry.swood()), address(swood));
        assertEq(beacon.owner(), address(script));

        // The owner can now seat the 30-minute window.
        vm.prank(address(script));
        registry.setReviewPeriod(NEW_FLOOR);
        assertEq(registry.reviewPeriod(), NEW_FLOOR);
    }

    /// @notice A governor impl built with the old voting floor is refused before anything moves.
    function test_upgrade_refusesAGovernorImplWithTheWrongFloor() public {
        address wrong = address(new SyndicateGovernor(OLD_VOTING_FLOOR, RobinhoodParams.MIN_COOLDOWN_PERIOD));
        vm.expectRevert(bytes("PRE-FLIGHT: the governor impl's floors are not the booked ones"));
        script.upgrade(t, wrong, regImpl);
        assertEq(registry.minReviewPeriod(), OLD_REVIEW_FLOOR);
    }

    /// @notice A governor impl that also moves the cooldown floor is refused.
    function test_upgrade_refusesAGovernorImplThatMovesTheCooldownFloor() public {
        address wrong = address(new SyndicateGovernor(RobinhoodParams.MIN_VOTING_PERIOD, 2 hours));
        vm.expectRevert(bytes("PRE-FLIGHT: the governor impl's floors are not the booked ones"));
        script.upgrade(t, wrong, regImpl);
    }

    /// @notice A registry impl built with the old review floor is refused.
    function test_upgrade_refusesARegistryImplWithTheWrongFloor() public {
        address wrong = address(new GuardianRegistry(OLD_REVIEW_FLOOR));
        vm.expectRevert(bytes("PRE-FLIGHT: the registry impl's floor is not the booked one"));
        script.upgrade(t, govImpl, wrong);
    }

    /// @notice Re-running against proxies already at 30 minutes is refused as a no-op.
    function test_upgrade_refusesARerun() public {
        script.upgrade(t, govImpl, regImpl);
        vm.expectRevert(bytes("PRE-FLIGHT: the live voting floor is already at or below the booked one"));
        script.upgrade(t, govImpl, regImpl);
    }

    /// @notice A sender that does not own the beacon cannot upgrade it.
    function test_upgrade_revertsForANonOwner() public {
        LowerTimingFloors stranger = new LowerTimingFloors();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(stranger)));
        stranger.upgrade(t, govImpl, regImpl);
    }

    // ── mintImpls ──

    /// @notice Both impls land at their salted CREATE3 addresses carrying the booked floors.
    function test_mintImpls_landsAtTheSaltedAddressesWithTheBookedFloors() public {
        Create3Factory c3 = new Create3Factory(address(script));
        (address g, address r) = script.mintImpls(c3);

        assertEq(g, Create3.addressOf(address(c3), DeploySalts.GOVERNOR_IMPL_30M));
        assertEq(r, Create3.addressOf(address(c3), DeploySalts.REGISTRY_IMPL_30M));
        assertEq(SyndicateGovernor(g).MIN_VOTING_PERIOD(), NEW_FLOOR);
        assertEq(SyndicateGovernor(g).MIN_COOLDOWN_PERIOD(), 1 hours);
        assertEq(GuardianRegistry(r).minReviewPeriod(), NEW_FLOOR);
        // The minted impls pass the same pre-flight the live upgrade runs.
        script.upgrade(t, g, r);
        assertEq(registry.minReviewPeriod(), NEW_FLOOR);
    }
}
