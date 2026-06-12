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
///         review lifecycle, multi-asset reward pools, and the slash-appeal
///         reserve. Holds **zero WOOD** — guardian stake, owner bonds, DPoS
///         delegation, vote checkpoints, and slashing live in `StakedWood`
///         (sWOOD). The registry reads vote weight from sWOOD and calls sWOOD
///         to slash. See
///         `docs/superpowers/specs/2026-05-21-swood-staking-split-design.md`.
contract GuardianRegistry is IGuardianRegistry, ReentrancyGuardTransient, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

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

    mapping(uint256 => Review) internal _reviews;
    mapping(uint256 => mapping(address => GuardianVoteType)) internal _votes;
    /// @dev Per-(proposal, voter) snapshot of the voter's vote weight at the
    ///      instant their review vote was recorded. Drives the reward-split
    ///      math in `claimProposalReward`. The slash snapshot lives on sWOOD
    ///      (`recordVoteStake` mirrors it there for slashing).
    mapping(uint256 => mapping(address => uint128)) internal _voteStake;
    mapping(uint256 => address[]) internal _approvers;
    mapping(uint256 => address[]) internal _blockers;
    mapping(uint256 => mapping(address => uint256)) internal _approverIndex;
    mapping(uint256 => mapping(address => uint256)) internal _blockerIndex;
    /// @dev Per-(proposal, blocker) proposed slash severity in bps, set when a
    ///      guardian casts a Block vote. Task 6.2 takes the stake-weighted
    ///      median of these (over `_blockers[pid]`) and clamps it at
    ///      `resolveReview`. Only meaningful for current Block voters — a
    ///      vote-change away from Block prunes the address from `_blockers`
    ///      via `_removeBlocker`, so the median never reads a stale entry.
    mapping(uint256 => mapping(address => uint256)) public blockerSlashBps;

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
    }

    mapping(uint256 => EmergencyReview) internal _emergencyReviews;
    // keyed by (proposalId, nonce, guardian) so cancelling + re-opening starts a
    // fresh round; prior-round votes are invisible to the new nonce.
    mapping(uint256 => mapping(uint8 => mapping(address => bool))) internal _emergencyBlockVotes;

    /// @dev Emergency call array — stored by governor via `openEmergency`,
    ///      returned on `finalizeEmergency`, cleared on cancel/finalize.
    mapping(uint256 => BatchExecutorLib.Call[]) internal _emergencyCalls;

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
    address public governor;
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

    // ── Per-proposal guardian-fee pool ──
    struct ProposalRewardPool {
        address asset;
        uint128 amount;
        uint64 settledAt;
    }

    /// @dev Funded by governor in `_distributeFees` when guardianFeeBps > 0.
    mapping(uint256 => ProposalRewardPool) internal _proposalGuardianPool;

    /// @dev Claim flags for approvers (set in `claimProposalReward`).
    mapping(uint256 => mapping(address => bool)) internal _approverClaimed;

    /// @dev Remainder (approver's net-of-commission pool) stored after the
    ///      approver claims, to be pulled by their delegators pro-rata.
    mapping(address => mapping(uint256 => uint256)) internal _delegatorProposalPool;
    mapping(address => mapping(uint256 => mapping(address => bool))) internal _delegatorProposalClaimed;

    /// @dev W-1 escrow for guardian-fee reward transfers that fail (e.g. USDC
    ///      blacklist). Keyed by `keccak256(proposalId, recipient, asset)` to
    ///      prevent cross-proposal drain.
    mapping(bytes32 => uint256) public unclaimedApproverFees;

    /// @dev Reserved storage for future upgrades.
    uint256[50] private __gap;

    // ── Initializer ──
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the slimmed registry.
    /// @param owner_ Owner multisig (parameter setter, pause, slash appeal).
    /// @param governor_ SyndicateGovernor address.
    /// @param factory_ SyndicateFactory address.
    /// @param swood_ StakedWood (sWOOD) — sole WOOD custodian; the registry
    ///        reads vote weight from it and calls it to slash.
    /// @param reviewPeriod_ Guardian review window.
    /// @param blockQuorumBps_ Block-quorum threshold in basis points.
    function initialize(
        address owner_,
        address governor_,
        address factory_,
        address swood_,
        uint256 reviewPeriod_,
        uint256 blockQuorumBps_
    ) external initializer {
        if (owner_ == address(0) || governor_ == address(0) || factory_ == address(0) || swood_ == address(0)) {
            revert ZeroAddress();
        }
        // Sherlock run #2 #16 invariant (cooldown >= review) is enforced at
        // the setters only — the deploy script seeds compatible values, and
        // skipping the init-time check claws back ~10 bytes under EIP-170.

        __Ownable_init(owner_);

        governor = governor_;
        factory = factory_;
        swood = IStakedWood(swood_);
        reviewPeriod = reviewPeriod_;
        blockQuorumBps = blockQuorumBps_;
        epochGenesis = block.timestamp;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ── Modifiers ──
    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
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
    ///      bare floor (`max(floor, TVL * ownerStakeTvlBps / 10_000)` → floor).
    function minOwnerStake() external view returns (uint256) {
        return swood.requiredOwnerBond(address(0));
    }

    // ──────────────────────────────────────────────────────────────
    // Guardian-fee pool funding
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    /// @dev Called by governor from `_distributeFees` after transferring the
    ///      guardian-fee slice to this contract.
    function fundProposalGuardianPool(uint256 proposalId, address asset, uint256 amount) external {
        if (msg.sender != governor) revert NotGovernor();
        if (amount == 0) return;
        if (_proposalGuardianPool[proposalId].settledAt != 0) revert PoolAlreadyFunded();
        _proposalGuardianPool[proposalId] =
            ProposalRewardPool({asset: asset, amount: uint128(amount), settledAt: uint64(block.timestamp)});
        emit ProposalGuardianPoolFunded(proposalId, asset, amount);
    }

    // ──────────────────────────────────────────────────────────────
    // Guardian-fee claim paths
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    /// @dev Approve-side reward. **Sherlock #41**: permissionless caller; the
    ///      approver is supplied explicitly so the delegator pool gets seeded
    ///      even if the approver themselves never invokes the claim path.
    ///
    ///      The approver's gross share is split by source: the portion
    ///      attributable to their OWN stake is paid in full; the portion
    ///      attributable to their delegators is split by DPoS commission rate
    ///      (commission paid to approver, remainder stored for delegators).
    ///      Own-stake weight and commission rate are read from sWOOD —
    ///      `getPastVotes` at `openedAt` (own + delegated) is the inverse of
    ///      the split, and `getPastDelegatedInbound` at `openedAt` gives the
    ///      delegated half; commission is `getPastCommission` at `settledAt`.
    function claimProposalReward(address approver, uint256 proposalId) external whenNotPaused {
        ProposalRewardPool memory pool = _proposalGuardianPool[proposalId];
        if (pool.amount == 0) revert NoPoolFunded();
        if (_approverClaimed[proposalId][approver]) revert AlreadyClaimed();

        if (_votes[proposalId][approver] != GuardianVoteType.Approve) revert NotApprover();

        // Sherlock run #2 #4 (review fix per PR #350 follow-up): gate reward
        // on snapshot-time own stake, not live state. Run-2 #16's
        // `coolDownPeriod >= reviewPeriod` invariant closes the original
        // "vote, exit during cooldown, claim post-settle" attack
        // structurally — an approver cannot fully exit before
        // `resolveReview` runs. This snapshot gate matches the design
        // signal that the approver held own stake at `r.openedAt` (mirrors
        // the voteOnProposal first-vote gate). Approvers in-process of
        // unstaking AND approvers burned to zero by a concurrent proposal
        // both keep their non-zero checkpoint at openedAt and are paid
        // correctly.
        //
        // Post sWOOD-split: own stake lives on sWOOD. `getPastVotes` returns
        // own + delegated weight at `openedAt`, so own-stake is
        // `getPastVotes - getPastDelegatedInbound`.
        Review storage r = _reviews[proposalId];
        IStakedWood sw = swood;
        uint256 totalW = sw.getPastVotes(approver, uint256(r.openedAt));
        uint256 delegatedW = sw.getPastDelegatedInbound(approver, uint256(r.openedAt));
        uint256 ownW = totalW - delegatedW;

        // PR #351 review #3: when `ownW == 0` (reachable via
        // unstake-then-restake around `openedAt` while inbound delegations
        // still cover the vote-gate), pre-fix this reverted `NotActiveGuardian`.
        // The revert bricked the entire claim path AND
        // `claimDelegatorProposalReward` (since `_delegatorProposalPool` is
        // only seeded inside this function at the write below). The approver's
        // gross slice + the delegators' pool were stranded in the registry
        // forever.
        //
        // Fix: drop the revert and route 100% of the slice to the delegator
        // pool — the approver had no own-stake skin in the game at `openedAt`
        // and didn't earn DPoS commission for that snapshot. The
        // `grossFromOwn = (gross * ownW) / w` math below collapses to 0
        // naturally; the inline `ownW == 0 ? 0 : getPastCommission(...)`
        // ternary at the commission-rate read forces commission to 0 as well,
        // so the entire `gross` lands in `remainder` and seeds the delegator
        // pool at the `_delegatorProposalPool` write below. (PR #359 review #6:
        // comment was referencing a non-existent `_zeroCommissionIfOwnIsZero`
        // flag — the impl is the ternary.)

        uint256 gross;
        uint256 commission;
        uint256 remainder;
        uint256 approverPayout;
        {
            uint256 w = _voteStake[proposalId][approver];
            // approveStakeWeight >= w by construction (w is one of the weights summed into it).
            gross = (uint256(pool.amount) * w) / uint256(r.approveStakeWeight);

            // Split the approver's gross share between own-stake portion (fully
            // to approver) and delegated-stake portion (commission split).
            // ownW is read at `r.openedAt` — the SAME timestamp used to freeze
            // `w` in voteOnProposal — so `w >= ownW` holds by construction (w =
            // own@openedAt + delegated@openedAt). No clamp needed. Reading at
            // `settledAt` instead would strand funds when an approver requests
            // unstake mid-review.
            uint256 grossFromOwn = (gross * ownW) / w;
            uint256 grossFromDelegated = gross - grossFromOwn;

            // PR #351 review #3: zero commission when there was no own stake
            // at `openedAt`. Otherwise an approver could game the gate via
            // unstake-restake and still skim a commission rate they didn't
            // earn as a validator. The full delegated portion lands in
            // `remainder` and seeds the delegator pool below.
            uint256 rate = ownW == 0 ? 0 : sw.getPastCommission(approver, uint256(pool.settledAt));
            commission = (grossFromDelegated * rate) / BPS_DENOMINATOR;
            approverPayout = grossFromOwn + commission;
            remainder = grossFromDelegated - commission;
        }

        // CEI: flag + pool-seed before external transfer.
        _approverClaimed[proposalId][approver] = true;
        _delegatorProposalPool[approver][proposalId] = remainder;

        if (approverPayout > 0) {
            _safeRewardTransfer(pool.asset, approver, approverPayout, proposalId);
        }
        emit ApproverRewardClaimed(proposalId, approver, gross, commission, remainder);
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Pulls the delegator's pro-rata share of the delegate's remainder
    ///      pool. Attribution timestamp is the review's `openedAt` — same as
    ///      the approver's vote-weight snapshot — so delegator denominator and
    ///      `grossFromDelegated` numerator align. Delegation history is read
    ///      from sWOOD (`getPastDelegation` / `getPastDelegatedInbound`).
    function claimDelegatorProposalReward(address delegate, uint256 proposalId) external {
        if (_delegatorProposalClaimed[delegate][proposalId][msg.sender]) revert AlreadyClaimed();
        uint256 pool = _delegatorProposalPool[delegate][proposalId];
        if (pool == 0) revert DelegatePoolEmpty();

        address asset = _proposalGuardianPool[proposalId].asset;
        uint256 openedAt = uint256(_reviews[proposalId].openedAt);

        IStakedWood sw = swood;
        uint256 my = sw.getPastDelegation(msg.sender, delegate, openedAt);
        uint256 totalDelegated = sw.getPastDelegatedInbound(delegate, openedAt);
        if (totalDelegated == 0) revert NoDelegationAtSettle();

        uint256 share = (pool * my) / totalDelegated;

        // CEI: flag before transfer.
        _delegatorProposalClaimed[delegate][proposalId][msg.sender] = true;

        if (share > 0) {
            _safeRewardTransfer(asset, msg.sender, share, proposalId);
        }
        emit DelegatorProposalRewardClaimed(msg.sender, delegate, proposalId, share);
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev W-1 retry path. After the transfer-failure condition is lifted,
    ///      anyone can flush the escrow to the recipient. Keyed by
    ///      (proposalId, recipient, asset) so a malicious flush cannot redirect.
    function flushUnclaimedApproverFee(uint256 proposalId, address recipient, address asset) external {
        bytes32 key = keccak256(abi.encode(proposalId, recipient, asset));
        uint256 amount = unclaimedApproverFees[key];
        if (amount == 0) revert NoEscrowedAmount();

        unclaimedApproverFees[key] = 0;
        IERC20(asset).safeTransfer(recipient, amount);
    }

    /// @dev Wrapped ERC20 transfer for guardian-fee claims. On failure (e.g.
    ///      USDC blacklist), records the amount in `unclaimedApproverFees`
    ///      keyed by `(proposalId, recipient, asset)` + emits
    ///      `ApproverFeeEscrowed`. Cross-proposal drain is impossible because
    ///      the key includes `proposalId`.
    ///
    ///      Sherlock run #3 #2: SafeERC20-style success check. The pre-fix
    ///      `try IERC20(asset).transfer(...) returns (bool r)` shape mis-
    ///      handled non-standard ERC20s like USDT that don't return a bool —
    ///      the bool decode reverted on empty returndata, the try block
    ///      reverted, the catch escrowed the amount, and yet the underlying
    ///      transfer ACTUALLY succeeded. Recipient then double-claimed via
    ///      `flushUnclaimedApproverFee` (which uses `SafeERC20.safeTransfer`,
    ///      tolerates empty returndata). Inlined here rather than reusing
    ///      `SafeERC20.safeTransfer` because OZ's helper REVERTS on failure
    ///      and the W-1 escrow path needs a signal (`ok=false`) instead.
    function _safeRewardTransfer(address asset, address recipient, uint256 amount, uint256 proposalId) internal {
        bool ok;
        // forge-lint: disable-next-line(unsafe-cheatcode)
        (bool success, bytes memory rd) = asset.call(abi.encodeCall(IERC20.transfer, (recipient, amount)));
        if (success) {
            if (rd.length == 0) {
                // Non-standard ERC20 (USDT-style): empty return = success.
                ok = true;
            } else if (rd.length >= 32) {
                ok = abi.decode(rd, (bool));
            }
            // else: malformed return data — treat as failure, escrow.
        }
        if (!ok) {
            unclaimedApproverFees[keccak256(abi.encode(proposalId, recipient, asset))] += amount;
            emit ApproverFeeEscrowed(proposalId, recipient, asset, amount);
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Guardian review voting
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    /// @dev First-vote path OR vote-change. Requires `openReview` to have been
    ///      called and `voteEnd <= now < reviewEnd`. Snapshots the caller's
    ///      vote weight at `r.openedAt` (read from sWOOD's `getPastVotes`) into
    ///      `_voteStake[proposalId][caller]` and adds it to the chosen side's
    ///      tally. Approvers and Blockers are each capped.
    ///
    ///      For Approve votes the snapshot is mirrored to sWOOD via
    ///      `recordVoteStake` so a later `slashGuardians` can size the slash.
    /// @param slashBps Proposed slash severity for a Block vote. Stored in
    ///        `blockerSlashBps` and median-aggregated + clamped at
    ///        `resolveReview` (Task 6.2). Ignored for Approve votes — NOT
    ///        bounds-checked here: clamping happens on the median.
    function voteOnProposal(uint256 proposalId, GuardianVoteType support, uint256 slashBps) external whenNotPaused {
        if (support == GuardianVoteType.None) revert();

        Review storage r = _reviews[proposalId];
        if (!r.opened) revert ReviewNotOpen();

        IGovernorMinimal.ProposalView memory p = IGovernorMinimal(governor).getProposalView(proposalId);
        if (block.timestamp < p.voteEnd || block.timestamp >= p.reviewEnd) revert ReviewNotOpen();

        if (!swood.isActiveGuardian(msg.sender)) revert NotActiveGuardian();

        GuardianVoteType existing = _votes[proposalId][msg.sender];
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
            _voteStake[proposalId][msg.sender] = weight;

            if (support == GuardianVoteType.Approve) {
                _pushApprover(proposalId, msg.sender);
                r.approveStakeWeight += weight;
                // Mirror the snapshot to sWOOD so `slashGuardians` can size
                // the slash against the exact weight voted with.
                swood.recordVoteStake(proposalId, msg.sender, weight);
            } else {
                _pushBlocker(proposalId, msg.sender);
                r.blockStakeWeight += weight;
                blockerSlashBps[proposalId][msg.sender] = slashBps;
            }
            _votes[proposalId][msg.sender] = support;
            emit GuardianVoteCast(proposalId, msg.sender, support, weight);
        } else {
            // Vote-change: must be before the late lockout window.
            uint256 reviewWindow = uint256(p.reviewEnd) - uint256(p.voteEnd);
            uint256 lockoutStart = p.reviewEnd - (reviewWindow * LATE_VOTE_LOCKOUT_BPS) / BPS_DENOMINATOR;
            if (block.timestamp >= lockoutStart) revert VoteChangeLockedOut();

            uint128 weight = _voteStake[proposalId][msg.sender]; // preserved snapshot
            // LOAD-BEARING INVARIANT: the new-side cap is checked inline BEFORE
            // any `_remove*` / `_push*` call.
            if (existing == GuardianVoteType.Approve) {
                // Approve → Block (blockers are capped).
                if (_blockers[proposalId].length >= MAX_BLOCKERS_PER_PROPOSAL) revert NewSideFull();
                _removeApprover(proposalId, msg.sender);
                r.approveStakeWeight -= weight;
                _pushBlocker(proposalId, msg.sender);
                r.blockStakeWeight += weight;
                blockerSlashBps[proposalId][msg.sender] = slashBps;
                // No longer an approver — drop the sWOOD slash snapshot.
                swood.recordVoteStake(proposalId, msg.sender, 0);
            } else {
                // Block → Approve.
                if (_approvers[proposalId].length >= MAX_APPROVERS_PER_PROPOSAL) revert NewSideFull();
                _removeBlocker(proposalId, msg.sender);
                r.blockStakeWeight -= weight;
                _pushApprover(proposalId, msg.sender);
                r.approveStakeWeight += weight;
                // Now an approver — record the slash snapshot on sWOOD.
                swood.recordVoteStake(proposalId, msg.sender, weight);
            }
            _votes[proposalId][msg.sender] = support;
            emit GuardianVoteChanged(proposalId, msg.sender, existing, support);
        }
    }

    // ── Internal vote helpers ──
    function _pushApprover(uint256 proposalId, address g) private {
        if (_approvers[proposalId].length >= MAX_APPROVERS_PER_PROPOSAL) {
            emit ApproverCapReached(proposalId);
            revert NewSideFull();
        }
        _approvers[proposalId].push(g);
        _approverIndex[proposalId][g] = _approvers[proposalId].length; // 1-indexed
    }

    function _pushBlocker(uint256 proposalId, address g) private {
        if (_blockers[proposalId].length >= MAX_BLOCKERS_PER_PROPOSAL) {
            emit BlockerCapReached(proposalId);
            revert NewSideFull();
        }
        _blockers[proposalId].push(g);
        _blockerIndex[proposalId][g] = _blockers[proposalId].length; // 1-indexed
    }

    /// @dev Swap-and-pop removal of `g` from `_approvers[proposalId]`.
    function _removeApprover(uint256 proposalId, address g) private {
        uint256 idx1 = _approverIndex[proposalId][g];
        uint256 idx = idx1 - 1;
        address[] storage arr = _approvers[proposalId];
        address last = arr[arr.length - 1];
        if (last != g) {
            arr[idx] = last;
            _approverIndex[proposalId][last] = idx1;
        }
        arr.pop();
        delete _approverIndex[proposalId][g];
    }

    /// @dev Mirror of `_removeApprover` for blockers.
    function _removeBlocker(uint256 proposalId, address g) private {
        uint256 idx1 = _blockerIndex[proposalId][g];
        uint256 idx = idx1 - 1;
        address[] storage arr = _blockers[proposalId];
        address last = arr[arr.length - 1];
        if (last != g) {
            arr[idx] = last;
            _blockerIndex[proposalId][last] = idx1;
        }
        arr.pop();
        delete _blockerIndex[proposalId][g];
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

        EmergencyReview storage er = _emergencyReviews[proposalId];
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

        _storeEmergencyCalls(proposalId, calls);
        emit EmergencyReviewOpened(proposalId, callsHash, newReviewEnd);
    }

    /// @dev Stores emergency calls in storage, replacing any prior array.
    function _storeEmergencyCalls(uint256 proposalId, BatchExecutorLib.Call[] calldata calls) private {
        delete _emergencyCalls[proposalId];
        BatchExecutorLib.Call[] storage stored = _emergencyCalls[proposalId];
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
        EmergencyReview storage er = _emergencyReviews[proposalId];
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
        delete _emergencyCalls[proposalId];
        emit EmergencyReviewCancelled(proposalId);
    }

    /// @notice Returns true if an emergency review is open (not yet resolved).
    function isEmergencyOpen(uint256 proposalId) external view returns (bool) {
        EmergencyReview storage er = _emergencyReviews[proposalId];
        return er.reviewEnd > 0 && !er.resolved;
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Mirrors `cancelEmergency` for the standard `_reviews` path.
    function cancelReview(uint256 proposalId) external onlyGovernor {
        Review storage r = _reviews[proposalId];
        if (r.resolved) return; // idempotent
        uint256 ve = IGovernorMinimal(governor).getProposalView(proposalId).reviewEnd;
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
    function openReview(uint256 proposalId) external whenNotPaused {
        Review storage r = _reviews[proposalId];
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
    /// @dev Permissionless. Idempotent. When blocked, slashes all approvers via
    ///      `swood.slashGuardians` and emits blocker attribution for Merkl.
    function resolveReview(uint256 proposalId) external whenNotPaused returns (bool) {
        IGovernorMinimal.ProposalView memory p = IGovernorMinimal(governor).getProposalView(proposalId);
        if (p.reviewEnd == 0 || block.timestamp < p.reviewEnd) revert ReviewNotReadyForResolve();

        Review storage r = _reviews[proposalId];
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
            // Slash every approver. The slash factor is the stake-weighted
            // median of the blockers' proposed severities, clamped to the
            // owner-set `[minSlashBps, maxSlashBps]` band on sWOOD. The burn
            // and re-checkpoint all happen on sWOOD.
            //
            // Sherlock run #3 #6: pass `r.openedAt` so sWOOD's `_slashOne`
            // can isolate the own-stake portion of each approver's combined
            // snapshot via `getPastDelegatedInbound(approver, openedAt)`.
            swood.slashGuardians(
                proposalId, uint256(r.openedAt), _approvers[proposalId], _weightedMedianSlashBps(proposalId)
            );
            _emitBlockerAttribution(proposalId);
        }

        emit ReviewResolved(proposalId, blocked_, 0);
        return blocked_;
    }

    /// @dev Stake-weighted median of the current Block voters' proposed
    ///      `slashBps`, clamped to sWOOD's `[minSlashBps, maxSlashBps]` band
    ///      (where `maxSlashBps < 10_000` — C-2 pool-bricking defense, so a
    ///      blocker voting `slashBps == 10_000` is clamped DOWN to
    ///      `maxSlashBps`). Each blocker's weight is
    ///      `_voteStake[proposalId][blocker]` — the exact per-blocker weight
    ///      that fed the block-quorum tally, so the median weighting matches
    ///      the quorum weighting. `_blockers` is capped at
    ///      `MAX_BLOCKERS_PER_PROPOSAL`, so the O(n²) insertion sort is
    ///      bounded. The median is the `slashBps` of the first pair (sorted
    ///      ascending by `slashBps`) whose cumulative weight reaches ≥ 50% of
    ///      total blocker weight. Fallback: if total weight is 0 (cannot occur
    ///      once quorum is reached, but defensive), return `minSlashBps`.
    function _weightedMedianSlashBps(uint256 proposalId) private view returns (uint256) {
        uint256 lo = swood.minSlashBps();
        uint256 hi = swood.maxSlashBps();

        address[] storage blockers = _blockers[proposalId];
        uint256 n = blockers.length;
        if (n == 0) return lo;

        // Collect (slashBps, weight) pairs.
        uint256[] memory bps = new uint256[](n);
        uint256[] memory wts = new uint256[](n);
        uint256 totalWeight;
        for (uint256 i = 0; i < n; i++) {
            address b = blockers[i];
            bps[i] = blockerSlashBps[proposalId][b];
            uint256 w = _voteStake[proposalId][b];
            wts[i] = w;
            totalWeight += w;
        }
        if (totalWeight == 0) return lo;

        // Insertion sort by `slashBps` ascending (n ≤ MAX_BLOCKERS_PER_PROPOSAL).
        for (uint256 i = 1; i < n; i++) {
            uint256 keyBps = bps[i];
            uint256 keyWt = wts[i];
            uint256 j = i;
            while (j > 0 && bps[j - 1] > keyBps) {
                bps[j] = bps[j - 1];
                wts[j] = wts[j - 1];
                j--;
            }
            bps[j] = keyBps;
            wts[j] = keyWt;
        }

        // Walk cumulative weight; median = first pair reaching ≥ 50%.
        // `* 2 >=` avoids a rounding-down division of an odd `totalWeight`.
        uint256 cumulative;
        uint256 median = bps[n - 1];
        for (uint256 i = 0; i < n; i++) {
            cumulative += wts[i];
            if (cumulative * 2 >= totalWeight) {
                median = bps[i];
                break;
            }
        }

        // Clamp to the owner-set band.
        if (median < lo) return lo;
        if (median > hi) return hi;
        return median;
    }

    /// @dev Emits `BlockerAttributed(proposalId, epochId, blocker, weight)`
    ///      for each blocker so Merkl's off-chain bot can build the epoch
    ///      WOOD campaign's Merkle roots.
    function _emitBlockerAttribution(uint256 proposalId) private {
        uint256 epochId = (block.timestamp - epochGenesis) / EPOCH_DURATION;
        address[] storage blockers = _blockers[proposalId];
        uint256 n = blockers.length;
        for (uint256 i = 0; i < n; i++) {
            address b = blockers[i];
            uint256 w = _voteStake[proposalId][b];
            if (w == 0) continue;
            emit BlockerAttributed(proposalId, epochId, b, w);
        }
    }

    /// @notice Governor finalizes an emergency review after the review window.
    function finalizeEmergency(uint256 proposalId)
        external
        onlyGovernor
        whenNotPaused
        returns (bool, BatchExecutorLib.Call[] memory)
    {
        EmergencyReview storage er = _emergencyReviews[proposalId];
        if (er.callsHash == bytes32(0) || block.timestamp < er.reviewEnd) revert ReviewNotReadyForResolve();
        if (!er.resolved) _resolveEmergency(proposalId, er);
        BatchExecutorLib.Call[] memory result = _loadEmergencyCalls(proposalId);
        delete _emergencyCalls[proposalId];
        return (er.blocked, result);
    }

    /// @notice Permissionless keeper entrypoint — commits emergency review
    ///         resolution and slashes the vault owner if blocked.
    function resolveEmergencyReview(uint256 proposalId) external whenNotPaused {
        EmergencyReview storage er = _emergencyReviews[proposalId];
        if (er.callsHash == bytes32(0) || block.timestamp < er.reviewEnd) revert ReviewNotReadyForResolve();
        if (er.resolved) return; // idempotent
        _resolveEmergency(proposalId, er);
    }

    /// @dev Shared resolution logic for `finalizeEmergency` and
    ///      `resolveEmergencyReview`. Commits flags and slashes the vault
    ///      owner's bond on sWOOD if blocked.
    function _resolveEmergency(uint256 proposalId, EmergencyReview storage er) private {
        // Sherlock #45: cold-start cohort → blocked=false regardless of votes.
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
            address vault = IGovernorMinimal(governor).getProposalView(proposalId).vault;
            // The owner-bond burn + slot clearing happen on sWOOD.
            swood.slashOwnerBond(vault);
        }
        emit EmergencyReviewResolved(proposalId, blocked_, 0);
    }

    /// @dev Copies emergency calls from storage to memory.
    function _loadEmergencyCalls(uint256 pid) private view returns (BatchExecutorLib.Call[] memory r) {
        BatchExecutorLib.Call[] storage s = _emergencyCalls[pid];
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
    function voteBlockEmergencySettle(uint256 proposalId) external whenNotPaused {
        EmergencyReview storage er = _emergencyReviews[proposalId];
        if (er.reviewEnd == 0 || block.timestamp >= er.reviewEnd) revert ReviewNotOpen();
        if (!swood.isActiveGuardian(msg.sender)) revert NotActiveGuardian();
        uint8 nonce = er.nonce;
        if (_emergencyBlockVotes[proposalId][nonce][msg.sender]) revert AlreadyVoted();

        uint256 weight256 = swood.getPastVotes(msg.sender, uint256(er.openedAt));
        if (weight256 == 0) revert NotActiveGuardian(); // no votable weight at open time
        uint128 weight = uint128(weight256);
        _emergencyBlockVotes[proposalId][nonce][msg.sender] = true;
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
        if (v < 6 hours || v > 7 days) revert InvalidParameter();
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
    function getReviewState(uint256 proposalId)
        external
        view
        returns (bool opened, bool resolved, bool blocked, bool cohortTooSmall)
    {
        Review storage r = _reviews[proposalId];
        return (r.opened, r.resolved, r.blocked, r.cohortTooSmall);
    }
}
