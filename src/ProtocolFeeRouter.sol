// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";

/// @title ProtocolFeeRouter
/// @notice The `ProtocolConfig.protocolFeeRecipient`: holds the protocol's fee leg and
///         forwards it per owner-set allocations through a permissionless `distribute`.
/// @dev Posture-neutral by design (SHE-239): addresses and bps only, no swap, no burn.
///      Starts in hold mode (no allocations), where fees only accrue.
contract ProtocolFeeRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Allocation {
        address target;
        uint16 bps;
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_ALLOCATIONS = 8;

    Allocation[] private _allocations;

    event AllocationsSet(Allocation[] allocations);
    event Distributed(address indexed token, uint256 amount, bytes32 allocationsHash);
    event Held(address indexed token, uint256 balance);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error InvalidAllocationSum(uint256 sum);
    error TooManyAllocations(uint256 count);
    error InvalidTarget(address target);
    error ZeroBps(address target);
    error DuplicateTarget(address target);
    error ZeroAddress();
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Replace every leg at once. Empty returns the router to hold mode.
    function setAllocations(Allocation[] calldata allocations_) external onlyOwner {
        uint256 n = allocations_.length;
        if (n > MAX_ALLOCATIONS) revert TooManyAllocations(n);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            Allocation calldata a = allocations_[i];
            if (a.target == address(0) || a.target == address(this)) revert InvalidTarget(a.target);
            if (a.bps == 0) revert ZeroBps(a.target);
            for (uint256 j; j < i; ++j) {
                if (allocations_[j].target == a.target) revert DuplicateTarget(a.target);
            }
            sum += a.bps;
        }
        if (n != 0 && sum != BPS_DENOMINATOR) revert InvalidAllocationSum(sum);

        delete _allocations;
        for (uint256 i; i < n; ++i) {
            _allocations.push(allocations_[i]);
        }
        emit AllocationsSet(allocations_);
    }

    /// @notice Forward this router's whole balance of `token` across the legs. Anyone may call.
    function distribute(address token) external nonReentrant {
        _distribute(token);
    }

    function distributeMany(address[] calldata tokens) external nonReentrant {
        for (uint256 i; i < tokens.length; ++i) {
            _distribute(tokens[i]);
        }
    }

    /// @notice Pull a fee the governor escrowed for this router after a failed transfer.
    /// @dev The governor pays escrow only to `msg.sender`, so without this the router's
    ///      escrowed fees would be unclaimable. Funds land here, never with the caller.
    function claimEscrowedFees(address governor, address vault, address token) external nonReentrant {
        ISyndicateGovernor(governor).claimUnclaimedFees(vault, token);
    }

    /// @notice Owner recovery for any token, fee assets included (SHE-239: the alternative is stranding).
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @notice Disabled: an ownerless router in hold mode would strand every fee it ever receives.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    function allocations() external view returns (Allocation[] memory) {
        return _allocations;
    }

    function allocationsHash() public view returns (bytes32) {
        Allocation[] memory a = _allocations;
        return keccak256(abi.encode(a));
    }

    function _distribute(address token) private {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 n = _allocations.length;
        if (n == 0) {
            emit Held(token, balance);
            return;
        }
        if (balance == 0) return;

        // The last leg takes the remainder, so rounding dust never strands here.
        uint256 sent;
        for (uint256 i; i < n; ++i) {
            Allocation memory a = _allocations[i];
            uint256 amount = i == n - 1 ? balance - sent : (balance * a.bps) / BPS_DENOMINATOR;
            sent += amount;
            if (amount != 0) IERC20(token).safeTransfer(a.target, amount);
        }
        emit Distributed(token, balance, allocationsHash());
    }
}
