// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProposerBondEscrow} from "./interfaces/IProposerBondEscrow.sol";

interface IRegistryAuthMinimal {
    function isAuthorizedGovernor(address gov) external view returns (bool);
}

/**
 * @title ProposerBondEscrow
 * @notice Holds the risk-scaled proposer bond (spec 2026-07-22 §3.9) for the
 *         lifetime of a proposal. The proposer is the actual attacker in the
 *         threat model, so it posts capital scaled to what the proposal can
 *         extract; in v1a the bond's only exit is release back to the
 *         proposer once the proposal reaches a terminal state (the governor
 *         gates WHEN — see `SyndicateGovernor.reclaimProposerBond`).
 *         Forfeiture to the compensation escrow arrives with the challenge
 *         game (Plan C); this contract deliberately has no owner and no
 *         discretionary exit — the invariant `wood.balanceOf(this) ==
 *         sum of locked-unreleased bonds` holds by construction.
 */
contract ProposerBondEscrow is IProposerBondEscrow {
    using SafeERC20 for IERC20;

    struct Bond {
        address proposer;
        uint96 amount; // WOOD fits in uint96 (total supply << 2^96) — enforced by lockBond's AmountTooLarge guard, not assumed
    }

    IERC20 public immutable wood;
    IRegistryAuthMinimal public immutable registry;

    mapping(bytes32 bondKey => Bond) internal _bonds;

    constructor(address wood_, address registry_) {
        if (wood_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        wood = IERC20(wood_);
        registry = IRegistryAuthMinimal(registry_);
    }

    modifier onlyGovernor() {
        if (!registry.isAuthorizedGovernor(msg.sender)) revert NotAuthorizedGovernor();
        _;
    }

    function _key(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    /// @inheritdoc IProposerBondEscrow
    function lockBond(uint256 proposalId, address proposer, uint256 amount) external onlyGovernor {
        if (proposer == address(0)) revert ZeroAddress();
        if (amount > type(uint96).max) revert AmountTooLarge();
        bytes32 key = _key(msg.sender, proposalId);
        if (_bonds[key].proposer != address(0)) revert BondAlreadyLocked();
        _bonds[key] = Bond({proposer: proposer, amount: uint96(amount)});
        wood.safeTransferFrom(proposer, address(this), amount);
        emit BondLocked(msg.sender, proposalId, proposer, amount);
    }

    /// @inheritdoc IProposerBondEscrow
    /// @dev Governor-only: the governor's `reclaimProposerBond` resolves the
    ///      proposal to a TERMINAL state before calling — the escrow does not
    ///      re-derive lifecycle state.
    function releaseBond(uint256 proposalId) external onlyGovernor {
        bytes32 key = _key(msg.sender, proposalId);
        Bond memory b = _bonds[key];
        if (b.proposer == address(0)) revert NoBond();
        delete _bonds[key];
        wood.safeTransfer(b.proposer, b.amount);
        emit BondReleased(msg.sender, proposalId, b.proposer, b.amount);
    }

    /// @inheritdoc IProposerBondEscrow
    function bondOf(address governor, uint256 proposalId) external view returns (address, uint256) {
        Bond memory b = _bonds[_key(governor, proposalId)];
        return (b.proposer, b.amount);
    }
}
