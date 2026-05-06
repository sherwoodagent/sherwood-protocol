// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Circle's official HyperEVM USDC bridge to HyperCore.
///         Strategies call `deposit(amount, destinationDex)` to move USDC
///         from EVM to HyperCore at a specific DEX (spot/perp/sub-account).
///         Source: github.com/circlefin/hyperevm-circle-contracts
interface ICoreDepositWallet {
    function deposit(uint256 amount, uint32 destinationDex) external;
}

/// @title HyperliquidBridge
/// @notice Explicit EVM→HyperCore bridge helper. Replaces the prior implicit
///         "auto-credit on transfer to a registered contract" assumption,
///         which the canonical ecosystem (Circle's CoreDepositWallet,
///         hyperliquid-dev/hyper-evm-lib's `bridgeToCore`, across-protocol's
///         HyperCoreLib) does NOT rely on for USDC. Without this explicit
///         bridge, USDC pulled from the vault sits on the strategy contract's
///         EVM address and HyperCore's spot balance never reflects it —
///         every subsequent `sendUsdClassTransfer` (HC spot → HC perp)
///         operates on an empty spot balance and silently no-ops.
///
///         Behavior on non-HyperEVM environments (foundry tests without
///         a deployed bridge, fork-tests against other chains): if the
///         CoreDepositWallet has no code, the function is a no-op so unit
///         tests don't need to mock the bridge. The strategy's `_settle`
///         + `sweepToVault` flow returns the un-bridged USDC to the vault.
library HyperliquidBridge {
    using SafeERC20 for IERC20;

    /// @notice Circle's CoreDepositWallet on HyperEVM mainnet (chain 999).
    /// @dev Source: hyperliquid-dev/hyper-evm-lib HLConstants.CORE_DEPOSIT_WALLET.
    ///      Verified deployed (4353 bytes runtime) at this address.
    address constant CORE_DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    /// @notice Sentinel for the spot DEX in CoreDepositWallet.deposit().
    /// @dev Mirrors `type(uint32).max` from hyper-evm-lib's bridgeToCore.
    uint32 constant SPOT_DEX = type(uint32).max;

    /// @notice Bridge USDC from this contract's EVM balance to its HC spot
    ///         balance via Circle's CoreDepositWallet.
    /// @dev Inlined into the calling strategy (library `internal`), so
    ///      `usdc.forceApprove` and `coreDepositWallet.deposit` execute with
    ///      `msg.sender == address(strategy)`. CoreDepositWallet pulls USDC
    ///      from the strategy via approve+transferFrom and credits the
    ///      strategy's HC spot account.
    /// @dev On non-HyperEVM environments where the bridge is not deployed,
    ///      this is a no-op — unit tests don't need a bridge mock; the
    ///      USDC stays on the strategy and is recovered at settle.
    function bridgeUsdcToSpot(IERC20 usdc, uint256 evmAmount) internal {
        if (evmAmount == 0) return;
        if (CORE_DEPOSIT_WALLET.code.length == 0) return;
        usdc.forceApprove(CORE_DEPOSIT_WALLET, evmAmount);
        ICoreDepositWallet(CORE_DEPOSIT_WALLET).deposit(evmAmount, SPOT_DEX);
    }
}
