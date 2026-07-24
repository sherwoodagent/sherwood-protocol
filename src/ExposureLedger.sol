// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";

/// @dev Narrow sWOOD read surface (own stake, inbound delegation, delegated
///      slash cap, cooldown). Mirrors the IGovernorMinimal pattern in
///      GuardianRegistry — the ledger does not import the full IStakedWood ABI.
interface ISwoodMinimal {
    function guardianStake(address guardian) external view returns (uint256);
    function delegatedInbound(address delegate) external view returns (uint256);
    function maxDelegatedSlashBps() external view returns (uint256);
    function coolDownPeriod() external view returns (uint256);
}

interface IAggregatorMinimal {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IERC20DecimalsMinimal {
    function decimals() external view returns (uint8);
}

interface ILedgerGovernorMinimal {
    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
    }

    function getProposalView(uint256 proposalId) external view returns (ProposalViewLite memory);
    function getRequiredCoverage(uint256 proposalId) external view returns (uint256);
}

interface IVaultAssetMinimal {
    function asset() external view returns (address);
}

interface IRegistryApproversMinimal {
    function getApproverWeights(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 totalApproveWeight);
}

/**
 * @title ExposureLedger
 * @notice Dollar-denominated coverage accounting for the guardian
 *         economic-security model (spec 2026-07-22 §3.3, §3.3a, §3.7).
 *
 *         `slashableBond(g)` (spec §3.3, precision definition):
 *             ownStake(g) * priceHaircut
 *           + delegatedInbound(g) * maxDelegatedSlashBps/10_000 * priceHaircut
 *         Delegated stake counts ONLY at the delegated-slash cap — a delegated
 *         pool cannot be slashed 100%; counting full vote weight would violate
 *         the coalition inequality at the accounting layer.
 *
 *         Exposure is EPOCH-BUCKETED (spec §3.4a): an approval consumes the
 *         current epoch's bucket; open exposure = the sum of all buckets young
 *         enough that their challenge window has not elapsed. Guardian
 *         commitment per approval is therefore bounded at one epoch + challenge
 *         window regardless of strategy duration.
 *
 * @dev    v1 is WOOD-only (spec §3.7): `woodUsdPriceX8` is a GOVERNANCE-SET
 *         conservative price (<= 30-day low), not an oracle read — no WOOD
 *         Chainlink feed exists on Robinhood Chain (spec §8). Fail-closed: an
 *         unset price values every bond at $0.
 */
contract ExposureLedger is Ownable2Step, IExposureLedger {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    bytes32 public constant PARAM_CHALLENGE_WINDOW = keccak256("challengeWindow");
    bytes32 public constant PARAM_K_NUMERATOR = keccak256("kNumerator");
    bytes32 public constant PARAM_COVERED_TVL_CAP = keccak256("coveredTvlCapUsd");
    bytes32 public constant PARAM_QUORUM_TIER_THRESHOLD = keccak256("quorumTierThreshold");
    bytes32 public constant PARAM_PROPOSER_BOND_BPS = keccak256("proposerBondBps");

    ISwoodMinimal public immutable swood;
    /// @notice Epoch length (spec §5: 28d initial). Immutable — changing it
    ///         would shift every existing bucket index.
    uint256 public immutable epochLength;
    uint256 public immutable epochGenesis;

    /// @notice Conservative WOOD→USD price, 8 decimals (spec §5 `priceHaircut`).
    uint256 public woodUsdPriceX8;
    /// @notice Post-epoch challenge window (spec §5: 14d initial, single window
    ///         in v1 — per-tier windows are a later refinement).
    uint256 public challengeWindow = 14 days;
    /// @notice k multiplier for the exposure cap (spec §5: k = 1).
    uint256 public kNumerator = 1;
    /// @notice Hard per-vault covered-TVL ceiling in USD-18 (spec §3.7). A
    ///         proposal whose coverage exceeds this cannot be opened. Zero =
    ///         cap unset = NOTHING can be proposed through a wired governor —
    ///         fail-closed until governance seeds it.
    uint256 public coveredTvlCapUsd;
    /// @notice Minimum envelopeTier at which the approve quorum is fail-closed
    ///         (spec §3.3a + §4 gate 2). Launch value 2: tier-2 only. Lowering
    ///         is gated on the §3.10 ROE validation — a BLOCKING launch gate.
    uint8 public quorumTierThreshold = 2;
    /// @notice Proposer bond as bps of USD coverage (spec §3.9/§5). Default 1%.
    uint256 public proposerBondBps = 100;

    address public guardianRegistry;

    /// @dev Per-asset USD feed config. `assetDecimals` cached at registration so
    ///      the hot path makes no external metadata call.
    struct AssetFeed {
        address feed;
        uint64 maxDelay;
        uint8 assetDecimals;
        uint8 feedDecimals;
    }

    mapping(address asset => AssetFeed) internal _assetFeeds;

    struct RecordedExposure {
        uint192 usd;
        uint64 epoch;
    }

    mapping(address guardian => mapping(uint256 epoch => uint256 usd)) internal _buckets;
    mapping(bytes32 reviewKey => mapping(address guardian => RecordedExposure)) internal _recorded;

    // ── Modifiers / helpers ──

    modifier onlyRegistry() {
        if (msg.sender != guardianRegistry) revert NotGuardianRegistry();
        _;
    }

    function _reviewKey(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId)); // same derivation as GuardianRegistry
    }

    constructor(address initialOwner, address swood_, uint256 epochLength_) Ownable(initialOwner) {
        if (swood_ == address(0)) revert ZeroAddress();
        if (epochLength_ == 0) revert InvalidParameter();
        swood = ISwoodMinimal(swood_);
        epochLength = epochLength_;
        epochGenesis = block.timestamp;
    }

    // ── Views ──

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - epochGenesis) / epochLength;
    }

    /// @inheritdoc IExposureLedger
    function slashableBondUsd(address guardian) public view returns (uint256) {
        uint256 own = swood.guardianStake(guardian);
        uint256 inbound = swood.delegatedInbound(guardian);
        uint256 slashableWood = own + (inbound * swood.maxDelegatedSlashBps()) / BPS_DENOMINATOR;
        return (slashableWood * woodUsdPriceX8) / 1e8;
    }

    // ── Owner setters ──

    function setWoodUsdPrice(uint256 newPriceX8) external onlyOwner {
        emit WoodUsdPriceSet(woodUsdPriceX8, newPriceX8);
        woodUsdPriceX8 = newPriceX8;
    }

    function setGuardianRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        guardianRegistry = registry;
    }

    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        // Bounded (0, epochLength]: zero would free coverage instantly;
        // beyond one epoch the lookback in openExposureUsd grows unbounded.
        if (newWindow == 0 || newWindow > epochLength) revert InvalidParameter();
        // Cross-contract invariant (spec §5): unstake delay must cover
        // epoch + challenge window, or an approver can unstake before its
        // epoch's approvals can be challenged.
        if (epochLength + newWindow > swood.coolDownPeriod()) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_CHALLENGE_WINDOW, challengeWindow, newWindow);
        challengeWindow = newWindow;
    }

    function setKNumerator(uint256 newK) external onlyOwner {
        if (newK == 0) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_K_NUMERATOR, kNumerator, newK);
        kNumerator = newK;
    }

    function setCoveredTvlCapUsd(uint256 newCap) external onlyOwner {
        emit ParameterChangeFinalized(PARAM_COVERED_TVL_CAP, coveredTvlCapUsd, newCap);
        coveredTvlCapUsd = newCap;
    }

    function setQuorumTierThreshold(uint8 newThreshold) external onlyOwner {
        if (newThreshold > 3) revert InvalidParameter(); // 3 = quorum disabled for all tiers
        emit ParameterChangeFinalized(PARAM_QUORUM_TIER_THRESHOLD, quorumTierThreshold, newThreshold);
        quorumTierThreshold = newThreshold;
    }

    function setProposerBondBps(uint256 newBps) external onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_PROPOSER_BOND_BPS, proposerBondBps, newBps);
        proposerBondBps = newBps;
    }

    /// @notice Register the Chainlink USD feed for a vault asset. Vault assets on
    ///         Robinhood have live feeds (USDG/USD, USDC/USD, ETH/USD —
    ///         chains/4663.json); WOOD deliberately does NOT go through this path
    ///         (governance haircut price instead, spec §8).
    function setAssetFeed(address asset, address feed, uint256 maxDelay) external onlyOwner {
        if (asset == address(0) || feed == address(0)) revert ZeroAddress();
        if (maxDelay == 0) revert InvalidParameter();
        uint8 assetDec = IERC20DecimalsMinimal(asset).decimals();
        uint8 feedDec = IAggregatorMinimal(feed).decimals();
        _assetFeeds[asset] =
            AssetFeed({feed: feed, maxDelay: uint64(maxDelay), assetDecimals: assetDec, feedDecimals: feedDec});
        emit AssetFeedSet(asset, feed, maxDelay, assetDec);
    }

    /// @inheritdoc IExposureLedger
    /// @dev USD-18 value of `amount` of `asset`. Fail-closed on unconfigured
    ///      asset or stale feed — a proposal in an unpriceable asset cannot be
    ///      coverage-checked and therefore cannot proceed.
    function coverageUsd(address asset, uint256 amount) public view returns (uint256) {
        AssetFeed storage f = _assetFeeds[asset];
        if (f.feed == address(0)) revert FeedNotConfigured();
        (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(f.feed).latestRoundData();
        if (answer <= 0) revert StalePrice();
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > f.maxDelay) revert StalePrice();
        return (amount * uint256(answer) * 1e18) / (10 ** f.assetDecimals) / (10 ** f.feedDecimals);
    }

    // ── Stubs replaced in Tasks 2–4 and 8 (placeholders so each task
    //    compiles and goes green before the next starts — NOT deferred work) ──

    function proposerBondWood(address, uint256) external view virtual returns (uint256) {
        revert FeedNotConfigured();
    }

    /// @inheritdoc IExposureLedger
    /// @dev Called by GuardianRegistry.voteOnProposal on the approve side (spec
    ///      §3.3: the cap is checked at vote time). Reverting here reverts the
    ///      guardian's vote — an over-exposed guardian simply cannot approve.
    function recordApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
        bytes32 key = _reviewKey(governor, proposalId);
        if (_recorded[key][guardian].usd != 0) return; // idempotent (vote-change round trip)
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        address asset = IVaultAssetMinimal(gov.getProposalView(proposalId).vault).asset();
        uint256 usd = coverageUsd(asset, gov.getRequiredCoverage(proposalId));
        if (usd == 0) return; // zero-coverage: nothing to book
        uint256 epoch = currentEpoch();
        if (openExposureUsd(guardian) + usd > kNumerator * slashableBondUsd(guardian)) {
            revert ExposureCapExceeded();
        }
        _buckets[guardian][epoch] += usd;
        _recorded[key][guardian] = RecordedExposure({usd: uint192(usd), epoch: uint64(epoch)});
        emit ExposureRecorded(guardian, key, usd, epoch);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Vote-change Approve→Block (or any registry-side unwind). Releases
    ///      exactly what was recorded, from the bucket it was recorded into.
    ///      No-op when nothing is recorded — never underflows.
    function releaseApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
        bytes32 key = _reviewKey(governor, proposalId);
        RecordedExposure memory r = _recorded[key][guardian];
        if (r.usd == 0) return;
        delete _recorded[key][guardian];
        _buckets[guardian][r.epoch] -= r.usd;
        emit ExposureReleased(guardian, key, r.usd, r.epoch);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Spec §3.7: hard per-vault ceiling on coverage-consuming proposals,
    ///      denominated in dollars. Zero cap fails closed (nothing proposable)
    ///      until governance seeds it. Called by SyndicateGovernor.propose.
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view {
        if (coverageUsd(asset, requiredCoverage) > coveredTvlCapUsd) revert CoveredTvlCapExceeded();
    }

    /// @inheritdoc IExposureLedger
    /// @dev Spec §3.3a: execution requires the covering approvers' aggregate
    ///      slashableBond (LIVE read, dollars) to meet the proposal's coverage.
    ///      Live rather than at-vote: sWOOD's coolDownPeriod >= epoch + challenge
    ///      window prevents full escape, and a live read is strictly conservative
    ///      (a bond that shrank since the vote counts at its shrunken value).
    ///      Zero approvers ALWAYS reverts, even at zero coverage — R1 requires an
    ///      identified signer for anything tier-gated into this check.
    ///      Called by SyndicateGovernor.executeProposal for proposals with
    ///      envelopeTier >= quorumTierThreshold.
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view
    {
        uint256 needUsd = coverageUsd(asset, requiredCoverage);
        (address[] memory approvers,,) =
            IRegistryApproversMinimal(guardianRegistry).getApproverWeights(governor, proposalId);
        if (approvers.length == 0) revert InsufficientApproveCoverage();
        uint256 haveUsd;
        for (uint256 i = 0; i < approvers.length; i++) {
            haveUsd += slashableBondUsd(approvers[i]);
            if (haveUsd >= needUsd) return; // early exit
        }
        if (haveUsd < needUsd) revert InsufficientApproveCoverage();
    }

    /// @inheritdoc IExposureLedger
    /// @dev Bucket `e` (covering [genesis + e·L, genesis + (e+1)·L)) counts until
    ///      its challenge window elapses at `genesis + (e+1)·L + W` — exact
    ///      expiry, so the coverage budget recycles every challenge window
    ///      (spec §3.3). First counted bucket: e such that (e+1)·L + W > elapsed,
    ///      i.e. from = (elapsed - W) / L when elapsed > W. from <= cur always
    ///      (W > 0), so the loop is bounded by ceil(W/L) + 1 iterations.
    function openExposureUsd(address guardian) public view returns (uint256 total) {
        uint256 cur = currentEpoch();
        uint256 elapsed = block.timestamp - epochGenesis;
        uint256 from = elapsed > challengeWindow ? (elapsed - challengeWindow) / epochLength : 0;
        for (uint256 e = from; e <= cur; e++) {
            total += _buckets[guardian][e];
        }
    }
}
