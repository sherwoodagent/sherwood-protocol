// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal mock LayerZero endpoint for testing WoodToken (OFT)
/// @dev Only implements setDelegate which is called in OAppCore constructor
contract MockLzEndpoint {
    mapping(address => address) public delegates;

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }
}
