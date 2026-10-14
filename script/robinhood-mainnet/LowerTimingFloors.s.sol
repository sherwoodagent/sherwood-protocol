// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {DeploySalts} from "../DeploySalts.sol";
import {RobinhoodParams} from "./RobinhoodParams.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";

/**
 * @title  LowerTimingFloors
 * @notice Seat the 30-minute `MIN_VOTING_PERIOD` and `minReviewPeriod` floors. Both are
 *         constructor immutables, so each is a new implementation behind the live proxy:
 *         one `beacon.upgradeTo` for every vault governor, one `upgradeToAndCall` for the
 *         registry. Storage is untouched; the operating values (`votingPeriod` per vault,
 *         `reviewPeriod`) stay where they are and the owner lowers them afterwards.
 * @dev    One broadcast by the owner of both the beacon and the registry. Addresses come
 *         from `chains/{chainId}.json`, numbers from `RobinhoodParams`. Rehearse on an anvil
 *         fork with `--disable-code-size-limit`: the governor impl is over the standard
 *         EIP-170 limit that vanilla revm enforces and under 4663's own 98,304.
 */
contract LowerTimingFloors is ScriptBase {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Targets {
        address beacon;
        address registry;
    }

    struct Snapshot {
        address registryOwner;
        address registryFactory;
        address registrySwood;
        uint256 reviewPeriod;
        uint256 blockQuorumBps;
        address beaconOwner;
    }

    function run() external {
        Targets memory t = _targets();
        vm.startBroadcast();
        (address govImpl, address regImpl) = mintImpls(_c3Factory(msg.sender));
        upgrade(t, govImpl, regImpl);
        vm.stopBroadcast();
        console.log("governor impl (30m voting floor): %s", govImpl);
        console.log("registry impl (30m review floor): %s", regImpl);
    }

    // ── Phases (public so the tests drive them) ──

    /// @notice Mint (or adopt) both implementations at their CREATE3 addresses.
    function mintImpls(Create3Factory c3) public returns (address govImpl, address regImpl) {
        govImpl = _c3(
            c3,
            DeploySalts.GOVERNOR_IMPL_30M,
            abi.encodePacked(
                type(SyndicateGovernor).creationCode,
                abi.encode(RobinhoodParams.MIN_VOTING_PERIOD, RobinhoodParams.MIN_COOLDOWN_PERIOD)
            )
        );
        regImpl = _c3(
            c3,
            DeploySalts.REGISTRY_IMPL_30M,
            abi.encodePacked(type(GuardianRegistry).creationCode, abi.encode(RobinhoodParams.MIN_REVIEW_PERIOD))
        );
    }

    /// @notice Pre-flight, swap both implementations, then prove the floors moved and nothing else did.
    function upgrade(Targets memory t, address govImpl, address regImpl) public {
        preflight(t, govImpl, regImpl);
        Snapshot memory before = _snapshot(t);

        GovernorBeacon(t.beacon).upgradeTo(govImpl);
        UUPSUpgradeable(t.registry).upgradeToAndCall(regImpl, "");

        require(GovernorBeacon(t.beacon).implementation() == govImpl, "POST: the beacon does not serve the new impl");
        // forge-lint: disable-next-line(unsafe-typecast)
        address served = address(uint160(uint256(vm.load(t.registry, IMPL_SLOT))));
        require(served == regImpl, "POST: the registry does not serve the new impl");
        require(
            SyndicateGovernor(govImpl).MIN_VOTING_PERIOD() == RobinhoodParams.MIN_VOTING_PERIOD,
            "POST: the voting floor did not move"
        );
        require(
            GuardianRegistry(t.registry).minReviewPeriod() == RobinhoodParams.MIN_REVIEW_PERIOD,
            "POST: the review floor did not move"
        );
        Snapshot memory after_ = _snapshot(t);
        require(keccak256(abi.encode(before)) == keccak256(abi.encode(after_)), "POST: proxy storage moved");
    }

    // ── Pre-flights ──

    /// @notice The impls carry the booked floors, the live floors sit above them, and the cooldown floor stays.
    /// @dev    CREATE3 adoption does not re-check bytecode, so the immutables are read back.
    function preflight(Targets memory t, address govImpl, address regImpl) public view {
        SyndicateGovernor g = SyndicateGovernor(govImpl);
        require(
            g.MIN_VOTING_PERIOD() == RobinhoodParams.MIN_VOTING_PERIOD
                && g.MIN_COOLDOWN_PERIOD() == RobinhoodParams.MIN_COOLDOWN_PERIOD,
            "PRE-FLIGHT: the governor impl's floors are not the booked ones"
        );
        require(
            GuardianRegistry(regImpl).minReviewPeriod() == RobinhoodParams.MIN_REVIEW_PERIOD,
            "PRE-FLIGHT: the registry impl's floor is not the booked one"
        );

        SyndicateGovernor live = SyndicateGovernor(GovernorBeacon(t.beacon).implementation());
        require(
            live.MIN_VOTING_PERIOD() > RobinhoodParams.MIN_VOTING_PERIOD,
            "PRE-FLIGHT: the live voting floor is already at or below the booked one"
        );
        require(
            live.MIN_COOLDOWN_PERIOD() == RobinhoodParams.MIN_COOLDOWN_PERIOD,
            "PRE-FLIGHT: this upgrade would move the cooldown floor"
        );
        require(
            GuardianRegistry(t.registry).minReviewPeriod() > RobinhoodParams.MIN_REVIEW_PERIOD,
            "PRE-FLIGHT: the live review floor is already at or below the booked one"
        );
    }

    // ── Internals ──

    function _targets() internal view returns (Targets memory) {
        return Targets({beacon: _readAddress("GOVERNOR_BEACON"), registry: _readAddress("GUARDIAN_REGISTRY")});
    }

    function _snapshot(Targets memory t) internal view returns (Snapshot memory) {
        GuardianRegistry r = GuardianRegistry(t.registry);
        return Snapshot({
            registryOwner: r.owner(),
            registryFactory: r.factory(),
            registrySwood: address(r.swood()),
            reviewPeriod: r.reviewPeriod(),
            blockQuorumBps: r.blockQuorumBps(),
            beaconOwner: GovernorBeacon(t.beacon).owner()
        });
    }
}
