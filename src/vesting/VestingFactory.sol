// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TokenVesting} from "./TokenVesting.sol";

/// @title VestingFactory — deploy, initialize, and fund TokenVesting clones atomically
/// @notice Permissionless and unowned: whoever creates a wallet funds it
///         (tokens pulled from the caller) and names its owner. Funding is
///         atomic with creation; a zero-`amount` create is a valid unfunded
///         shell, funded later by plain transfer (allocation is
///         balance-derived).
///
///         Anyone can create wallets naming any beneficiary/owner/token —
///         consumers must filter `VestingCreated` by the indexed `creator`
///         topic.
contract VestingFactory {
    using SafeERC20 for IERC20;

    address public immutable implementation;

    mapping(address beneficiary => address[] wallets) private _walletsOf;

    event VestingCreated(
        address indexed wallet,
        address indexed beneficiary,
        address token,
        address indexed creator,
        address owner,
        uint256 amount,
        uint64 start,
        uint64 cliffDuration,
        uint64 duration,
        bool cancelable
    );

    constructor() {
        implementation = address(new TokenVesting());
    }

    /// @notice Deploy a TokenVesting clone, initialize it, and pull `amount`
    ///         tokens from the caller into it — one atomic call.
    /// @param owner Cancel authority: the only address that may `cancel()` the
    ///        wallet (when `cancelable`); receives the unvested residue.
    /// @param beneficiary Recipient of all vested tokens via `release()`.
    /// @param token ERC20 token being vested.
    /// @param start Vesting start timestamp (may be in the past or future).
    /// @param cliffDuration Seconds after `start` before anything vests;
    ///        0 = no cliff. At the cliff the linear-from-start amount unlocks
    ///        retroactively. Must not exceed `duration`.
    /// @param duration Total vesting length in seconds from `start`.
    /// @param cancelable Whether `owner` may cancel; immutable afterwards.
    /// @param amount Tokens pulled from `msg.sender` into the new wallet;
    ///        0 = valid unfunded shell, funded later by plain transfer.
    /// @return wallet Address of the new TokenVesting clone.
    function createVesting(
        address owner,
        address beneficiary,
        address token,
        uint64 start,
        uint64 cliffDuration,
        uint64 duration,
        bool cancelable,
        uint256 amount
    ) external returns (address wallet) {
        wallet = Clones.clone(implementation);
        TokenVesting(wallet).initialize(owner, beneficiary, token, start, cliffDuration, duration, cancelable);
        _walletsOf[beneficiary].push(wallet);
        if (amount > 0) IERC20(token).safeTransferFrom(msg.sender, wallet, amount);
        emit VestingCreated(
            wallet, beneficiary, token, msg.sender, owner, amount, start, cliffDuration, duration, cancelable
        );
    }

    /// @return All vesting wallets ever created for `beneficiary`, in
    ///         creation order (including cancelled ones).
    function walletsOf(address beneficiary) external view returns (address[] memory) {
        return _walletsOf[beneficiary];
    }
}
