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

    /// @dev Mirrors `SyndicateFactory.MAX_PAGE_LIMIT` / `SyndicateVault.MAX_PAGE_LIMIT`:
    ///      hard cap on `walletsOfPaginated`'s `limit` so the call always fits
    ///      in a node's `eth_call` gas budget no matter how large `_walletsOf`
    ///      grows for a given beneficiary (see `walletsOf`'s DoS note).
    uint256 public constant MAX_PAGE_LIMIT = 100;

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

    /// @notice Unpaginated: returns the ENTIRE array for `beneficiary`.
    /// @dev DoS HAZARD: `createVesting` is permissionless, accepts an
    ///      arbitrary `beneficiary`, and a zero-`amount` create is a valid,
    ///      cheap (one clone + one SSTORE) unfunded shell — so anyone can
    ///      inflate any address's wallet list until this call exceeds a
    ///      node's `eth_call` gas budget, breaking on-chain enumeration for
    ///      that beneficiary. Prefer `walletsOfPaginated` (clamped to
    ///      `MAX_PAGE_LIMIT` per call) or `walletCountOf`, or fall back to
    ///      the indexed `VestingCreated` events. Kept for backward
    ///      compatibility only.
    /// @return All vesting wallets ever created for `beneficiary`, in
    ///         creation order (including cancelled ones).
    function walletsOf(address beneficiary) external view returns (address[] memory) {
        return _walletsOf[beneficiary];
    }

    /// @notice Number of vesting wallets ever created for `beneficiary`
    ///         (including cancelled ones). Use with `walletsOfPaginated` to
    ///         enumerate without the DoS hazard of `walletsOf`.
    function walletCountOf(address beneficiary) external view returns (uint256) {
        return _walletsOf[beneficiary].length;
    }

    /// @notice Paginated `walletsOf`: a slice `[offset, offset +
    ///         min(limit, MAX_PAGE_LIMIT))` clipped to the beneficiary's
    ///         wallet count, in creation order. Returns an empty array when
    ///         `offset >= walletCountOf(beneficiary)`. Mirrors
    ///         `SyndicateVaultAdminLib.pageAddresses`'s clamping.
    /// @param beneficiary Address whose wallets to page through.
    /// @param offset Starting index (0-based) into the beneficiary's wallets.
    /// @param limit Maximum number of results to return; clamped to
    ///        `MAX_PAGE_LIMIT`.
    function walletsOfPaginated(address beneficiary, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory out)
    {
        address[] storage wallets = _walletsOf[beneficiary];
        uint256 total = wallets.length;
        if (offset >= total) return new address[](0);
        if (limit > MAX_PAGE_LIMIT) limit = MAX_PAGE_LIMIT;
        uint256 end = offset + limit;
        if (end > total) end = total;
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = wallets[i];
        }
    }
}
