// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";

/**
 * @notice Testnet acceleration: swap in governor + registry implementations that
 *         carry LOWER per-deployment timing floors, then compress the guardian
 *         review window. Mainnet impls are unaffected — this only re-points the
 *         Robinhood-testnet (46630) GovernorBeacon and UUPS-upgrades the shared
 *         GuardianRegistry proxy.
 *
 *         The timing floors are constructor immutables (bytecode, not storage),
 *         so both swaps preserve ALL proxy storage: every per-vault governor's
 *         proposals/params and the registry's live state decode unchanged. The
 *         new floors only relax what a vault owner (or the registry owner) may
 *         SET going forward — no per-vault param is touched here.
 *
 *   Env (all optional; testnet defaults shown):
 *     GOV_MIN_VOTING_PERIOD   = 600  (10 min)  — new governor `MIN_VOTING_PERIOD`
 *     GOV_MIN_COOLDOWN_PERIOD = 60   (1 min)   — new governor `MIN_COOLDOWN_PERIOD`
 *     REG_MIN_REVIEW_PERIOD   = 60   (1 min)   — new registry `minReviewPeriod` floor
 *     REG_REVIEW_PERIOD       = 600  (10 min)  — value to set `reviewPeriod` to
 *     GOVERNOR_BEACON         = 0x11B726c49E0bAc95bEafF8d648cf3030Dc11B73a
 *     GUARDIAN_REGISTRY       = 0x57f0fa384d0d7e2F234535d1235440312866872B
 *
 *   Usage (deployer owns both the beacon and the registry):
 *     forge script script/robinhood-testnet/UpgradeGovernorFloors.s.sol:UpgradeGovernorFloors \
 *       --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
 *       --private-key "$SHERWOODAGENT_PK" \
 *       --broadcast --slow --gas-price 100000000
 */
contract UpgradeGovernorFloors is ScriptBase {
    address constant DEFAULT_BEACON = 0x11B726c49E0bAc95bEafF8d648cf3030Dc11B73a;
    address constant DEFAULT_REGISTRY = 0x57f0fa384d0d7e2F234535d1235440312866872B;

    function run() external {
        uint256 minVoting = vm.envOr("GOV_MIN_VOTING_PERIOD", uint256(600));
        uint256 minCooldown = vm.envOr("GOV_MIN_COOLDOWN_PERIOD", uint256(60));
        uint256 minReview = vm.envOr("REG_MIN_REVIEW_PERIOD", uint256(60));
        uint256 reviewPeriod = vm.envOr("REG_REVIEW_PERIOD", uint256(600));
        address beacon = vm.envOr("GOVERNOR_BEACON", DEFAULT_BEACON);
        address registry = vm.envOr("GUARDIAN_REGISTRY", DEFAULT_REGISTRY);

        console.log("Beacon:", beacon);
        console.log("Registry:", registry);
        console.log("New governor floors (voting / cooldown):", minVoting, minCooldown);
        console.log("New registry floor / reviewPeriod:", minReview, reviewPeriod);

        vm.startBroadcast();

        // 1. New governor implementation with testnet floors → mass-upgrade every
        //    per-vault BeaconProxy governor via the beacon.
        SyndicateGovernor newGovImpl = new SyndicateGovernor(minVoting, minCooldown);
        console.log("New governor impl:", address(newGovImpl));
        GovernorBeacon(beacon).upgradeTo(address(newGovImpl));
        console.log("Beacon repointed. beacon.implementation():", GovernorBeacon(beacon).implementation());

        // 2. New registry implementation with a lower review floor → UUPS-upgrade
        //    the shared registry proxy, then compress the review window.
        GuardianRegistry newRegImpl = new GuardianRegistry(minReview);
        console.log("New registry impl:", address(newRegImpl));
        GuardianRegistry(registry).upgradeToAndCall(address(newRegImpl), "");
        GuardianRegistry(registry).setReviewPeriod(reviewPeriod);

        vm.stopBroadcast();

        // Post-checks (revert loudly on drift).
        _checkUint("registry.minReviewPeriod", GuardianRegistry(registry).minReviewPeriod(), minReview);
        _checkUint("registry.reviewPeriod", GuardianRegistry(registry).reviewPeriod(), reviewPeriod);
        console.log("Done. Verify a per-vault governor's MIN_VOTING_PERIOD reads", minVoting);
    }
}
