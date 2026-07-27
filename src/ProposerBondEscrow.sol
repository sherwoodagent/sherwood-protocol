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
 *         discretionary exit — the invariant `wood.balanceOf(this) >=
 *         sum of locked-unreleased bonds` holds by construction (equality
 *         absent direct transfers; surplus from donations is permanently
 *         stuck, accepted for v1a).
 */
contract ProposerBondEscrow is IProposerBondEscrow {
    using SafeERC20 for IERC20;

    struct Bond {
        address proposer;
        uint96 amount; // WOOD fits in uint96 (total supply << 2^96) — enforced by lockBond's AmountTooLarge guard, not assumed
    }

    /// @dev Integration requirement: WOOD must be a standard ERC20 — no
    ///      transfer fee, no rebasing, no hooks, AND NO BLOCKLIST (review m3).
    ///      A fee-on-transfer token would make the escrow insolvent (recorded
    ///      amounts exceed held balance). A blocklisting token is the quieter
    ///      hazard: `releaseBond` pays the RECORDED proposer, so blocklisting
    ///      that address strands the bond permanently — there is no alternate
    ///      payee and no sweep. Informational while WOOD is in-house, and a
    ///      hard requirement on any future bond token.
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
    /// @dev `proposer` COMES FROM THE CALLER, not from `msg.sender` (review m4).
    ///      Any authorized governor can therefore lock a bond against any
    ///      address that has approved this escrow — and agents hold standing
    ///      approvals in normal operation. It is a lockup grief rather than
    ///      theft: the bond is recorded to that address and returns to it on
    ///      release or reclaim, so nothing can be redirected. Governors are
    ///      factory-registered, so the caller set is not open — but a
    ///      compromised or buggy governor can freeze a third party's WOOD for
    ///      the life of a proposal it did not consent to.
    function lockBond(uint256 proposalId, address proposer, uint256 amount) external onlyGovernor {
        if (proposer == address(0)) revert ZeroAddress();
        if (amount > type(uint96).max) revert AmountTooLarge();
        bytes32 key = _key(msg.sender, proposalId);
        if (_bonds[key].proposer != address(0)) revert BondAlreadyLocked();
        // casting to 'uint96' is safe: the AmountTooLarge guard above bounds amount <= type(uint96).max
        // forge-lint: disable-next-line(unsafe-typecast)
        _bonds[key] = Bond({proposer: proposer, amount: uint96(amount)});
        wood.safeTransferFrom(proposer, address(this), amount);
        emit BondLocked(msg.sender, proposalId, proposer, amount);
    }

    /// @inheritdoc IProposerBondEscrow
    /// @dev The governor's `reclaimProposerBond` resolves the proposal to a
    ///      TERMINAL state before calling — the escrow does not re-derive
    ///      lifecycle state. Deliberately NOT gated on the live registry
    ///      check: the bond key binds to msg.sender, so only the governor
    ///      that locked a bond can ever address it — a random caller computes
    ///      key(caller, proposalId) and hits NoBond. Skipping the live check
    ///      means a later-deauthorized governor can still release open bonds
    ///      to the recorded proposer instead of stranding them forever.
    ///      `lockBond` keeps onlyGovernor — that is where trust matters.
    function releaseBond(uint256 proposalId) external {
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
