// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStakedWood} from "../../src/interfaces/IStakedWood.sol";

/// @dev Intentionally unused on this branch (Task 7.1) — committed ahead of
///      time; wired into the governor test suites in a later task (Task 8.x).
///      Not dead code.
/// @notice Minimal `IStakedWood` mock for tests that exercise the slimmed
///         `GuardianRegistry` / `SyndicateGovernor` surfaces without needing a
///         full `StakedWood` proxy + WOOD-staking setup. Every read is a
///         settable storage slot; the registry-only mutations
///         (`slashGuardians`, `slashOwnerBond`) are no-ops
///         that record their last arguments so emergency-flow tests can assert
///         the governor/registry called sWOOD.
///
///         Mirrors the shape of `MockRegistryMinimal`: defaults model an
///         "empty cohort" — `getPast*` returns 0, `isActiveGuardian` returns
///         false, totals are 0 — so governor unit tests that only touch the
///         optimistic path keep their previous semantics. Tests that drive
///         guardian-review slashing should use a real `StakedWood` proxy via
///         `RegistryTestHarness`.
contract MockStakedWood is IStakedWood {
    // ── Settable reads ──
    address public wood;
    mapping(address => uint256) internal _votes;
    mapping(address => mapping(uint256 => uint256)) internal _pastVotes;
    mapping(uint256 => uint256) internal _pastTotalVotes;
    mapping(uint256 => uint256) internal _pastTotalSupply;
    mapping(uint256 => uint256) internal _pastTotalDelegated;
    mapping(uint256 => uint256) internal _pastTotalActiveDelegated;
    mapping(address => mapping(uint256 => uint256)) internal _pastCommission;
    mapping(address => mapping(address => mapping(uint256 => uint256))) internal _pastDelegation;
    mapping(address => mapping(uint256 => uint256)) internal _pastDelegatedInbound;
    mapping(address => uint256) internal _requiredOwnerBond;
    mapping(address => uint256) internal _ownerStake;
    mapping(address => bool) internal _isActiveGuardian;
    uint256 public totalGuardianStake;
    uint256 public totalDelegatedStake;
    mapping(address => uint256) internal _guardianStake;
    mapping(address => mapping(address => uint256)) internal _delegationOf;
    mapping(address => uint256) internal _delegatedInbound;
    mapping(address => uint256) internal _commissionOf;
    mapping(address => uint256) internal _preparedStakeOf;
    mapping(address => bool) internal _canCreateVault;
    uint256 public flatRequiredOwnerBond;
    uint256 public minSlashBps;
    uint256 public maxSlashBps;
    uint256 public coolDownPeriod;

    // ── Recorded mutation args (for assertions) ──
    uint256 public slashGuardiansCallCount;
    bytes32 public lastSlashReviewKey;
    uint256 public lastSlashBps;
    uint256 public slashOwnerBondCallCount;
    address public lastSlashedVault;

    // ── Setters ──
    function setWood(address w) external {
        wood = w;
    }

    function setVotes(address account, uint256 v) external {
        _votes[account] = v;
    }

    function setPastVotes(address guardian, uint256 timestamp, uint256 v) external {
        _pastVotes[guardian][timestamp] = v;
    }

    function setPastTotalVotes(uint256 timestamp, uint256 v) external {
        _pastTotalVotes[timestamp] = v;
    }

    function setPastTotalSupply(uint256 timestamp, uint256 v) external {
        _pastTotalSupply[timestamp] = v;
    }

    function setPastTotalDelegated(uint256 timestamp, uint256 v) external {
        _pastTotalDelegated[timestamp] = v;
    }

    function setPastTotalActiveDelegated(uint256 timestamp, uint256 v) external {
        _pastTotalActiveDelegated[timestamp] = v;
    }

    function setPastCommission(address delegate, uint256 timestamp, uint256 v) external {
        _pastCommission[delegate][timestamp] = v;
    }

    function setPastDelegation(address delegator, address delegate, uint256 timestamp, uint256 v) external {
        _pastDelegation[delegator][delegate][timestamp] = v;
    }

    function setPastDelegatedInbound(address delegate, uint256 timestamp, uint256 v) external {
        _pastDelegatedInbound[delegate][timestamp] = v;
    }

    function setRequiredOwnerBond(address vault, uint256 v) external {
        _requiredOwnerBond[vault] = v;
    }

    function setFlatRequiredOwnerBond(uint256 v) external {
        flatRequiredOwnerBond = v;
    }

    function setOwnerStake(address vault, uint256 v) external {
        _ownerStake[vault] = v;
    }

    function setActiveGuardian(address guardian, bool active) external {
        _isActiveGuardian[guardian] = active;
    }

    function setTotalGuardianStake(uint256 v) external {
        totalGuardianStake = v;
    }

    function setTotalDelegatedStake(uint256 v) external {
        totalDelegatedStake = v;
    }

    function setGuardianStake(address guardian, uint256 v) external {
        _guardianStake[guardian] = v;
    }

    function setDelegationOf(address delegator, address delegate, uint256 v) external {
        _delegationOf[delegator][delegate] = v;
    }

    function setDelegatedInbound(address delegate, uint256 v) external {
        _delegatedInbound[delegate] = v;
    }

    function setCommissionOf(address delegate, uint256 v) external {
        _commissionOf[delegate] = v;
    }

    function setPreparedStakeOf(address owner, uint256 v) external {
        _preparedStakeOf[owner] = v;
    }

    function setCanCreateVault(address owner, bool v) external {
        _canCreateVault[owner] = v;
    }

    function setSlashBounds(uint256 minBps, uint256 maxBps) external {
        minSlashBps = minBps;
        maxSlashBps = maxBps;
    }

    // ── Checkpoint reads ──
    function getVotes(address account) external view returns (uint256) {
        return _votes[account];
    }

    function getPastVotes(address guardian, uint256 timestamp) external view returns (uint256) {
        return _pastVotes[guardian][timestamp];
    }

    function getPastTotalVotes(uint256 timestamp) external view returns (uint256) {
        return _pastTotalVotes[timestamp];
    }

    function getPastTotalSupply(uint256 timestamp) external view returns (uint256) {
        return _pastTotalSupply[timestamp];
    }

    function getPastTotalDelegated(uint256 timestamp) external view returns (uint256) {
        return _pastTotalDelegated[timestamp];
    }

    function getPastTotalActiveDelegated(uint256 timestamp) external view returns (uint256) {
        return _pastTotalActiveDelegated[timestamp];
    }

    function getPastCommission(address delegate, uint256 timestamp) external view returns (uint256) {
        return _pastCommission[delegate][timestamp];
    }

    function getPastDelegation(address delegator, address delegate, uint256 timestamp) external view returns (uint256) {
        return _pastDelegation[delegator][delegate][timestamp];
    }

    function getPastDelegatedInbound(address delegate, uint256 timestamp) external view returns (uint256) {
        return _pastDelegatedInbound[delegate][timestamp];
    }

    // ── Live reads ──
    function requiredOwnerBond(address vault) external view returns (uint256) {
        uint256 perVault = _requiredOwnerBond[vault];
        return perVault != 0 ? perVault : flatRequiredOwnerBond;
    }

    function isActiveGuardian(address guardian) external view returns (bool) {
        return _isActiveGuardian[guardian];
    }

    function guardianStake(address guardian) external view returns (uint256) {
        return _guardianStake[guardian];
    }

    function ownerStake(address vault) external view returns (uint256) {
        return _ownerStake[vault];
    }

    function delegationOf(address delegator, address delegate) external view returns (uint256) {
        return _delegationOf[delegator][delegate];
    }

    function delegatedInbound(address delegate) external view returns (uint256) {
        return _delegatedInbound[delegate];
    }

    function commissionOf(address delegate) external view returns (uint256) {
        return _commissionOf[delegate];
    }

    function preparedStakeOf(address owner) external view returns (uint256) {
        return _preparedStakeOf[owner];
    }

    function canCreateVault(address owner) external view returns (bool) {
        return _canCreateVault[owner];
    }

    // ── Registry-only mutations (no-op stubs that record args) ──
    // Sherlock run #3 #6: signature carries `openedAt` — sWOOD sizes the own
    // and delegated slash legs off disjoint at-open snapshots (raw own-stake
    // checkpoint + `getPastDelegatedInbound`). Mock ignores it.
    function slashGuardians(
        bytes32 reviewKey,
        uint256,
        /* openedAt */
        address[] calldata,
        uint256 slashBps
    )
        external
    {
        slashGuardiansCallCount++;
        lastSlashReviewKey = reviewKey;
        lastSlashBps = slashBps;
    }

    function slashOwnerBond(address vault) external {
        slashOwnerBondCallCount++;
        lastSlashedVault = vault;
        _ownerStake[vault] = 0;
    }

    // ── Unused interface methods (revert if a test exercises a path the mock
    //    intentionally does not model — fail loud, never silently no-op) ──
    function stakeAsGuardian(uint256, uint256) external pure {
        revert("MockStakedWood: stakeAsGuardian not modeled");
    }

    function requestUnstakeGuardian() external pure {
        revert("MockStakedWood: requestUnstakeGuardian not modeled");
    }

    function cancelUnstakeGuardian() external pure {
        revert("MockStakedWood: cancelUnstakeGuardian not modeled");
    }

    function claimUnstakeGuardian() external pure {
        revert("MockStakedWood: claimUnstakeGuardian not modeled");
    }

    function prepareOwnerStake(uint256) external pure {
        revert("MockStakedWood: prepareOwnerStake not modeled");
    }

    function cancelPreparedStake() external pure {
        revert("MockStakedWood: cancelPreparedStake not modeled");
    }

    function bindOwnerStake(address, address) external pure {
        revert("MockStakedWood: bindOwnerStake not modeled");
    }

    function requestUnstakeOwner(address) external pure {
        revert("MockStakedWood: requestUnstakeOwner not modeled");
    }

    function claimUnstakeOwner(address) external pure {
        revert("MockStakedWood: claimUnstakeOwner not modeled");
    }

    function transferOwnerStakeSlot(address, address) external pure {
        revert("MockStakedWood: transferOwnerStakeSlot not modeled");
    }

    function delegateStake(address, uint256) external pure {
        revert("MockStakedWood: delegateStake not modeled");
    }

    function requestUnstakeDelegation(address) external pure {
        revert("MockStakedWood: requestUnstakeDelegation not modeled");
    }

    function cancelUnstakeDelegation(address) external pure {
        revert("MockStakedWood: cancelUnstakeDelegation not modeled");
    }

    function claimUnstakeDelegation(address) external pure {
        revert("MockStakedWood: claimUnstakeDelegation not modeled");
    }

    function setCommission(uint256) external pure {
        revert("MockStakedWood: setCommission not modeled");
    }

    function setMinGuardianStake(uint256) external pure {
        revert("MockStakedWood: setMinGuardianStake not modeled");
    }

    function setMinOwnerStake(uint256) external pure {
        revert("MockStakedWood: setMinOwnerStake not modeled");
    }

    function setCooldownPeriod(uint256) external pure {
        revert("MockStakedWood: setCooldownPeriod not modeled");
    }

    function setDelegationEnabled(bool) external pure {
        revert("MockStakedWood: setDelegationEnabled not modeled");
    }

    function setMinSlashBps(uint256) external pure {
        revert("MockStakedWood: setMinSlashBps not modeled");
    }

    function setMaxSlashBps(uint256) external pure {
        revert("MockStakedWood: setMaxSlashBps not modeled");
    }
}
