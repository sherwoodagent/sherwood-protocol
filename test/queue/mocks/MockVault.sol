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
    /// @dev Stands in for the real vault's `depositsLocked()` — an open proposal
    ///      OR a settled strategy still holding a residue. The queue's deposit
    ///      claim gates on this (finding #3), so the tests drive it directly
    ///      rather than modelling a strategy.
    bool public depositsLockedFlag;
    address public queue;
    IERC20 public immutable assetToken;
    address public lastRedeemTo;
    address public lastDepositTo;
    /// @dev Live assets->shares rate, settable so a test can move the price
    ///      between request and claim — which is exactly what a swept-in residue
    ///      does to the real vault. Defaults to 1:1.
    uint256 public convertNum = 1;
    uint256 public convertDen = 1;

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

    function setDepositsLocked(bool l) external {
        depositsLockedFlag = l;
    }

    function depositsLocked() external view returns (bool) {
        return depositsLockedFlag;
    }

    /// @dev Set the live price a deposit claim will convert at. `num/den` is
    ///      shares-per-asset: a HIGHER den (more assets backing each share)
    ///      means a deposit mints FEWER shares, which is what a residue arriving
    ///      into the pool does.
    function setConvertRate(uint256 num, uint256 den) external {
        convertNum = num;
        convertDen = den;
    }

    /// @dev The queue's deposit claim prices through `previewDeposit`, which on
    ///      the real vault includes value settled strategies still owe. Here it
    ///      is just the settable rate.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return (assets * convertNum) / convertDen;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * convertNum) / convertDen;
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
