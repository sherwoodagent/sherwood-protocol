// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L1Write} from "./L1Write.sol";

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

    /// @notice Sentinel for the spot DEX in CoreDepositWallet.deposit() and
    ///         in `sendAsset` source/destination dex fields.
    /// @dev Mirrors `type(uint32).max` from hyper-evm-lib's bridgeToCore /
    ///      HLConstants.SPOT_DEX.
    uint32 constant SPOT_DEX = type(uint32).max;

    /// @notice Base system address on HyperCore for HC spot → EVM token
    ///         bridges. The system address for token index N is
    ///         `BASE_SYSTEM_ADDRESS + N`. For USDC (token index 0) the
    ///         system address is `0x2000...0000` itself.
    /// @dev Source: hyperliquid-dev/hyper-evm-lib HLConstants.BASE_SYSTEM_ADDRESS.
    uint160 constant BASE_SYSTEM_ADDRESS = uint160(0x2000000000000000000000000000000000000000);

    /// @notice HyperCore token index for USDC.
    /// @dev Source: hyperliquid-dev/hyper-evm-lib HLConstants.USDC_TOKEN_INDEX.
    uint64 constant USDC_TOKEN_INDEX = 0;

    /// @notice Spot-wei scaling factor between HC perp (6-decimal) and HC
    ///         spot (8-decimal). HC perp `accountValue` * 100 == HC spot wei
    ///         for the same USD amount.
    /// @dev Source: hyperliquid-dev/hyper-evm-lib HLConversions.perpToWei.
    uint64 constant PERP_TO_SPOT_WEI = 100;

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

    /// @notice Bridge USDC from this contract's HC spot balance to its EVM
    ///         address. Issues a CoreWriter `sendAsset` action targeted at
    ///         the USDC system address (`0x2000...0000`); HC's system actor
    ///         processes it post-block, drains the amount from the strategy's
    ///         HC spot, and calls `CoreDepositWallet.transfer(strategy, evmAmount)`
    ///         to deliver USDC back on EVM.
    /// @dev    `spotWeiAmount` is in HC spot wei (8-decimal for USDC). To
    ///         bridge a perp-domain amount (6-decimal `accountValue`), multiply
    ///         by `PERP_TO_SPOT_WEI` (= 100) first.
    /// @dev    HYPE GAS REQUIREMENT: per hyper-evm-lib's note on
    ///         `bridgeToEvm` ("the contract must hold some HYPE on core"),
    ///         non-HYPE outbound bridges consume HC-side gas. If the strategy's
    ///         HC HYPE balance is zero, the action no-ops on the HC side and
    ///         the USDC remains on HC spot — recovery requires either funding
    ///         the strategy's HC HYPE balance and re-firing this action, or
    ///         off-chain recovery via the HL exchange API.
    /// @dev    No-op on non-HyperEVM environments (precompile address has no
    ///         code). Settle paths can call this unconditionally.
    function bridgeUsdcSpotToEvm(uint64 spotWeiAmount) internal {
        if (spotWeiAmount == 0) return;
        // Skip on non-HyperEVM env. The CoreWriter precompile is at a fixed
        // address; if no code, we're in a fork/test without HC plumbing.
        if (L1Write.CORE_WRITER_ADDRESS.code.length == 0) return;
        L1Write.sendAsset(
            address(BASE_SYSTEM_ADDRESS + USDC_TOKEN_INDEX),
            address(0),
            SPOT_DEX,
            SPOT_DEX,
            USDC_TOKEN_INDEX,
            spotWeiAmount
        );
    }
}
