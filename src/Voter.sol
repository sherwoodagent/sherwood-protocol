// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {ISyndicateFactory} from "./interfaces/ISyndicateFactory.sol";
import {SyndicateGauge} from "./SyndicateGauge.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Voter — Epoch voting for syndicate gauges
/// @notice Manages 7-day epoch voting system where veWOOD holders allocate votes
///         across syndicates to determine WOOD emission distribution.
contract Voter is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;

    // ==================== STRUCTS ====================

    /// @notice Vote allocation for a veNFT in an epoch
    struct VoteAllocation {
        uint256[] syndicateIds; // Syndicates voted for
        uint256[] weights; // Vote weights (basis points, must sum to 10000)
    }

    /// @notice Gauge information for a syndicate
    struct GaugeInfo {
        address gauge; // SyndicateGauge contract address
        bool active; // Whether gauge is active for voting
    }

    // ==================== CONSTANTS ====================

    /// @notice Epoch duration (7 days)
    uint256 public constant EPOCH_DURATION = 7 days;

    /// @notice Minimum quorum threshold (10% of total veWOOD supply)
    uint256 public constant QUORUM_THRESHOLD = 1000; // 10% in basis points

    /// @notice Maximum votes per syndicate (25% of total votes)
    uint256 public constant MAX_SYNDICATE_SHARE = 2500; // 25% in basis points

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Vote buffer period (1 second) after epoch start before votes count
    uint256 public constant VOTE_BUFFER_PERIOD = 1;

    /// @notice Minimum vote threshold for redistribution (1% of total votes)
    uint256 public constant MIN_REDISTRIBUTION_THRESHOLD = 100; // 1% in basis points

    /// @notice Epoch start reference (first Thursday 00:00 UTC after deployment)
    uint256 public immutable EPOCH_START_REFERENCE;

    // ==================== IMMUTABLE ====================

    /// @notice VotingEscrow contract
    IVotingEscrow public immutable votingEscrow;

    /// @notice SyndicateFactory contract
    ISyndicateFactory public immutable syndicateFactory;

    /// @notice WOOD token address (needed for SyndicateGauge deployment)
    address public immutable wood;

    /// @notice Minter contract address (needed for SyndicateGauge deployment)
    address public immutable minter;

    // ==================== STORAGE ====================

    /// @notice Current epoch number (starts from 1)
    uint256 private _currentEpoch;

    /// @notice Vote allocations per veNFT per epoch
    /// @dev tokenId => epoch => VoteAllocation
    mapping(uint256 => mapping(uint256 => VoteAllocation)) private _voteAllocations;

    /// @notice Total votes per syndicate per epoch
    /// @dev syndicateId => epoch => totalVotes
    mapping(uint256 => mapping(uint256 => uint256)) private _syndicateVotes;

    /// @notice Total votes cast per epoch
    /// @dev epoch => totalVotes
    mapping(uint256 => uint256) private _totalVotes;

    /// @notice Gauge information per syndicate
    /// @dev syndicateId => GaugeInfo
    mapping(uint256 => GaugeInfo) private _gauges;

    /// @notice Set of active syndicate IDs
    EnumerableSet.UintSet private _activeSyndicates;

    /// @notice Whether voting has started
    bool private _votingStarted;

    /// @notice Track which epochs had quorum met
    mapping(uint256 => bool) private _quorumMet;

    /// @notice Snapshot of active syndicate IDs at each epoch (for quorum fallback consistency)
    /// @dev epoch => syndicateId[]
    mapping(uint256 => uint256[]) private _epochSyndicateSnapshot;

    /// @notice Last epoch where quorum was met (for fallback)
    uint256 private _lastQuorumEpoch;

    // ==================== EVENTS ====================

    event Voted(
        address indexed voter,
        uint256 indexed tokenId,
        uint256 indexed epoch,
        uint256[] syndicateIds,
        uint256[] weights,
        uint256 power
    );

    event GaugeCreated(uint256 indexed syndicateId, address indexed gauge, address pool, uint256 nftTokenId);

    event GaugeActivated(uint256 indexed syndicateId, address indexed gauge);

    event GaugeDeactivated(uint256 indexed syndicateId, address indexed gauge);

    event EpochFlipped(uint256 indexed newEpoch, uint256 timestamp);

    event VotingStarted(uint256 timestamp);

    // ==================== ERRORS ====================

    error NotAuthorized();
    error InvalidWeights();
    error GaugeNotExists();
    error GaugeAlreadyExists();
    error VotingNotActive();
    error InvalidSyndicateId();
    error QuorumNotMet();
    error WeightsSumInvalid();

    // ==================== CONSTRUCTOR ====================

    /// @param _votingEscrow VotingEscrow contract address
    /// @param _syndicateFactory SyndicateFactory contract address
    /// @param _epochStartReference First Thursday 00:00 UTC timestamp
    /// @param _owner Contract owner
    constructor(
        address _votingEscrow,
        address _syndicateFactory,
        uint256 _epochStartReference,
        address _wood,
        address _minter,
        address _owner
    ) Ownable(_owner) {
        if (
            _votingEscrow == address(0) || _syndicateFactory == address(0) || _wood == address(0)
                || _minter == address(0)
        ) revert NotAuthorized();

        votingEscrow = IVotingEscrow(_votingEscrow);
        syndicateFactory = ISyndicateFactory(_syndicateFactory);
        EPOCH_START_REFERENCE = _epochStartReference;
        wood = _wood;
        minter = _minter;
        _currentEpoch = 1;
    }

    // ==================== CORE FUNCTIONS ====================

    function vote(uint256 tokenId, uint256[] calldata syndicateIds, uint256[] calldata weights) external nonReentrant {
        if (!isVotingActive()) revert VotingNotActive();
        if (votingEscrow.ownerOf(tokenId) != msg.sender) revert NotAuthorized();
        if (syndicateIds.length != weights.length) revert InvalidWeights();

        // Validate weights sum to 10000 basis points (100%) and no duplicate syndicate IDs
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
            if (!_activeSyndicates.contains(syndicateIds[i])) revert InvalidSyndicateId();
            // Check for duplicate syndicate IDs
            for (uint256 j = 0; j < i; j++) {
                if (syndicateIds[j] == syndicateIds[i]) revert InvalidSyndicateId();
            }
        }
        if (totalWeight != BASIS_POINTS) revert WeightsSumInvalid();

        uint256 epoch = _currentEpoch;

        // Get voting power for this veNFT at epoch start (historical snapshot to prevent manipulation)
        uint256 votingPower = votingEscrow.balanceOfNFTAt(tokenId, getEpochStart(epoch));
        if (votingPower == 0) revert NotAuthorized();

        // Remove previous votes if any
        _removeExistingVotes(tokenId, epoch);

        // Store new vote allocation
        VoteAllocation storage allocation = _voteAllocations[tokenId][epoch];
        allocation.syndicateIds = syndicateIds;
        allocation.weights = weights;

        // Apply new votes
        for (uint256 i = 0; i < syndicateIds.length; i++) {
            uint256 voteAmount = (votingPower * weights[i]) / BASIS_POINTS;
            _syndicateVotes[syndicateIds[i]][epoch] += voteAmount;
        }

        // Update total votes for this epoch
        _totalVotes[epoch] += votingPower;

        emit Voted(msg.sender, tokenId, epoch, syndicateIds, weights, votingPower);
    }

    function reset(uint256 tokenId) external nonReentrant {
        if (!isVotingActive()) revert VotingNotActive();
        if (votingEscrow.ownerOf(tokenId) != msg.sender) revert NotAuthorized();

        uint256 epoch = _currentEpoch;
        _removeExistingVotes(tokenId, epoch);

        // Clear allocation
        delete _voteAllocations[tokenId][epoch];
    }

    function flipEpoch() external {
        if (msg.sender != minter && msg.sender != owner()) revert NotAuthorized();
        require(block.timestamp >= getEpochEnd(_currentEpoch), "Epoch not finished");

        // Snapshot active syndicates for this epoch (used by quorum fallback)
        _epochSyndicateSnapshot[_currentEpoch] = _activeSyndicates.values();

        // Check if current epoch had quorum before flipping
        bool hadQuorum = _isQuorumMet(_currentEpoch);
        _quorumMet[_currentEpoch] = hadQuorum;
        if (hadQuorum) {
            _lastQuorumEpoch = _currentEpoch;
        }

        _currentEpoch++;
        emit EpochFlipped(_currentEpoch, block.timestamp);
    }

    function createGauge(
        uint256 syndicateId,
        address syndicateVault,
        address vaultRewardsDistributor,
        address pool,
        uint256 nftTokenId
    ) external onlyOwner {
        if (_gauges[syndicateId].gauge != address(0)) revert GaugeAlreadyExists();

        // Deploy a real SyndicateGauge for this syndicate
        SyndicateGauge gauge = new SyndicateGauge(
            syndicateId, syndicateVault, vaultRewardsDistributor, pool, nftTokenId, wood, address(this), minter, owner()
        );

        _gauges[syndicateId] = GaugeInfo({gauge: address(gauge), active: true});

        _activeSyndicates.add(syndicateId);

        emit GaugeCreated(syndicateId, address(gauge), pool, nftTokenId);
        emit GaugeActivated(syndicateId, address(gauge));
    }

    function setGaugeActive(uint256 syndicateId, bool active) external onlyOwner {
        if (_gauges[syndicateId].gauge == address(0)) revert GaugeNotExists();

        _gauges[syndicateId].active = active;

        if (active) {
            _activeSyndicates.add(syndicateId);
            emit GaugeActivated(syndicateId, _gauges[syndicateId].gauge);
        } else {
            _activeSyndicates.remove(syndicateId);
            emit GaugeDeactivated(syndicateId, _gauges[syndicateId].gauge);
        }
    }

    // ==================== VIEW FUNCTIONS ====================

    function currentEpoch() external view returns (uint256) {
        return _currentEpoch;
    }

    function getEpochStart(uint256 epoch) public view returns (uint256) {
        if (epoch == 0) return 0;
        return EPOCH_START_REFERENCE + (epoch - 1) * EPOCH_DURATION;
    }

    function getEpochEnd(uint256 epoch) public view returns (uint256) {
        if (epoch == 0) return 0;
        return getEpochStart(epoch) + EPOCH_DURATION - 1;
    }

    function isVotingActive() public view returns (bool) {
        if (!_votingStarted) return false;
        uint256 currentTime = block.timestamp;
        uint256 epochStart = getEpochStart(_currentEpoch);
        uint256 epochEnd = getEpochEnd(_currentEpoch);
        uint256 votingStart = epochStart + VOTE_BUFFER_PERIOD;
        return currentTime >= votingStart && currentTime <= epochEnd;
    }

    function getVoteAllocation(uint256 tokenId, uint256 epoch)
        external
        view
        returns (VoteAllocation memory allocation)
    {
        if (epoch == 0) epoch = _currentEpoch;
        return _voteAllocations[tokenId][epoch];
    }

    function getSyndicateVotes(uint256 syndicateId, uint256 epoch) external view returns (uint256) {
        if (epoch == 0) epoch = _currentEpoch;
        return _syndicateVotes[syndicateId][epoch];
    }

    function getTotalVotes(uint256 epoch) external view returns (uint256) {
        if (epoch == 0) epoch = _currentEpoch;
        return _totalVotes[epoch];
    }

    function isQuorumMet(uint256 epoch) external view returns (bool) {
        if (epoch == 0) epoch = _currentEpoch;
        return _isQuorumMet(epoch);
    }

    function _isQuorumMet(uint256 epoch) internal view returns (bool) {
        uint256 totalSupply = votingEscrow.totalSupplyAt(getEpochStart(epoch));
        if (totalSupply == 0) return false;

        uint256 requiredVotes = (totalSupply * QUORUM_THRESHOLD) / BASIS_POINTS;
        return _totalVotes[epoch] >= requiredVotes;
    }

    function getGaugeInfo(uint256 syndicateId) external view returns (GaugeInfo memory info) {
        return _gauges[syndicateId];
    }

    function getActiveSyndicates() external view returns (uint256[] memory) {
        return _activeSyndicates.values();
    }

    function getVoteDistribution(uint256 epoch)
        external
        view
        returns (uint256[] memory syndicateIds, uint256[] memory allocations)
    {
        if (epoch == 0) epoch = _currentEpoch;

        // If quorum wasn't met for this epoch, use the last epoch where quorum was met
        if (!_quorumMet[epoch] && _lastQuorumEpoch > 0) {
            epoch = _lastQuorumEpoch;
        }

        // Use snapshotted syndicates from the epoch (not current set) for consistency
        uint256[] memory activeSyndicateIds =
            _epochSyndicateSnapshot[epoch].length > 0 ? _epochSyndicateSnapshot[epoch] : _activeSyndicates.values(); // fallback for current/unfinished epoch

        uint256 totalVotesInEpoch = _totalVotes[epoch];

        if (totalVotesInEpoch == 0) {
            return (activeSyndicateIds, new uint256[](activeSyndicateIds.length));
        }

        syndicateIds = activeSyndicateIds;
        allocations = new uint256[](activeSyndicateIds.length);

        // Calculate base allocations
        uint256[] memory rawVotes = new uint256[](activeSyndicateIds.length);
        uint256 totalRawVotes = 0;

        for (uint256 i = 0; i < activeSyndicateIds.length; i++) {
            rawVotes[i] = _syndicateVotes[activeSyndicateIds[i]][epoch];
            totalRawVotes += rawVotes[i];
        }

        if (totalRawVotes == 0) {
            return (syndicateIds, allocations);
        }

        // Apply 25% cap and redistribute excess (multi-pass until convergence)
        uint256 maxVotes = (totalRawVotes * MAX_SYNDICATE_SHARE) / BASIS_POINTS;
        uint256 minVotesForRedistribution = (totalRawVotes * MIN_REDISTRIBUTION_THRESHOLD) / BASIS_POINTS;
        bool[] memory isCapped = new bool[](activeSyndicateIds.length);

        // Initialize allocations from raw votes
        for (uint256 i = 0; i < activeSyndicateIds.length; i++) {
            allocations[i] = rawVotes[i];
        }

        // Multi-pass cap + redistribute (max 10 iterations to prevent infinite loop)
        for (uint256 pass = 0; pass < 10; pass++) {
            uint256 totalExcess = 0;

            // Cap pass
            for (uint256 i = 0; i < allocations.length; i++) {
                if (allocations[i] > maxVotes && !isCapped[i]) {
                    totalExcess += allocations[i] - maxVotes;
                    allocations[i] = maxVotes;
                    isCapped[i] = true;
                }
            }

            if (totalExcess == 0) break; // Converged

            // Redistribute excess proportionally to eligible uncapped gauges
            uint256 uncappedVotes = 0;
            for (uint256 i = 0; i < allocations.length; i++) {
                if (!isCapped[i] && rawVotes[i] >= minVotesForRedistribution) {
                    uncappedVotes += allocations[i];
                }
            }

            if (uncappedVotes == 0) break; // No eligible recipients

            for (uint256 i = 0; i < allocations.length; i++) {
                if (!isCapped[i] && rawVotes[i] >= minVotesForRedistribution) {
                    allocations[i] += (totalExcess * allocations[i]) / uncappedVotes;
                }
            }
        }

        // Convert to basis points
        uint256 finalTotal = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            finalTotal += allocations[i];
        }

        if (finalTotal > 0) {
            for (uint256 i = 0; i < allocations.length; i++) {
                allocations[i] = (allocations[i] * BASIS_POINTS) / finalTotal;
            }
        }
    }

    // ==================== ADMIN FUNCTIONS ====================

    /// @notice Start voting (can only be called once)
    function startVoting() external onlyOwner {
        require(!_votingStarted, "Voting already started");
        _votingStarted = true;
        emit VotingStarted(block.timestamp);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /// @dev Remove existing votes for a tokenId in an epoch
    function _removeExistingVotes(uint256 tokenId, uint256 epoch) internal {
        VoteAllocation storage existing = _voteAllocations[tokenId][epoch];

        if (existing.syndicateIds.length > 0) {
            // Use historical voting power at epoch start for consistency
            uint256 existingPower = votingEscrow.balanceOfNFTAt(tokenId, getEpochStart(epoch));

            // Remove votes from syndicates
            for (uint256 i = 0; i < existing.syndicateIds.length; i++) {
                uint256 voteAmount = (existingPower * existing.weights[i]) / BASIS_POINTS;
                _syndicateVotes[existing.syndicateIds[i]][epoch] -= voteAmount;
            }

            // Remove from total votes
            _totalVotes[epoch] -= existingPower;
        }
    }
}
