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
    /// @notice RETAINED FOR ABI STABILITY, no longer thrown. The exposure cap
    ///         is enforced by booking zero rather than by reverting the vote
    ///         (review N1); indexers and off-chain decoders that already know
    ///         this selector keep working.
    error ExposureCapExceeded();
    error CoveredTvlCapExceeded();

    /// @notice Reverts when a proposal's settlement (`executeBy +
    ///         strategyDuration`) lands further ahead than the ledger will book
    ///         a commitment for. Signals a duration ceiling set out of step with
    ///         the epoch length, rather than silently under-covering the tail.
    error CoverageHorizonExceeded();

    /// @notice `settleCoverage` called before the review window shut, while the
    ///         approver set can still change.
    error ReviewNotClosed();

    /// @notice Emitted when reservations collapse to allocations for a proposal.
    event CoverageSettled(bytes32 indexed reviewKey, uint256 reservedTotal, uint256 allocatedTotal);
    error InsufficientApproveCoverage();
    error NotGuardianRegistry();
    error FeedNotConfigured();
    error StalePrice();
    error InvalidParameter();
    error ZeroAddress();

    // ── Events ──
    event WoodUsdPriceSet(uint256 oldPriceX8, uint256 newPriceX8);
    event WoodFeedSet(address indexed feed, uint256 maxDelay);
    event GuardianRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event AssetFeedSet(address indexed asset, address feed, uint256 maxDelay, uint8 assetDecimals);
    event ExposureRecorded(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ExposureReleased(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);

    // ── Registry-only mutations ──
    function recordApproval(address governor, uint256 proposalId, address guardian) external;
    function releaseApproval(address governor, uint256 proposalId, address guardian) external;

    // ── Governor-consumed checks (view) ──
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view;

    /// @notice Reverts when a proposal's settlement lands beyond the ledger's
    ///         booking horizon. Called at propose so the error lands on the
    ///         proposer rather than on the guardian cohort.
    function requireWithinCoverageHorizon(uint256 executeBy, uint256 strategyDuration) external view;
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view;

    // ── Views ──

    /// @notice Per-approver slash rates for a proposal, in bps of each
    ///         guardian's own slashable stake, positionally aligned with the
    ///         returned approver list.
    /// @dev    Feeds `IStakedWood.slashToEscrow` directly. Each rate is that
    ///         guardian's booked coverage divided by their live slashable bond
    ///         — both USD, so the quotient is DIMENSIONALLY unitless, but both
    ///         operands are priced (PR #24 review 🟡N5): the numerator reads
    ///         the asset's Chainlink feed behind a `StalePrice` gate (a stale
    ///         feed makes the conviction unpriceable and this view reverts),
    ///         and the denominator is priced by `woodPriceX8()` — Chainlink
    ///         with the haircut, owner-set `woodUsdPriceX8` only as the
    ///         degraded fallback. See the implementation natspec for the
    ///         liveness and governance-trust consequences. A guardian who
    ///         booked nothing returns 0 and is therefore slashed nothing.
    function slashBpsFor(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory bps);
    /// @notice What `guardian` actually carries on this proposal, after the
    ///         pro-rata scale-back — as opposed to the deliberately over-sized
    ///         amount `recordApproval` reserved.
    /// @dev    Reservations are per-approver and each may run up to the full
    ///         coverage, so the real split is computed at read time from
    ///         whoever is still an approver. This is the number a conviction
    ///         should slash against; the raw reservation would over-slash.
    function allocatedUsd(address governor, uint256 proposalId, address guardian) external view returns (uint256);

    /// @notice Return each approver's over-reservation once the review has shut
    ///         and the approver set is final. Permissionless; safe to skip.
    function settleCoverage(address governor, uint256 proposalId) external;

    function slashableBondUsd(address guardian) external view returns (uint256);
    function openExposureUsd(address guardian) external view returns (uint256);
    function coverageUsd(address asset, uint256 amount) external view returns (uint256);
    function proposerBondWood(address asset, uint256 requiredCoverage) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function woodUsdPriceX8() external view returns (uint256);
    function woodPriceX8() external view returns (uint256);

    /// @notice The WOOD price plus whether it came from the fallback rather than
    ///         the feed — so monitoring can observe the degraded path.
    function woodPriceDetail() external view returns (uint256 price, bool usingFallback);
    function woodHaircutBps() external view returns (uint256);
    function epochLength() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    function kNumerator() external view returns (uint256);
    function coveredTvlCapUsd() external view returns (uint256);
    function quorumTierThreshold() external view returns (uint8);
    function proposerBondBps() external view returns (uint256);

    // ── Owner setters ──
    function setWoodUsdPrice(uint256 newPriceX8) external;
    function setWoodFeed(address feed, uint256 maxDelay) external;
    function setWoodHaircutBps(uint256 newBps) external;
    function setAssetFeed(address asset, address feed, uint256 maxDelay) external;
    function setGuardianRegistry(address registry) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setKNumerator(uint256 newK) external;
    function setCoveredTvlCapUsd(uint256 newCap) external;
    function setQuorumTierThreshold(uint8 newThreshold) external;
    function setProposerBondBps(uint256 newBps) external;
}
