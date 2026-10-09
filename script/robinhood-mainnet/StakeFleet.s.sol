// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {StakedWood} from "../../src/StakedWood.sol";

/// @title  StakeFleet
/// @notice Plans the guardian fleet's first stake from the owner Safe (SHE-351): WOOD to each
///         approving key, and the juror reserve staked under the Safe's own address. Prints the
///         Safe calls as (target, calldata) and each key's own two calls. Broadcasts nothing.
/// @dev    Refuses any key (or the Safe) that already holds stake: a top-up re-anchors `stakedAt`,
///         so the topology must be final before the first stake (SHE-351).
///
///   FLEET_APPROVERS=0xA,0xB FLEET_APPROVER_WOOD=2000000,2000000 FLEET_RESERVE_WOOD=60000000 \
///     forge script script/robinhood-mainnet/StakeFleet.s.sol:StakeFleet --rpc-url robinhood
contract StakeFleet is ScriptBase {
    struct Call {
        address target;
        bytes data;
    }

    function run() external view {
        address[] memory keys = vm.envAddress("FLEET_APPROVERS", ",");
        uint256[] memory wood = vm.envUint("FLEET_APPROVER_WOOD", ",");
        uint256 reserve = vm.envUint("FLEET_RESERVE_WOOD");
        address safe = _readAddress("OWNER_MULTISIG");
        StakedWood swood = StakedWood(_readAddress("STAKED_WOOD"));

        for (uint256 i; i < wood.length; ++i) {
            wood[i] *= 1e18;
        }
        Call[] memory calls = plan(swood, safe, keys, wood, reserve * 1e18);

        console.log("Safe:", safe);
        console.log("sWOOD:", address(swood));
        console.log("Safe calls, in order:");
        for (uint256 i; i < calls.length; ++i) {
            console.log("  target:", calls[i].target);
            console.logBytes(calls[i].data);
        }
        console.log(
            "Then each approving key, from itself: WOOD.approve(sWOOD, amount); sWOOD.stakeAsGuardian(amount, 0)"
        );
        for (uint256 i; i < keys.length; ++i) {
            console.log("  key:", keys[i], "amount (WOOD-18):", wood[i]);
        }
    }

    /// @notice The Safe's batch: one transfer per approving key, then approve + stake the reserve.
    function plan(StakedWood swood, address safe, address[] memory keys, uint256[] memory wood, uint256 reserve)
        public
        view
        returns (Call[] memory calls)
    {
        require(keys.length > 0 && keys.length == wood.length, "StakeFleet: keys and amounts differ");
        IERC20 token = swood.wood();
        uint256 min = swood.minGuardianStake();
        require(reserve >= min, "StakeFleet: reserve below minGuardianStake");
        _requireFresh(swood, safe);

        uint256 total = reserve;
        calls = new Call[](keys.length + 2);
        for (uint256 i; i < keys.length; ++i) {
            require(keys[i] != safe, "StakeFleet: the Safe is the reserve and never approves");
            for (uint256 j; j < i; ++j) {
                require(keys[j] != keys[i], "StakeFleet: duplicate key");
            }
            require(wood[i] >= min, "StakeFleet: approving key below minGuardianStake");
            _requireFresh(swood, keys[i]);
            total += wood[i];
            calls[i] = Call(address(token), abi.encodeCall(IERC20.transfer, (keys[i], wood[i])));
        }
        require(token.balanceOf(safe) >= total, "StakeFleet: Safe holds too little WOOD");
        calls[keys.length] = Call(address(token), abi.encodeCall(IERC20.approve, (address(swood), reserve)));
        calls[keys.length + 1] = Call(address(swood), abi.encodeCall(StakedWood.stakeAsGuardian, (reserve, 0)));
    }

    function _requireFresh(StakedWood swood, address who) internal view {
        require(swood.guardianStake(who) == 0, "StakeFleet: already staked; a top-up resets the 30-day clock");
    }
}
