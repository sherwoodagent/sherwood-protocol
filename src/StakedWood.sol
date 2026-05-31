// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakedWoodDelegation} from "./StakedWoodDelegation.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Minimal `SyndicateGovernor` surface consumed by sWOOD: the
///         open-proposal signals used by the rage-quit gate in
///         `requestUnstakeOwner`. Relocated verbatim from `GuardianRegistry`.
interface IGovernorMinimal {
    function getActiveProposal(address vault) external view returns (uint256);
    /// @notice Count of proposals for a vault in any non-terminal state
    ///         (Pending / GuardianReview / Approved / Executed). Consumed
    ///         by the rage-quit gate in `requestUnstakeOwner`. The OR check
    ///         against `getActiveProposal` is belt-and-braces — any real
    ///         open proposal must trip at least one of the two signals.
    function openProposalCount(address vault) external view returns (uint256);
}

/// @notice Minimal `GuardianRegistry` surface consumed by sWOOD: the
///         guardian review window. Used by `setCooldownPeriod` to enforce
///         the `coolDownPeriod >= reviewPeriod` cross-contract invariant
///         (Sherlock #16) from the sWOOD side.
interface IRegistryReviewPeriod {
    function reviewPeriod() external view returns (uint256);
}

/// @title StakedWood (sWOOD)
/// @notice Non-transferable vote-escrow contract. Sole WOOD custodian:
///         guardian stake, owner bonds, DPoS delegation, vote checkpoints,
///         slashing + burn. See spec 2026-05-21-swood-staking-split-design.md.
contract StakedWood is StakedWoodDelegation, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    error ZeroAddress();
    error RegistryAlreadySet();
    error NotRegistry();
    error NotFactory();

    /// @notice Insufficient WOOD to satisfy a stake minimum.
    /// @dev Relocated from `IGuardianRegistry` alongside `stakeAsGuardian`.
    error InsufficientStake();

    /// @notice Parameter setter argument failed bounds validation.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    error InvalidParameter();
    /// @notice Sherlock #16: `setCooldownPeriod` rejected because the new
    ///         cooldown is shorter than the registry's `reviewPeriod`. The
    ///         `coolDownPeriod >= reviewPeriod` invariant closes slash-evasion
    ///         for guardian OWN stake (the `isActiveGuardian` voting gate);
    ///         delegator stake evasion is closed separately by the delegation
    ///         unbonding-escrow.
    error CooldownBelowReviewPeriod();

    /// @notice Caller already has an unbound prepared owner stake.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    error PreparedStakeAlreadyExists();

    /// @notice No matching prepared owner stake (zero amount or already bound).
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    error PreparedStakeNotFound();

    /// @notice Prepared stake is below the `minOwnerStake` floor at bind time.
    /// @dev Relocated from `IGuardianRegistry`. In V1 the owner bond is the flat
    ///      `minOwnerStake` floor — there is no TVL scaling. `bindOwnerStake`
    ///      raises this whenever the prepared stake is below that floor.
    error OwnerBondInsufficient();

    /// @notice Owner cannot unstake while the vault has an open proposal.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    error VaultHasActiveProposal();

    /// @notice The slot's prior owner still holds residual stake — they must
    ///         fully unstake or be slashed before the slot can be transferred.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    error PriorStakeNotCleared();

    /// @notice Emitted on every guardian stake / top-up.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event GuardianStaked(address indexed guardian, uint256 amount, uint256 agentId);

    /// @notice Emitted when a guardian requests to unstake (starts cooldown).
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event GuardianUnstakeRequested(address indexed guardian, uint256 requestedAt);

    /// @notice Emitted when a guardian cancels a pending unstake request.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event GuardianUnstakeCancelled(address indexed guardian);

    /// @notice Emitted when a guardian claims WOOD after cooldown elapsed.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event GuardianUnstakeClaimed(address indexed guardian, uint256 amount);

    /// @notice Emitted when an owner parameter setter changes a value.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);

    /// @notice Emitted when a prospective vault owner escrows a prepared stake.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event OwnerStakePrepared(address indexed owner, uint256 amount);

    /// @notice Emitted when an unbound prepared owner stake is cancelled and refunded.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event PreparedStakeCancelled(address indexed owner, uint256 amount);

    /// @notice Emitted when the factory binds a prepared stake to a new vault.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event OwnerStakeBound(address indexed owner, address indexed vault, uint256 amount);

    /// @notice Emitted when a vault owner requests to unstake their bond (starts cooldown).
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event OwnerUnstakeRequested(address indexed vault, uint256 requestedAt);

    /// @notice Emitted when a vault owner claims their bond after cooldown elapsed.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event OwnerUnstakeClaimed(address indexed vault, address indexed owner, uint256 amount);

    /// @notice Emitted when the factory re-points a vault's owner-stake slot.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event OwnerStakeSlotTransferred(address indexed vault, address indexed oldOwner, address indexed newOwner);

    /// @notice Parameter key for `minGuardianStake`.
    /// @dev Relocated verbatim from `GuardianRegistry`.
    bytes32 public constant PARAM_MIN_GUARDIAN_STAKE = keccak256("minGuardianStake");

    /// @notice Parameter key for `coolDownPeriod`.
    /// @dev Relocated verbatim from `GuardianRegistry`.
    bytes32 public constant PARAM_COOLDOWN = keccak256("coolDownPeriod");

    /// @notice Parameter key for `minOwnerStake`.
    /// @dev Relocated verbatim from `GuardianRegistry`.
    bytes32 public constant PARAM_MIN_OWNER_STAKE = keccak256("minOwnerStake");

    /// @notice Parameter key for `minSlashBps`.
    /// @dev Graduated slash severity — lower clamp bound for the voted median.
    bytes32 public constant PARAM_MIN_SLASH_BPS = keccak256("minSlashBps");

    /// @notice Parameter key for `maxSlashBps`.
    /// @dev Graduated slash severity — upper clamp bound for the voted median.
    bytes32 public constant PARAM_MAX_SLASH_BPS = keccak256("maxSlashBps");

    /// @notice Emitted when the owner toggles the delegation feature flag.
    event DelegationEnabledSet(bool enabled);

    /// @notice Emitted once per approver actually slashed for a blocked proposal.
    /// @dev A slash is a significant value-destroying change; the appeal flow
    ///      (`refundSlash`), delegators, and indexers all need on-chain records.
    ///      Emitted only when `ownSlash != 0 || delegatedSlash != 0`.
    ///      `delegatedSlash` is the COMBINED delegated hit — the live
    ///      delegation pool plus the I-1 unbonding-escrow pool.
    event GuardianSlashed(
        uint256 indexed proposalId, address indexed approver, uint256 ownSlash, uint256 delegatedSlash
    );

    /// @notice Emitted when a burn transfer fails and the amount is queued for
    ///         a later `flushBurn` retry.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event PendingBurnRecorded(uint256 amount);

    /// @notice Emitted when a queued burn is successfully flushed.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    event BurnFlushed(uint256 amount);

    /// @notice Emitted when a vault's owner bond is slashed and burned.
    /// @dev A slashed owner bond is fully consumed (e.g. on an emergency-settle
    ///      failure); the appeal flow and indexers need an on-chain record.
    event OwnerBondSlashed(address indexed vault, uint256 amount);

    IERC20 public wood;

    /// @notice Guardian registry coordinating reviews, slashing, and rewards.
    /// @dev Set once via `setRegistry` AFTER deployment, never rewired. The
    ///      registry is deployed after sWOOD in the split's deploy order, so it
    ///      cannot be passed to `initialize`; `_registrySet` guards re-assignment.
    address public registry;

    address public governor;
    address public factory;

    bool private _registrySet;

    // ── Guardian-stake storage (relocated verbatim from GuardianRegistry) ──

    /// @dev Per-guardian stake record. Relocated from `GuardianRegistry`.
    struct Guardian {
        uint128 stakedAmount;
        uint64 stakedAt;
        uint64 unstakeRequestedAt;
        uint256 agentId;
        /// @dev Sherlock run #2 #14: cooldown value at the moment
        ///      `requestUnstakeGuardian` stamped `unstakeRequestedAt`. Used by
        ///      `claimUnstakeGuardian` so the owner can't extend lockup
        ///      retroactively by raising `coolDownPeriod` mid-request.
        uint64 cooldownAtRequest;
    }

    mapping(address => Guardian) internal _guardians;
    uint256 public totalGuardianStake;

    /// @notice Minimum WOOD required for an active guardian stake.
    uint256 public minGuardianStake;

    /// @notice Cooldown between `requestUnstakeGuardian` and `claimUnstakeGuardian`.
    /// @dev Relocated verbatim from `GuardianRegistry` (set in `initialize`).
    uint256 public coolDownPeriod;

    /// @dev Per-guardian own-stake history, keyed by timestamp. Pushed on every
    ///      state change that affects votable weight: stakeAsGuardian,
    ///      requestUnstakeGuardian (push 0), cancelUnstakeGuardian, slash.
    mapping(address => Checkpoints.Trace224) internal _stakeCheckpoints;

    /// @dev Global total-active-stake history. Mirrors `totalGuardianStake`
    ///      but indexed by timestamp for historical quorum-denominator lookups.
    Checkpoints.Trace224 internal _totalStakeCheckpoint;

    // ── Owner-bond storage (relocated verbatim from GuardianRegistry) ──

    /// @dev Per-vault bound owner bond. Relocated verbatim from `GuardianRegistry`.
    struct OwnerStake {
        uint128 stakedAmount;
        uint64 unstakeRequestedAt;
        address owner;
        /// @dev Sherlock run #2 #14: cooldown value at the moment
        ///      `requestUnstakeOwner` stamped `unstakeRequestedAt`. Used by
        ///      `claimUnstakeOwner` so the owner can't extend the bond's
        ///      lockup retroactively by raising `coolDownPeriod` mid-request.
        uint64 cooldownAtRequest;
    }

    mapping(address vault => OwnerStake) internal _ownerStakes;

    /// @dev Prospective vault owner's escrowed (not-yet-bound) stake. Relocated
    ///      verbatim from `GuardianRegistry`.
    struct PreparedOwnerStake {
        uint128 amount;
        uint64 preparedAt;
        bool bound;
    }

    mapping(address owner => PreparedOwnerStake) internal _prepared;

    /// @notice Minimum WOOD a vault owner must bond at vault creation.
    /// @dev Relocated verbatim from `GuardianRegistry` (set in `initialize`).
    uint256 public minOwnerStake;

    /// @notice Lower clamp bound (bps) for the graduated slash severity.
    /// @dev The registry computes the stake-weighted median of blockers'
    ///      proposed `slashBps` and clamps it to `[minSlashBps, maxSlashBps]`.
    ///      A non-zero floor preserves the deterrent. See spec §6/§7.
    uint256 public minSlashBps;

    /// @notice Upper clamp bound (bps, strictly `< 10_000`) for the graduated
    ///         slash severity.
    /// @dev Strictly less than `10_000` (i.e. max `9_999`) — a 100% slash
    ///      zeroes `poolTokens` while `poolShares` stay nonzero, bricking the
    ///      delegation pool (subsequent `delegateStake` reverts with
    ///      `Math.mulDiv` divide-by-zero). Same applies to the unbonding pool.
    ///      Capping at `9_999` keeps `mulDiv(poolTokens, slashBps, 10_000)`
    ///      strictly less than `poolTokens` — at least 1 wei remains. (C-2)
    uint256 public maxSlashBps;

    /// @notice Per-(proposal, voter) snapshot of the voter's stake at the
    ///         instant their review vote was recorded. The registry calls
    ///         `recordVoteStake` to populate this; `slashGuardians` reads it
    ///         (clamped to live stake) to size each approver's own-stake slash.
    /// @dev Relocated from `GuardianRegistry._voteStake`. The clamp in
    ///      `_slashOne` guards against a concurrent slash having already
    ///      reduced live stake below the snapshot.
    mapping(uint256 proposalId => mapping(address voter => uint128)) public voteStake;

    /// @notice Slashed WOOD whose burn transfer failed, queued for retry.
    /// @dev Keyed by `address(this)` — relocated verbatim from
    ///      `GuardianRegistry._pendingBurn`. A malicious / blacklisting WOOD
    ///      that reverts or returns false on `transfer(BURN_ADDRESS, ...)` must
    ///      not be able to brick `slashGuardians` / `slashOwnerBond` (the slash
    ///      accounting has already happened — only the burn transfer is at
    ///      risk). The amount accumulates here and `flushBurn` retries it.
    mapping(address => uint256) internal _pendingBurn;

    /// @dev Reserves upgrade headroom for this leaf contract. Later tasks
    ///      (slash bounds, etc.) decrement this as they add storage.
    ///      Decremented 16 → 15 in Task 5.1: `voteStake` consumes one slot.
    ///      Decremented 15 → 14 in Task 5.2: `_pendingBurn` consumes one slot.
    ///      Decremented 14 → 12 in Task 6.2: `minSlashBps` + `maxSlashBps`.
    uint256[12] private __gap;

    /// @notice Slashed WOOD is sent here — permanently out of circulation.
    /// @dev Burning via a transfer to a known-dead address keeps WOOD's
    ///      `totalSupply` semantics intact (no `burn` dependency on the token).
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Grouped `initialize` arguments. A struct keeps the call site
    ///         keyword-addressed — a prior review flagged the positional arg
    ///         list as swap-prone.
    struct InitParams {
        /// @dev Contract owner (the parameter-setter multisig).
        address owner;
        /// @dev WOOD ERC20 token custodied for staking and bonds.
        address wood;
        /// @dev SyndicateGovernor — coordinates reviews and proposal lifecycle.
        address governor;
        /// @dev SyndicateFactory — sole caller authorized to `bindOwnerStake`.
        address factory;
        /// @dev Minimum WOOD for an active guardian stake.
        uint256 minGuardianStake;
        /// @dev Cooldown between guardian unstake request and claim.
        uint256 coolDownPeriod;
        /// @dev Minimum WOOD a vault owner must bond at vault creation.
        uint256 minOwnerStake;
        /// @dev Lower clamp bound (bps) for graduated slash severity.
        uint256 minSlashBps;
        /// @dev Upper clamp bound (bps, ≤ 10_000) for graduated slash severity.
        uint256 maxSlashBps;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.owner == address(0) || p.wood == address(0) || p.governor == address(0) || p.factory == address(0)) {
            revert ZeroAddress();
        }
        __Ownable_init(p.owner);
        wood = IERC20(p.wood);
        governor = p.governor;
        factory = p.factory;
        minGuardianStake = p.minGuardianStake;
        coolDownPeriod = p.coolDownPeriod;
        minOwnerStake = p.minOwnerStake;
        // Graduated slash severity: enforce `minSlashBps <= maxSlashBps < 10_000`.
        // Strict `<` defends against pool-bricking: a 100% (10_000 bps) slash
        // zeroes `poolTokens` while `poolShares` stay nonzero, after which
        // `delegateStake`'s `Math.mulDiv(amount, sh, ts=0)` panics with
        // divide-by-zero. Capping at 9_999 keeps at least 1 wei in the pool.
        if (p.minSlashBps > p.maxSlashBps || p.maxSlashBps >= 10_000) {
            revert InvalidParameter();
        }
        minSlashBps = p.minSlashBps;
        maxSlashBps = p.maxSlashBps;
        _initEpochGenesis();
    }

    function setRegistry(address registry_) external onlyOwner {
        if (_registrySet) revert RegistryAlreadySet();
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
        _registrySet = true;
    }

    function _wood() internal view override returns (IERC20) {
        return wood;
    }

    /// @dev Active iff the guardian holds stake >= `minGuardianStake` and has no
    ///      pending unstake request. Relocated verbatim from `GuardianRegistry`.
    function _isActiveGuardian(address g) internal view override returns (bool) {
        Guardian storage gs = _guardians[g];
        return gs.stakedAmount > 0 && gs.unstakeRequestedAt == 0;
    }

    function _coolDownPeriod() internal view virtual override returns (uint256) {
        return coolDownPeriod;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    // ── Guardian staking (relocated verbatim from GuardianRegistry) ──

    /// @notice Stake WOOD as a guardian (or top up an existing stake).
    /// @dev Idempotent top-up: on first stake records `agentId` and activates
    ///      the guardian; on subsequent calls the `agentId` arg is ignored.
    ///      Relocated verbatim from `GuardianRegistry.stakeAsGuardian`.
    function stakeAsGuardian(uint256 amount, uint256 agentId) external nonReentrant {
        // Stake intentionally not gated by pause: guardians must be able to
        // manage their position (stake/unstake/claim) even during an incident.
        Guardian storage g = _guardians[msg.sender];
        // Bug A fix: a guardian with a pending unstake request is NOT active
        // (see `_isActiveGuardian`), so letting them top up would grow
        // `totalGuardianStake` without creating votable weight — quorum
        // denominator would outrun the real cohort. Force them to cancel the
        // unstake first.
        if (g.unstakeRequestedAt != 0) revert UnstakeAlreadyRequested();
        uint256 newTotal = uint256(g.stakedAmount) + amount;
        if (newTotal < minGuardianStake) revert InsufficientStake();

        wood.safeTransferFrom(msg.sender, address(this), amount);

        bool wasInactive = g.stakedAmount == 0;
        g.stakedAmount = uint128(newTotal);
        if (wasInactive) {
            g.stakedAt = uint64(block.timestamp);
            g.agentId = agentId; // recorded once; ignored on top-ups
        }
        totalGuardianStake += amount;

        // Checkpoint votable stake for historical quorum lookups.
        _stakeCheckpoints[msg.sender].push(uint32(block.timestamp), uint224(newTotal));
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));

        // Sherlock #39 / Run-1 #22: first-time stake transitions guardian
        // active. Any pre-existing delegations to msg.sender (which until
        // now were excluded from `totalActiveDelegatedStake`) now count.
        if (wasInactive) {
            uint256 pool = poolTokens[msg.sender];
            if (pool != 0) {
                _writeActiveDelegated(totalActiveDelegatedStake + pool);
            }
        }

        emit GuardianStaked(msg.sender, amount, agentId);
    }

    /// @notice A guardian's current own stake.
    function guardianStake(address guardian) external view returns (uint256) {
        return _guardians[guardian].stakedAmount;
    }

    /// @notice A guardian's total votable weight at a past timestamp.
    /// @dev Votes = own checkpointed stake + delegated inbound (`poolTokens`)
    ///      at `timestamp`. The own-stake checkpoint drops to 0 once the
    ///      guardian requests unstake; the delegated term is independent.
    function getPastVotes(address guardian, uint256 timestamp) public view returns (uint256) {
        return
            _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp))
                + getPastDelegatedInbound(guardian, timestamp);
    }

    /// @notice Total guardian vote weight (quorum denominator) at a past timestamp.
    /// @dev Reads the global total-active-stake checkpoint trace. Relocated from
    ///      `GuardianRegistry`.
    function getPastTotalVotes(uint256 timestamp) public view returns (uint256) {
        return _totalStakeCheckpoint.upperLookupRecent(uint32(timestamp));
    }

    // ── Snapshot-compatible vote-read surface ──
    //
    // `getVotes` / `getPastVotes` / `getPastTotalSupply` give Snapshot's
    // `erc20-votes` strategy the read surface it consumes, since the post-split
    // `WoodToken` no longer inherits `ERC20Votes`. sWOOD intentionally does NOT
    // implement the full OZ `IVotes` interface: `delegate` / `delegates` /
    // `delegateBySig` would collide with sWOOD's custodial DPoS delegation,
    // which is a different mechanism (stake-pool shares, not vote re-pointing).
    // Vote weight = own staked WOOD (votable — zero once unstake is requested)
    // + delegated-inbound WOOD.

    /// @notice An account's CURRENT vote weight: own votable stake + delegated
    ///         inbound. The live counterpart of `getPastVotes`.
    /// @dev Delegates to `getPastVotes(account, block.timestamp)`. The
    ///      checkpoint traces are pushed on every votable-weight change with
    ///      key `uint32(block.timestamp)`, and `upperLookupRecent` includes a
    ///      checkpoint written in the current block — so a same-block lookup
    ///      returns the live value. A guardian with a pending unstake request
    ///      has a 0 own-stake checkpoint, so the own term is 0; the
    ///      delegated-inbound term is independent.
    function getVotes(address account) external view returns (uint256) {
        return getPastVotes(account, block.timestamp);
    }

    /// @notice Total system vote weight at a past timestamp — the denominator a
    ///         Snapshot quorum/total would use.
    /// @dev Delegates to `getPastTotalVotes(timestamp) + getPastTotalDelegated(timestamp)`,
    ///      consistent with per-account `getPastVotes` = own + delegated.
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256) {
        return getPastTotalVotes(timestamp) + getPastTotalDelegated(timestamp);
    }

    /// @notice True iff `guardian` has an active stake and no pending unstake.
    /// @dev Relocated verbatim from `GuardianRegistry`.
    function isActiveGuardian(address guardian) external view returns (bool) {
        return _isActiveGuardian(guardian);
    }

    // ── Parameter setters (owner-instant; the owner is a multisig with an
    //    external delay, so an on-chain timelock would double-count it) ──

    /// @notice Set the minimum WOOD required for an active guardian stake.
    /// @dev Owner-only. Relocated from `GuardianRegistry.setMinGuardianStake`.
    function setMinGuardianStake(uint256 v) external onlyOwner {
        if (v < 1e18) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MIN_GUARDIAN_STAKE, minGuardianStake, v);
        minGuardianStake = v;
    }

    /// @notice Set the guardian unstake cooldown period.
    /// @dev Owner-only. Relocated from `GuardianRegistry.setCooldownPeriod`.
    ///      Enforces the absolute `[1 days, 30 days]` bounds AND the
    ///      `coolDownPeriod >= reviewPeriod` cross-contract invariant
    ///      (Sherlock #16): once the registry is wired, the cooldown may not
    ///      drop below the registry's review window. This invariant closes
    ///      slash-evasion for guardian OWN stake only — a guardian cannot
    ///      unstake and escape the slash before `resolveReview` runs.
    ///      Delegator stake evasion is closed independently by the delegation
    ///      unbonding-escrow. The cross-call is guarded behind
    ///      `registry != address(0)` so a not-yet-wired sWOOD (deploy-time,
    ///      before `setRegistry`) does not revert.
    function setCooldownPeriod(uint256 v) external onlyOwner {
        if (v < 1 days || v > 30 days) revert InvalidParameter();
        address reg = registry;
        if (reg != address(0) && v < IRegistryReviewPeriod(reg).reviewPeriod()) {
            revert CooldownBelowReviewPeriod();
        }
        emit ParameterChangeFinalized(PARAM_COOLDOWN, coolDownPeriod, v);
        coolDownPeriod = v;
    }

    /// @notice Set the minimum WOOD a vault owner must bond at vault creation.
    /// @dev Owner-only. Relocated verbatim from `GuardianRegistry.setMinOwnerStake`.
    function setMinOwnerStake(uint256 v) external onlyOwner {
        if (v < 1_000 * 1e18) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MIN_OWNER_STAKE, minOwnerStake, v);
        minOwnerStake = v;
    }

    /// @notice Set the lower clamp bound for the graduated slash severity.
    /// @dev Owner-only. Must keep `minSlashBps <= maxSlashBps < 10_000`.
    ///      The implicit ceiling is `maxSlashBps < 10_000` (enforced by
    ///      `setMaxSlashBps` / `initialize`), so this only needs to gate
    ///      against `v > maxSlashBps`.
    function setMinSlashBps(uint256 v) external onlyOwner {
        if (v > maxSlashBps) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MIN_SLASH_BPS, minSlashBps, v);
        minSlashBps = v;
    }

    /// @notice Set the upper clamp bound for the graduated slash severity.
    /// @dev Owner-only. Must keep `minSlashBps <= maxSlashBps < 10_000`.
    ///      Strict `<` defends against pool-bricking — see `maxSlashBps`.
    function setMaxSlashBps(uint256 v) external onlyOwner {
        if (v < minSlashBps || v >= 10_000) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MAX_SLASH_BPS, maxSlashBps, v);
        maxSlashBps = v;
    }

    // ── Guardian unstake cooldown (relocated verbatim from GuardianRegistry) ──

    /// @notice Request to unstake guardian WOOD; starts the cooldown.
    /// @dev Immediately revokes voting power by zeroing the guardian's contribution to
    ///      `totalGuardianStake`. WOOD stays in the contract until
    ///      `claimUnstakeGuardian` after `coolDownPeriod`.
    function requestUnstakeGuardian() external {
        Guardian storage g = _guardians[msg.sender];
        if (g.stakedAmount == 0) revert NoActiveStake();
        if (g.unstakeRequestedAt != 0) revert UnstakeAlreadyRequested();

        g.unstakeRequestedAt = uint64(block.timestamp);
        // Sherlock run #2 #14: freeze the cooldown at request time so the
        // owner can't extend lockup retroactively.
        // forge-lint: disable-next-line(unchecked-cast)
        g.cooldownAtRequest = uint64(coolDownPeriod);
        totalGuardianStake -= g.stakedAmount;

        // Unstake-requested stake is not votable. Push 0 so getPastStake
        // reflects the on-cooldown state accurately.
        _stakeCheckpoints[msg.sender].push(uint32(block.timestamp), 0);
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));

        // Sherlock #39 / Run-1 #22: guardian transitions inactive — their
        // delegated pool stops contributing to the active-only total
        // (delegators still hold pool shares; they can re-bind to an
        // active delegate or wait out the cooldown).
        uint256 pool = poolTokens[msg.sender];
        if (pool != 0) {
            _writeActiveDelegated(totalActiveDelegatedStake - pool);
        }

        emit GuardianUnstakeRequested(msg.sender, block.timestamp);
    }

    /// @notice Cancel a pending unstake request.
    /// @dev Reverses `requestUnstakeGuardian`: restores voting power.
    function cancelUnstakeGuardian() external {
        Guardian storage g = _guardians[msg.sender];
        if (g.unstakeRequestedAt == 0) revert UnstakeNotRequested();
        // If the guardian was slashed between `requestUnstakeGuardian` and
        // now, `stakedAmount == 0` but `unstakeRequestedAt` still points at
        // the original request. "Cancelling" here would resurrect a ghost
        // guardian with no stake. Nothing to restore → revert.
        if (g.stakedAmount == 0) revert NoActiveStake();

        g.unstakeRequestedAt = 0;
        totalGuardianStake += g.stakedAmount;

        // Stake is votable again.
        _stakeCheckpoints[msg.sender].push(uint32(block.timestamp), uint224(g.stakedAmount));
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));

        // Sherlock #39 / Run-1 #22: guardian transitions back to active —
        // their delegated pool resumes contributing to the active-only
        // total.
        uint256 pool = poolTokens[msg.sender];
        if (pool != 0) {
            _writeActiveDelegated(totalActiveDelegatedStake + pool);
        }

        emit GuardianUnstakeCancelled(msg.sender);
    }

    /// @notice Claim guardian WOOD after the cooldown has elapsed.
    /// @dev After `coolDownPeriod` from `unstakeRequestedAt`, releases WOOD and
    ///      deregisters the guardian entirely (struct deleted — agentId can differ on
    ///      a subsequent re-stake).
    /// @dev nonReentrant dropped — CEI: struct deleted before transfer.
    function claimUnstakeGuardian() external {
        Guardian storage g = _guardians[msg.sender];
        if (g.unstakeRequestedAt == 0) revert UnstakeNotRequested();
        // Sherlock run #2 #14: use cooldown frozen at request time.
        if (block.timestamp < uint256(g.unstakeRequestedAt) + uint256(g.cooldownAtRequest)) {
            revert CooldownNotElapsed();
        }

        uint256 amount = g.stakedAmount;
        delete _guardians[msg.sender];

        wood.safeTransfer(msg.sender, amount);

        emit GuardianUnstakeClaimed(msg.sender, amount);
    }

    // ── Owner-bond prepare/bind (relocated verbatim from GuardianRegistry) ──

    /// @notice Escrow WOOD as a prospective vault owner's bond.
    /// @dev Pulls WOOD into the contract under `_prepared[msg.sender]`. At prepare
    ///      time we don't yet know the target vault's TVL-scaled bond, so only the
    ///      floor (`minOwnerStake`) is enforced here. The factory checks the bond
    ///      at `bindOwnerStake` time.
    function prepareOwnerStake(uint256 amount) external nonReentrant {
        if (amount < minOwnerStake) revert InsufficientStake();

        PreparedOwnerStake storage p = _prepared[msg.sender];
        // Allow re-prepare only after a previous prepared stake was bound (slot consumed).
        if (p.amount != 0 && !p.bound) revert PreparedStakeAlreadyExists();

        wood.safeTransferFrom(msg.sender, address(this), amount);

        _prepared[msg.sender] =
            PreparedOwnerStake({amount: uint128(amount), preparedAt: uint64(block.timestamp), bound: false});

        emit OwnerStakePrepared(msg.sender, amount);
    }

    /// @notice Refund an unbound prepared owner stake.
    /// @dev Reverts if the slot has already been bound to a vault (use the
    ///      owner-unstake flow in that case).
    /// @dev nonReentrant dropped — CEI: struct deleted before transfer.
    function cancelPreparedStake() external {
        PreparedOwnerStake storage p = _prepared[msg.sender];
        if (p.amount == 0 || p.bound) revert PreparedStakeNotFound();

        uint256 amount = p.amount;
        delete _prepared[msg.sender];

        wood.safeTransfer(msg.sender, amount);

        emit PreparedStakeCancelled(msg.sender, amount);
    }

    /// @notice Bind a prepared owner stake to a newly created vault.
    /// @dev Consumes `_prepared[owner_]` and binds it to `_ownerStakes[vault]`.
    ///      Called by `SyndicateFactory.createSyndicate` after the vault address
    ///      is known. Reverts if the prepared amount is below `minOwnerStake` —
    ///      at factory-creation time `totalAssets()` is 0, so only the floor applies.
    /// @dev nonReentrant dropped — no external calls after state write.
    function bindOwnerStake(address owner_, address vault) external onlyFactory {
        PreparedOwnerStake storage p = _prepared[owner_];
        if (p.amount == 0 || p.bound) revert PreparedStakeNotFound();
        if (p.amount < minOwnerStake) revert OwnerBondInsufficient();

        _ownerStakes[vault] =
            OwnerStake({stakedAmount: p.amount, unstakeRequestedAt: 0, owner: owner_, cooldownAtRequest: 0});
        p.bound = true;

        emit OwnerStakeBound(owner_, vault, p.amount);
    }

    /// @notice Vault owner signals intent to exit; starts the unstake cooldown.
    /// @dev Blocked while the vault has any open proposal (Pending /
    ///      GuardianReview / Approved / Executed) to prevent rage-quit around
    ///      malicious executions. Immediately stamps `unstakeRequestedAt`; WOOD
    ///      stays escrowed until `claimUnstakeOwner`.
    ///
    ///      `openProposalCount` tracks every non-terminal state — a
    ///      `getActiveProposal` check alone would only cover Executed and let a
    ///      malicious owner propose a draining strategy and rage-quit before
    ///      execution. The OR against `getActiveProposal` is belt-and-braces so
    ///      any stale-cache window still reverts. Relocated verbatim from
    ///      `GuardianRegistry`.
    function requestUnstakeOwner(address vault) external {
        OwnerStake storage s = _ownerStakes[vault];
        if (s.owner != msg.sender || s.stakedAmount == 0) revert NoActiveStake();
        if (s.unstakeRequestedAt != 0) revert UnstakeAlreadyRequested();
        IGovernorMinimal gov = IGovernorMinimal(governor);
        if (gov.openProposalCount(vault) != 0 || gov.getActiveProposal(vault) != 0) {
            revert VaultHasActiveProposal();
        }

        s.unstakeRequestedAt = uint64(block.timestamp);
        // Sherlock run #2 #14: freeze cooldown at request time.
        // forge-lint: disable-next-line(unchecked-cast)
        s.cooldownAtRequest = uint64(coolDownPeriod);

        emit OwnerUnstakeRequested(vault, block.timestamp);
    }

    /// @notice Claim a vault owner's bond after the cooldown has elapsed.
    /// @dev After `coolDownPeriod` from `unstakeRequestedAt`, releases WOOD to
    ///      the recorded owner and deletes `_ownerStakes[vault]` entirely — the
    ///      vault then enters grace-period state (`ownerStaked == false`). New
    ///      proposals cannot be created until owner re-binds a fresh stake via
    ///      the factory. Relocated verbatim from `GuardianRegistry`.
    /// @dev nonReentrant dropped — CEI: struct deleted before transfer.
    function claimUnstakeOwner(address vault) external {
        OwnerStake storage s = _ownerStakes[vault];
        if (s.owner != msg.sender || s.stakedAmount == 0) revert NoActiveStake();
        if (s.unstakeRequestedAt == 0) revert UnstakeNotRequested();
        // Sherlock run #2 #14: use cooldown frozen at request time.
        if (block.timestamp < uint256(s.unstakeRequestedAt) + uint256(s.cooldownAtRequest)) {
            revert CooldownNotElapsed();
        }
        // Sherlock run #2 #7: re-check open proposals at claim time. The
        // gate in `requestUnstakeOwner` only fires once; without this
        // re-check an owner who is also a registered agent could call
        // `requestUnstakeOwner` when clean, wait through cooldown, then in
        // a single transaction `propose` a draining strategy + claim their
        // bond. Slash would then find `stakedAmount == 0` and burn nothing.
        // Symmetric with the request-time gate.
        if (IGovernorMinimal(governor).openProposalCount(vault) != 0) revert VaultHasActiveProposal();

        uint256 amount = s.stakedAmount;
        address recipient = s.owner;
        delete _ownerStakes[vault];

        wood.safeTransfer(recipient, amount);

        emit OwnerUnstakeClaimed(vault, recipient, amount);
    }

    /// @notice Re-point a vault's owner-stake slot to a new owner.
    /// @dev Reassigns `_ownerStakes[vault]` to `newOwner`'s prepared stake after
    ///      the previous owner's stake has been slashed or fully unstaked
    ///      (guarded by `stakedAmount == 0`). `newOwner` must have called
    ///      `prepareOwnerStake` with >= `minOwnerStake`. Reverts with
    ///      `PriorStakeNotCleared` if the prior owner still has residual stake
    ///      (they must first complete `requestUnstakeOwner` →
    ///      `claimUnstakeOwner`, or be slashed, before the slot can be
    ///      transferred). Relocated verbatim from `GuardianRegistry`.
    /// @dev nonReentrant dropped — no external calls after state write.
    function transferOwnerStakeSlot(address vault, address newOwner) external onlyFactory {
        OwnerStake storage existing = _ownerStakes[vault];
        address oldOwner = existing.owner;
        if (existing.stakedAmount != 0) revert PriorStakeNotCleared();

        PreparedOwnerStake storage p = _prepared[newOwner];
        if (p.amount == 0 || p.bound) revert PreparedStakeNotFound();
        if (p.amount < minOwnerStake) revert OwnerBondInsufficient();

        _ownerStakes[vault] =
            OwnerStake({stakedAmount: p.amount, unstakeRequestedAt: 0, owner: newOwner, cooldownAtRequest: 0});
        p.bound = true;

        emit OwnerStakeSlotTransferred(vault, oldOwner, newOwner);
    }

    /// @notice The owner bond a vault must hold.
    /// @dev Relocated from `GuardianRegistry`. TVL scaling is not implemented in
    ///      V1; the bond is unconditionally `minOwnerStake`. The `vault`
    ///      parameter is retained for ABI / forward-compatibility. Re-declared
    ///      here as an explicit view so callers (`GovernorEmergency`,
    ///      `SyndicateFactory`) can repoint registry → sWOOD without depending
    ///      on storage-variable visibility.
    function requiredOwnerBond(address vault) external view returns (uint256) {
        vault; // unused — bond is the flat `minOwnerStake` floor in V1.
        return minOwnerStake;
    }

    /// @notice A vault's bound owner stake.
    /// @dev Relocated verbatim from `GuardianRegistry`.
    function ownerStake(address v) external view returns (uint256) {
        return _ownerStakes[v].stakedAmount;
    }

    /// @notice A prospective owner's escrowed prepared stake amount.
    /// @dev Relocated verbatim from `GuardianRegistry`.
    function preparedStakeOf(address o) external view returns (uint256) {
        return _prepared[o].amount;
    }

    /// @notice True iff `o` has a prepared, unbound stake at or above the floor.
    /// @dev Relocated verbatim from `GuardianRegistry`.
    function canCreateVault(address o) external view returns (bool) {
        return _prepared[o].amount >= minOwnerStake && !_prepared[o].bound;
    }

    /// @notice Enable or disable share-based DPoS delegation.
    /// @dev Owner-only. `delegationEnabled` defaults false at deploy so
    ///      delegation can be switched on after the cohort bootstraps.
    function setDelegationEnabled(bool enabled) external onlyOwner {
        delegationEnabled = enabled;
        emit DelegationEnabledSet(enabled);
    }

    // ── Vote-stake snapshot + slashing (registry-gated) ──

    /// @notice Snapshot a voter's stake for a proposal's review.
    /// @dev Registry-only. Called when an approver's review vote is recorded;
    ///      `slashGuardians` later reads this (clamped to live stake) to size
    ///      the own-stake portion of the slash. Relocated from
    ///      `GuardianRegistry._voteStake`.
    function recordVoteStake(uint256 proposalId, address voter, uint128 weight) external onlyRegistry {
        voteStake[proposalId][voter] = weight;
    }

    /// @notice Slash a set of approvers for a blocked proposal.
    /// @dev Registry-only. For each approver, burns `slashBps` of both their
    ///      OWN guardian stake (sized by the `voteStake` snapshot, clamped to
    ///      live stake) AND their inbound delegation pool. The delegated slash
    ///      is O(1): a single write to `poolTokens` dilutes every delegator in
    ///      that pool pro-rata via the ERC-4626 share model — no per-delegator
    ///      loop. The aggregate total-stake checkpoint is pushed once after the
    ///      loop; the slashed WOOD is burned in a single transfer.
    /// @param proposalId The blocked proposal whose approvers are slashed.
    /// @param openedAt   Sherlock run #3 #6: snapshot timestamp the review's
    ///                   `recordVoteStake` was captured at. `_slashOne` reads
    ///                   `getPastDelegatedInbound(approver, openedAt)` to
    ///                   isolate the own-stake portion of the combined weight
    ///                   snapshot — without it, an approver whose vote weight
    ///                   included delegated inbound would lose own stake sized
    ///                   off the combined weight, AND have their delegated pool
    ///                   slashed separately (effective double-slash on the
    ///                   delegated portion contributing to the snapshot).
    /// @param approvers  The approver addresses to slash.
    /// @param slashBps   Slash fraction in basis points out of `10_000`.
    /// @return total     Total WOOD burned across all approvers.
    function slashGuardians(uint256 proposalId, uint256 openedAt, address[] calldata approvers, uint256 slashBps)
        external
        onlyRegistry
        returns (uint256 total)
    {
        for (uint256 i = 0; i < approvers.length; i++) {
            total += _slashOne(proposalId, openedAt, approvers[i], slashBps);
        }
        if (total == 0) return 0;
        // Checkpoint the aggregate total-stake drop once after the loop.
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));
        _burnWood(total);
    }

    /// @dev Per-approver slash: own-stake portion (clamped `voteStake`
    ///      snapshot) + delegated-pool portion (single `poolTokens` write).
    ///      Extracted to keep `slashGuardians`'s stack frame shallow.
    ///      Returns the WOOD slashed from `approver` (own + delegated).
    ///
    ///      Sherlock run #3 #6: `voteStake[proposalId][approver]` mirrors the
    ///      registry's `getPastVotes(approver, openedAt_)` — own + delegated
    ///      inbound at the openedAt_ snapshot. Sized by that snapshot, the
    ///      own-stake slash would over-debit `g.stakedAmount` by the
    ///      delegated-at-snapshot portion (and the delegated pool was
    ///      already separately slashed via `delSlash` below — effective
    ///      double-slash on the delegated contribution). Fix: subtract
    ///      `getPastDelegatedInbound(approver, openedAt_)` to isolate the
    ///      pure-own-stake snapshot. The snapshot-inbound is correct even
    ///      if delegators staked/unstaked between open and slash (live
    ///      `poolTokens` would diverge from the snapshot).
    function _slashOne(uint256 proposalId, uint256 openedAt, address approver, uint256 slashBps)
        private
        returns (uint256 amt)
    {
        Guardian storage g = _guardians[approver];
        uint256 live = g.stakedAmount;
        // Sherlock #39 / Run-1 #22: snapshot pre-slash active state + pool
        // so the active-delegated adjustment can pick the right delta
        // after own-stake and pool writes mutate the relevant fields.
        bool wasActive = live > 0 && g.unstakeRequestedAt == 0;
        uint256 oldPool = poolTokens[approver];

        // Sherlock run #3 #6: extract own-stake snapshot from the combined
        // voteStake by subtracting the snapshot-time delegated inbound. If
        // the snapshot or inbound view ever returns 0 (no vote recorded /
        // pre-fix proposal / no delegations), this collapses to the raw
        // snapshot — which is the correct pre-#6 behavior for those cases.
        uint256 snapTotal = uint256(voteStake[proposalId][approver]);
        uint256 snapDelegated = getPastDelegatedInbound(approver, openedAt);
        uint256 snapOwn = snapTotal > snapDelegated ? snapTotal - snapDelegated : 0;
        // Clamp: a concurrent slash may have already reduced live stake below
        // the recorded snapshot — take only what is actually there.
        uint256 ownSlash = Math.mulDiv(snapOwn <= live ? snapOwn : live, slashBps, 10_000);
        if (ownSlash != 0) {
            // forge-lint: disable-next-line(unchecked-cast)
            // Safe-by-construction: `live - ownSlash <= live`, and `live`
            // originates from the `uint128 stakedAmount` field, so the
            // difference fits a `uint128`.
            g.stakedAmount = uint128(live - ownSlash);
            if (g.unstakeRequestedAt == 0) {
                // Still active: their stake counts toward the aggregate, so
                // decrement it and re-checkpoint the post-slash votable stake.
                totalGuardianStake -= ownSlash;
                _stakeCheckpoints[approver].push(uint32(block.timestamp), uint224(g.stakedAmount));
            } else if (g.stakedAmount == 0) {
                // Unstake-requested: `totalGuardianStake` was already
                // decremented at request time. If fully slashed, clear the
                // request stamp so `cancelUnstakeGuardian` can't resurrect a
                // ghost guardian with no stake.
                g.unstakeRequestedAt = 0;
            }
        }
        // Delegated-pool slash: ONE write dilutes every LIVE delegator
        // pro-rata. `totalDelegatedStake` only tracks the live pool, so it is
        // decremented by this portion alone.
        uint256 delSlash = Math.mulDiv(oldPool, slashBps, 10_000);
        if (delSlash != 0) {
            poolTokens[approver] -= delSlash;
            totalDelegatedStake -= delSlash;
            _pushDelegationCheckpoints(address(0), approver); // re-checkpoint pool aggregates
        }
        // Sherlock #39 / Run-1 #22: active-delegated adjustment based on
        // the (wasActive, nowActive) transition. Inactive → inactive is a
        // no-op (pool was already excluded). Active → active: drop by the
        // pool slash. Active → inactive: drop by the FULL pre-slash pool
        // (everything that was counting now stops counting). Active →
        // active cannot happen from a slash (slash only reduces).
        if (wasActive) {
            bool nowActive = g.stakedAmount > 0 && g.unstakeRequestedAt == 0;
            if (nowActive) {
                if (delSlash != 0) _writeActiveDelegated(totalActiveDelegatedStake - delSlash);
            } else if (oldPool != 0) {
                _writeActiveDelegated(totalActiveDelegatedStake - oldPool);
            }
        }
        // I-1: unbonding-escrow slash. Stake requested-out sits in the
        // unbonding pool for the full `coolDownPeriod` and is slashable —
        // ONE write dilutes every unbonding delegator pro-rata. The unbonding
        // pool is not vote-weighted / not in `totalDelegatedStake`, so no
        // checkpoint and no `totalDelegatedStake` decrement here.
        uint256 unbondSlash = Math.mulDiv(unbondingPoolTokens[approver], slashBps, 10_000);
        if (unbondSlash != 0) {
            unbondingPoolTokens[approver] -= unbondSlash;
        }
        amt = ownSlash + delSlash + unbondSlash;
        // Emit only when something was actually slashed — an approver with no
        // own stake and no delegated/unbonding pool produces no on-chain
        // record. `delegatedSlash` reports the COMBINED delegated slash
        // (live pool + unbonding-escrow pool) so indexers and the appeal flow
        // see the full delegated hit.
        if (amt != 0) {
            emit GuardianSlashed(proposalId, approver, ownSlash, delSlash + unbondSlash);
        }
    }

    /// @notice Slash a vault's owner bond — burns the entire bond.
    /// @dev Registry-only. The owner bond is fully consumed on an
    ///      emergency-settle failure; this reads the bonded amount, clears the
    ///      `_ownerStakes[vault]` slot, then burns the WOOD. CEI: the slot is
    ///      cleared BEFORE `_burnWood`'s external transfer. A no-op (no burn,
    ///      no revert) when the vault holds no bond.
    /// @param vault The vault whose owner bond is slashed.
    function slashOwnerBond(address vault) external onlyRegistry {
        uint256 amount = _ownerStakes[vault].stakedAmount;
        if (amount == 0) return;
        // CEI: clear the slot before the burn's external call.
        delete _ownerStakes[vault];
        _burnWood(amount);
        emit OwnerBondSlashed(vault, amount);
    }

    /// @notice Retry a stuck slash burn. Permissionless.
    /// @dev Reads `_pendingBurn[address(this)]`, returns early when empty,
    ///      zeros it (CEI) then `safeTransfer`s to `BURN_ADDRESS`.
    ///      `safeTransfer` reverts on failure — if WOOD is still broken the
    ///      whole tx reverts and the pending amount stays queued (state update
    ///      and transfer are atomic). Relocated from `GuardianRegistry`; the
    ///      registry's `whenNotPaused` modifier is dropped — sWOOD has no pause
    ///      mechanism (pausing is a registry-only concern post-split).
    function flushBurn() external {
        uint256 amt = _pendingBurn[address(this)];
        if (amt == 0) return;
        _pendingBurn[address(this)] = 0;
        wood.safeTransfer(BURN_ADDRESS, amt);
        emit BurnFlushed(amt);
    }

    /// @notice WOOD currently queued for a burn retry via `flushBurn`.
    function pendingBurn() external view returns (uint256) {
        return _pendingBurn[address(this)];
    }

    /// @dev Moves slashed WOOD permanently out of circulation. A malicious /
    ///      broken WOOD that reverts or returns false on transfer to
    ///      `BURN_ADDRESS` falls through to the pull-based `flushBurn`
    ///      fallback — the slash accounting has already happened, only the
    ///      burn transfer is at risk. Relocated verbatim from
    ///      `GuardianRegistry._slashApprovers`.
    function _burnWood(uint256 amount) private {
        try IERC20(wood).transfer(BURN_ADDRESS, amount) returns (bool ok) {
            if (!ok) {
                _pendingBurn[address(this)] += amount;
                emit PendingBurnRecorded(amount);
            }
        } catch {
            _pendingBurn[address(this)] += amount;
            emit PendingBurnRecorded(amount);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
