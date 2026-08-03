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
///         optimistic path keep their previous semantics. The ONE deliberate
///         exception is `getVotes` (present holdings, B4's gate) — see its
///         own doc below for why, and why it still can't express a state the
///         real `StakedWood` can't produce. Tests that drive guardian-review
///         slashing should use a real `StakedWood` proxy via
///         `RegistryTestHarness`.
contract MockStakedWood is IStakedWood {
    // ── Settable reads ──
    address public wood;
    mapping(address => uint256) internal _votes;
    /// @dev Tracks whether `setVotes` was ever called for an account.
    mapping(address => bool) internal _votesSet;
    /// @dev Tracks whether `setPastVotes` was ever called for an account with
    ///      a NON-ZERO value, at any timestamp — a zero-weight `setPastVotes`
    ///      call is indistinguishable from never having been staked at all,
    ///      so it does NOT set this flag. `getVotes` (present holdings)
    ///      defaults to 1 — NOT 0 — for an account with real snapshot weight
    ///      recorded somewhere but no explicit `setVotes` call, because the
    ///      vast majority of existing fixtures set weight via `setPastVotes`
    ///      alone and are modeling a voter who still holds, just without
    ///      bothering to say so explicitly. An account with NEITHER a
    ///      non-zero `setPastVotes` NOR a `setVotes` call defaults `getVotes`
    ///      to 0, same as the rest of the "empty cohort" surface — this keeps
    ///      the mock from expressing `getVotes == 1 && isActiveGuardian ==
    ///      false` for an account nothing ever meaningfully configured, a
    ///      combination the real `StakedWood` cannot produce (both reduce to
    ///      `stakedAmount > 0 && unstakeRequestedAt == 0`). Only an explicit
    ///      `setVotes(acct, 0)` after a non-zero `setPastVotes` models a
    ///      fully-exited holder (the present-holdings gate, B4).
    mapping(address => bool) internal _hasPastVotes;
    mapping(address => mapping(uint256 => uint256)) internal _pastVotes;
    mapping(uint256 => uint256) internal _pastTotalVotes;
    mapping(uint256 => uint256) internal _pastTotalSupply;
    mapping(address => uint256) internal _requiredOwnerBond;
    mapping(address => uint256) internal _ownerStake;
    mapping(address => bool) internal _isActiveGuardian;
    uint256 public totalGuardianStake;
    mapping(address => uint256) internal _guardianStake;
    mapping(address => uint256) internal _preparedStakeOf;
    mapping(address => bool) internal _canCreateVault;
    mapping(address => address) public approvedBindVault;
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
        _votesSet[account] = true;
    }

    function setPastVotes(address guardian, uint256 timestamp, uint256 v) external {
        _pastVotes[guardian][timestamp] = v;
        if (v != 0) _hasPastVotes[guardian] = true;
    }

    function setPastTotalVotes(uint256 timestamp, uint256 v) external {
        _pastTotalVotes[timestamp] = v;
    }

    /// @dev RAW own stake — the quantity `getPastTotalVotes` is literally the sum
    ///      of. DEFAULTS to the `getPastVotes` value so every existing fixture
    ///      behaves exactly as before; set it only to open the gap between the
    ///      two measures, which is the subject of review 🔴F17.
    ///
    ///      NOTE what this mock has always allowed: `setPastVotes` and
    ///      `setPastTotalVotes` are independent, so a fixture can pick
    ///      per-account weights that sum comfortably below the total — an
    ///      invariant the REAL `StakedWood` does not provide, because delegation
    ///      enters `getPastVotes` and never enters `getPastTotalVotes`. That is
    ///      why the suite stayed green over a floor that can reach zero.
    mapping(address => mapping(uint256 => uint256)) internal _pastStake;
    mapping(address => mapping(uint256 => bool)) internal _pastStakeSet;

    function setPastStake(address guardian, uint256 timestamp, uint256 v) external {
        _pastStake[guardian][timestamp] = v;
        _pastStakeSet[guardian][timestamp] = true;
    }

    function getPastStake(address guardian, uint256 timestamp) external view returns (uint256) {
        return _pastStakeSet[guardian][timestamp] ? _pastStake[guardian][timestamp] : _pastVotes[guardian][timestamp];
    }

    function setPastTotalSupply(uint256 timestamp, uint256 v) external {
        _pastTotalSupply[timestamp] = v;
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

    function setGuardianStake(address guardian, uint256 v) external {
        _guardianStake[guardian] = v;
    }

    function setPreparedStakeOf(address owner, uint256 v) external {
        _preparedStakeOf[owner] = v;
    }

    function setCanCreateVault(address owner, bool v) external {
        _canCreateVault[owner] = v;
    }

    /// @dev Owner-stake binding consent (issue #98) is a settable read here,
    ///      like the rest of the mock's surface. The real clearing lifecycle
    ///      (consume on bind, clear on cancel / fresh prepare) lives in
    ///      `StakedWood` — tests that exercise it use a real proxy.
    function setApprovedBindVault(address owner, address vault) external {
        approvedBindVault[owner] = vault;
    }

    function setSlashBounds(uint256 minBps, uint256 maxBps) external {
        minSlashBps = minBps;
        maxSlashBps = maxBps;
    }

    // ── Checkpoint reads ──
    function getVotes(address account) external view returns (uint256) {
        if (_votesSet[account]) return _votes[account];
        return _hasPastVotes[account] ? 1 : 0;
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

    function preparedStakeOf(address owner) external view returns (uint256) {
        return _preparedStakeOf[owner];
    }

    function canCreateVault(address owner) external view returns (bool) {
        return _canCreateVault[owner];
    }

    // ── Registry-only mutations (no-op stubs that record args) ──
    // Sherlock run #3 #6: signature carries `openedAt` — sWOOD sizes the slash
    // off the raw own-stake checkpoint at open. Mock ignores it.
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

    // Verdict slash path (spec §4). Not modeled: the burn needs a real WOOD
    // balance, so `StakedWoodSlashVerdict.t.sol` drives a real proxy.
    function slashVerdict(bytes32, uint256, address[] calldata, uint256[] calldata) external pure returns (uint256) {
        revert("MockStakedWood: slashVerdict not modeled");
    }

    /// @dev MODELLED AS A PLAIN SETTABLE SLOT (review PR #56 M2), unlike the
    ///      neighbouring "not modeled" stubs. `ChallengeGame.setStakedWood` now
    ///      READS this back and refuses a sWOOD that has not named it — the
    ///      other half of a two-sided grant, whose absence wedged every
    ///      `_settle` inside `slashToEscrow`'s own caller gate. A reverting stub
    ///      would make that setter unreachable in any suite that points a game
    ///      at this mock, which is not the failure those suites mean to
    ///      exercise. No access control: it is a test double.
    address public authorizedSlasher;

    function setAuthorizedSlasher(address slasher) external {
        authorizedSlasher = slasher;
    }

    // Per-(caseKey, approver) verdict dedup (PR #24 review 🟠N2). Same reason
    // as `slashVerdict`: the path it guards is not modeled here.
    function verdictSlashed(bytes32, address) external pure returns (bool) {
        revert("MockStakedWood: verdictSlashed not modeled");
    }

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

    function approveOwnerStakeBinding(address) external pure {
        revert("MockStakedWood: approveOwnerStakeBinding not modeled; use setApprovedBindVault");
    }

    function revokeOwnerStakeBinding() external pure {
        revert("MockStakedWood: revokeOwnerStakeBinding not modeled; use setApprovedBindVault");
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

    function setMinSlashBps(uint256) external pure {
        revert("MockStakedWood: setMinSlashBps not modeled");
    }

    function setMaxSlashBps(uint256) external pure {
        revert("MockStakedWood: setMaxSlashBps not modeled");
    }
}
