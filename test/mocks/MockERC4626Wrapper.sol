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
contract MockERC4626Wrapper is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}
}
