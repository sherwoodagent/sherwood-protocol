// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev Minimal governor surface consumed by the registry. Intentionally a
///      narrow stub so that GuardianRegistry does not depend on the full
///      ISyndicateGovernor ABI (which would pull in the entire StrategyProposal
///      struct along with the rest of the governor's types).
///
///      `ProposalView` carries only the review-window timestamps and vault; the
///      governor exposes a dedicated `getProposalView(uint256)` that returns a
///      matching-shape struct.
interface IGovernorMinimal {
    struct ProposalView {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
    }

    function getProposalView(uint256 proposalId) external view returns (ProposalView memory);
}

/// @title GuardianRegistry
/// @notice UUPS-upgradeable registry for guardian review votes, emergency
///         review lifecycle, and the slash-appeal reserve. Holds **zero
///         assets** — the guardian fee is paid out off-chain (buyback-WOOD via
///         weekly Merkl); the on-chain reward pool/claim machinery was deleted
///         and `getApproverWeights` exposes the per-proposal approver split for
///         the bot. Guardian stake, owner bonds, DPoS
///         delegation, vote checkpoints, and slashing live in `StakedWood`
///         (sWOOD). The registry reads vote weight from sWOOD and calls sWOOD
///         to slash. See
///         `docs/superpowers/specs/2026-05-21-swood-staking-split-design.md`.
contract GuardianRegistry is IGuardianRegistry, ReentrancyGuardTransient, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ── Constants ──
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @notice 7-day epoch — anchors the `_emitBlockerAttribution` epoch index
    ///         and the `refundSlash` per-epoch cap window.
    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant MIN_COHORT_STAKE_AT_OPEN = 50_000 * 1e18;
    uint256 public constant MAX_APPROVERS_PER_PROPOSAL = 100;
    /// @notice Upper bound on blockers per proposal. Caps the O(n)
    ///         `BlockerAttributed` emit loop in `_emitBlockerAttribution` so
    ///         `resolveReview` cannot be gas-DoS'd.
    uint256 public constant MAX_BLOCKERS_PER_PROPOSAL = 100;
    uint256 public constant LATE_VOTE_LOCKOUT_BPS = 1000;
    /// @notice Block decisiveness (bps of at-open total weight) at which the
    ///         deterministic severity hits `maxSlashBps`. 2/3 supermajority.
    uint256 public constant SUPERMAJORITY_BPS = 6_667;
    uint256 public constant MAX_REFUND_PER_EPOCH_BPS = 2000;
    uint256 public constant DEADMAN_UNPAUSE_DELAY = 7 days;
    uint256 public constant MAX_CALLS_PER_PROPOSAL = 64;

    // ── Parameter keys (used as event topic discriminators) ──
    bytes32 public constant PARAM_REVIEW_PERIOD = keccak256("reviewPeriod");
    bytes32 public constant PARAM_BLOCK_QUORUM_BPS = keccak256("blockQuorumBps");

    // ── Storage ──
    struct Review {
        bool opened;
        bool resolved;
        bool blocked;
        bool cohortTooSmall;
        uint128 totalStakeAtOpen;
        uint128 approveStakeWeight;
        uint128 blockStakeWeight;
        uint64 openedAt; // timestamp for checkpoint lookup of vote weight
        uint128 totalDelegatedAtOpen; // delegation half of the quorum denom
        /// @dev Sherlock run #2 #15: snapshot the block-quorum threshold at
        ///      `openReview` so the owner cannot shift it mid-review and
        ///      flip the resolution outcome. Read by `resolveReview` +
        ///      `cancelReview` instead of the live `blockQuorumBps` slot.
        uint16 blockQuorumBpsAtOpen;
    }

    mapping(bytes32 => Review) internal _reviews;
    mapping(bytes32 => mapping(address => GuardianVoteType)) internal _votes;
    /// @dev Per-(key, voter) snapshot of the voter's vote weight at the
    ///      instant their review vote was recorded. Read by the off-chain Merkl
    ///      bot via `getApproverWeights` to attribute the (off-chain) guardian
    ///      fee. Vote accounting only — slashing is sized on sWOOD from its
    ///      own raw own-stake checkpoint at `openedAt` (spec 2026-07-19 §5).
    mapping(bytes32 => mapping(address => uint128)) internal _voteStake;
    mapping(bytes32 => address[]) internal _approvers;
    mapping(bytes32 => address[]) internal _blockers;
    mapping(bytes32 => mapping(address => uint256)) internal _approverIndex;
    mapping(bytes32 => mapping(address => uint256)) internal _blockerIndex;

    struct EmergencyReview {
        bytes32 callsHash;
        uint64 reviewEnd;
        uint128 totalStakeAtOpen;
        uint128 blockStakeWeight;
        bool resolved;
        bool blocked;
        uint8 nonce; // bumped on open/cancel so prior block votes go stale
        uint64 openedAt; // timestamp for checkpoint lookup of vote weight
        uint128 totalDelegatedAtOpen; // delegation half of the quorum denom
        bool cohortTooSmall;
        /// @dev Sherlock run #2 #15 (emergency variant): snapshot block-quorum
        ///      threshold at `openEmergency` so the owner cannot shift it
        ///      mid-review. Read by `cancelEmergency` + `_resolveEmergency`.
        uint16 blockQuorumBpsAtOpen;
        /// @dev Set to msg.sender at openEmergency; read by _resolveEmergency
        ///      for the owner-bond slash via governor.getProposalView().vault.
        address governor;
    }

    mapping(bytes32 => EmergencyReview) internal _emergencyReviews;
    // keyed by (bytes32 key, nonce, guardian) so cancelling + re-opening starts a
    // fresh round; prior-round votes are invisible to the new nonce.
    mapping(bytes32 => mapping(uint8 => mapping(address => bool))) internal _emergencyBlockVotes;

    /// @dev Emergency call array — stored by governor via `openEmergency`,
    ///      returned on `finalizeEmergency`, cleared on cancel/finalize.
    ///      Moved from SyndicateGovernor to consolidate emergency state.
    mapping(bytes32 => BatchExecutorLib.Call[]) internal _emergencyCalls;

    // Epoch accounting. `epochGenesis` anchors the `_emitBlockerAttribution`
    // epoch index and the `refundSlash` per-epoch cap window.
    uint256 public epochGenesis;

    // Pause state
    bool public paused;
    uint64 public pausedAt;

    // Slash appeal
    uint256 public slashAppealReserve;
    mapping(uint256 => uint256) public refundedInEpoch;

    // Parameters
    uint256 public reviewPeriod;
    uint256 public blockQuorumBps;

    // Privileged addresses
    /// @dev Set of authorized governor addresses (replaces the single `governor` slot).
    ///      Added by `addGovernor` (factory-only). The slot formerly held by the
    ///      `address public governor` singleton is repurposed as the EnumerableSet
    ///      internal storage; callers must use `addGovernor` after deploy.
    EnumerableSet.AddressSet private _authorizedGovernors;
    /// @dev Retained post-slim purely as an alignment beacon: the slimmed
    ///      registry no longer gates any logic on `factory` (factory-gated
    ///      staking moved to sWOOD), but `SyndicateFactory.setGuardianRegistry`
    ///      reads this getter as a Sherlock #28 misconfig check, and it is part
    ///      of the deployed proxy storage layout. Do not remove.
    address public factory;

    /// @notice The StakedWood (sWOOD) contract — sole WOOD custodian. The
    ///         registry reads vote weight / commission / delegation from sWOOD
    ///         and calls sWOOD to slash. Set in `initialize`.
    IStakedWood public swood;

    // Guardian-fee reward distribution is OFF-CHAIN (buyback-WOOD via weekly
    // Merkl): the governor sends the fee slice to the team `guardiansFeeRecipient`
    // multisig and emits `GuardianFeeAccrued`; the bot reads that event +
    // `getApproverWeights` to attribute WOOD airdrops. The on-chain pool /
    // claim / escrow machinery was deleted — the registry holds zero assets.
    // (Slots freed; the __gap below absorbs the layout delta — this is a fresh
    // V1.5 mainnet redeployment so no live storage to migrate.)

    /// @dev Reserved storage for future upgrades.
    uint256[50] private __gap;

    /// @notice Per-deployment hard floor for `reviewPeriod` (impl-time immutable;
    ///         mainnet 6h). Lives in bytecode, not storage — the layout above is
    ///         unchanged and the value resolves through the UUPS proxy. A testnet
    ///         impl may deploy a lower floor so `setReviewPeriod` can compress the
    ///         guardian-review window; the 7-day ceiling and the
    ///         `reviewPeriod <= sWOOD.coolDownPeriod()` cross-invariant still hold.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable minReviewPeriod;

    /// @notice Absolute floor-of-floors: no deploy may seat a review floor below this.
    uint256 internal constant ABSOLUTE_MIN_REVIEW_FLOOR = 1 minutes;

    // ── Initializer ──
    /// @param minReviewPeriod_ Per-deployment `reviewPeriod` floor (mainnet 6h).
    /// @dev Bounded `[1 minutes, 7 days]` so an arg-less deploy reverts rather than
    ///      silently seating a 0 floor (which would let `setReviewPeriod(0)` disable
    ///      the review window).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint256 minReviewPeriod_) {
        if (minReviewPeriod_ < ABSOLUTE_MIN_REVIEW_FLOOR || minReviewPeriod_ > 7 days) revert InvalidParameter();
        minReviewPeriod = minReviewPeriod_;
        _disableInitializers();
    }

    /// @notice Initialize the slimmed registry.
    /// @param owner_ Owner multisig (parameter setter, pause, slash appeal).
    /// @param factory_ SyndicateFactory address.
    /// @param swood_ StakedWood (sWOOD) — sole WOOD custodian; the registry
    ///        reads vote weight from it and calls it to slash.
    /// @param reviewPeriod_ Guardian review window.
    /// @param blockQuorumBps_ Block-quorum threshold in basis points.
    function initialize(
        address owner_,
        address factory_,
        address swood_,
        uint256 reviewPeriod_,
        uint256 blockQuorumBps_
    ) external initializer {
        if (owner_ == address(0) || factory_ == address(0) || swood_ == address(0)) {
            revert ZeroAddress();
        }
        // Sherlock run #2 #16 invariant (cooldown >= review) is enforced at
        // the setters only — the deploy script seeds compatible values, and
        // skipping the init-time check claws back ~10 bytes under EIP-170.

        __Ownable_init(owner_);

        factory = factory_;
        swood = IStakedWood(swood_);
        reviewPeriod = reviewPeriod_;
        blockQuorumBps = blockQuorumBps_;
        epochGenesis = block.timestamp;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ── Modifiers ──
    modifier onlyGovernor() {
        if (!_authorizedGovernors.contains(msg.sender)) revert UnauthorizedGovernor();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    // ── Multi-governor management ──

    /// @notice Register an additional governor. Factory-only — called immediately
    ///         after a new per-vault governor is deployed.
    function addGovernor(address gov) external {
        // I3 (review) + spec §7: factory-only. The registry owner authorizing an
        // arbitrary governor would let an attacker-controlled getProposalView().vault
        // reach slashOwnerBond(anyVault) — restore the spec's onlyFactory gate.
        if (msg.sender != factory) revert UnauthorizedGovernor();
        if (gov == address(0)) revert ZeroAddress();
        _authorizedGovernors.add(gov);
        emit GovernorAdded(gov);
    }

    /// @dev Composite key isolating per-(governor, proposalId) review state.
    ///      `abi.encode` pads both fields to 32 bytes — no (addr, id) collision.
    function _reviewKey(address gov, uint256 proposalId) private pure returns (bytes32) {
        return keccak256(abi.encode(gov, proposalId));
    }

    // ── sWOOD passthrough views (so `GovernorEmergency` can read the owner
    //    bond through the registry handle without a separate sWOOD reference) ──

    /// @inheritdoc IGuardianRegistry
    function ownerStake(address vault) external view returns (uint256) {
        return swood.ownerStake(vault);
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Passes `address(0)` to obtain the unscaled floor: a zero vault has
    ///      zero TVL, so the TVL-scaled `requiredOwnerBond` collapses to the
    ///      bare floor (`max(floor, TVL * ownerStakeTvlBps / 10_000)` -> floor).
    function minOwnerStake() external view returns (uint256) {
        return swood.requiredOwnerBond(address(0));
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev TVL-scaled owner-bond floor: `max(minFloor, TVL * ownerStakeTvlBps / 10_000)`.
    ///      Passthrough to sWOOD. Used by `GovernorEmergency` to validate the
    ///      owner bond at `emergencySettleWithCalls` call time.
    function requiredOwnerBond(address vault) external view returns (uint256) {
        return swood.requiredOwnerBond(vault);
    }

    /// @notice Returns whether the given address is an authorized governor.
    function isAuthorizedGovernor(address gov) external view returns (bool) {
        return _authorizedGovernors.contains(gov);
    }

    // ──────────────────────────────────────────────────────────────
    // Guardian-fee attribution (read-only)
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    /// @dev Reads the (retained) `_approvers` / `_voteStake` accounting. Data
    ///      persists after settle (arrays are not cleared), so this is callable
    ///      for any historical proposal. The off-chain Merkl bot pulls this in
    ///      a single RPC call to attribute the guardian fee (paid out as WOOD)
    ///      to approvers — replacing the deleted on-chain claim machinery.
    function getApproverWeights(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 totalApproveWeight)
    {
        bytes32 key = _reviewKey(governor, proposalId);
        approvers = _approvers[key];
        uint256 n = approvers.length;
        weights = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            weights[i] = _voteStake[key][approvers[i]];
        }
        totalApproveWeight = _reviews[key].approveStakeWeight;
    }

    // ──────────────────────────────────────────────────────────────
    // Guardian review voting
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    /// @dev First-vote path OR vote-change. Requires `openReview` to have been
    ///      called and `voteEnd <= now < reviewEnd`. Snapshots the caller's
    ///      vote weight at `r.openedAt` (read from sWOOD's `getPastVotes`) into
    ///      `_voteStake[key][caller]` and adds it to the chosen side's
    ///      tally. Approvers and Blockers are each capped. Block votes carry
    ///      no proposed severity: the slash severity is not voted — it is a
    ///      deterministic function of block-side decisiveness computed at
    ///      `resolveReview` (see `_severityBps`, spec 2026-07-19 Part D).
    function voteOnProposal(address governor, uint256 proposalId, GuardianVoteType support) external whenNotPaused {
        if (support == GuardianVoteType.None) revert();
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();

        bytes32 key = _reviewKey(governor, proposalId);
        Review storage r = _reviews[key];
        if (!r.opened) revert ReviewNotOpen();

        IGovernorMinimal.ProposalView memory p = IGovernorMinimal(governor).getProposalView(proposalId);
        if (block.timestamp < p.voteEnd || block.timestamp >= p.reviewEnd) revert ReviewNotOpen();

        if (!swood.isActiveGuardian(msg.sender)) revert NotActiveGuardian();

        GuardianVoteType existing = _votes[key][msg.sender];
        if (existing == support) revert NoVoteChange();

        if (existing == GuardianVoteType.None) {
            // Sherlock #42: apply the late-vote lockout to first-time votes too.
            uint256 reviewWindow = uint256(p.reviewEnd) - uint256(p.voteEnd);
            uint256 lockoutStart = p.reviewEnd - (reviewWindow * LATE_VOTE_LOCKOUT_BPS) / BPS_DENOMINATOR;
            if (block.timestamp >= lockoutStart) revert VoteChangeLockedOut();

            // First vote — snapshot own + delegated weight AT `r.openedAt`.
            uint256 weight256 = swood.getPastVotes(msg.sender, uint256(r.openedAt));
            if (weight256 == 0) revert NotActiveGuardian(); // no votable weight at open time
            uint128 weight = uint128(weight256);
            _voteStake[key][msg.sender] = weight;

            if (support == GuardianVoteType.Approve) {
                _pushApprover(key, proposalId, msg.sender);
                r.approveStakeWeight += weight;
            } else {
                _pushBlocker(key, proposalId, msg.sender);
                r.blockStakeWeight += weight;
            }
            _votes[key][msg.sender] = support;
            emit GuardianVoteCast(proposalId, msg.sender, support, weight);
        } else {
            // Vote-change: must be before the late lockout window.
            uint256 reviewWindow = uint256(p.reviewEnd) - uint256(p.voteEnd);
            uint256 lockoutStart = p.reviewEnd - (reviewWindow * LATE_VOTE_LOCKOUT_BPS) / BPS_DENOMINATOR;
            if (block.timestamp >= lockoutStart) revert VoteChangeLockedOut();

            uint128 weight = _voteStake[key][msg.sender]; // preserved snapshot
            // LOAD-BEARING INVARIANT: the new-side cap is checked inline BEFORE
            // any `_remove*` / `_push*` call.
            if (existing == GuardianVoteType.Approve) {
                // Approve -> Block (blockers are capped).
                if (_blockers[key].length >= MAX_BLOCKERS_PER_PROPOSAL) revert NewSideFull();
                _removeApprover(key, msg.sender);
                r.approveStakeWeight -= weight;
                _pushBlocker(key, proposalId, msg.sender); // cap pre-checked above -- must succeed
                r.blockStakeWeight += weight;
            } else {
                // Block -> Approve.
                if (_approvers[key].length >= MAX_APPROVERS_PER_PROPOSAL) revert NewSideFull();
                _removeBlocker(key, msg.sender);
                r.blockStakeWeight -= weight;
                _pushApprover(key, proposalId, msg.sender); // cap pre-checked above -- must succeed
                r.approveStakeWeight += weight;
            }
            _votes[key][msg.sender] = support;
            emit GuardianVoteChanged(proposalId, msg.sender, existing, support);
        }
    }

    // ── Internal vote helpers (all take composite bytes32 key) ──
    function _pushApprover(bytes32 key, uint256 proposalId, address g) private {
        if (_approvers[key].length >= MAX_APPROVERS_PER_PROPOSAL) {
            emit ApproverCapReached(proposalId);
            revert NewSideFull();
        }
        _approvers[key].push(g);
        _approverIndex[key][g] = _approvers[key].length; // 1-indexed
    }

    function _pushBlocker(bytes32 key, uint256 proposalId, address g) private {
        // Cap parallels MAX_APPROVERS_PER_PROPOSAL so the
        // `BlockerAttributed` emit loop in `_emitBlockerAttribution` is
        // O(MAX_BLOCKERS_PER_PROPOSAL) — bounded gas at `resolveReview`.
        if (_blockers[key].length >= MAX_BLOCKERS_PER_PROPOSAL) {
            emit BlockerCapReached(proposalId);
            revert NewSideFull();
        }
        _blockers[key].push(g);
        _blockerIndex[key][g] = _blockers[key].length; // 1-indexed
    }

    /// @dev Swap-and-pop removal of `g` from `_approvers[key]`, keeping
    ///      `_approverIndex` consistent. Expects `g` to be present (idx1 > 0).
    function _removeApprover(bytes32 key, address g) private {
        uint256 idx1 = _approverIndex[key][g];
        uint256 idx = idx1 - 1;
        address[] storage arr = _approvers[key];
        address last = arr[arr.length - 1];
        if (last != g) {
            arr[idx] = last;
            _approverIndex[key][last] = idx1;
        }
        arr.pop();
        delete _approverIndex[key][g];
    }

    /// @dev Mirror of `_removeApprover` for blockers.
    function _removeBlocker(bytes32 key, address g) private {
        uint256 idx1 = _blockerIndex[key][g];
        uint256 idx = idx1 - 1;
        address[] storage arr = _blockers[key];
        address last = arr[arr.length - 1];
        if (last != g) {
            arr[idx] = last;
            _blockerIndex[key][last] = idx1;
        }
        arr.pop();
        delete _blockerIndex[key][g];
    }

    // ── Governor-only (emergency) ──
    /// @inheritdoc IGuardianRegistry
    /// @notice Governor opens an emergency review, storing the call array and
    ///         its pre-commitment hash.
    function openEmergency(uint256 proposalId, bytes32 callsHash, BatchExecutorLib.Call[] calldata calls)
        external
        onlyGovernor
    {
        if (calls.length > MAX_CALLS_PER_PROPOSAL) revert EmergencyTooManyCalls();
        if (keccak256(abi.encode(calls)) != callsHash) revert EmergencyHashMismatch();

        bytes32 eKey = _reviewKey(msg.sender, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        if (er.reviewEnd > 0 && block.timestamp < er.reviewEnd) revert EmergencyAlreadyOpen();
        // Sherlock #45: snapshot stake totals at open + flag cold-start cohort.
        // Sherlock #35 / Run-1 #18: denominator read at `t-1` matches the
        // numerator's checkpoint anchor — symmetric flash-(de)stake defense.
        // Sherlock #39 / Run-1 #22: active-only delegated total excludes
        // delegations to inactive guardians.
        IStakedWood sw = swood;
        uint256 ts1 = block.timestamp - 1;
        uint256 gs = sw.getPastTotalVotes(ts1);
        uint256 ds = sw.getPastTotalActiveDelegated(ts1);

        er.governor = msg.sender; // stored before any external calls
        er.callsHash = callsHash;
        er.reviewEnd = uint64(block.timestamp + reviewPeriod);
        er.totalStakeAtOpen = uint128(gs);
        er.totalDelegatedAtOpen = uint128(ds);
        er.blockStakeWeight = 0;
        er.resolved = false;
        er.blocked = false;
        er.openedAt = uint64(ts1);
        er.cohortTooSmall = gs + ds < MIN_COHORT_STAKE_AT_OPEN;
        // Sherlock run #2 #15: snapshot block-quorum threshold at open so the
        // owner can't shift it mid-review.
        // forge-lint: disable-next-line(unchecked-cast)
        er.blockQuorumBpsAtOpen = uint16(blockQuorumBps);
        uint64 newReviewEnd = er.reviewEnd;
        unchecked {
            er.nonce++;
        }

        _storeEmergencyCalls(eKey, calls);
        emit EmergencyReviewOpened(proposalId, callsHash, newReviewEnd);
    }

    /// @dev Stores emergency calls in storage, replacing any prior array.
    ///      The storage-array reference and the calldata length are cached
    ///      outside the loop so the legacy compiler pipeline (forge coverage,
    ///      no via_ir) doesn't trip stack-too-deep on the per-iteration
    ///      mapping derivation + calldata struct copy.
    function _storeEmergencyCalls(bytes32 key, BatchExecutorLib.Call[] calldata calls) private {
        delete _emergencyCalls[key];
        BatchExecutorLib.Call[] storage stored = _emergencyCalls[key];
        uint256 n = calls.length;
        for (uint256 i; i < n;) {
            stored.push(calls[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Governor cancels an open emergency review.
    /// @dev Reverts after `reviewEnd` — once the review window elapsed the
    ///      owner must face resolution. Prevents cancel-after-block-quorum.
    function cancelEmergency(uint256 proposalId) external onlyGovernor {
        bytes32 eKey = _reviewKey(msg.sender, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        if (er.reviewEnd > 0 && block.timestamp >= er.reviewEnd) revert ReviewNotOpen();
        // Sherlock #44: once block quorum is reached, the owner can't dodge.
        if (!er.cohortTooSmall) {
            uint256 denom = uint256(er.totalStakeAtOpen) + uint256(er.totalDelegatedAtOpen);
            // Sherlock run #2 #15: at-open snapshot.
            if (uint256(er.blockStakeWeight) * 10_000 >= uint256(er.blockQuorumBpsAtOpen) * denom) {
                revert ReviewNotOpen();
            }
        }
        er.resolved = true;
        er.blocked = false;
        er.blockStakeWeight = 0;
        // Sherlock #15: repurpose `reviewEnd` post-cancel to encode the
        // cooldown deadline.
        er.reviewEnd = uint64(block.timestamp + reviewPeriod);
        er.callsHash = bytes32(0);
        unchecked {
            er.nonce++;
        }
        delete _emergencyCalls[eKey];
        emit EmergencyReviewCancelled(proposalId);
    }

    /// @notice Returns true if an emergency review is open (not yet resolved)
    ///         for the given proposal. Used by the governor's `_finishSettlement`
    ///         to skip unnecessary `cancelEmergency` calls.
    function isEmergencyOpen(address governor, uint256 proposalId) external view returns (bool) {
        bytes32 eKey = _reviewKey(governor, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        return er.reviewEnd > 0 && !er.resolved;
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Mirrors `cancelEmergency` for the standard `_reviews` path.
    function cancelReview(uint256 proposalId) external onlyGovernor {
        bytes32 key = _reviewKey(msg.sender, proposalId);
        Review storage r = _reviews[key];
        if (r.resolved) return; // idempotent
        // Reject after the review window has closed: the proposer has had the
        // entire window to bail out; permitting cancel after `reviewEnd` would
        // let the proposer race a pending `resolveReview` slash.
        uint256 ve = IGovernorMinimal(msg.sender).getProposalView(proposalId).reviewEnd;
        if (ve > 0 && block.timestamp >= ve) revert ReviewNotOpen();
        // Sherlock run #2 #2: once block quorum is reached, the proposer
        // can't dodge approver slashing by cancelling. Mirrors
        // `cancelEmergency`'s Sherlock #44 gate. Cold-start cohorts skip
        // the check — quorum is not meaningful when `totalStakeAtOpen` is
        // below the floor. Sherlock run #2 #15: use the at-open snapshot.
        if (!r.cohortTooSmall) {
            uint256 denom = uint256(r.totalStakeAtOpen) + uint256(r.totalDelegatedAtOpen);
            if (uint256(r.blockStakeWeight) * 10_000 >= uint256(r.blockQuorumBpsAtOpen) * denom) {
                revert ReviewNotOpen();
            }
        }
        r.resolved = true;
        r.blocked = false;
        emit ReviewResolved(proposalId, false, 0);
    }

    // ── Permissionless ──
    /// @inheritdoc IGuardianRegistry
    /// @dev Permissionless keeper entrypoint. Callable once
    ///      `block.timestamp >= proposal.voteEnd`. Snapshots sWOOD's
    ///      `totalGuardianStake` / `totalDelegatedStake` into the review.
    ///      Idempotent: subsequent calls are no-ops.
    function openReview(address governor, uint256 proposalId) external whenNotPaused {
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();
        bytes32 key = _reviewKey(governor, proposalId);
        Review storage r = _reviews[key];
        if (r.opened) return; // idempotent

        uint256 ve = IGovernorMinimal(governor).getProposalView(proposalId).voteEnd;
        if (ve == 0 || block.timestamp < ve) revert ReviewNotOpen();

        IStakedWood sw = swood;
        // Sherlock #35 / Run-1 #18: read denominator at the SAME `t-1`
        // checkpoint that the numerator (voter weight) lookup uses, so
        // flash-stake / flash-delegation in the same block as openReview
        // can't asymmetrically inflate the quorum denominator while the
        // matching numerator weight stays at the t-1 snapshot.
        // Sherlock #39 / Run-1 #22: delegated total uses the ACTIVE-only
        // checkpoint — delegations to inactive guardians are dead weight
        // and don't inflate the quorum bar honest blockers must clear.
        uint256 ts1 = block.timestamp - 1;
        uint128 totalAtOpen = uint128(sw.getPastTotalVotes(ts1));
        uint128 delegatedAtOpen = uint128(sw.getPastTotalActiveDelegated(ts1));
        uint256 combinedAtOpen = uint256(totalAtOpen) + uint256(delegatedAtOpen);
        r.opened = true;
        r.totalStakeAtOpen = totalAtOpen;
        r.totalDelegatedAtOpen = delegatedAtOpen;
        // Sherlock run #2 #15: snapshot block-quorum at open so the owner
        // can't shift the threshold after voters have cast.
        // forge-lint: disable-next-line(unchecked-cast)
        r.blockQuorumBpsAtOpen = uint16(blockQuorumBps);
        r.openedAt = uint64(ts1);
        if (combinedAtOpen < MIN_COHORT_STAKE_AT_OPEN) {
            r.cohortTooSmall = true;
            emit CohortTooSmallToReview(proposalId, uint128(combinedAtOpen));
        } else {
            emit ReviewOpened(proposalId, uint128(combinedAtOpen));
        }
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Permissionless. Idempotent — once resolved, returns the cached
    ///      `blocked` flag without re-slashing. Requires
    ///      `block.timestamp >= reviewEnd`. Short-circuits to `false` when
    ///      `!opened` (no activity) or `cohortTooSmall` (cold-start fallback).
    ///      CEI: sets `resolved`/`blocked` flags BEFORE any token transfer.
    /// @dev nonReentrant dropped — CEI respected: `resolved`/`blocked` flags
    ///      committed before the slash transfer. Reentrant call
    ///      into `resolveReview` hits `if (r.resolved) return r.blocked` early.
    function resolveReview(address governor, uint256 proposalId) external whenNotPaused returns (bool) {
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();
        IGovernorMinimal.ProposalView memory p = IGovernorMinimal(governor).getProposalView(proposalId);
        if (p.reviewEnd == 0 || block.timestamp < p.reviewEnd) revert ReviewNotReadyForResolve();

        bytes32 key = _reviewKey(governor, proposalId);
        Review storage r = _reviews[key];
        if (r.resolved) return r.blocked; // idempotent
        if (!r.opened) {
            r.resolved = true;
            emit ReviewResolved(proposalId, false, 0);
            return false;
        }
        if (r.cohortTooSmall) {
            r.resolved = true;
            emit ReviewResolved(proposalId, false, 0);
            return false;
        }

        // Denominator is own stake + delegated stake at review open.
        // Sherlock run #2 #15: use the at-open block-quorum snapshot.
        uint256 denom = uint256(r.totalStakeAtOpen) + uint256(r.totalDelegatedAtOpen);
        bool blocked_ = (uint256(r.blockStakeWeight) * 10_000 >= uint256(r.blockQuorumBpsAtOpen) * denom);

        // CEI: commit state BEFORE the external slash call.
        r.resolved = true;
        r.blocked = blocked_;

        if (blocked_) {
            // Slash every approver. The slash factor is DETERMINISTIC — a
            // quadratic ramp of block-side decisiveness from the at-open
            // block quorum (floor: `minSlashBps`) to SUPERMAJORITY_BPS
            // (ceiling: `maxSlashBps`), computed by `_severityBps` from the
            // Review's at-open snapshots. Severity is not voted (spec
            // 2026-07-19 Part D). The burn and re-checkpoint all happen on
            // sWOOD.
            //
            // Sherlock run #3 #6: pass `r.openedAt` so sWOOD's `_slashOne`
            // can isolate the own-stake portion of each approver's combined
            // snapshot via `getPastDelegatedInbound(approver, openedAt)`.
            swood.slashGuardians(key, uint256(r.openedAt), _approvers[key], _severityBps(r));
            _emitBlockerAttribution(key, governor, proposalId);
        }

        emit ReviewResolved(proposalId, blocked_, 0);
        return blocked_;
    }

    /// @dev Deterministic slash severity from block-side decisiveness
    ///      (spec 2026-07-19 Part D). Replaces the blocker-voted
    ///      stake-weighted median: the winning side of a review must not
    ///      choose the losers' penalty. Quadratic ramp from the at-open
    ///      block quorum (floor — a scraped quorum is a genuinely contested
    ///      call) to SUPERMAJORITY_BPS (ceiling — overwhelming condemnation).
    ///      Approvers cannot lower it (honest blockers' weight is not theirs
    ///      to remove) and blockers gain nothing by inflating it (slashed
    ///      WOOD burns; blocker rewards are epoch-level, not
    ///      slash-proportional). Only called when the block quorum was
    ///      reached, so bBps >= qBps up to rounding; the bBps <= qBps branch
    ///      floors defensively.
    function _severityBps(Review storage r) private view returns (uint256) {
        uint256 lo = swood.minSlashBps();
        uint256 hi = swood.maxSlashBps();
        uint256 denom = uint256(r.totalStakeAtOpen) + uint256(r.totalDelegatedAtOpen);
        if (denom == 0) return lo; // defensive: a reached quorum implies denom > 0
        uint256 bBps = uint256(r.blockStakeWeight) * 10_000 / denom;
        uint256 qBps = uint256(r.blockQuorumBpsAtOpen);
        if (qBps >= SUPERMAJORITY_BPS || bBps >= SUPERMAJORITY_BPS) return hi;
        if (bBps <= qBps) return lo;
        // t in 1e18 fixed point; severity = lo + (hi - lo) * t^2.
        uint256 t = (bBps - qBps) * 1e18 / (SUPERMAJORITY_BPS - qBps);
        return lo + (hi - lo) * (t * t / 1e18) / 1e18;
    }

    /// @dev Emits `BlockerAttributed(governor, proposalId, epochId, blocker, weight)`
    ///      for each blocker so Merkl's off-chain bot can build the epoch WOOD
    ///      campaign's Merkle roots. `governor` disambiguates the (governor,
    ///      proposalId) review since per-vault governors all number from 1.
    function _emitBlockerAttribution(bytes32 key, address governor, uint256 proposalId) private {
        uint256 epochId = (block.timestamp - epochGenesis) / EPOCH_DURATION;
        address[] storage blockers = _blockers[key];
        uint256 n = blockers.length;
        for (uint256 i = 0; i < n; i++) {
            address b = blockers[i];
            uint256 w = _voteStake[key][b];
            if (w == 0) continue;
            emit BlockerAttributed(governor, proposalId, epochId, b, w);
        }
    }

    /// @notice Governor finalizes an emergency review after the review window.
    function finalizeEmergency(uint256 proposalId)
        external
        onlyGovernor
        whenNotPaused
        returns (bool, BatchExecutorLib.Call[] memory)
    {
        bytes32 eKey = _reviewKey(msg.sender, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        // `callsHash == 0` covers both never-opened AND cancelled reviews —
        // cancelEmergency zeroes the hash, so a cancelled emergency can't be
        // finalized as an empty-batch success.
        if (er.callsHash == bytes32(0) || block.timestamp < er.reviewEnd) revert ReviewNotReadyForResolve();
        if (!er.resolved) _resolveEmergency(eKey, proposalId, er);
        BatchExecutorLib.Call[] memory result = _loadEmergencyCalls(eKey);
        delete _emergencyCalls[eKey];
        return (er.blocked, result);
    }

    /// @notice Permissionless keeper entrypoint — commits emergency review
    ///         resolution and slashes the vault owner if blocked. Does NOT
    ///         return or execute calls. The governor's `finalizeEmergencySettle`
    ///         must still be called to execute the calls (if not blocked).
    /// @dev Restores the V1 permissionless slash path so the bond deterrent
    ///      works even if the owner never calls `finalizeEmergencySettle`.
    function resolveEmergencyReview(address governor, uint256 proposalId) external whenNotPaused {
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();
        bytes32 eKey = _reviewKey(governor, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        // See finalizeEmergency: callsHash==0 = never-opened or cancelled.
        if (er.callsHash == bytes32(0) || block.timestamp < er.reviewEnd) revert ReviewNotReadyForResolve();
        if (er.resolved) return; // idempotent
        _resolveEmergency(eKey, proposalId, er);
    }

    /// @dev Shared resolution logic for `finalizeEmergency` and
    ///      `resolveEmergencyReview`. Commits flags and slashes the vault
    ///      owner's bond on sWOOD if blocked. Reads `er.governor` (set at
    ///      `openEmergency`) instead of the removed singleton to locate the vault.
    function _resolveEmergency(bytes32, uint256 proposalId, EmergencyReview storage er) private {
        // Sherlock #45: cold-start cohort -> blocked=false regardless of votes.
        bool blocked_;
        if (!er.cohortTooSmall) {
            uint256 denomE = uint256(er.totalStakeAtOpen) + uint256(er.totalDelegatedAtOpen);
            if (denomE > 0) {
                // Sherlock run #2 #15: at-open snapshot.
                blocked_ = (uint256(er.blockStakeWeight) * 10_000 >= uint256(er.blockQuorumBpsAtOpen) * denomE);
            }
        }
        er.resolved = true;
        er.blocked = blocked_;
        if (blocked_) {
            address vault = IGovernorMinimal(er.governor).getProposalView(proposalId).vault;
            // The owner-bond burn + slot clearing happen on sWOOD.
            swood.slashOwnerBond(vault);
        }
        emit EmergencyReviewResolved(proposalId, blocked_, 0);
    }

    /// @dev Copies emergency calls from storage to memory.
    function _loadEmergencyCalls(bytes32 key) private view returns (BatchExecutorLib.Call[] memory r) {
        BatchExecutorLib.Call[] storage s = _emergencyCalls[key];
        uint256 n = s.length;
        r = new BatchExecutorLib.Call[](n);
        for (uint256 i; i < n;) {
            r[i] = s[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Active-guardian-only. Block-only side. One vote per guardian.
    ///      Weight is read from sWOOD's `getPastVotes` at `er.openedAt`.
    function voteBlockEmergencySettle(address governor, uint256 proposalId) external whenNotPaused {
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();
        bytes32 eKey = _reviewKey(governor, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        if (er.reviewEnd == 0 || block.timestamp >= er.reviewEnd) revert ReviewNotOpen();
        if (!swood.isActiveGuardian(msg.sender)) revert NotActiveGuardian();
        uint8 nonce = er.nonce;
        if (_emergencyBlockVotes[eKey][nonce][msg.sender]) revert AlreadyVoted();

        uint256 weight256 = swood.getPastVotes(msg.sender, uint256(er.openedAt));
        if (weight256 == 0) revert NotActiveGuardian(); // no votable weight at open time
        uint128 weight = uint128(weight256);
        _emergencyBlockVotes[eKey][nonce][msg.sender] = true;
        er.blockStakeWeight += weight;

        emit EmergencyBlockVoteCast(proposalId, msg.sender, weight);
    }

    // ── Slash appeal ──
    /// @inheritdoc IGuardianRegistry
    /// @dev Pulls WOOD from caller into `slashAppealReserve`. Owner-only.
    function fundSlashAppealReserve(uint256 amount) external onlyOwner {
        IERC20(swood.wood()).safeTransferFrom(msg.sender, address(this), amount);
        slashAppealReserve += amount;
        emit SlashAppealReserveFunded(msg.sender, amount);
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Per-epoch refund cap is `MAX_REFUND_PER_EPOCH_BPS` (20%) of the
    ///      CURRENT reserve size. Owner-only.
    function refundSlash(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 ep = (block.timestamp - epochGenesis) / EPOCH_DURATION;
        uint256 cap = (slashAppealReserve * MAX_REFUND_PER_EPOCH_BPS) / BPS_DENOMINATOR;
        if (refundedInEpoch[ep] + amount > cap) revert RefundCapExceeded();

        refundedInEpoch[ep] += amount;
        slashAppealReserve -= amount;

        IERC20(swood.wood()).safeTransfer(recipient, amount);
        emit SlashAppealRefunded(recipient, amount, ep);
    }

    // ── Pause ──
    /// @inheritdoc IGuardianRegistry
    /// @dev Owner-only. Freezes review voting and proposal-reward claim.
    function pause() external onlyOwner {
        if (paused) revert AlreadyPaused();
        paused = true;
        pausedAt = uint64(block.timestamp);
        emit Paused(msg.sender);
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Owner can unpause at any time. After `DEADMAN_UNPAUSE_DELAY` any
    ///      address can unpause.
    function unpause() external {
        if (!paused) revert NotPausedOrDeadmanNotElapsed();
        bool deadman = msg.sender != owner();
        if (deadman && block.timestamp < uint256(pausedAt) + DEADMAN_UNPAUSE_DELAY) {
            revert NotPausedOrDeadmanNotElapsed();
        }
        paused = false;
        pausedAt = 0;
        emit Unpaused(msg.sender, deadman);
    }

    // ── Parameter setters (owner-instant; owner is a multisig with external
    //    delay) ──

    /// @inheritdoc IGuardianRegistry
    /// @dev Enforces the absolute `[6 hours, 7 days]` bounds AND the
    ///      `coolDownPeriod >= reviewPeriod` cross-contract invariant
    ///      (Sherlock run #2 #16): the review window may not exceed sWOOD's
    ///      guardian unstake cooldown. This invariant closes slash-evasion
    ///      for guardian OWN stake only — an approver cannot unstake and
    ///      escape the slash before `resolveReview`. Delegator stake evasion
    ///      is closed independently by the delegation unbonding-escrow.
    ///      Post sWOOD-split: cooldown lives on sWOOD; cross-call gated
    ///      behind `address(swood) != address(0)` for the pre-wiring window.
    ///      Other staking params (`minGuardianStake`, `minOwnerStake`,
    ///      `coolDownPeriod`) moved to sWOOD with their own setters there.
    function setReviewPeriod(uint256 v) external onlyOwner {
        if (v < minReviewPeriod || v > 7 days) revert InvalidParameter();
        IStakedWood sw = swood;
        if (address(sw) != address(0) && v > sw.coolDownPeriod()) {
            revert CooldownBelowReviewPeriod();
        }
        emit ParameterChangeFinalized(PARAM_REVIEW_PERIOD, reviewPeriod, v);
        reviewPeriod = v;
    }

    /// @inheritdoc IGuardianRegistry
    function setBlockQuorumBps(uint256 v) external onlyOwner {
        if (v < 1_000 || v > 10_000) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_BLOCK_QUORUM_BPS, blockQuorumBps, v);
        blockQuorumBps = v;
    }

    // ── Views ──

    /// @inheritdoc IGuardianRegistry
    function getReviewState(address governor, uint256 proposalId)
        external
        view
        returns (bool opened, bool resolved, bool blocked, bool cohortTooSmall)
    {
        Review storage r = _reviews[_reviewKey(governor, proposalId)];
        return (r.opened, r.resolved, r.blocked, r.cohortTooSmall);
    }
}
