// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal vault mock for `VaultWithdrawalQueue` (Lane B) unit tests:
///         share-token (ERC20) semantics plus the queue-callback surface the
///         frozen queue depends on (asset / redemptionsLocked / settleRedeem /
///         settleDeposit). The queue computes the frozen amounts; the vault just
///         mints / burns / pays exactly what it's told.
contract MockVault is ERC20("MV", "MV") {
    bool public locked;
    address public queue;
    IERC20 public immutable assetToken;
    address public lastRedeemTo;
    address public lastDepositTo;

    constructor(address asset_) {
        assetToken = IERC20(asset_);
    }

    function setQueue(address q) external {
        queue = q;
    }

    function setLocked(bool l) external {
        locked = l;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function redemptionsLocked() external view returns (bool) {
        return locked;
    }

    function settleRedeem(uint256 shares, uint256 assets, address to) external {
        require(msg.sender == queue, "auth");
        _burn(queue, shares);
        lastRedeemTo = to;
        require(assetToken.transfer(to, assets), "xfer");
    }

    function settleDeposit(uint256 shares, address to) external {
        require(msg.sender == queue, "auth");
        lastDepositTo = to;
        _mint(to, shares);
    }
}
