// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {StakedWood} from "../../src/StakedWood.sol";

/**
 * @notice Zero owner-bond onboarding: UUPS-upgrade the live Robinhood-testnet
 *         (46630) StakedWood proxy to an impl that binds a vault even when the
 *         creator prepared no stake, then drop `minOwnerStake` to 0. After this
 *         a creator holding 0 WOOD can `createSyndicate` — the factory's
 *         `canCreateVault` gate already passes at floor 0, and the upgraded
 *         `bindOwnerStake` no longer reverts on a zero prepared amount.
 *
 *         Storage-safe: only function logic changed (`bindOwnerStake`,
 *         `setMinOwnerStake`) — no state vars added / reordered, so every
 *         guardian stake, owner bond, checkpoint, and delegation slot decodes
 *         unchanged across the upgrade.
 *
 *   Env (all optional; testnet defaults shown):
 *     STAKED_WOOD      = 0x15F48A9f24c8ECaa8f03c28Ecd1a3b4784CdCb3c  (proxy)
 *     SWOOD_MIN_OWNER_STAKE = 0  (new floor — 0 = open onboarding)
 *
 *   Usage (deployer must own the StakedWood proxy):
 *     forge script script/robinhood-testnet/UpgradeStakedWoodZeroBond.s.sol:UpgradeStakedWoodZeroBond \
 *       --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
 *       --private-key "$SHERWOODAGENT_PK" \
 *       --broadcast --slow --gas-price 100000000
 */
contract UpgradeStakedWoodZeroBond is ScriptBase {
    address constant DEFAULT_STAKED_WOOD = 0x15F48A9f24c8ECaa8f03c28Ecd1a3b4784CdCb3c;

    function run() external {
        address swoodProxy = vm.envOr("STAKED_WOOD", DEFAULT_STAKED_WOOD);
        uint256 newFloor = vm.envOr("SWOOD_MIN_OWNER_STAKE", uint256(0));

        console.log("StakedWood proxy:", swoodProxy);
        console.log("New minOwnerStake floor:", newFloor);

        vm.startBroadcast();

        // 1. New StakedWood implementation (zero-bond bind + 0-permitting
        //    setMinOwnerStake) → UUPS-upgrade the live proxy in place.
        StakedWood newImpl = new StakedWood();
        console.log("New StakedWood impl:", address(newImpl));
        StakedWood(swoodProxy).upgradeToAndCall(address(newImpl), "");

        // 2. Drop the owner-bond floor to `newFloor` (0 = open onboarding).
        StakedWood(swoodProxy).setMinOwnerStake(newFloor);

        vm.stopBroadcast();

        // Post-check (revert loudly on drift).
        _checkUint("swood.minOwnerStake", StakedWood(swoodProxy).minOwnerStake(), newFloor);
        console.log("Done. A 0-WOOD creator can now createSyndicate on 46630.");
    }
}
