// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Create3 — Deterministic deployment with constructor-arg-independent addresses
/// @notice Deploys contracts to the same address on any chain regardless of constructor args.
///         Uses CREATE2 to deploy a minimal trampoline, which then CREATEs the actual contract.
///         Final address depends only on (deployer, salt), not on init code.
/// @dev Based on the solady CREATE3 pattern.
library Create3 {
    // ── Errors ──
    error TrampolineDeployFailed();
    error DeployFailed();

    /// @dev Trampoline runtime bytecode.
    ///      Copies calldata (the init code) to memory and CREATEs a contract from it.
    ///      Bytecode: CALLDATASIZE DUP1 PUSH1(0) CALLDATACOPY PUSH1(0) DUP2 CREATE PUSH1(0) MSTORE PUSH1(20) PUSH1(12) RETURN
    ///      Hex:      36 3d 3d 37 36 3d 34 f0 3d 52 60 08 60 18 f3
    ///      Wrapped as creation code: PUSH15(<runtime>) PUSH1(0) MSTORE PUSH1(15) PUSH1(17) RETURN
    bytes private constant _TRAMPOLINE_CREATION_CODE = hex"6e363d3d37363d34f03d5260086018f3600052600f6011f3";

    /// @notice Deploy a contract via CREATE3
    /// @param salt Unique salt — same salt + same deployer = same final address on any chain
    /// @param creationCode abi.encodePacked(type(Contract).creationCode, abi.encode(constructorArgs))
    /// @return deployed The address of the deployed contract
    function deploy(bytes32 salt, bytes memory creationCode) internal returns (address deployed) {
        // 1. CREATE2 the trampoline (deterministic address based on deployer + salt)
        address trampoline;
        bytes memory tc = _TRAMPOLINE_CREATION_CODE;
        assembly {
            trampoline := create2(0, add(tc, 0x20), mload(tc), salt)
        }
        if (trampoline == address(0)) revert TrampolineDeployFailed();

        // 2. Call trampoline with creation code — it CREATEs the actual contract
        (bool success,) = trampoline.call(creationCode);
        deployed = _getDeployed(trampoline);
        if (!success || deployed.code.length == 0) revert DeployFailed();
    }

    /// @notice Predict the address that will be deployed for a given deployer + salt
    /// @param deployer The address that will call deploy() (typically address(this) in a script)
    /// @param salt The salt that will be used
    function addressOf(address deployer, bytes32 salt) internal pure returns (address) {
        // Predict trampoline address (CREATE2: keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode)))
        address trampoline = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(_TRAMPOLINE_CREATION_CODE))))
            )
        );
        // Predict deployed address (CREATE from trampoline with nonce=1: RLP([trampoline, 1]))
        return _getDeployed(trampoline);
    }

    /// @dev Compute the CREATE address from a deployer with nonce 1
    ///      RLP encoding of [address, 1] = 0xd6 0x94 <20-byte-address> 0x01
    function _getDeployed(address trampoline) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), trampoline, bytes1(0x01))))));
    }
}
