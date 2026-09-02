// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockLedgerFullLocks
/// @notice A ledger stand-in under which EVERY approver has locked its WHOLE
///         stake behind every proposal it approves — the shape the review-path
///         slash had before declared coverage locks, when `slashGuardians` took
///         one severity for the cohort and burned it off each approver's entire
///         bond.
/// @dev    `GuardianRegistry._reviewSlashRates` reads `slashBpsForAt` from the
///         wired ledger and multiplies each approver's LOCK RATE by the review
///         severity; with NO ledger wired every rate is zero and a blocked
///         review burns nothing. Suites that pin severity arithmetic on real
///         `StakedWood` balances (`GuardianRegistrySeverity`,
///         `GuardianReviewLifecycle`, `SwoodReviewSlash`, ...) therefore wire
///         this: a 10_000-bps lock rate makes `ceil(10_000 x severity / 10_000)
///         == severity`, so the burn is exactly the severity the suite
///         computed, and only the LOCK SET (which guardians approved) is
///         modelled. The lock set follows the registry's own calls:
///         `recordApproval` lists, `releaseApproval` unlists, a zero
///         declaration lists nothing — the same membership rule as the real
///         ledger, minus the budget clamp.
///
///         Never use where a test reasons about coverage SIZE: `coverageUsdOf`
///         and `lockOf` report the sentinel `type(uint256).max`-declared
///         "whole stake" only as a non-zero flag, not as WOOD arithmetic.
contract MockLedgerFullLocks {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Above `GuardianRegistry.setExposureLedger`'s floor of
    ///      `reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW` for every review
    ///      period a suite uses.
    uint256 public challengeWindow = 60 days;
    /// @dev `address(0)` is the "not yet bound" state the registry's
    ///      reciprocal-grant check accepts.
    address public guardianRegistry;

    mapping(bytes32 => address[]) internal _approvers;
    mapping(bytes32 => mapping(address => uint256)) internal _index; // 1-based

    event LockRecorded(
        address indexed governor, uint256 indexed proposalId, address indexed guardian, uint256 declared
    );

    function setGuardianRegistry(address r) external {
        guardianRegistry = r;
    }

    function setChallengeWindow(uint256 w) external {
        challengeWindow = w;
    }

    function _key(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    function recordApproval(address governor, uint256 proposalId, address guardian, uint256 lockWood) external {
        if (lockWood == 0) return; // a zero declaration is never listed
        bytes32 k = _key(governor, proposalId);
        if (_index[k][guardian] != 0) return; // idempotent
        _approvers[k].push(guardian);
        _index[k][guardian] = _approvers[k].length;
        emit LockRecorded(governor, proposalId, guardian, lockWood);
    }

    function releaseApproval(address governor, uint256 proposalId, address guardian) external {
        bytes32 k = _key(governor, proposalId);
        uint256 idx = _index[k][guardian];
        if (idx == 0) return;
        address[] storage list = _approvers[k];
        uint256 last = list.length;
        if (idx != last) {
            address moved = list[last - 1];
            list[idx - 1] = moved;
            _index[k][moved] = idx;
        }
        list.pop();
        delete _index[k][guardian];
    }

    /// @dev Whole-stake lock: 10_000 bps for every listed approver.
    function slashBpsForAt(address governor, uint256 proposalId, uint256)
        public
        view
        returns (address[] memory approvers, uint256[] memory bps)
    {
        approvers = _approvers[_key(governor, proposalId)];
        bps = new uint256[](approvers.length);
        for (uint256 i = 0; i < approvers.length; i++) {
            bps[i] = BPS_DENOMINATOR;
        }
    }

    function slashBpsFor(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory bps)
    {
        return slashBpsForAt(governor, proposalId, 0);
    }

    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory lockedWood)
    {
        approvers = _approvers[_key(governor, proposalId)];
        lockedWood = new uint256[](approvers.length);
        for (uint256 i = 0; i < approvers.length; i++) {
            lockedWood[i] = type(uint256).max;
        }
    }

    function lockOf(address governor, uint256 proposalId, address guardian) external view returns (uint256) {
        return _index[_key(governor, proposalId)][guardian] == 0 ? 0 : type(uint256).max;
    }

    /// @dev Not priced here: the fee-weight path is a different suite's job.
    function coverageUsdOf(address, uint256, address) external pure returns (uint256) {
        return 0;
    }
}
