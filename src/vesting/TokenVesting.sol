// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title TokenVesting — cancelable linear ERC20 vesting with optional retroactive cliff
/// @notice ERC-1167 clonable. One wallet per (beneficiary, grant). Schedule is
///         immutable after `initialize`; the owner's only power is `cancel()`
///         (and only when the wallet was created cancelable).
///
///         Allocation is derived — `token.balanceOf(this) + released` — so
///         funding is a plain transfer and top-ups extend the same curve.
///         `cancel()` freezes the vested amount: what vested stays claimable
///         by the beneficiary; the unvested residue returns to the owner.
///
///         Tokens transferred to the wallet AFTER `cancel()` (or any
///         non-vesting ERC20 sent at any time) are unrecoverable — there is
///         deliberately no sweep/rescue function.
///
///         Use plain ERC20s only — no blacklisting, rebasing, or deflationary
///         behavior. A token that can blacklist the beneficiary strands the
///         vested-but-unreleased slice forever (`beneficiary` is immutable and
///         `cancel()` recovers only the unvested residue); a token that can
///         block transfers TO the owner bricks `cancel()` itself (the residue
///         is pushed to the owner in the same call). Balance shrinkage is
///         tolerated — `releasable()` clamps to zero and catches up as the
///         curve advances, and `cancel()` clamps the residue to the wallet
///         balance (in that state the owner sweeps what remains; the
///         beneficiary's earlier over-released amount already absorbed the
///         shrink).
///
///         `owner` is fixed at initialization (no rotation): pick a durable
///         address (multisig). Note a cancelable grant can be cancelled just
///         before the cliff for zero beneficiary payout — inherent to the
///         retroactive-cliff design.
contract TokenVesting is Initializable {
    using SafeERC20 for IERC20;

    address public owner;
    address public beneficiary;
    IERC20 public token;
    uint64 public start;
    uint64 public cliff;
    uint64 public duration;
    bool public cancelable;
    bool public cancelled;
    uint256 public released;
    /// @dev Vested amount frozen at cancel; only meaningful when `cancelled`.
    uint256 private _vestedAtCancel;

    error ZeroAddress();
    error ZeroDuration();
    error CliffExceedsDuration();
    error ScheduleOverflow();
    error NotOwner();
    error NotCancelable();
    error AlreadyCancelled();

    event Released(uint256 amount);
    event VestingCancelled(uint256 vested, uint256 residue);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address beneficiary_,
        address token_,
        uint64 start_,
        uint64 cliffDuration_,
        uint64 duration_,
        bool cancelable_
    ) external initializer {
        if (owner_ == address(0) || beneficiary_ == address(0) || token_ == address(0)) {
            revert ZeroAddress();
        }
        if (duration_ == 0) revert ZeroDuration();
        if (cliffDuration_ > duration_) revert CliffExceedsDuration();
        if (start_ > type(uint64).max - duration_) revert ScheduleOverflow();
        owner = owner_;
        beneficiary = beneficiary_;
        token = IERC20(token_);
        start = start_;
        cliff = start_ + cliffDuration_;
        duration = duration_;
        cancelable = cancelable_;
    }

    /// @notice Total tokens governed by this wallet: current balance plus
    ///         everything already released. Frozen at `cancel()`.
    function totalAllocation() public view returns (uint256) {
        if (cancelled) return _vestedAtCancel;
        return token.balanceOf(address(this)) + released;
    }

    /// @notice Vested amount at `timestamp`. Zero before the cliff; at the
    ///         cliff the linear-from-start amount unlocks retroactively.
    ///         After `cancel()` this is the frozen vested amount regardless
    ///         of `timestamp`.
    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        uint256 total = totalAllocation();
        if (cancelled) return total;
        if (timestamp < cliff) return 0;
        if (timestamp >= start + duration) return total;
        return (total * (timestamp - start)) / duration;
    }

    function releasable() public view returns (uint256) {
        uint256 vested = vestedAmount(uint64(block.timestamp));
        return vested > released ? vested - released : 0;
    }

    /// @notice Transfer everything vested-but-unreleased to the beneficiary.
    ///         Permissionless — anyone may trigger a payout to the beneficiary.
    function release() external {
        uint256 amount = releasable();
        if (amount == 0) return;
        released += amount;
        token.safeTransfer(beneficiary, amount);
        emit Released(amount);
    }

    /// @notice Stop vesting. The amount vested so far stays claimable by the
    ///         beneficiary via `release()`; the unvested residue transfers to
    ///         the owner immediately. Irreversible.
    function cancel() external {
        if (msg.sender != owner) revert NotOwner();
        if (!cancelable) revert NotCancelable();
        if (cancelled) revert AlreadyCancelled();
        uint256 vested = vestedAmount(uint64(block.timestamp));
        uint256 residue = totalAllocation() - vested;
        uint256 balance = token.balanceOf(address(this));
        if (residue > balance) residue = balance; // shrunken state: sweep what's actually left
        cancelled = true;
        _vestedAtCancel = vested;
        if (residue > 0) token.safeTransfer(owner, residue);
        emit VestingCancelled(vested, residue);
    }
}
