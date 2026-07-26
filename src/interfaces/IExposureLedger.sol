// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IExposureLedger
/// @notice Dollar-denominated aggregate exposure cap + covered-TVL cap +
///         approve-quorum arithmetic (spec 2026-07-22 §3.3, §3.3a, §3.7).
///         Singleton; consumed by GuardianRegistry (exposure recording at
///         approve-vote time) and SyndicateGovernor (covered-TVL check at
///         propose, approve-quorum check at execute).
interface IExposureLedger {
    // ── Errors ──
    error ExposureCapExceeded();
    error CoveredTvlCapExceeded();
    error InsufficientApproveCoverage();
    error NotGuardianRegistry();
    error FeedNotConfigured();
    error StalePrice();
    error InvalidParameter();
    error ZeroAddress();
    error NotCoverageFreezer();
    error CoverageFrozen();

    // ── Events ──
    event WoodUsdPriceSet(uint256 oldPriceX8, uint256 newPriceX8);
    event GuardianRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event AssetFeedSet(address indexed asset, address feed, uint256 maxDelay, uint8 assetDecimals);
    event ExposureRecorded(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ExposureReleased(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);
    event CoverageFreezerSet(address indexed oldFreezer, address indexed newFreezer);
    event RenewalAgentSet(address indexed oldAgent, address indexed newAgent);
    event CoverageFrozenSet(address indexed governor, uint256 indexed proposalId, bool frozen);

    // ── Gated mutations ──
    /// @notice Book a guardian's share of a proposal's coverage against its
    ///         aggregate cap. Callable by the guardian registry (an approve
    ///         vote) OR the renewal agent (a §3.4a epoch renewal) — both are
    ///         commitments to cover the same proposal, so both must consume the
    ///         same budget. Reverts `NotGuardianRegistry` for anyone else.
    function recordApproval(address governor, uint256 proposalId, address guardian) external;
    /// @notice Registry-only, deliberately NOT widened to the renewal agent.
    ///         Booking coverage and freeing someone else's coverage are
    ///         different powers: a renewal agent that could release would be
    ///         able to recycle a bond that is still answerable for a live
    ///         proposal.
    function releaseApproval(address governor, uint256 proposalId, address guardian) external;

    // ── Renewal agent (CoverageEpochs, spec §3.4a) ──
    function setRenewalAgent(address agent) external;
    function renewalAgent() external view returns (address);

    // ── Governor-consumed checks (view) ──
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view;
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view;

    // ── Coverage freeze (challenge game, spec §3.4) ──
    function freezeCoverage(address governor, uint256 proposalId) external;
    function unfreezeCoverage(address governor, uint256 proposalId) external;
    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool);
    function setCoverageFreezer(address freezer) external;
    function coverageFreezer() external view returns (address);

    // ── Views ──
    /// @notice The covering approvers of a proposal and the USD each committed.
    ///         A released commitment reports a zero share rather than being
    ///         dropped, so a caller sees the full historical set.
    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory committedUsd);

    function slashableBondUsd(address guardian) external view returns (uint256);
    function openExposureUsd(address guardian) external view returns (uint256);
    function coverageUsd(address asset, uint256 amount) external view returns (uint256);
    function proposerBondWood(address asset, uint256 requiredCoverage) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function woodUsdPriceX8() external view returns (uint256);
    function epochLength() external view returns (uint256);
    /// @notice Timestamp epoch 0 began, pinned at deploy. Paired with
    ///         `epochLength` this is the entire epoch schedule, which
    ///         `CoverageEpochs` copies onto a cover at open (spec §3.4a, D3) so
    ///         a future ledger re-point cannot re-slice a live cover's epochs.
    function epochGenesis() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    function kNumerator() external view returns (uint256);
    function coveredTvlCapUsd() external view returns (uint256);
    function quorumTierThreshold() external view returns (uint8);
    function proposerBondBps() external view returns (uint256);

    // ── Owner setters ──
    function setWoodUsdPrice(uint256 newPriceX8) external;
    function setAssetFeed(address asset, address feed, uint256 maxDelay) external;
    function setGuardianRegistry(address registry) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setKNumerator(uint256 newK) external;
    function setCoveredTvlCapUsd(uint256 newCap) external;
    function setQuorumTierThreshold(uint8 newThreshold) external;
    function setProposerBondBps(uint256 newBps) external;
}
