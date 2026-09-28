// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The one asset-leg rule: enforced by the vault at execute and settle, mirrored by the
///         governor at propose, so a stored leg can never pass one and revert at the other.
library AssetCallRules {
    /// @dev A call on the asset is a metered transfer (`transferFrom` from `vault` only) or
    ///      allowance-shaped: its first argument is the spender to reset after the batch.
    ///      Returns that spender, or zero when the call names none.
    function spenderOf(address vault, bytes calldata data) internal pure returns (address) {
        if (data.length < 36) {
            revert ISyndicateVault.MalformedAssetCall(data.length >= 4 ? bytes4(data[0:4]) : bytes4(0));
        }
        bytes4 sel = bytes4(data[0:4]);
        bytes32 arg0 = bytes32(data[4:36]);
        if (sel == IERC20.transferFrom.selector) {
            if (arg0 != bytes32(uint256(uint160(vault)))) {
                revert ISyndicateVault.TransferFromNotVault(address(uint160(uint256(arg0))));
            }
            return address(0);
        }
        if (sel == IERC20.transfer.selector) return address(0);
        return address(uint160(uint256(arg0)));
    }
}
