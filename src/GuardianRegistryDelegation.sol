// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @title GuardianRegistryDelegation
/// @notice Abstract — stake-pool delegation + DPoS commission + delegator-side
///         guardian-fee claim. Extracted from `GuardianRegistry` for EIP-170
///         bytecode headroom. Mirrors the `GovernorEmergency` precedent (PR
///         #229) — abstract owns its own storage + externals; concrete
///         contract implements virtual accessors for state it needs to read
///         in the parent (e.g. `_isActiveGuardian`, review/proposal state).
///
///         **Storage layout**: the abstract's storage slots come FIRST in the
///         final contract's layout (per C3 linearization with the concrete
///         contract inheriting this abstract). V1.5 is a fresh mainnet
///         redeployment so this storage reorganization is safe — proxies
///         start zeroed. The per-abstract `__delegationGap` reserves room
///         for future delegation additions without shifting the concrete
///         contract's layout.
abstract contract GuardianRegistryDelegation is IGuardianRegistry, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    // ── Constants ──

    /// @notice 100% in basis points (duplicated from concrete for arithmetic
    ///         in `claimDelegatorProposalReward`).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice 7-day epoch — used by `setCommission`'s raise-cap math.
    ///         Public so off-chain Merkl bot reads the same constant.
    uint256 public constant EPOCH_DURATION = 7 days;

    /// @notice Max commission a delegate can charge their delegators (50%).
    uint256 public constant MAX_COMMISSION_BPS = 5000;

    /// @notice Max bps increase per epoch (5%). Prevents delegates from
    ///         instant-ramping commission to rug their delegators' share of
    ///         already-earned rewards. Decreases are unbounded.
    uint256 public constant MAX_COMMISSION_INCREASE_PER_EPOCH = 500;

    // ── Delegation storage ──

    /// @dev Per-(delegator, delegate) locked balance. WOOD moves from the
    ///      delegator's wallet into the registry on `delegateStake`.
    mapping(address delegator => mapping(address delegate => uint256)) internal _delegations;

    /// @dev Per-(delegator, delegate) historical balance. At vote / reward
    ///      attribution we look up `_delegationCheckpoints[delegator][delegate]
    ///      .upperLookupRecent(reviewOpenedAt)` to split the delegate's
    ///      voting pool among their delegators.
    mapping(address delegator => mapping(address delegate => Checkpoints.Trace224)) internal _delegationCheckpoints;

    /// @dev Per-(delegator, delegate) unstake-request timestamp; 0 = no request.
    mapping(address delegator => mapping(address delegate => uint64)) internal _unstakeDelegationRequestedAt;

    /// @dev Per-delegate inbound delegation sum (current).
    mapping(address delegate => uint256) internal _delegatedInbound;

    /// @dev Per-delegate inbound delegation history for `getPastDelegated`.
    mapping(address delegate => Checkpoints.Trace224) internal _delegatedInboundCheckpoints;

    /// @dev Global sum of all delegations (for quorum denominator at review open).
    uint256 public totalDelegatedStake;

    /// @dev Global delegation total history for `getPastTotalDelegated`.
    Checkpoints.Trace224 internal _totalDelegatedCheckpoint;

    // ── DPoS commission storage ──

    /// @dev Current commission rate per delegate.
    mapping(address => uint256) internal _commissionBps;

    /// @dev Epoch in which the delegate last raised (or first-set) their
    ///      commission. Used to detect transition into a new raise-epoch so
    ///      `_commissionEpochBaseline` can be re-anchored.
    mapping(address => uint256) internal _lastCommissionRaiseEpoch;

    /// @dev Anchor for the per-epoch cumulative raise cap. Seeded on:
    ///      - first-ever set: baseline = newBps (rate is being announced)
    ///      - first raise of a new epoch: baseline = rate at epochStart - 1
    ///        (last pre-epoch checkpoint)
    ///      Subsequent raises within the same epoch keep the baseline fixed,
    ///      so chained raises cannot compound past
    ///      `baseline + MAX_COMMISSION_INCREASE_PER_EPOCH`.
    mapping(address => uint256) internal _commissionEpochBaseline;

    /// @dev Per-delegate commission history keyed by timestamp. Consumed by
    ///      `claimProposalReward` (in concrete contract) which looks up the
    ///      rate at `settledAt` — closes the retroactive-raise vector. Also
    ///      consumed by `setCommission` itself to derive the per-epoch raise
    ///      baseline.
    mapping(address => Checkpoints.Trace224) internal _commissionCheckpoints;

    // ── Delegator pool storage (seeded by concrete's claimProposalReward) ──

    /// @dev Remainder (approver's net-of-commission pool) stored after the
    ///      approver claims, to be pulled by their delegators pro-rata.
    ///      Written by concrete's `claimProposalReward`; read by abstract's
    ///      `claimDelegatorProposalReward`.
    mapping(address => mapping(uint256 => uint256)) internal _delegatorProposalPool;
    mapping(address => mapping(uint256 => mapping(address => bool))) internal _delegatorProposalClaimed;

    /// @dev Reserved storage slots at the `GuardianRegistryDelegation` layer
    ///      so future delegation additions don't shift `GuardianRegistry`'s
    ///      layout.
    uint256[10] private __delegationGap;

    // ── Virtual accessors (implemented by concrete GuardianRegistry) ──

    /// @notice Returns the WOOD token reference (lives in concrete storage).
    function _wood() internal view virtual returns (IERC20);

    /// @notice Returns the global unstake-cooldown period (lives in concrete).
    function _coolDownPeriod() internal view virtual returns (uint256);

    /// @notice Returns the epoch-genesis timestamp anchor (lives in concrete).
    function _epochGenesis() internal view virtual returns (uint256);

    /// @notice Whether `g` has active own-stake (lives in concrete's
    ///         `_guardians[g]` struct check).
    function _isActiveGuardian(address g) internal view virtual returns (bool);

    /// @notice Returns the `openedAt` timestamp of the named proposal's
    ///         review (lives in concrete's `_reviews[pid]`).
    function _reviewOpenedAt(uint256 proposalId) internal view virtual returns (uint32);

    /// @notice Returns the asset address of the named proposal's guardian-fee
    ///         pool (lives in concrete's `_proposalGuardianPool[pid]`).
    function _proposalRewardAsset(uint256 proposalId) internal view virtual returns (address);

    /// @notice Wrapped ERC20 transfer for guardian-fee claims. Concrete
    ///         implements via the W-1 escrow path (`unclaimedApproverFees`
    ///         mapping).
    function _safeRewardTransfer(address asset, address recipient, uint256 amount, uint256 proposalId) internal virtual;

    // ──────────────────────────────────────────────────────────────
    // Stake-pool delegation
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    /// @dev Permissive delegation — any address can be a delegate. To be
    ///      active-guardian-eligible, the delegate still needs their OWN
    ///      stake >= minGuardianStake (delegation adds to vote weight but
    ///      does not bypass activation). Delegating to self is disallowed to
    ///      keep own-stake and delegated pools strictly disjoint.
    ///
    ///      Custody moves into the registry; balance tracked per-(delegator,
    ///      delegate) pair with a Trace224 checkpoint for historical
    ///      attribution. If the delegator had a pending unstake request for
    ///      this delegate, re-delegating implicitly cancels it.
    function delegateStake(address delegate, uint256 amount) external nonReentrant {
        if (delegate == msg.sender) revert CannotSelfDelegate();
        if (delegate == address(0)) revert InvalidDelegate();
        if (amount == 0) revert AmountZero();
        // I-5: delegating to a guardian that has 0 active stake (never staked,
        // fully slashed, or mid-unstake) traps the delegator's WOOD behind the
        // 7-day cooldown pointing at a vote-inert address. Reject early so the
        // UX surface + accounting both reflect reality.
        if (!_isActiveGuardian(delegate)) revert InactiveDelegate();

        // Re-delegation implicitly cancels any in-flight unstake request.
        _unstakeDelegationRequestedAt[msg.sender][delegate] = 0;

        _wood().safeTransferFrom(msg.sender, address(this), amount);

        uint256 newBalance = _delegations[msg.sender][delegate] + amount;
        _delegations[msg.sender][delegate] = newBalance;
        _delegatedInbound[delegate] += amount;
        totalDelegatedStake += amount;

        _delegationCheckpoints[msg.sender][delegate].push(uint32(block.timestamp), uint224(newBalance));
        _delegatedInboundCheckpoints[delegate].push(uint32(block.timestamp), uint224(_delegatedInbound[delegate]));
        _totalDelegatedCheckpoint.push(uint32(block.timestamp), uint224(totalDelegatedStake));

        emit DelegationIncreased(msg.sender, delegate, amount);
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Starts the unstake-delegation cooldown. The delegation slot stays
    ///      non-zero in `_delegations` (delegate's vote weight at any
    ///      already-opened review that referenced the delegator's weight at
    ///      `r.openedAt` is frozen via the Trace224 checkpoint, so requesting
    ///      unstake now does not retroactively change anything).
    function requestUnstakeDelegation(address delegate) external {
        if (_delegations[msg.sender][delegate] == 0) revert NoActiveDelegation();
        if (_unstakeDelegationRequestedAt[msg.sender][delegate] != 0) revert UnstakeAlreadyRequested();
        _unstakeDelegationRequestedAt[msg.sender][delegate] = uint64(block.timestamp);
        emit DelegationUnstakeRequested(msg.sender, delegate, block.timestamp);
    }

    /// @inheritdoc IGuardianRegistry
    function cancelUnstakeDelegation(address delegate) external {
        if (_unstakeDelegationRequestedAt[msg.sender][delegate] == 0) revert NoUnstakeRequest();
        _unstakeDelegationRequestedAt[msg.sender][delegate] = 0;
        emit DelegationUnstakeCancelled(msg.sender, delegate);
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev After `coolDownPeriod`, zeros the delegation slot, decrements the
    ///      delegate's inbound totals and global total, pushes zero checkpoints
    ///      for the delegator + inbound histories, and refunds WOOD.
    /// @dev nonReentrant dropped — CEI: delegation zeroed + checkpoints
    ///      pushed before transfer.
    function claimUnstakeDelegation(address delegate) external {
        uint64 requestedAt = _unstakeDelegationRequestedAt[msg.sender][delegate];
        if (requestedAt == 0) revert NoUnstakeRequest();
        if (block.timestamp < uint256(requestedAt) + _coolDownPeriod()) revert UnstakeCooldownActive();

        uint256 amount = _delegations[msg.sender][delegate];
        _delegations[msg.sender][delegate] = 0;
        _unstakeDelegationRequestedAt[msg.sender][delegate] = 0;
        _delegatedInbound[delegate] -= amount;
        totalDelegatedStake -= amount;

        _delegationCheckpoints[msg.sender][delegate].push(uint32(block.timestamp), 0);
        _delegatedInboundCheckpoints[delegate].push(uint32(block.timestamp), uint224(_delegatedInbound[delegate]));
        _totalDelegatedCheckpoint.push(uint32(block.timestamp), uint224(totalDelegatedStake));

        _wood().safeTransfer(msg.sender, amount);
        emit DelegationUnstakeClaimed(msg.sender, delegate, amount);
    }

    // ──────────────────────────────────────────────────────────────
    // DPoS commission configuration
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    /// @dev Sets the caller's commission rate (0 – MAX_COMMISSION_BPS) that
    ///      applies to their delegators' share of future guardian-fee and WOOD
    ///      epoch rewards. Raises capped to `MAX_COMMISSION_INCREASE_PER_EPOCH`
    ///      bps above the rate that held at the start of the current epoch —
    ///      *cumulative*, so chaining multiple raises within the same epoch
    ///      can't compound past the cap. Decreases are unbounded. Pushes a
    ///      checkpoint so historical claims resolve the rate at their
    ///      `settledAt`.
    function setCommission(uint256 newBps) external {
        if (newBps > MAX_COMMISSION_BPS) revert CommissionExceedsMax();

        uint256 old = _commissionBps[msg.sender];
        if (newBps == old) return;

        if (newBps > old) {
            uint256 curEpoch = (block.timestamp - _epochGenesis()) / EPOCH_DURATION;
            (bool hasHistory,,) = _commissionCheckpoints[msg.sender].latestCheckpoint();
            // First-set is exempt from the raise cap ONLY if the delegate
            // has no delegators yet. An unconditional first-set exemption
            // would allow a delegate to accept delegations at implied 0%
            // commission and then JIT-rug to 50% in the same block as
            // `settledAt` — defeating rug-protection. By gating the
            // exemption on `_delegatedInbound == 0`, legitimate delegates
            // can still announce any opening rate before attracting
            // delegators, but any post-delegation raise is rate-limited.
            if (!hasHistory && _delegatedInbound[msg.sender] == 0) {
                // Pure announcement: no delegators at risk, no cap.
                _commissionEpochBaseline[msg.sender] = newBps;
                _lastCommissionRaiseEpoch[msg.sender] = curEpoch;
            } else {
                if (_lastCommissionRaiseEpoch[msg.sender] != curEpoch) {
                    // New raise-epoch: re-anchor baseline to previous-epoch
                    // final state. Lookup at epochStart - 1 excludes any
                    // checkpoint pushed this epoch. First-set-with-delegators
                    // (no prior checkpoint) yields baseline = 0.
                    uint256 epochStart = _epochGenesis() + curEpoch * EPOCH_DURATION;
                    uint256 probe = epochStart - 1;
                    _commissionEpochBaseline[msg.sender] =
                        _commissionCheckpoints[msg.sender].upperLookupRecent(uint32(probe));
                    _lastCommissionRaiseEpoch[msg.sender] = curEpoch;
                }
                uint256 baseline = _commissionEpochBaseline[msg.sender];
                if (newBps > baseline + MAX_COMMISSION_INCREASE_PER_EPOCH) {
                    revert CommissionRaiseExceedsLimit();
                }
            }
        }

        _commissionBps[msg.sender] = newBps;
        _commissionCheckpoints[msg.sender].push(uint32(block.timestamp), uint224(newBps));

        emit CommissionSet(msg.sender, old, newBps);
    }

    /// @inheritdoc IGuardianRegistry
    function commissionOf(address delegate) external view returns (uint256) {
        return _commissionBps[delegate];
    }

    // ──────────────────────────────────────────────────────────────
    // Delegation views
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    function delegationOf(address delegator, address delegate) external view returns (uint256) {
        return _delegations[delegator][delegate];
    }

    /// @inheritdoc IGuardianRegistry
    function delegatedInbound(address delegate) external view returns (uint256) {
        return _delegatedInbound[delegate];
    }

    // ──────────────────────────────────────────────────────────────
    // Delegator-side guardian-fee claim
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IGuardianRegistry
    /// @dev Pulls the delegator's pro-rata share of the delegate's remainder
    ///      pool. Post-#41, anyone (including the delegator) can call
    ///      `claimProposalReward(approver, pid)` to seed the pool if the
    ///      approver hasn't yet — so a dead-key or absentee approver no
    ///      longer strands delegators. Attribution timestamp is `openedAt`
    ///      — same as the approver's vote-weight snapshot — so delegator
    ///      denominator and `grossFromDelegated` numerator align.
    /// @dev Not `whenNotPaused` — bytecode reclaim. The delegator pool was
    ///      already seeded by the approver's claim (which IS paused-gated),
    ///      so value is already earmarked for delegators; pausing the pull
    ///      doesn't protect anything. `claimUnstakeGuardian` applies the
    ///      same reasoning.
    function claimDelegatorProposalReward(address delegate, uint256 proposalId) external {
        if (_delegatorProposalClaimed[delegate][proposalId][msg.sender]) revert AlreadyClaimed();
        uint256 pool = _delegatorProposalPool[delegate][proposalId];
        if (pool == 0) revert DelegatePoolEmpty();

        address asset = _proposalRewardAsset(proposalId);
        uint32 openedAt = _reviewOpenedAt(proposalId);

        uint256 my = _delegationCheckpoints[msg.sender][delegate].upperLookupRecent(openedAt);
        uint256 totalDelegated = _delegatedInboundCheckpoints[delegate].upperLookupRecent(openedAt);
        // `totalDelegated == 0` would underflow division. `my == 0` would just
        // compute share = 0; claim flag still flips so no double-claim rot.
        if (totalDelegated == 0) revert NoDelegationAtSettle();

        uint256 share = (pool * my) / totalDelegated;

        // CEI: flag before transfer.
        _delegatorProposalClaimed[delegate][proposalId][msg.sender] = true;

        if (share > 0) {
            _safeRewardTransfer(asset, msg.sender, share, proposalId);
        }
        emit DelegatorProposalRewardClaimed(msg.sender, delegate, proposalId, share);
    }
}
