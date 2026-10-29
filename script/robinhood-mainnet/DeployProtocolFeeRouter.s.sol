// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {DeploySalts} from "../DeploySalts.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ProtocolFeeRouter} from "../../src/ProtocolFeeRouter.sol";

interface ISafeMinimal {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// @title  DeployProtocolFeeRouter
/// @notice Mints the protocol-leg fee router (SHE-239) through CREATE3, owned by the Safe and in hold
///         mode, records it as `PROTOCOL_FEE_ROUTER`, and prints the `setProtocolFeeRecipient` call.
/// @dev    Seat it as soon as it is minted and BEFORE the first proposal: the governor snapshots the
///         recipient at propose. DeployAll's validation accepts the router, so the later handoff run still passes.
///
///   forge script script/robinhood-mainnet/DeployProtocolFeeRouter.s.sol:DeployProtocolFeeRouter \
///     --rpc-url robinhood --broadcast --sig "run(address)" <SAFE>
///
///   The Safe is an argument, not the book's `OWNER_MULTISIG`: during the deferred-handoff launch the
///   book names the deployer there.
contract DeployProtocolFeeRouter is ScriptBase {
    function run(address safe) external returns (ProtocolFeeRouter router) {
        address deployer = _readAddress("DEPLOYER");
        ProtocolConfig config = ProtocolConfig(_readAddress("PROTOCOL_CONFIG"));

        // Broadcast AS the book's deployer (the Create3Factory owner): forge refuses without its key.
        vm.startBroadcast(deployer);
        router = _deploy(safe, deployer);
        vm.stopBroadcast();

        // A dry run mints nothing on chain: never record or seat an address that holds no code yet.
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console.log("DRY RUN: nothing minted. Do NOT seat", address(router), "until a --broadcast run.");
            return router;
        }
        _patchAddress("PROTOCOL_FEE_ROUTER", address(router));

        console.log("ProtocolFeeRouter:", address(router));
        console.log("NEXT, from the ProtocolConfig owner", Ownable(address(config)).owner(), "- before any proposal:");
        console.log("  target:", address(config));
        console.logBytes(abi.encodeCall(ProtocolConfig.setProtocolFeeRecipient, (address(router))));
        console.log("current protocolFeeRecipient:", config.protocolFeeRecipient());
    }

    /// @notice The router at its salt. A fresh mint must be owned by `safe` and in hold mode; an adopted one
    ///         must carry the pinned code and a non-deployer contract owner.
    /// @dev The caller must own the Create3Factory (`_c3Factory` bootstraps it at `msg.sender`).
    function deploy(address safe) public returns (ProtocolFeeRouter router) {
        return _deploy(safe, msg.sender);
    }

    function _deploy(address safe, address deployer) internal returns (ProtocolFeeRouter router) {
        _requireSafe(safe);
        require(
            keccak256(type(ProtocolFeeRouter).runtimeCode) == DeploySalts.PROTOCOL_FEE_ROUTER_RUNTIME_HASH,
            "ProtocolFeeRouter runtime hash drift: re-record DeploySalts.PROTOCOL_FEE_ROUTER_RUNTIME_HASH"
        );
        Create3Factory c3 = _c3Factory(deployer);
        bool fresh = _predict(c3, DeploySalts.PROTOCOL_FEE_ROUTER).code.length == 0;
        bytes memory initcode = abi.encodePacked(type(ProtocolFeeRouter).creationCode, abi.encode(safe));
        router = ProtocolFeeRouter(_c3(c3, DeploySalts.PROTOCOL_FEE_ROUTER, initcode));

        // Code first: on adopt, `owner()` is only meaningful once the code is known to be the router.
        _requireProtocolFeeRouter(address(router), deployer);
        if (fresh) {
            require(router.owner() == safe, "DeployProtocolFeeRouter: owner is not the Safe");
            require(router.allocations().length == 0, "DeployProtocolFeeRouter: not in hold mode");
        } else if (router.owner() != safe) {
            console.log("ADOPTED an existing router; its owner", router.owner(), "is NOT the Safe passed:", safe);
        }
        console.log("router owner:", router.owner(), "allocations:", router.allocations().length);
    }

    /// @dev Any contract has code, so ask it the question only a Safe answers.
    function _requireSafe(address safe) internal view {
        require(safe.code.length != 0, "DeployProtocolFeeRouter: the Safe must be a contract, not an EOA");
        try ISafeMinimal(safe).getThreshold() returns (uint256 threshold) {
            require(threshold != 0, "DeployProtocolFeeRouter: Safe threshold is zero");
            console.log("Safe threshold:", threshold, "owners:", ISafeMinimal(safe).getOwners().length);
        } catch {
            revert("DeployProtocolFeeRouter: owner does not answer getThreshold(); not a Safe");
        }
    }
}
