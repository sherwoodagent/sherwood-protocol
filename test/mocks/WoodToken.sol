// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title WOOD
/// @notice ⚠️ NON-PRODUCTION — OUT OF SCOPE FOR AUDIT. Mainnet WOOD is an
///         existing external ERC20 launch; this fixture mirrors its shape so
///         local/fork/testnet deploys have a WOOD-shaped token to wire against.
///
///         Vanilla OpenZeppelin v5 ERC20:
///   - 18 decimals (the OZ default).
///   - Fixed supply minted to the deployer in the constructor. No mint after deploy.
///   - Ownable + ownership renounced inside the constructor — `owner()` returns
///     address(0) the instant the contract is deployed, visibly on the explorer.
///   - No tax, no rebase, no blacklist, no pause. Required for Uniswap V2's
///     standard constant-product swap math.
contract WOOD is ERC20, Ownable {
    /// @param name_ token name
    /// @param symbol_ token symbol
    /// @param totalSupply_ already scaled to 18 decimals (raw units)
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _mint(msg.sender, totalSupply_);
        renounceOwnership();
    }
}
