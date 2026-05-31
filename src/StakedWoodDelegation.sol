// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StakedWoodDelegation
/// @notice Abstract — share-based DPoS delegation + commission for the
///         `StakedWood` (sWOOD) contract. Mirrors the `GuardianRegistryDelegation`
///         precedent: the abstract owns its own storage + externals; the
///         concrete `StakedWood` implements virtual accessors for state it
///         needs (`_wood`, `_isActiveGuardian`, `_coolDownPeriod`).
///
///         **Storage layout**: the abstract's storage slots come FIRST in the
///         final contract's layout (C3 linearization). V1.5 is a fresh mainnet
///         redeployment so this storage organization is safe — proxies start
///         zeroed. The per-abstract `__delegationGap` reserves room for future
///         delegation additions without shifting `StakedWood`'s layout.
///
/// @dev Fully implemented — share-based delegation, unstake cooldown,
///      delegation checkpoints, and DPoS commission (`setCommission` and the
///      commission read paths) are all live and tested.
///      See `docs/superpowers/specs/2026-05-21-swood-staking-split-design.md`.
abstract contract StakedWoodDelegation is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    // ── Constants ──

    /// @notice 100% in basis points.
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

    // ── Share-based delegation storage ──

    /// @notice Per-delegate total WOOD tokens held in their delegation pool.
    /// @dev ERC-4626-style: a slash later just reduces this one slot and all
    ///      delegators are diluted pro-rata — no per-delegator loop.
    mapping(address delegate => uint256) public poolTokens;

    /// @notice Per-delegate total shares issued against their delegation pool.
    mapping(address delegate => uint256) public poolShares;

    /// @dev Per-(delegator, delegate) share balance in the delegate's pool.
    mapping(address delegator => mapping(address delegate => uint256)) internal delegationShares;

    /// @dev Per-(delegator, delegate) unbonding-escrow `requestedAt` timestamp.
    ///      Zero means no unbonding entry. Set by `requestUnstakeDelegation`,
    ///      cleared by `cancelUnstakeDelegation` / `claimUnstakeDelegation`.
    ///      `delegateStake` no longer clears this — a live re-delegation is
    ///      independent of any in-flight unbonding entry (I-1: the unbonding
    ///      shares are separate state; clearing the stamp without moving them
    ///      would strand them).
    mapping(address delegator => mapping(address delegate => uint64)) internal _unstakeDelegationRequestedAt;

    /// @dev Sherlock run #2 #14: per-(delegator, delegate) frozen cooldown
    ///      from the moment `requestUnstakeDelegation` stamped the request.
    ///      Read by `claimUnstakeDelegation` so the sWOOD owner cannot
    ///      extend the unbonding lockup retroactively by raising
    ///      `coolDownPeriod` mid-request.
    mapping(address delegator => mapping(address delegate => uint64)) internal _unstakeDelegationCooldown;

    // ── Unbonding-escrow pool (I-1: Cosmos-style unbonding) ──

    /// @notice Per-delegate total WOOD tokens held in the unbonding-escrow pool.
    /// @dev Second ERC-4626-style share-pool, parallel to `poolTokens`. Stake
    ///      requested-out via `requestUnstakeDelegation` sits here for the full
    ///      `coolDownPeriod` and is slashable (`_slashOne` reduces this slot
    ///      pro-rata). Does NOT count toward vote weight, the quorum
    ///      denominator, or reward attribution — so it needs no checkpoints.
    mapping(address delegate => uint256) public unbondingPoolTokens;

    /// @notice Per-delegate total shares issued against the unbonding pool.
    mapping(address delegate => uint256) public unbondingPoolShares;

    /// @dev Per-(delegator, delegate) share balance in the unbonding pool. One
    ///      unbonding entry per pair — `requestUnstakeDelegation` reverts if a
    ///      nonzero entry already exists.
    mapping(address delegator => mapping(address delegate => uint256)) internal unbondingShares;

    /// @notice Global sum of all WOOD currently delegated across every pool.
    uint256 public totalDelegatedStake;

    /// @notice Feature flag — `delegateStake` reverts unless enabled. Defaults
    ///         false; flipped by the owner via `StakedWood.setDelegationEnabled`.
    bool public delegationEnabled;

    // ── DPoS commission storage (relocated from GuardianRegistryDelegation) ──

    /// @dev Current commission rate per delegate.
    mapping(address => uint256) internal _commissionBps;

    /// @dev Epoch in which the delegate last raised (or first-set) their
    ///      commission. Used to detect transition into a new raise-epoch so
    ///      `_commissionEpochBaseline` can be re-anchored.
    mapping(address => uint256) internal _lastCommissionRaiseEpoch;

    /// @dev Anchor for the per-epoch cumulative raise cap.
    mapping(address => uint256) internal _commissionEpochBaseline;

    /// @dev Per-delegate commission history keyed by timestamp. Claim paths
    ///      look up the rate at `settledAt` — closes the retroactive-raise
    ///      vector.
    mapping(address => Checkpoints.Trace224) internal _commissionCheckpoints;

    /// @dev Epoch-index anchor for `setCommission`'s raise-epoch calculation.
    ///      Relocated from `GuardianRegistry.epochGenesis` — the registry
    ///      seeded it to `block.timestamp` in `initialize`; `StakedWood`
    ///      seeds it the same way via `_initEpochGenesis`.
    uint256 public epochGenesis;

    // ── Delegation checkpoints (Task 4.3) ──

    /// @dev Per-delegate `poolTokens` history keyed by `uint32(block.timestamp)`.
    ///      Lets `getPastDelegatedInbound` / `getPastDelegation` read pool size
    ///      at a past instant (quorum + reward attribution).
    mapping(address delegate => Checkpoints.Trace224) internal _poolTokensCheckpoints;

    /// @dev Per-delegate `poolShares` history keyed by `uint32(block.timestamp)`.
    mapping(address delegate => Checkpoints.Trace224) internal _poolSharesCheckpoints;

    /// @dev Per-(delegator, delegate) `delegationShares` history keyed by
    ///      `uint32(block.timestamp)`.
    mapping(address delegator => mapping(address delegate => Checkpoints.Trace224)) internal
        _delegationSharesCheckpoints;

    /// @dev Global `totalDelegatedStake` history — quorum denominator.
    Checkpoints.Trace224 internal _totalDelegatedCheckpoint;

    /// @notice Sherlock #39 / Run-1 #22: live sum of `poolTokens[g]` over
    ///         CURRENTLY-ACTIVE guardians only. `totalDelegatedStake`
    ///         includes inactive guardians' pools (dead weight) and would
    ///         inflate the quorum denominator — `openReview` consumes this
    ///         counter so honest blockers don't have to clear a quorum
    ///         padded by inactive delegations.
    /// @dev Maintained at every mutation site that touches `poolTokens[g]`
    ///      OR transitions guardian g between active/inactive — see
    ///      `_pushActiveDelegatedCheckpoint` and the `_adjustActive` helpers
    ///      called from `delegateStake` / `requestUnstakeDelegation` /
    ///      `cancelUnstakeDelegation` / `stakeAsGuardian` /
    ///      `requestUnstakeGuardian` / `cancelUnstakeGuardian` /
    ///      `_slashOne`. An invariant test fuzz over every handler
    ///      enforces `Σ poolTokens[g] over active g == totalActiveDelegatedStake`.
    uint256 public totalActiveDelegatedStake;

    /// @dev Historical trace of `totalActiveDelegatedStake` for past-lookup
    ///      reads from `GuardianRegistry.openReview` (anchored at `t-1`).
    Checkpoints.Trace224 internal _totalActiveDelegatedCheckpoint;

    /// @dev Reserved storage slots at the `StakedWoodDelegation` layer so
    ///      future delegation additions don't shift `StakedWood`'s layout.
    ///      Decremented 10 → 7 in Task 4.1: `_unstakeDelegationRequestedAt`,
    ///      `totalDelegatedStake`, and `delegationEnabled` each consume one
    ///      slot (the bool does not pack — adjacent members are full-slot).
    ///      Decremented 7 → 3 in Task 4.3: three checkpoint mappings + one
    ///      `Trace224` member each consume one slot.
    ///      Decremented 3 → 2 in Task 4.4: `epochGenesis` (relocated from
    ///      `GuardianRegistry`) consumes one slot.
    ///      Re-baselined 2 → 7 for the I-1 unbonding escrow: three new
    ///      mappings (`unbondingPoolTokens`, `unbondingPoolShares`,
    ///      `unbondingShares`) each consume one slot. V1.5 is a fresh
    ///      pre-mainnet redeployment so the layout is not locked — the gap is
    ///      re-baselined to a 7-slot reserve rather than driven negative.
    ///      Decremented 7 → 5 for Sherlock #39: `totalActiveDelegatedStake`
    ///      (uint256) + `_totalActiveDelegatedCheckpoint` (Trace224) each
    ///      consume one slot.
    uint256[5] private __delegationGap;

    // ── Errors ──

    /// @notice `delegateStake` called while the feature flag is off.
    error DelegationDisabled();

    /// @notice A delegator cannot delegate to themselves.
    error CannotSelfDelegate();

    /// @notice The chosen delegate is not an active guardian.
    error InactiveDelegate();

    /// @notice `delegateStake` called with `amount == 0` — a no-op that would
    ///         only pollute the event log with a zero-value `DelegationIncreased`.
    error ZeroAmount();

    /// @notice Caller has no active stake/shares to operate on.
    /// @dev Shared with guardian/owner unstake flows on `StakedWood`.
    error NoActiveStake();

    /// @notice A nonzero unbonding entry already exists for this
    ///         (delegator, delegate) pair — `cancel` or `claim` it first.
    error UnstakeAlreadyRequested();

    /// @notice No pending unstake request to cancel or claim.
    error UnstakeNotRequested();

    /// @notice `claim*` called before `coolDownPeriod` elapsed.
    error CooldownNotElapsed();

    /// @notice Sherlock run #3 #1: an unstake request would burn live shares
    ///         for zero `amount` (poolTokens × liveShares < poolShares after
    ///         extreme slashing), creating a permanent fund-trap. Revert
    ///         instead of corrupting state.
    error UnstakeAmountZero();

    /// @notice `setCommission` argument exceeds `MAX_COMMISSION_BPS`.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    error CommissionExceedsMax();

    /// @notice `setCommission` raise exceeds the per-epoch raise cap.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    error CommissionRaiseExceedsLimit();

    // ── Events ──

    /// @notice Emitted when a delegator adds WOOD to a delegate's pool.
    event DelegationIncreased(address indexed delegator, address indexed delegate, uint256 amount);

    /// @notice Emitted when a delegator redeems shares and withdraws WOOD.
    event DelegationClaimed(address indexed delegator, address indexed delegate, uint256 amount);

    /// @notice Emitted when a delegator moves their entire live delegation
    ///         into the slashable unbonding-escrow pool and starts the
    ///         cooldown. `amount` is the WOOD redeemed from the live pool at
    ///         request time; `requestedAt` is the stamped cooldown start.
    event UnbondingRequested(address indexed delegator, address indexed delegate, uint256 amount, uint64 requestedAt);

    /// @notice Emitted when a delegate changes their DPoS commission rate.
    /// @dev Relocated verbatim from `IGuardianRegistry`. Off-chain Merkl bot
    ///      streams historical commission off this event.
    event CommissionSet(address indexed delegate, uint256 oldBps, uint256 newBps);

    // ── Virtual accessors (implemented by concrete StakedWood) ──

    /// @notice Returns the WOOD token reference (lives in concrete storage).
    function _wood() internal view virtual returns (IERC20);

    /// @notice Whether `g` has active own-stake (lives in concrete storage).
    function _isActiveGuardian(address) internal view virtual returns (bool);

    /// @notice Returns the global unstake-cooldown period (lives in concrete).
    function _coolDownPeriod() internal view virtual returns (uint256);

    /// @dev Seeds the `epochGenesis` anchor at construction/initialization.
    ///      Called once by `StakedWood.initialize` — mirrors the registry,
    ///      which set `epochGenesis = block.timestamp` in its initializer.
    ///      Idempotent: only sets the anchor when unset, so a future
    ///      reinitializer or accidental second call cannot jump
    ///      `epochGenesis` forward and corrupt commission-epoch math.
    function _initEpochGenesis() internal {
        if (epochGenesis == 0) epochGenesis = block.timestamp;
    }

    // ──────────────────────────────────────────────────────────────
    // Stake-pool delegation
    // ──────────────────────────────────────────────────────────────

    /// @notice Delegate WOOD into a guardian's stake pool, minting pool shares.
    /// @dev ERC-4626-style share math: the first delegation into an empty pool
    ///      mints 1:1; subsequent delegations mint `amount * shares / tokens`
    ///      against the current pool rate. The delegator holds shares, not raw
    ///      tokens, so a later slash that reduces `poolTokens` dilutes every
    ///      delegator pro-rata in O(1).
    ///      A fresh `delegateStake` is an independent LIVE delegation: it does
    ///      NOT touch any in-flight unbonding entry for the same delegate. The
    ///      unbonding entry must be `cancelUnstakeDelegation`-ed or
    ///      `claimUnstakeDelegation`-ed on its own (I-1 unbonding escrow).
    function delegateStake(address delegate, uint256 amount) external nonReentrant {
        if (!delegationEnabled) revert DelegationDisabled();
        if (delegate == msg.sender) revert CannotSelfDelegate();
        if (!_isActiveGuardian(delegate)) revert InactiveDelegate();
        if (amount == 0) revert ZeroAmount();

        _wood().safeTransferFrom(msg.sender, address(this), amount);

        uint256 ts = poolTokens[delegate];
        uint256 sh = poolShares[delegate];
        uint256 minted = sh == 0 ? amount : Math.mulDiv(amount, sh, ts);

        poolTokens[delegate] = ts + amount;
        poolShares[delegate] = sh + minted;
        delegationShares[msg.sender][delegate] += minted;
        totalDelegatedStake += amount;
        // Sherlock #39 / Run-1 #22: delegate is asserted active above
        // (`InactiveDelegate`), so the new stake also enters the active-
        // only total.
        _writeActiveDelegated(totalActiveDelegatedStake + amount);
        // NOTE: `_unstakeDelegationRequestedAt` is deliberately NOT cleared
        // here. Under the I-1 unbonding-escrow model an in-flight unbonding
        // entry is independent state (its shares live in the unbonding pool);
        // clearing the stamp without moving those shares back would strand
        // them. A fresh `delegateStake` is a new LIVE delegation; the
        // unbonding entry must be `cancel`-ed or `claim`-ed on its own.

        _pushDelegationCheckpoints(msg.sender, delegate);
        emit DelegationIncreased(msg.sender, delegate, amount);
    }

    /// @dev Checkpoint hook for delegation vote-weight history. Pushes the
    ///      current pool aggregates (`poolTokens`, `poolShares`,
    ///      `totalDelegatedStake`) and the per-pair `delegationShares` at
    ///      `uint32(block.timestamp)`.
    ///
    ///      Zero-delegator path: a slash (Task 5.1) re-checkpoints only the
    ///      pool aggregates with `delegator == address(0)` (no specific
    ///      delegator), so the per-pair push is skipped in that case.
    function _pushDelegationCheckpoints(address delegator, address delegate) internal {
        uint32 ts = uint32(block.timestamp);
        _poolTokensCheckpoints[delegate].push(ts, uint224(poolTokens[delegate]));
        _poolSharesCheckpoints[delegate].push(ts, uint224(poolShares[delegate]));
        _totalDelegatedCheckpoint.push(ts, uint224(totalDelegatedStake));
        if (delegator != address(0)) {
            _delegationSharesCheckpoints[delegator][delegate].push(ts, uint224(delegationShares[delegator][delegate]));
        }
    }

    /// @dev Sherlock #39 / Run-1 #22: write + checkpoint the active-only
    ///      delegated total in lock-step. Same-block multi-updates collapse
    ///      to a single checkpoint (OZ `Trace224.push` overwrites at the
    ///      same `key`). Used by every mutation site that either changes
    ///      `poolTokens[g]` for an active guardian OR transitions a
    ///      guardian g between active/inactive.
    function _writeActiveDelegated(uint256 newTotal) internal {
        totalActiveDelegatedStake = newTotal;
        _totalActiveDelegatedCheckpoint.push(uint32(block.timestamp), uint224(newTotal));
    }

    /// @notice Total active-only delegated stake at a past timestamp.
    /// @dev Sherlock #39 / Run-1 #22 — `GuardianRegistry.openReview` reads
    ///      this anchored at `t-1` so the quorum denominator excludes
    ///      delegations to currently-inactive guardians.
    function getPastTotalActiveDelegated(uint256 timestamp) public view returns (uint256) {
        return _totalActiveDelegatedCheckpoint.upperLookupRecent(uint32(timestamp));
    }

    /// @notice Unbond the caller's ENTIRE live delegation to `delegate` into
    ///         the slashable unbonding-escrow pool and begin the cooldown.
    /// @dev I-1: closes the slash-evasion vector. The delegator's WOOD moves
    ///      out of the vote-weighted live pool and into the unbonding pool,
    ///      where it stays slashable for the full `coolDownPeriod` —
    ///      `resolveReview` lands the slash on the unbonding pool before the
    ///      delegator can `claim`. The delegator instantly stops counting
    ///      toward `delegate`'s vote weight (mirrors `requestUnstakeGuardian`
    ///      zeroing own-stake voting power).
    ///
    ///      One unbonding entry per `(delegator, delegate)` pair — reverts if
    ///      a nonzero entry already exists; `cancel` or `claim` it first.
    ///
    ///      No `delegationEnabled` check — exits must always work even after
    ///      the feature is disabled (fund-trap guard).
    ///
    ///      Share round-trips (`request`→`cancel`, `request`→`claim`) lose
    ///      sub-wei dust to the pool by design: each `mulDiv` redeem/mint
    ///      rounds down, the conventional ERC-4626 round-against-the-user
    ///      direction. This is safe — not a bug.
    function requestUnstakeDelegation(address delegate) external nonReentrant {
        uint256 liveShares = delegationShares[msg.sender][delegate];
        if (liveShares == 0) revert NoActiveStake();
        if (unbondingShares[msg.sender][delegate] != 0) revert UnstakeAlreadyRequested();

        // Redeem the live shares at the current live rate.
        uint256 amount = Math.mulDiv(liveShares, poolTokens[delegate], poolShares[delegate]);
        // Sherlock run #3 #1: after extreme slashing (poolTokens × liveShares <
        // poolShares) the redeem amount can round to 0. Proceeding would burn
        // the delegator's live shares without minting any unbonding shares,
        // strand `_unstakeDelegationRequestedAt` non-zero, and brick both
        // `cancelUnstakeDelegation` (reverts `UnstakeNotRequested`) and
        // `claimUnstakeDelegation` (reverts `NoActiveStake`) — a permanent
        // fund-trap. Revert here so the delegator can keep their (now-tiny)
        // live position or wait for the pool to recover.
        if (amount == 0) revert UnstakeAmountZero();

        // Remove from the live pool.
        poolShares[delegate] -= liveShares;
        poolTokens[delegate] -= amount;
        delegationShares[msg.sender][delegate] = 0;
        totalDelegatedStake -= amount;
        // Sherlock #39 / Run-1 #22: unbonding pool isn't votable. Subtract
        // from the active-only total iff the delegate is currently active —
        // if they're inactive, their pool was already excluded.
        if (_isActiveGuardian(delegate)) {
            _writeActiveDelegated(totalActiveDelegatedStake - amount);
        }

        // Mint unbonding-pool shares for `amount` (first mint is 1:1).
        uint256 uShares = unbondingPoolShares[delegate];
        uint256 mintedU = uShares == 0 ? amount : Math.mulDiv(amount, uShares, unbondingPoolTokens[delegate]);
        unbondingPoolTokens[delegate] += amount;
        unbondingPoolShares[delegate] = uShares + mintedU;
        unbondingShares[msg.sender][delegate] = mintedU;

        uint64 requestedAt = uint64(block.timestamp);
        _unstakeDelegationRequestedAt[msg.sender][delegate] = requestedAt;
        // Sherlock run #2 #14: freeze cooldown at request so a later
        // `setCooldownPeriod` raise cannot extend this entry's lockup.
        // forge-lint: disable-next-line(unchecked-cast)
        _unstakeDelegationCooldown[msg.sender][delegate] = uint64(_coolDownPeriod());

        // The live pool shrank — re-checkpoint vote-weight history.
        _pushDelegationCheckpoints(msg.sender, delegate);
        emit UnbondingRequested(msg.sender, delegate, amount, requestedAt);
    }

    /// @notice Re-bond a pending unbonding entry back into the live pool.
    /// @dev Redeems the unbonding entry at the current unbonding rate (which
    ///      reflects any slash that hit the unbonding pool during its life)
    ///      and re-mints into the live pool at the current live rate. No
    ///      `delegationEnabled` check — symmetric exit/re-entry path.
    function cancelUnstakeDelegation(address delegate) external nonReentrant {
        uint256 uShares = unbondingShares[msg.sender][delegate];
        if (uShares == 0) revert UnstakeNotRequested();

        // Redeem from the unbonding pool at the current (possibly slashed) rate.
        // Load-bearing invariant: a nonzero per-pair `uShares` implies a
        // nonzero `unbondingPoolShares[delegate]` total, so the divisor is
        // never zero. A refactor that reorders the pool-share writes must
        // preserve `uShares != 0 => unbondingPoolShares != 0`.
        uint256 owed = Math.mulDiv(uShares, unbondingPoolTokens[delegate], unbondingPoolShares[delegate]);
        unbondingPoolShares[delegate] -= uShares;
        unbondingPoolTokens[delegate] -= owed;
        unbondingShares[msg.sender][delegate] = 0;
        _unstakeDelegationRequestedAt[msg.sender][delegate] = 0;

        // Re-mint into the live pool at the current live rate (first mint 1:1).
        uint256 sh = poolShares[delegate];
        uint256 minted = sh == 0 ? owed : Math.mulDiv(owed, sh, poolTokens[delegate]);
        poolTokens[delegate] += owed;
        poolShares[delegate] = sh + minted;
        delegationShares[msg.sender][delegate] += minted;
        totalDelegatedStake += owed;
        // Sherlock #39 / Run-1 #22: add back to active total iff delegate
        // is currently active. If they went inactive between request and
        // cancel, the live pool grew but it doesn't yet vote — picked up
        // again at the next `cancelUnstakeGuardian`.
        if (_isActiveGuardian(delegate)) {
            _writeActiveDelegated(totalActiveDelegatedStake + owed);
        }

        // The live pool grew — re-checkpoint vote-weight history.
        _pushDelegationCheckpoints(msg.sender, delegate);
        emit DelegationIncreased(msg.sender, delegate, owed);
    }

    /// @notice Redeem a matured unbonding entry, returning WOOD to the caller.
    /// @dev Redeems at the current (possibly slashed) unbonding rate — a slash
    ///      that hit the unbonding pool between request and claim reduces
    ///      `unbondingPoolTokens` and the delegator receives less (I-1: this
    ///      is exactly the point — evasion is closed). NO gate on review
    ///      activity: always succeeds once `coolDownPeriod` has elapsed, so
    ///      funds are never trapped. No `delegationEnabled` check.
    function claimUnstakeDelegation(address delegate) external nonReentrant {
        uint64 reqAt = _unstakeDelegationRequestedAt[msg.sender][delegate];
        if (reqAt == 0) revert UnstakeNotRequested();
        // Sherlock run #2 #14: use cooldown frozen at request time.
        uint256 frozen = uint256(_unstakeDelegationCooldown[msg.sender][delegate]);
        if (block.timestamp < uint256(reqAt) + frozen) revert CooldownNotElapsed();

        uint256 uShares = unbondingShares[msg.sender][delegate];
        if (uShares == 0) revert NoActiveStake();

        // Load-bearing invariant: a nonzero per-pair `uShares` implies a
        // nonzero `unbondingPoolShares[delegate]` total, so the divisor is
        // never zero. A refactor that reorders the pool-share writes must
        // preserve `uShares != 0 => unbondingPoolShares != 0`.
        uint256 owed = Math.mulDiv(uShares, unbondingPoolTokens[delegate], unbondingPoolShares[delegate]);
        unbondingShares[msg.sender][delegate] = 0;
        unbondingPoolShares[delegate] -= uShares;
        unbondingPoolTokens[delegate] -= owed;
        _unstakeDelegationRequestedAt[msg.sender][delegate] = 0;

        _wood().safeTransfer(msg.sender, owed);
        emit DelegationClaimed(msg.sender, delegate, owed);
    }

    // ──────────────────────────────────────────────────────────────
    // DPoS commission configuration (relocated verbatim from
    // GuardianRegistryDelegation)
    // ──────────────────────────────────────────────────────────────

    /// @notice Sets the caller's commission rate (0 – MAX_COMMISSION_BPS) that
    ///         applies to their delegators' share of future guardian-fee and
    ///         WOOD epoch rewards. Raises capped to
    ///         `MAX_COMMISSION_INCREASE_PER_EPOCH` bps above the rate that held
    ///         at the start of the current epoch — *cumulative*, so chaining
    ///         multiple raises within the same epoch can't compound past the
    ///         cap. Decreases are unbounded. Pushes a checkpoint so historical
    ///         claims resolve the rate at their `settledAt`.
    /// @dev Relocated verbatim from `GuardianRegistryDelegation.setCommission`.
    function setCommission(uint256 newBps) external {
        if (newBps > MAX_COMMISSION_BPS) revert CommissionExceedsMax();

        uint256 old = _commissionBps[msg.sender];
        if (newBps == old) return;

        if (newBps > old) {
            uint256 curEpoch = (block.timestamp - epochGenesis) / EPOCH_DURATION;
            (bool hasHistory,,) = _commissionCheckpoints[msg.sender].latestCheckpoint();
            // First-set is exempt from the raise cap ONLY if the delegate
            // has no delegators yet. An unconditional first-set exemption
            // would allow a delegate to accept delegations at implied 0%
            // commission and then JIT-rug to 50% in the same block as
            // `settledAt` — defeating rug-protection. By gating the
            // exemption on inbound stake == 0, legitimate delegates can
            // still announce any opening rate before attracting
            // delegators, but any post-delegation raise is rate-limited.
            if (!hasHistory && poolTokens[msg.sender] == 0) {
                // Pure announcement: no delegators at risk, no cap.
                _commissionEpochBaseline[msg.sender] = newBps;
                _lastCommissionRaiseEpoch[msg.sender] = curEpoch;
            } else {
                if (_lastCommissionRaiseEpoch[msg.sender] != curEpoch) {
                    // New raise-epoch: re-anchor baseline to previous-epoch
                    // final state. Lookup at epochStart - 1 excludes any
                    // checkpoint pushed this epoch. First-set-with-delegators
                    // (no prior checkpoint) yields baseline = 0.
                    uint256 epochStart = epochGenesis + curEpoch * EPOCH_DURATION;
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

    /// @notice A delegate's current DPoS commission rate (bps).
    function commissionOf(address delegate) external view returns (uint256) {
        return _commissionBps[delegate];
    }

    /// @notice A delegate's DPoS commission rate (bps) frozen at a past
    ///         timestamp — a later raise does not retroactively change a
    ///         historical read. Reward-claim paths resolve the rate at
    ///         `settledAt` so a delegate cannot rug already-earned rewards.
    function getPastCommission(address delegate, uint256 timestamp) external view returns (uint256) {
        return _commissionCheckpoints[delegate].upperLookupRecent(uint32(timestamp));
    }

    // ──────────────────────────────────────────────────────────────
    // Delegation views
    // ──────────────────────────────────────────────────────────────

    /// @notice The token-equivalent of a delegator's shares in a delegate's pool.
    /// @dev `shares * poolTokens / poolShares` — tracks slashing automatically.
    function delegationOf(address delegator, address delegate) public view returns (uint256) {
        uint256 sh = poolShares[delegate];
        if (sh == 0) return 0;
        return Math.mulDiv(delegationShares[delegator][delegate], poolTokens[delegate], sh);
    }

    function delegatedInbound(address delegate) external view returns (uint256) {
        return poolTokens[delegate];
    }

    // ──────────────────────────────────────────────────────────────
    // Delegation checkpoint reads (Task 4.3)
    // ──────────────────────────────────────────────────────────────

    /// @notice The token-equivalent of a delegator's shares in a delegate's
    ///         pool as of a past timestamp.
    /// @dev Reads `delegationShares`, `poolTokens` and `poolShares` from their
    ///      checkpoint histories at `ts`, then applies the ERC-4626 share math.
    ///      Returns 0 if the pool had no shares at `ts`.
    function getPastDelegation(address delegator, address delegate, uint256 ts) public view returns (uint256) {
        uint256 sh = _poolSharesCheckpoints[delegate].upperLookupRecent(uint32(ts));
        if (sh == 0) return 0;
        uint256 myShares = _delegationSharesCheckpoints[delegator][delegate].upperLookupRecent(uint32(ts));
        uint256 tok = _poolTokensCheckpoints[delegate].upperLookupRecent(uint32(ts));
        return Math.mulDiv(myShares, tok, sh);
    }

    /// @notice A delegate's total inbound delegated WOOD as of a past timestamp.
    function getPastDelegatedInbound(address del, uint256 ts) public view returns (uint256) {
        return _poolTokensCheckpoints[del].upperLookupRecent(uint32(ts));
    }

    /// @notice The global `totalDelegatedStake` as of a past timestamp — used
    ///         later as a quorum denominator.
    function getPastTotalDelegated(uint256 ts) public view returns (uint256) {
        return _totalDelegatedCheckpoint.upperLookupRecent(uint32(ts));
    }

    /// @notice The pending delegation-unstake-request timestamp for a
    ///         (delegator, delegate) pair. Zero means no pending request.
    /// @dev Exposed so the CLI/app can display pending delegation-unstake
    ///      requests; the backing mapping is `internal`.
    function unstakeDelegationRequestedAt(address delegator, address delegate) external view returns (uint64) {
        return _unstakeDelegationRequestedAt[delegator][delegate];
    }
}
