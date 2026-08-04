// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A real ERC-4626 wrapper over a test ERC-20, standing in for the
///         `spUSDG`-over-`USDG` shape measured on Robinhood Chain 4663.
/// @dev    OpenZeppelin's implementation rather than a hand-rolled stub: the
///         strategy's collateral check probes `asset()` and its execute/settle
///         paths call `deposit`/`redeem`, so the share-accounting and the
///         decimals-offset behaviour need to be the real ones. A stub that
///         returned shares 1:1 would hide a rounding direction the settlement
///         path depends on.
///
///         Distinct from `MockERC4626Vault`, which is a totalAssets()/owner()
///         surface for GuardianRegistry bond tests and implements none of this.
///         The redemption levers below exist because the strategy's settlement
///         path treats this contract as a THIRD PARTY it does not control: a
///         real spUSDG-class wrapper can pause, cap or fee its redemptions
///         without asking the proposal that holds its shares. A wrapper that
///         only ever succeeds cannot exercise that, so it cannot show whether
///         settlement survives it.
contract MockERC4626Wrapper is ERC4626 {
    /// @notice Fee retained by the wrapper on the way out, in bps.
    /// @dev    Overriding `previewRedeem` alone is sufficient AND coherent:
    ///         OpenZeppelin's `redeem` prices through `previewRedeem` and then
    ///         burns the full share count, so the fee stays in the vault exactly
    ///         as a real one would.
    uint256 public exitFeeBps;

    /// @notice Redemption is refused outright.
    bool public redeemPaused;

    /// @notice Ceiling on shares redeemable in one call. Defaults to unlimited.
    uint256 public redeemCap = type(uint256).max;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}

    function setExitFeeBps(uint256 bps) external {
        exitFeeBps = bps;
    }

    function setRedeemPaused(bool paused) external {
        redeemPaused = paused;
    }

    function setRedeemCap(uint256 cap) external {
        redeemCap = cap;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return (super.previewRedeem(shares) * (10_000 - exitFeeBps)) / 10_000;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 held = super.maxRedeem(owner);
        return held < redeemCap ? held : redeemCap;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        require(!redeemPaused, "MockERC4626Wrapper: redeem paused");
        return super.redeem(shares, receiver, owner);
    }
}
