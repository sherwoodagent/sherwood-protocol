// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Minimal `SyndicateGovernor` surface consumed by sWOOD: the
///         open-proposal signals used by the rage-quit gate in
///         `requestUnstakeOwner`. Per-vault governor — no vault arg needed.
interface IGovernorMinimal {
    function getActiveProposal() external view returns (uint256);
    function openProposalCount() external view returns (uint256);
}

interface IFactoryGovernorLookup {
    function governorOf(address vault) external view returns (address);
}

/// @notice Minimal `GuardianRegistry` surface consumed by sWOOD: the
///         guardian review window. Used by `setCooldownPeriod` to enforce
///         the `coolDownPeriod >= reviewPeriod` cross-contract invariant.
interface IRegistryReviewPeriod {
    function reviewPeriod() external view returns (uint256);
}

/// @title StakedWood (sWOOD)
/// @notice Non-transferable vote-escrow contract. Sole WOOD custodian:
///         guardian stake, owner bonds, vote checkpoints, slashing + burn.
/// @dev Vote weight is aged own stake only; slashing has exactly one leg
///      (the guardian's own bond). No DPoS delegation.
/// @dev Narrow ExposureLedger read surface, mirrored in the other direction
///      by `ISwoodMinimal` — neither contract imports the other's full ABI.
///      Both directions are views, so the mutual reference carries no
///      reentrancy concern.
interface ILedgerExposureMinimal {
    function openExposure(address guardian) external view returns (uint256);
    function hasFrozenCoverage(address guardian) external view returns (bool);
}

contract StakedWood is ReentrancyGuardTransient, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    error ZeroAddress();
    error RegistryAlreadySet();
    error NotRegistry();
    error NotFactory();

    /// @notice Reverts when a non-slasher calls the verdict slash path.
    /// @dev Mirrors `IStakedWood.NotAuthorizedSlasher` (same selector) — sWOOD
    ///      declares its own errors rather than inheriting the interface.
    error NotAuthorizedSlasher();

    /// @notice `slashVerdict` rejected because the per-approver rate array is
    ///         not the same length as `approvers`. Positional alignment is the
    ///         only thing tying a guardian to their own rate.
    /// @dev Mirrors `IStakedWood.SlashBpsLengthMismatch`.
    error SlashBpsLengthMismatch();

    /// @notice `slashVerdict` rejected because `openedAt` is in the future.
    ///         The at-open anchor `_slashOne` sizes the legs against must be a
    ///         real past instant (also keeps the `uint32` checkpoint lookup
    ///         from wrapping on an absurd value).
    /// @dev Mirrors `IStakedWood.VerdictNotPast`.
    error VerdictNotPast();

    /// @notice `slashVerdict` rejected because `approvers` names the same address
    ///         twice. Without dedup, repeating one approver N times re-applies its
    ///         clamped rate to the already-reduced stake, compounding past the
    ///         `maxSlashBps` ceiling. Checked pairwise over calldata rather than
    ///         requiring sorted input, since the production feed emits vote-order
    ///         arrays positionally aligned with their rates.
    error DuplicateApprover();

    /// @dev Mirrors `IStakedWood.ApproverAlreadySlashed`.
    error ApproverAlreadySlashed();

    /// @notice Insufficient WOOD to satisfy a stake minimum.
    error InsufficientStake();

    // ── Guardian/owner unstake errors ──

    /// @notice Caller has no active stake to operate on.
    error NoActiveStake();

    /// @notice An unstake request is already pending.
    error UnstakeAlreadyRequested();

    /// @notice No pending unstake request to cancel or claim.
    error UnstakeNotRequested();

    /// @notice `claim*` called before `coolDownPeriod` elapsed.
    error CooldownNotElapsed();

    /// @notice Parameter setter argument failed bounds validation.
    error InvalidParameter();
    /// @notice `setCooldownPeriod` rejected because the new cooldown is
    ///         shorter than the registry's `reviewPeriod`. The
    ///         `coolDownPeriod >= reviewPeriod` invariant closes slash-evasion
    ///         for guardian OWN stake (the `isActiveGuardian` voting gate).
    error CooldownBelowReviewPeriod();

    /// @notice `claimUnstakeGuardian` refused: the guardian still backs a
    ///         proposal whose drain could yet be challenged. REQUESTING the
    ///         unstake stays open; only the release waits.
    error CoverageStillOpen();

    event ExposureLedgerSet(address indexed ledger);

    /// @notice Caller already has an unbound prepared owner stake.
    error PreparedStakeAlreadyExists();

    /// @notice No matching prepared owner stake (zero amount or already bound).
    error PreparedStakeNotFound();

    /// @notice Prepared stake is below the `minOwnerStake` floor at bind time.
    /// @dev In V1 the owner bond is the flat `minOwnerStake` floor — there is
    ///      no TVL scaling. `bindOwnerStake` raises this whenever the
    ///      prepared stake is below that floor.
    error OwnerBondInsufficient();

    /// @notice Owner cannot unstake while the vault has an open proposal.
    error VaultHasActiveProposal();

    /// @notice The slot's prior owner still holds residual stake — they must
    ///         fully unstake or be slashed before the slot can be transferred.
    error PriorStakeNotCleared();

    /// @notice The incoming owner has not consented to having their prepared stake
    ///         bound to this vault.
    /// @dev Adversary: the owner of a vault whose bond slot is empty, rotating that
    ///      vault onto a third party purely to SPEND the third party's escrowed
    ///      prepared stake. `SyndicateFactory.rotateOwner` authorizes only its own
    ///      caller, and `newOwner` is a bare parameter checked solely against
    ///      zero. Without this guard the victim's escrow becomes bound to a vault
    ///      they never chose: `cancelPreparedStake` reverts, their own
    ///      `createSyndicate` is blocked, and the bond is exposed to
    ///      `slashOwnerBond` for the whole unstake-cooldown-claim recovery.
    ///      Consent lives HERE, at the spend site, so every present and future
    ///      factory route lands on the guard rather than on the hazard.
    error BindingNotApproved();

    /// @notice Emitted on every guardian stake / top-up.
    event GuardianStaked(address indexed guardian, uint256 amount, uint256 agentId);

    /// @notice Emitted when a guardian requests to unstake (starts cooldown).
    event GuardianUnstakeRequested(address indexed guardian, uint256 requestedAt);

    /// @notice Emitted when a guardian cancels a pending unstake request.
    event GuardianUnstakeCancelled(address indexed guardian);

    /// @notice Emitted when a guardian claims WOOD after cooldown elapsed.
    event GuardianUnstakeClaimed(address indexed guardian, uint256 amount);

    /// @notice Emitted when an owner parameter setter changes a value.
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);

    /// @notice Emitted when a prospective vault owner escrows a prepared stake.
    event OwnerStakePrepared(address indexed owner, uint256 amount);

    /// @notice Emitted when an unbound prepared owner stake is cancelled and refunded.
    event PreparedStakeCancelled(address indexed owner, uint256 amount);

    /// @notice Emitted when the factory binds a prepared stake to a new vault.
    event OwnerStakeBound(address indexed owner, address indexed vault, uint256 amount);

    /// @notice Emitted when a vault owner requests to unstake their bond (starts cooldown).
    event OwnerUnstakeRequested(address indexed vault, uint256 requestedAt);

    /// @notice Emitted when a vault owner claims their bond after cooldown elapsed.
    event OwnerUnstakeClaimed(address indexed vault, address indexed owner, uint256 amount);

    event OwnerUnstakeCancelled(address indexed vault, address indexed owner);

    /// @notice Emitted when the factory re-points a vault's owner-stake slot.
    event OwnerStakeSlotTransferred(address indexed vault, address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when a prospective owner consents to having their
    ///         prepared stake bound to `vault` by a slot transfer.
    event OwnerStakeBindingApproved(address indexed owner, address indexed vault);

    /// @notice Emitted when a prospective owner withdraws that consent.
    /// @dev `vault` is the approval being cleared, so an indexer can retire the
    ///      exact record rather than inferring it from the last approve.
    event OwnerStakeBindingRevoked(address indexed owner, address indexed vault);

    /// @notice Parameter key for `minGuardianStake`.
    bytes32 public constant PARAM_MIN_GUARDIAN_STAKE = keccak256("minGuardianStake");

    /// @notice Parameter key for `coolDownPeriod`.
    bytes32 public constant PARAM_COOLDOWN = keccak256("coolDownPeriod");

    /// @notice Parameter key for `minOwnerStake`.
    bytes32 public constant PARAM_MIN_OWNER_STAKE = keccak256("minOwnerStake");

    /// @notice The smallest owner bond this contract treats as a bond at all.
    /// @dev    Two jobs, one number. (1) `setMinOwnerStake` / `initialize` reject
    ///         any NONZERO `minOwnerStake` below it, so a token-dust creation
    ///         floor cannot be seated by mistake — this is the pre-existing
    ///         `1_000 * 1e18` literal, now named. (2) `requiredOwnerBond` floors
    ///         at it UNCONDITIONALLY, including under the `minOwnerStake == 0`
    ///         open-onboarding sentinel, so the owner-supplied emergency-settle
    ///         path always has a slashable bond behind it. Matches the published
    ///         parameter range in `docs/guardian-network.md` ("0 (open
    ///         onboarding) or ≥ 1 000"), i.e. 1 000 WOOD is already the
    ///         protocol's own notion of the smallest meaningful bond.
    uint256 public constant MIN_OWNER_BOND_FLOOR = 1_000 * 1e18;

    /// @notice Parameter key for `minSlashBps`.
    /// @dev Floor of the registry's deterministic slash-severity ramp.
    bytes32 public constant PARAM_MIN_SLASH_BPS = keccak256("minSlashBps");

    /// @notice Parameter key for `maxSlashBps`.
    /// @dev Ceiling of the registry's deterministic slash-severity ramp.
    bytes32 public constant PARAM_MAX_SLASH_BPS = keccak256("maxSlashBps");

    /// @notice Parameter key for `ageFloorBps`.
    bytes32 public constant PARAM_AGE_FLOOR_BPS = keccak256("ageFloorBps");

    /// @notice Parameter key for `maturationPeriod`.
    bytes32 public constant PARAM_MATURATION_PERIOD = keccak256("maturationPeriod");

    /// @notice Emitted when the owner rewires the verdict-slash role.
    /// @dev Mirrors `IStakedWood.AuthorizedSlasherSet`.
    event AuthorizedSlasherSet(address indexed slasher);

    /// @notice Emitted when a verdict slash is settled, reporting what was
    ///         destroyed. `burned` is also the function's return value.
    /// @dev The slash pays no one — there is one leg, so the event states one
    ///      number. The prosecutor is paid from the convicted proposer's bond
    ///      by `ProposerBondEscrow`, which is the only pot a prosecutor cannot
    ///      fund for itself. Mirrors `IStakedWood.VerdictSlashBurned`.
    event VerdictSlashBurned(bytes32 indexed caseKey, uint256 burned);

    /// @notice Emitted once per approver actually slashed for a blocked proposal.
    /// @dev A slash is a significant value-destroying change; the appeal flow
    ///      (`refundSlash`) and indexers need on-chain records. Emitted only
    ///      when `ownSlash != 0`. `delegatedSlash` is retained in the ABI for
    ///      indexer compatibility but is ALWAYS 0 — the own bond is the only
    ///      slashable leg.
    event GuardianSlashed(
        bytes32 indexed reviewKey, address indexed approver, uint256 ownSlash, uint256 delegatedSlash
    );

    /// @notice Emitted when a burn transfer fails and the amount is queued for
    ///         a later `flushBurn` retry.
    event PendingBurnRecorded(uint256 amount);

    /// @notice Emitted when a queued burn is successfully flushed.
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

    /// @notice SyndicateFactory — resolves the per-vault governor via
    ///         `factory.governorOf(vault)` in the owner-unstake proposal gate.
    ///         There is no protocol-wide governor.
    address public factory;

    bool private _registrySet;

    // ── Guardian-stake storage ──

    /// @dev Per-guardian stake record.
    struct Guardian {
        uint128 stakedAmount;
        uint64 stakedAt;
        uint64 unstakeRequestedAt;
        uint256 agentId;
        /// @dev Cooldown value at the moment `requestUnstakeGuardian` stamped
        ///      `unstakeRequestedAt`. Used by `claimUnstakeGuardian` so the
        ///      owner can't extend lockup retroactively by raising
        ///      `coolDownPeriod` mid-request.
        uint64 cooldownAtRequest;
    }

    mapping(address => Guardian) internal _guardians;
    uint256 public totalGuardianStake;

    /// @notice Minimum WOOD required for an active guardian stake.
    uint256 public minGuardianStake;

    /// @notice Cooldown between `requestUnstakeGuardian` and `claimUnstakeGuardian`.
    /// @dev Set in `initialize`.
    uint256 public coolDownPeriod;

    /// @dev Per-guardian own-stake history, keyed by timestamp. Pushed on every
    ///      state change that affects votable weight: stakeAsGuardian,
    ///      requestUnstakeGuardian (push 0), cancelUnstakeGuardian, slash.
    mapping(address => Checkpoints.Trace224) internal _stakeCheckpoints;

    /// @dev Global total-active-stake history. Mirrors `totalGuardianStake`
    ///      but indexed by timestamp for historical quorum-denominator lookups.
    Checkpoints.Trace224 internal _totalStakeCheckpoint;

    // ── Owner-bond storage ──

    /// @dev Per-vault bound owner bond.
    struct OwnerStake {
        uint128 stakedAmount;
        uint64 unstakeRequestedAt;
        address owner;
        /// @dev Cooldown value at the moment `requestUnstakeOwner` stamped
        ///      `unstakeRequestedAt`. Used by `claimUnstakeOwner` so the
        ///      owner can't extend the bond's lockup retroactively by
        ///      raising `coolDownPeriod` mid-request.
        uint64 cooldownAtRequest;
    }

    mapping(address vault => OwnerStake) internal _ownerStakes;

    /// @dev Prospective vault owner's escrowed (not-yet-bound) stake.
    struct PreparedOwnerStake {
        uint128 amount;
        uint64 preparedAt;
        bool bound;
    }

    mapping(address owner => PreparedOwnerStake) internal _prepared;

    /// @notice Minimum WOOD a vault owner must bond at vault creation.
    /// @dev Set in `initialize`.
    uint256 public minOwnerStake;

    /// @notice Floor (bps) of the deterministic slash severity.
    /// @dev The registry's `_severityBps` ramps quadratically with block-side
    ///      decisiveness from this floor (at a scraped block quorum) to
    ///      `maxSlashBps` (at 2/3 supermajority). A non-zero floor preserves
    ///      the deterrent.
    uint256 public minSlashBps;

    /// @notice Ceiling (bps) of the deterministic slash severity.
    /// @dev May be a full `10_000` (100%) — the ceiling sizes the approver's
    ///      OWN-stake slash, a plain integer subtraction with no share math
    ///      to brick.
    uint256 public maxSlashBps;

    /// @notice Vote-weight fraction (bps) of raw own stake at age 0.
    uint256 public ageFloorBps;

    /// @notice Stake age at which own-stake weight reaches par (100%).
    uint256 public maturationPeriod;

    /// @notice Slashed WOOD whose burn transfer failed, queued for retry.
    /// @dev Keyed by `address(this)`. A malicious or blacklisting WOOD that reverts
    ///      on `transfer(BURN_ADDRESS, ...)` must not be able to brick
    ///      `slashGuardians`/`slashOwnerBond` — the slash accounting has already
    ///      happened, only the burn transfer is at risk. `flushBurn` retries it.
    mapping(address => uint256) internal _pendingBurn;

    /// @dev Reserves upgrade headroom for this leaf contract, re-baselined
    ///      pre-mainnet when DPoS delegation was removed.
    ///      DECLARATION ORDER IS DELIBERATE: new fields are declared immediately
    ///      below this gap so a shrink comes off the END of it and every field
    ///      behind keeps its slot. From the first mainnet deploy onward, changes
    ///      must be append-only, carved off the FRONT of this gap.
    uint256[3] private __gap;

    /// @notice Per-guardian history of the `stakedAt` anchor, so a historical
    ///         `getPastVotes` read applies `_ageFactorBps` against the anchor AS IT
    ///         STOOD at the queried timestamp instead of the live one.
    /// @dev `stakedAt` on `Guardian` is a plain live field with no history of its
    ///      own, and it only ever moves forward, so a later top-up or
    ///      unstake-request re-anchor could silently deflate an already-past read.
    ///      This trace makes historical reads exact.
    ///
    ///      Pushed at every anchor WRITE site, same-transaction as the raw
    ///      `_stakeCheckpoints` push: first stake, top-up re-anchor, and
    ///      unstake-request re-anchor. Deliberately NOT pushed at
    ///      `cancelUnstakeGuardian` (does not write the anchor), at
    ///      `claimUnstakeGuardian` (the raw trace already reads 0 from the request
    ///      instant onward, so any historical read is zero regardless), or on any
    ///      slash path (slashing never writes `stakedAt`). An empty trace resolves
    ///      to anchor 0, and the raw trace is empty there too, so the product is 0.
    mapping(address guardian => Checkpoints.Trace224) internal _anchorCheckpoints;

    /// @notice The single vault an address consents to have its PREPARED owner
    ///         stake bound to via `transferOwnerStakeSlot`. Zero = no consent.
    /// @dev The slot transfer spends `_prepared[newOwner]`, but its only caller
    ///      authorizes `msg.sender` alone — so without an opt-in recorded BY the
    ///      incoming owner, any owner of an empty-slot vault could bind a
    ///      stranger's escrow.
    ///
    ///      At most one approved vault per address, deliberately: an address can
    ///      hold at most one prepared escrow, so an approval spanning several
    ///      vaults would model a consent the escrow cannot honor. Approving again
    ///      overwrites.
    ///
    ///      SCOPED TO ONE ESCROW LIFETIME: cleared on the successful bind, on
    ///      `cancelPreparedStake`, and on a fresh `prepareOwnerStake`. Without the
    ///      last two, an approval given for an abandoned rotation would still be
    ///      standing when the approver later escrows a NEW stake for their own
    ///      vault. An approval on its own moves nothing and locks nothing.
    mapping(address owner => address vault) public approvedBindVault;

    /// @dev Per-guardian OWN-STAKE LIABILITY history: what the guardian is on the
    ///      hook for at a past instant, as distinct from what it could VOTE with.
    ///      `_stakeCheckpoints` answers the votability question and is zeroed by
    ///      `requestUnstakeGuardian`; this one is not — sharing one trace would let
    ///      an approver discharge its liability with a reversible request sent
    ///      BEFORE the drain it voted for executes, zeroing the slash basis while
    ///      the coverage gate still credits the full bond.
    ///
    ///      Pushed on stake, on slash and on claim — every event that changes what
    ///      is actually recoverable. Deliberately NOT pushed on request/cancel,
    ///      which change only votability.
    mapping(address guardian => Checkpoints.Trace224) internal _liabilityCheckpoints;

    /// @notice The one address permitted to drive the VERDICT slash path
    ///         (`slashVerdict`). Deliberately distinct from `onlyRegistry`,
    ///         which drives the block-quorum review slash: the paths must stay
    ///         separate so the registry's `refundSlash` reserve can never
    ///         refund a proven-malice verdict. Owner-set, which makes a
    ///         verdict a governance action.
    address public authorizedSlasher;

    /// @dev One slash per (verdict, approver) — the persistent half of the severity
    ///      envelope, keyed by the RAW `caseKey` the caller passed so a slasher can
    ///      read `verdictSlashed` with the same key it will pass back in.
    ///
    ///      Why persistence is needed at all: `_slashOne` applies its rate to the
    ///      LIVE stake but sizes off the `openedAt` checkpoint, so repeats compound
    ///      geometrically — N calls at `bps` take `1-(1-bps)^N`. The intra-call
    ///      pairwise dedup bounds one array and says nothing about the next
    ///      transaction. Splitting IS the expected shape here: a 100-approver
    ///      quorum slash costs ~27M gas, so the batch has to be split to land at
    ///      all, and without this map the workaround for the gas limit silently
    ///      voids the ceiling governance set.
    mapping(bytes32 caseKey => mapping(address approver => bool)) private _verdictSlashed;

    /// @notice Coverage ledger consulted before releasing a guardian's stake.
    /// @dev    Asks the ledger directly whether a guardian's obligations have
    ///         cleared, rather than sizing `coolDownPeriod` to the worst-case
    ///         obligation any guardian could hold. FAIL-OPEN WHEN UNSET:
    ///         `claimUnstakeGuardian` behaves as if this gate did not exist, since
    ///         failing closed on a zero pointer would brick withdrawals over a
    ///         missed configuration step. Deploy scripts must assert the wiring.
    address public exposureLedger;

    /// @notice Slashed WOOD is sent here — permanently out of circulation.
    /// @dev WHAT BURN MEANS HERE, PRECISELY: WOOD exposes no `burn()`, so this is a
    ///      SUPPLY SINK, not a supply reduction — `totalSupply` never falls. The
    ///      effect is on CIRCULATING supply, and only for anyone who treats this
    ///      address as outside circulation. State any deflation claim in those
    ///      terms; a claim about `totalSupply` would be false.
    ///
    ///      Nothing in this protocol reads WOOD's `totalSupply`, so the
    ///      accumulating dead balance pollutes no internal denominator. The
    ///      exposure is purely external reporting.
    ///
    ///      Volume is CONVICTION-DRIVEN, not continuous: a healthy protocol burns
    ///      nothing, and the supply curve steps down exactly when the protocol is
    ///      being successfully attacked. There is no continuous WOOD burn source to
    ///      complement it — the only protocol fee is denominated in the vault's
    ///      asset, not in WOOD.
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Grouped `initialize` arguments. A struct keeps the call site
    ///         keyword-addressed, avoiding a swap-prone positional arg list.
    struct InitParams {
        /// @dev Contract owner (the parameter-setter multisig).
        address owner;
        /// @dev WOOD ERC20 token custodied for staking and bonds.
        address wood;
        /// @dev SyndicateFactory — sole caller authorized to `bindOwnerStake`
        ///      and the source for per-vault governor lookups (`governorOf`).
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
        /// @dev Own-stake weight fraction at age 0 (bps, [1, 10_000]).
        uint256 ageFloorBps;
        /// @dev Age at which own-stake weight reaches par ([7, 90] days).
        uint256 maturationPeriod;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.owner == address(0) || p.wood == address(0) || p.factory == address(0)) {
            revert ZeroAddress();
        }
        __Ownable_init(p.owner);
        wood = IERC20(p.wood);
        factory = p.factory;
        minGuardianStake = p.minGuardianStake;
        coolDownPeriod = p.coolDownPeriod;
        // Same admission rule `setMinOwnerStake` enforces, applied at deploy
        // time too: `0` stays the open-onboarding sentinel, any NONZERO value
        // must clear the 1_000 WOOD dust floor. Without this a deploy could
        // seat a token-dust floor that no later setter would ever accept.
        if (p.minOwnerStake != 0 && p.minOwnerStake < MIN_OWNER_BOND_FLOOR) revert InvalidParameter();
        minOwnerStake = p.minOwnerStake;
        // Severity ceiling may be a full 100% (own stake is a plain integer
        // subtraction with no share math to brick).
        if (p.minSlashBps > p.maxSlashBps || p.maxSlashBps > 10_000) {
            revert InvalidParameter();
        }
        minSlashBps = p.minSlashBps;
        maxSlashBps = p.maxSlashBps;
        if (p.ageFloorBps == 0 || p.ageFloorBps > 10_000) revert InvalidParameter();
        ageFloorBps = p.ageFloorBps;
        if (p.maturationPeriod < 7 days || p.maturationPeriod > 90 days) revert InvalidParameter();
        maturationPeriod = p.maturationPeriod;
    }

    function setRegistry(address registry_) external onlyOwner {
        if (_registrySet) revert RegistryAlreadySet();
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
        _registrySet = true;
    }

    /// @dev Active iff the guardian holds ANY nonzero stake and has no pending
    ///      unstake request. `minGuardianStake` is an ENTRY requirement, not a
    ///      continuing one: `stakeAsGuardian` is its only enforcer. A guardian CAN
    ///      sit below the minimum and remain active, two ways:
    ///        1. SLASHING. `_slashOne` reduces `stakedAmount` to any positive
    ///           residual and keeps the guardian on its still-active branch, so
    ///           one ground down to 1 wei keeps voting rights.
    ///        2. A RAISED FLOOR. Governance can raise `minGuardianStake`,
    ///           stranding every guardian who entered under the old bar.
    ///
    ///      THIS IS DELIBERATE, AND THE PREDICATE MUST NOT BE MADE MIN-AWARE ON ITS
    ///      OWN. `totalGuardianStake` is the quorum denominator, and `_slashOne`
    ///      decrements it ONLY on the branch where the guardian is still active.
    ///      Adding `stakedAmount >= minGuardianStake` here without simultaneously
    ///      moving that stake out of the aggregate leaves stake in the denominator
    ///      that can no longer produce a ballot, so quorum becomes harder to reach
    ///      than intended — unreachable, if enough is stranded. Any future change
    ///      must deactivate AND decrement in the same step, and must decide what
    ///      happens to guardians stranded by case 2, for whom no slash ever fires.
    ///
    ///      ACCEPTED CONSEQUENCE: a sub-minimum guardian still consumes one of the
    ///      capped review seats. Their INFLUENCE is negligible — vote weight is
    ///      stake-proportional — but the SEAT is real, so seat exhaustion is the
    ///      residual surface here rather than vote capture. Pinned by
    ///      `test_isActiveGuardian_staysActiveBelowMinStake_byDesign`.
    function _isActiveGuardian(address g) internal view returns (bool) {
        Guardian storage gs = _guardians[g];
        return gs.stakedAmount > 0 && gs.unstakeRequestedAt == 0;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    /// @dev Gate on the VERDICT slash path. Distinct from `onlyRegistry` by
    ///      design — the review slash and the verdict slash must never share
    ///      a caller role, so the registry's appeal reserve can never refund
    ///      a proven-malice verdict.
    modifier onlyAuthorizedSlasher() {
        if (msg.sender != authorizedSlasher) revert NotAuthorizedSlasher();
        _;
    }

    // ── Guardian staking ──

    /// @notice Stake WOOD as a guardian (or top up an existing stake).
    /// @dev Idempotent top-up: on first stake records `agentId` and activates
    ///      the guardian; on subsequent calls the `agentId` arg is ignored.
    ///      A top-up re-anchors `stakedAt` to the stake-weighted average
    ///      timestamp — new WOOD matures pro-rata rather than inheriting the
    ///      position's age.
    function stakeAsGuardian(uint256 amount, uint256 agentId) external nonReentrant {
        // Stake intentionally not gated by pause: guardians must be able to
        // manage their position (stake/unstake/claim) even during an incident.
        Guardian storage g = _guardians[msg.sender];
        // A guardian with a pending unstake request is NOT active (see
        // `_isActiveGuardian`), so letting them top up would grow
        // `totalGuardianStake` without creating votable weight — quorum
        // denominator would outrun the real cohort. Force them to cancel the
        // unstake first.
        if (g.unstakeRequestedAt != 0) revert UnstakeAlreadyRequested();
        uint256 newTotal = uint256(g.stakedAmount) + amount;
        if (newTotal < minGuardianStake) revert InsufficientStake();

        wood.safeTransferFrom(msg.sender, address(this), amount);

        bool wasInactive = g.stakedAmount == 0;
        if (wasInactive) {
            g.stakedAt = uint64(block.timestamp);
            g.agentId = agentId; // recorded once; ignored on top-ups
        } else {
            // Weighted-average age re-anchor: a top-up ages in pro-rata instead of
            // inheriting the old tranche's full age, closing the stake-dust-early-
            // top-up-later hole. Ceil-divide so rounding moves toward `now` and
            // never grants free age. The checked `*` reverts on overflow rather
            // than wrapping, and for any realistic WOOD supply both products stay
            // well under 2^192.
            uint256 num = uint256(g.stakedAmount) * uint256(g.stakedAt) + amount * block.timestamp;
            // Lossless cast: `num` is a stake-weighted average of two
            // timestamps (`stakedAt <= now` and `block.timestamp`), and the
            // ceil-divide by `newTotal` keeps the result <= block.timestamp,
            // which fits uint64 (as does every timestamp this contract sees).
            // forge-lint: disable-next-line(unchecked-cast)
            g.stakedAt = uint64((num + newTotal - 1) / newTotal);
        }
        g.stakedAmount = uint128(newTotal);
        totalGuardianStake += amount;

        // Checkpoint votable stake for historical quorum lookups.
        _stakeCheckpoints[msg.sender].push(uint32(block.timestamp), uint224(newTotal));
        // New capital is recoverable from this instant on, so liability moves
        // with it. The two traces agree here; they diverge only across an
        // unstake request.
        _liabilityCheckpoints[msg.sender].push(uint32(block.timestamp), uint224(newTotal));
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));
        // Issue #82: checkpoint the anchor `g.stakedAt` just finalized above
        // (first-stake or the weighted-average top-up re-anchor, whichever
        // branch ran) so a historical `getPastVotes` read sees the anchor AS
        // IT STOOD at the queried timestamp, not the live one.
        _anchorCheckpoints[msg.sender].push(uint32(block.timestamp), uint224(g.stakedAt));

        emit GuardianStaked(msg.sender, amount, agentId);
    }

    /// @notice A guardian's current own stake.
    function guardianStake(address guardian) external view returns (uint256) {
        return _guardians[guardian].stakedAmount;
    }

    /// @dev Linear discount-to-par age factor (bps of raw stake). Weight ramps from
    ///      `ageFloorBps` at age 0 to par at `maturationPeriod`, then plateaus —
    ///      never exceeds raw stake, so the raw checkpointed totals remain a valid
    ///      conservative quorum denominator. `stakedAt_` is always the anchor AS OF
    ///      the queried timestamp, resolved from `_anchorCheckpoints`, so
    ///      `ts < stakedAt_` does not arise for a historical read.
    function _ageFactorBps(uint64 stakedAt_, uint256 ts) internal view returns (uint256) {
        if (stakedAt_ == 0) return ageFloorBps; // never staked in this era
        uint256 age = ts > stakedAt_ ? ts - uint256(stakedAt_) : 0;
        uint256 m = maturationPeriod;
        if (age >= m) return 10_000;
        return ageFloorBps + ((10_000 - ageFloorBps) * age) / m;
    }

    /// @notice A guardian's total votable weight at a past timestamp.
    /// @dev Votes = AGE-WEIGHTED own checkpointed stake at `timestamp`: the raw
    ///      checkpoint discounted by `_ageFactorBps`, dropping to 0 once the
    ///      guardian requests unstake. Totals (`getPastTotalVotes`,
    ///      `getPastTotalSupply`) deliberately stay RAW — aging only shrinks
    ///      numerators, so the raw denominator is conservative.
    /// @dev ANCHOR-EXACT HISTORICAL READS. The age factor is applied against
    ///      `_anchorCheckpoints[guardian]` AS OF `timestamp`, not the live
    ///      `stakedAt`, so a later re-anchor can neither inflate nor deflate an
    ///      already-past read. At the current timestamp the checkpointed anchor IS
    ///      the live anchor, so `getVotes` is bit-identical. One qualification:
    ///      `_ageFactorBps` still reads the LIVE `ageFloorBps`/`maturationPeriod`,
    ///      so a historical evaluation uses today's parameter values — an existing,
    ///      owner-timelocked exposure this trace does not change either way.
    function getPastVotes(address guardian, uint256 timestamp) public view returns (uint256) {
        uint256 rawOwn = _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp));
        uint64 anchor = uint64(_anchorCheckpoints[guardian].upperLookupRecent(uint32(timestamp)));
        return rawOwn * _ageFactorBps(anchor, timestamp) / 10_000;
    }

    /// @notice A guardian's RAW votable own stake at a past timestamp — the same
    ///         basis `getPastTotalVotes` is a sum of.
    /// @dev    ITS COUNTERPART `getPastVotes` IS NOT: that one applies
    ///         `_ageFactorBps` on top, so it is WOOD-scaled but is not a term of
    ///         the total.
    ///
    ///         `TokenCourt._participationFloor` subtracts the accused cohort from
    ///         the electorate using this getter rather than `getPastVotes`, so the
    ///         accused sum can never exceed the total AT THE SAME TIMESTAMP — both
    ///         traces are pushed in the same transaction at every mutation site.
    ///         The raw basis also denies the accused a lever on its own conviction
    ///         threshold: an aged basis would let an accused approver call
    ///         `requestUnstakeGuardian` between the drain and `refer`, re-anchoring
    ///         its `stakedAt` and flooring its own contribution — shrinking the
    ///         subtrahend, raising the participation floor, and pushing a case the
    ///         accused was certain to lose into `Inconclusive`. This getter reads
    ///         the checkpointed amount directly, with no re-anchorable factor.
    function getPastStake(address guardian, uint256 timestamp) public view returns (uint256) {
        return _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp));
    }

    /// @notice Total guardian vote weight (quorum denominator) at a past timestamp.
    /// @dev Reads the global total-active-stake checkpoint trace.
    function getPastTotalVotes(uint256 timestamp) public view returns (uint256) {
        return _totalStakeCheckpoint.upperLookupRecent(uint32(timestamp));
    }

    // Snapshot-compatible vote-read surface. `getVotes` / `getPastVotes` /
    // `getPastTotalSupply` give Snapshot's `erc20-votes` strategy the read surface
    // it consumes, since `WoodToken` does not inherit `ERC20Votes`. sWOOD
    // intentionally does NOT implement the full OZ `IVotes` interface (no
    // delegation). Vote weight is age-weighted own staked WOOD, zero once unstake
    // is requested; totals stay raw.

    /// @notice An account's CURRENT vote weight — the live counterpart of
    ///         `getPastVotes`.
    /// @dev Delegates to `getPastVotes(account, block.timestamp)`. The checkpoint
    ///      traces are pushed on every votable-weight change with key
    ///      `uint32(block.timestamp)`, and `upperLookupRecent` includes a
    ///      checkpoint written in the current block, so a same-block lookup returns
    ///      the live value.
    function getVotes(address account) external view returns (uint256) {
        return getPastVotes(account, block.timestamp);
    }

    /// @notice Total system vote weight at a past timestamp — the denominator a
    ///         Snapshot quorum/total would use.
    /// @dev Delegates to `getPastTotalVotes(timestamp)` — the RAW
    ///      (conservative) counterpart of the per-account reads: the
    ///      age-weighted `getPastVotes` values sum to AT MOST this total, so
    ///      it remains a valid quorum denominator.
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256) {
        return getPastTotalVotes(timestamp);
    }

    /// @notice True iff `guardian` holds any nonzero stake and has no pending
    ///         unstake request. NOT a `minGuardianStake` check — that floor
    ///         gates entry only, so a slashed-down or floor-raised guardian
    ///         reads active here. See `_isActiveGuardian` for why that is
    ///         deliberate and what a corrected version would have to change
    ///         alongside it.
    function isActiveGuardian(address guardian) external view returns (bool) {
        return _isActiveGuardian(guardian);
    }

    // ── Parameter setters (owner-instant; the owner is a multisig with an
    //    external delay, so an on-chain timelock would double-count it) ──

    /// @notice Set the minimum WOOD required for an active guardian stake.
    /// @dev Owner-only.
    function setMinGuardianStake(uint256 v) external onlyOwner {
        if (v < 1e18) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MIN_GUARDIAN_STAKE, minGuardianStake, v);
        minGuardianStake = v;
    }

    /// @notice Set the guardian unstake cooldown period.
    /// @dev Owner-only. Enforces the absolute `[1 days, 30 days]` bounds AND the
    ///      `coolDownPeriod >= reviewPeriod` cross-contract invariant: once the
    ///      registry is wired, the cooldown may not drop below the review window,
    ///      so a guardian cannot unstake and escape the slash before
    ///      `resolveReview` runs. Guarded behind `registry != address(0)` so a
    ///      not-yet-wired sWOOD does not revert.
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
    /// @dev Owner-only. `v == 0` is the deliberate open-onboarding sentinel — a 0-WOOD
    ///      creator can then open a vault (`bindOwnerStake` binds a zero bond).
    ///      Any nonzero value still floors at `MIN_OWNER_BOND_FLOOR` so a
    ///      token-dust bond can't be set by mistake.
    ///
    ///      SCOPE OF THE SENTINEL: it governs vault CREATION only. It does NOT
    ///      reach `requiredOwnerBond`, which floors at `MIN_OWNER_BOND_FLOOR`
    ///      unconditionally — open onboarding lets anyone open a vault without a
    ///      bond, it does not hand them the owner-supplied emergency-settle
    ///      escape hatch for free. See `requiredOwnerBond`.
    function setMinOwnerStake(uint256 v) external onlyOwner {
        if (v != 0 && v < MIN_OWNER_BOND_FLOOR) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MIN_OWNER_STAKE, minOwnerStake, v);
        minOwnerStake = v;
    }

    /// @notice Set the floor of the deterministic slash severity.
    /// @dev Owner-only. Must keep `minSlashBps <= maxSlashBps`, where
    ///      `maxSlashBps <= 10_000` (a full-100% own-stake ceiling is legal).
    ///      So this only needs to gate against `v > maxSlashBps`.
    function setMinSlashBps(uint256 v) external onlyOwner {
        if (v > maxSlashBps) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MIN_SLASH_BPS, minSlashBps, v);
        minSlashBps = v;
    }

    /// @notice Set the upper clamp bound for the slash severity.
    /// @dev Owner-only. `10_000` (100%) is legal for the OWN-stake ceiling.
    ///      Must keep `minSlashBps <= maxSlashBps`.
    function setMaxSlashBps(uint256 v) external onlyOwner {
        if (v < minSlashBps || v > 10_000) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MAX_SLASH_BPS, maxSlashBps, v);
        maxSlashBps = v;
    }

    /// @notice Set the age-0 weight floor.
    function setAgeFloorBps(uint256 v) external onlyOwner {
        if (v == 0 || v > 10_000) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_AGE_FLOOR_BPS, ageFloorBps, v);
        ageFloorBps = v;
    }

    /// @notice Set the age at which own-stake weight reaches par.
    function setMaturationPeriod(uint256 v) external onlyOwner {
        if (v < 7 days || v > 90 days) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_MATURATION_PERIOD, maturationPeriod, v);
        maturationPeriod = v;
    }

    // ── Guardian unstake cooldown ──

    /// @notice Request to unstake guardian WOOD; starts the cooldown.
    /// @dev Immediately revokes voting power by zeroing the guardian's contribution to
    ///      `totalGuardianStake`. WOOD stays in the contract until
    ///      `claimUnstakeGuardian` after `coolDownPeriod`.
    function requestUnstakeGuardian() external {
        Guardian storage g = _guardians[msg.sender];
        if (g.stakedAmount == 0) revert NoActiveStake();
        if (g.unstakeRequestedAt != 0) revert UnstakeAlreadyRequested();

        g.unstakeRequestedAt = uint64(block.timestamp);
        // Freeze the cooldown at request time so the owner can't extend
        // lockup retroactively.
        // forge-lint: disable-next-line(unchecked-cast)
        g.cooldownAtRequest = uint64(coolDownPeriod);
        // Age clock re-anchors to the request timestamp: pre-request age is
        // forfeited, but maturation DOES keep accruing from this instant
        // onward — including through the cooldown. So a request → (wait) →
        // cancel round-trip returns a stake aged from the request, not from
        // the original stake and not from the cancel: waiting out the
        // cooldown is not penalized, only the pre-request age is dropped.
        g.stakedAt = uint64(block.timestamp);
        totalGuardianStake -= g.stakedAmount;

        // Unstake-requested stake is not votable, so push 0.
        // `_liabilityCheckpoints` IS DELIBERATELY NOT PUSHED HERE. A request
        // revokes voting power; it does not settle what the guardian already
        // underwrote, and the WOOD is still in this contract —
        // `claimUnstakeGuardian` is where liability drops.
        _stakeCheckpoints[msg.sender].push(uint32(block.timestamp), 0);
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));
        // Issue #82: the re-anchor above is a `stakedAt` write like any
        // other — checkpoint it so a historical read at or after the
        // request sees this anchor, not a later one.
        _anchorCheckpoints[msg.sender].push(uint32(block.timestamp), uint224(g.stakedAt));

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
        // Use cooldown frozen at request time.
        if (block.timestamp < uint256(g.unstakeRequestedAt) + uint256(g.cooldownAtRequest)) {
            revert CooldownNotElapsed();
        }
        // GATE ON THE CLAIM, NOT THE REQUEST. Requesting stays open at any time
        // and is behaviour to encourage: it marks the guardian inactive
        // immediately, so they take on no NEW commitments while existing ones run
        // down. It is the moment the stake actually leaves that has to wait.
        //
        // The cooldown above still earns its place — it covers the REVIEW path
        // (`coolDownPeriod >= reviewPeriod`), which the ledger knows nothing about.
        // This check covers the challenge path. Neither subsumes the other.
        address ledger = exposureLedger;
        if (ledger != address(0)) {
            // TWO QUESTIONS, NOT ONE. `openExposure` sums epoch buckets that age
            // out on pure wall-clock and do not pause because the guardian is under
            // accusation. The challenge game's disputed tail outlives that by
            // design, so an accused approver could request at execution, wait out
            // the cooldown, and claim its whole bond before the challenge resolves.
            // A frozen commitment is the accusation itself, and it does not expire
            // on a clock.
            ILedgerExposureMinimal l = ILedgerExposureMinimal(ledger);
            if (l.openExposure(msg.sender) != 0 || l.hasFrozenCoverage(msg.sender)) {
                revert CoverageStillOpen();
            }
        }

        uint256 amount = g.stakedAmount;
        delete _guardians[msg.sender];
        // THE MOMENT LIABILITY ACTUALLY ENDS. Every gate above has cleared, so
        // the capital is leaving and nothing further is recoverable from it —
        // this, not the request, is where the liability trace drops to zero.
        _liabilityCheckpoints[msg.sender].push(uint32(block.timestamp), 0);

        wood.safeTransfer(msg.sender, amount);

        emit GuardianUnstakeClaimed(msg.sender, amount);
    }

    // ── Owner-bond prepare/bind ──

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
        // A new escrow lifetime starts here, so any consent left over from the
        // previous one is void — otherwise an approval granted for a rotation
        // that never happened could be replayed against THIS stake.
        delete approvedBindVault[msg.sender];

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
        // The escrow this consent was scoped to is gone; the consent goes with
        // it (see `approvedBindVault`).
        delete approvedBindVault[msg.sender];

        wood.safeTransfer(msg.sender, amount);

        emit PreparedStakeCancelled(msg.sender, amount);
    }

    /// @notice Consent to having your prepared owner stake bound to `vault` by a
    ///         factory owner-rotation.
    /// @dev `rotateOwner` names the incoming owner as a bare parameter and is
    ///      authorized against the OUTGOING owner only, so without this the owner
    ///      of an empty-slot vault could rotate it onto whoever currently holds a
    ///      prepared stake and spend that stranger's escrow. Recording the
    ///      approval from the escrow holder's own `msg.sender` makes the bind
    ///      consensual.
    ///
    ///      One approved vault per address; calling again overwrites. The approval
    ///      survives until consumed, revoked, or cleared by the escrow lifecycle —
    ///      including across a front-run revoke, since a rotation that lands first
    ///      lands on a consent that was granted and not yet withdrawn.
    function approveOwnerStakeBinding(address vault) external {
        if (vault == address(0)) revert ZeroAddress();

        approvedBindVault[msg.sender] = vault;

        emit OwnerStakeBindingApproved(msg.sender, vault);
    }

    /// @notice Withdraw a previously granted binding consent.
    /// @dev A no-op consent (nothing approved) is not an error — the
    ///      post-condition callers care about is "no standing approval", and
    ///      reverting would only make the safe state harder to reach.
    /// @dev nonReentrant omitted — no external calls, no value movement.
    function revokeOwnerStakeBinding() external {
        address vault = approvedBindVault[msg.sender];
        delete approvedBindVault[msg.sender];

        emit OwnerStakeBindingRevoked(msg.sender, vault);
    }

    /// @notice Bind a prepared owner stake to a newly created vault.
    /// @dev Consumes `_prepared[owner_]` and binds it to `_ownerStakes[vault]`.
    ///      Called by `SyndicateFactory.createSyndicate` after the vault address is
    ///      known. At factory-creation time `totalAssets()` is 0, so only the
    ///      `minOwnerStake` floor applies. At `minOwnerStake == 0` a 0-WOOD creator
    ///      who never prepared binds a zero bond, and the empty prepared slot is
    ///      NOT consumed, so they can open more vaults.
    /// @dev DEFENCE IN DEPTH — `PriorStakeNotCleared`. Binding over a vault that
    ///      already holds a live owner bond would drop the prior owner's record on
    ///      the floor and strand their WOOD, since both unstake paths key on
    ///      `s.owner == msg.sender`. Unreachable today — the sole call site targets
    ///      a freshly derived CREATE3 address — so this costs one SLOAD to make a
    ///      fund-stranding overwrite impossible rather than merely unreached.
    /// @dev NO `approvedBindVault` CHECK HERE, deliberately: consent is STRUCTURAL
    ///      on this path, since `createSyndicate` passes its own `msg.sender` as
    ///      `owner_`. The consent guard in `transferOwnerStakeSlot` exists because
    ///      THAT path takes the incoming owner as a parameter chosen by someone
    ///      else.
    function bindOwnerStake(address owner_, address vault) external onlyFactory {
        if (_ownerStakes[vault].stakedAmount != 0) revert PriorStakeNotCleared();

        PreparedOwnerStake storage p = _prepared[owner_];
        if (p.bound) revert PreparedStakeNotFound();
        if (p.amount < minOwnerStake) revert OwnerBondInsufficient();

        _ownerStakes[vault] =
            OwnerStake({stakedAmount: p.amount, unstakeRequestedAt: 0, owner: owner_, cooldownAtRequest: 0});
        if (p.amount != 0) p.bound = true;

        emit OwnerStakeBound(owner_, vault, p.amount);
    }

    /// @notice Vault owner signals intent to exit; starts the unstake cooldown.
    /// @dev Blocked while the vault has any open proposal, to prevent rage-quit
    ///      around malicious executions. `openProposalCount` tracks every
    ///      non-terminal state — a `getActiveProposal` check alone would only cover
    ///      Executed and let a malicious owner propose a draining strategy and
    ///      rage-quit before execution. The OR against `getActiveProposal` is
    ///      belt-and-braces so any stale-cache window still reverts.
    function requestUnstakeOwner(address vault) external {
        OwnerStake storage s = _ownerStakes[vault];
        if (s.owner != msg.sender || s.stakedAmount == 0) revert NoActiveStake();
        if (s.unstakeRequestedAt != 0) revert UnstakeAlreadyRequested();
        address vaultGov = IFactoryGovernorLookup(factory).governorOf(vault);
        if (vaultGov != address(0)) {
            IGovernorMinimal gov = IGovernorMinimal(vaultGov);
            if (gov.openProposalCount() != 0 || gov.getActiveProposal() != 0) {
                revert VaultHasActiveProposal();
            }
        }

        s.unstakeRequestedAt = uint64(block.timestamp);
        // Freeze cooldown at request time.
        // forge-lint: disable-next-line(unchecked-cast)
        s.cooldownAtRequest = uint64(coolDownPeriod);

        emit OwnerUnstakeRequested(vault, block.timestamp);
    }

    /// @notice Cancel a pending owner-bond unstake request.
    /// @dev Reverses `requestUnstakeOwner`: the slot goes back to live and
    ///      `ownerBondLive` returns true again, so the vault's proposal lane
    ///      reopens. Mirrors `cancelUnstakeGuardian`.
    /// @dev THE REVERSIBILITY THE PROPOSE GATE NEEDS (SHE-215). Once
    ///      `requestUnstakeOwner` closes the proposal lane, an owner who
    ///      changes their mind had no way back except claiming the bond (which
    ///      leaves the lane shut) and then a two-transaction `rotateOwner` ->
    ///      `transferOwnerStakeSlot`. Without this, a single exploratory
    ///      request would strand a live vault's agents for the whole cooldown.
    /// @dev A SLASHED SLOT CANNOT BE CANCELLED BACK TO LIFE. If the bond was
    ///      slashed between the request and now, `slashOwnerBond` deleted the
    ///      record entirely, so `s.owner` is zero and `NoActiveStake` fires on
    ///      the first check — the same "nothing to restore" reasoning
    ///      `cancelUnstakeGuardian` spells out, reached one field earlier
    ///      because the owner path deletes rather than zeroes.
    /// @dev nonReentrant omitted — no external calls, no value movement.
    function cancelUnstakeOwner(address vault) external {
        OwnerStake storage s = _ownerStakes[vault];
        if (s.owner != msg.sender || s.stakedAmount == 0) revert NoActiveStake();
        if (s.unstakeRequestedAt == 0) revert UnstakeNotRequested();

        s.unstakeRequestedAt = 0;
        s.cooldownAtRequest = 0;

        emit OwnerUnstakeCancelled(vault, msg.sender);
    }

    /// @notice Claim a vault owner's bond after the cooldown has elapsed.
    /// @dev Releases WOOD to the recorded owner and deletes `_ownerStakes[vault]`
    ///      entirely — `ownerBondLive(vault)` then reads false, and
    ///      `SyndicateGovernor.propose` / `executeProposal` refuse until the
    ///      slot is re-funded. The lane in fact closes one step EARLIER, at
    ///      `requestUnstakeOwner`, since a bond already committed to leaving is
    ///      not collateral behind anything (SHE-215).
    /// @dev RE-FUNDING THE SLOT: `bindOwnerStake` is reachable only from
    ///      `createSyndicate`, i.e. once per vault at birth. The single route back
    ///      to a funded slot on a LIVE vault is `rotateOwner` ->
    ///      `transferOwnerStakeSlot`, which consumes the incoming owner's
    ///      `prepareOwnerStake` — and the incoming owner may be the outgoing one.
    function claimUnstakeOwner(address vault) external {
        OwnerStake storage s = _ownerStakes[vault];
        if (s.owner != msg.sender || s.stakedAmount == 0) revert NoActiveStake();
        if (s.unstakeRequestedAt == 0) revert UnstakeNotRequested();
        // Use cooldown frozen at request time.
        if (block.timestamp < uint256(s.unstakeRequestedAt) + uint256(s.cooldownAtRequest)) {
            revert CooldownNotElapsed();
        }
        // Re-check open proposals at claim time. The gate in
        // `requestUnstakeOwner` only fires once; without this re-check an owner who
        // is also a registered agent could request when clean, wait through
        // cooldown, then in a single transaction propose a draining strategy and
        // claim their bond — leaving the slash to find `stakedAmount == 0`.
        address vaultGov2 = IFactoryGovernorLookup(factory).governorOf(vault);
        if (vaultGov2 != address(0) && IGovernorMinimal(vaultGov2).openProposalCount() != 0) {
            revert VaultHasActiveProposal();
        }

        uint256 amount = s.stakedAmount;
        address recipient = s.owner;
        delete _ownerStakes[vault];

        wood.safeTransfer(recipient, amount);

        emit OwnerUnstakeClaimed(vault, recipient, amount);
    }

    /// @notice Re-point a vault's owner-stake slot to a new owner.
    /// @dev Reassigns `_ownerStakes[vault]` to `newOwner`'s prepared stake after the
    ///      previous owner's stake has been slashed or fully unstaked. `newOwner`
    ///      must have called `prepareOwnerStake` with at least `minOwnerStake`.
    /// @dev CONSENT REQUIRED: `newOwner` must have called
    ///      `approveOwnerStakeBinding(vault)` first, else `BindingNotApproved` —
    ///      the caller of the factory's `rotateOwner` is the OUTGOING owner, so
    ///      `newOwner` is a parameter picked by someone else. The approval is
    ///      single-use and consumed here, so a rotation is two transactions across
    ///      two contracts.
    function transferOwnerStakeSlot(address vault, address newOwner) external onlyFactory {
        OwnerStake storage existing = _ownerStakes[vault];
        address oldOwner = existing.owner;
        if (existing.stakedAmount != 0) revert PriorStakeNotCleared();

        PreparedOwnerStake storage p = _prepared[newOwner];
        if (p.amount == 0 || p.bound) revert PreparedStakeNotFound();
        if (p.amount < minOwnerStake) revert OwnerBondInsufficient();
        if (approvedBindVault[newOwner] != vault) revert BindingNotApproved();

        _ownerStakes[vault] =
            OwnerStake({stakedAmount: p.amount, unstakeRequestedAt: 0, owner: newOwner, cooldownAtRequest: 0});
        p.bound = true;
        // Consume: one consent authorizes exactly one bind.
        delete approvedBindVault[newOwner];

        emit OwnerStakeSlotTransferred(vault, oldOwner, newOwner);
    }

    /// @notice The owner bond a vault must hold to open an owner-supplied
    ///         emergency settle.
    /// @dev TVL scaling is not implemented in V1; the bond is
    ///      `max(minOwnerStake, MIN_OWNER_BOND_FLOOR)`. The `vault` parameter is
    ///      retained for ABI / forward-compatibility. Declared as an explicit
    ///      view so callers (`GovernorEmergency`, `SyndicateFactory`) can
    ///      repoint registry → sWOOD without depending on storage-variable
    ///      visibility.
    ///
    ///      WHY THE FLOOR IS UNCONDITIONAL, i.e. why this does NOT honour the
    ///      `minOwnerStake == 0` open-onboarding sentinel. The consumer that
    ///      matters is `GovernorEmergency.emergencySettleWithCalls`'s gate
    ///      `ownerStake(vault) < requiredOwnerBond(vault)`. Returning
    ///      `minOwnerStake` verbatim made that gate evaluate `0 < 0` — false —
    ///      for every vault created under the sentinel, so the gate passed with
    ///      NO bond posted, `bindOwnerStake` had bound a zero-amount stake, and
    ///      `slashOwnerBond` returned early on `amount == 0`: a complete no-op
    ///      deterrent that, because the slot is deleted after any successful
    ///      slash, kept passing forever. What it was deterring is
    ///      `finalizeEmergencySettle`, which runs OWNER-SUPPLIED calldata with
    ///      EMPTY per-call caps (`BatchExecutorLib` metering off entirely),
    ///      bounded only by `effectiveMaxCapital` — up to 100% of vault assets.
    ///
    ///      Splitting the two decisions is the fix: the sentinel keeps meaning
    ///      "anyone may OPEN a vault" (`bindOwnerStake` / `prepareOwnerStake` /
    ///      `canCreateVault` all still read `minOwnerStake` directly and are
    ///      untouched), while the escape hatch always costs a slashable bond.
    ///      A zero-bond vault is not stranded by this: `unstick` replays the
    ///      already-voted settlement batch with no bond requirement, and the
    ///      route back to a funded slot is `rotateOwner` →
    ///      `transferOwnerStakeSlot`, whose incoming owner may be the outgoing
    ///      one.
    ///
    ///      TVL SCALING IS STILL NOT IMPLEMENTED and is deliberately out of
    ///      scope here: a bond proportional to vault assets changes the value
    ///      `bindOwnerStake`/`transferOwnerStakeSlot` must check at bind time
    ///      (when `totalAssets()` is 0) versus at emergency time, i.e. it needs
    ///      a top-up path on a live vault that does not exist today. A flat
    ///      floor is a strictly smaller change than that, and it is what closes
    ///      the zero-bond hole.
    function requiredOwnerBond(address vault) external view returns (uint256) {
        vault; // unused — no TVL scaling in V1.
        uint256 v = minOwnerStake;
        return v < MIN_OWNER_BOND_FLOOR ? MIN_OWNER_BOND_FLOOR : v;
    }

    /// @notice A vault's bound owner stake.
    function ownerStake(address v) external view returns (uint256) {
        return _ownerStakes[v].stakedAmount;
    }

    /// @notice True iff `v`'s owner-stake slot is bound and not exiting.
    /// @dev The predicate `SyndicateGovernor.propose` / `executeProposal` gate
    ///      on (SHE-215). `claimUnstakeOwner` promised a grace period in which
    ///      "new proposals cannot be created until the slot is re-funded" and
    ///      nothing enforced it: `_propose` never read the owner bond, so an
    ///      owner who is also a registered agent could claim their bond in a
    ///      quiet gap and then propose and execute on a fully unbonded vault.
    ///
    ///      TWO CLAUSES, AND BOTH ARE LOAD-BEARING.
    ///
    ///      `s.owner != address(0)` is the SLOT-EXISTS test, and it is
    ///      deliberately not `stakedAmount != 0`. `minOwnerStake == 0` is a
    ///      documented open-onboarding sentinel under which `bindOwnerStake`
    ///      binds a zero-amount stake with a real owner — a vault that never
    ///      posted a bond and was never meant to. Keying on the amount would
    ///      brick the proposal lane of every such vault at birth, which is not
    ///      the state this closes. Both routes that empty a funded slot
    ///      (`claimUnstakeOwner`, `slashOwnerBond`) `delete` the record, so
    ///      they zero the owner too and are caught; the route back is
    ///      `rotateOwner` -> `transferOwnerStakeSlot`, exactly as
    ///      `claimUnstakeOwner`'s natspec describes.
    ///
    ///      `s.unstakeRequestedAt == 0` closes the lane one step EARLIER than
    ///      the claim. A bond inside its exit cooldown is already committed to
    ///      leaving, and the whole reason `claimUnstakeOwner` re-checks
    ///      `openProposalCount()` is that a gate which fires once can be walked
    ///      around by changing the state it measured. Reading the request stamp
    ///      here means there is no window in which a proposal can be opened
    ///      against collateral whose exit is already in flight. Reversible via
    ///      `cancelUnstakeOwner`.
    ///
    ///      NOT `>= requiredOwnerBond`, deliberately, and for the same reason
    ///      `GovernorEmergency.finalizeEmergencySettle` refuses that
    ///      comparison: the threshold is governance-mutable and there is no
    ///      top-up path on a live vault, so a raised `minOwnerStake` would
    ///      permanently brick the proposal lane of every vault correctly
    ///      bonded under the old floor. Existence is the property with no
    ///      legitimate reading.
    function ownerBondLive(address v) external view returns (bool) {
        OwnerStake storage s = _ownerStakes[v];
        return s.owner != address(0) && s.unstakeRequestedAt == 0;
    }

    /// @notice A prospective owner's escrowed prepared stake amount.
    function preparedStakeOf(address o) external view returns (uint256) {
        return _prepared[o].amount;
    }

    /// @notice True iff `o` has a prepared, unbound stake at or above the floor.
    function canCreateVault(address o) external view returns (bool) {
        return _prepared[o].amount >= minOwnerStake && !_prepared[o].bound;
    }

    /// @notice Wire the coverage ledger that gates unstake claims.
    /// @dev Settable to zero deliberately — that is the documented fail-open
    ///      state, and an operator must be able to reach it if the ledger is
    ///      ever replaced or found broken.
    function setExposureLedger(address ledger) external onlyOwner {
        exposureLedger = ledger;
        emit ExposureLedgerSet(ledger);
    }

    /// @notice Set the address permitted to drive `slashVerdict`.
    /// @dev Owner-only, and deliberately NOT `setRegistry`'s set-once shape:
    ///      the role is rewirable to a future challenge game. Zero is a valid
    ///      value — it disables the verdict path entirely.
    function setAuthorizedSlasher(address slasher) external onlyOwner {
        authorizedSlasher = slasher;
        emit AuthorizedSlasherSet(slasher);
    }

    /// @notice Whether `approver` has already been slashed under `caseKey`.
    /// @dev Read this before resuming a verdict that had to be split across
    ///      transactions (a full-quorum batch does not fit one block), so the
    ///      continuation names only approvers still owed a slash.
    function verdictSlashed(bytes32 caseKey, address approver) external view returns (bool) {
        return _verdictSlashed[caseKey][approver];
    }

    // ── Slashing (registry-gated) ──

    /// @notice Slash a set of approvers for a blocked proposal, each at its own
    ///         lock-derived rate.
    /// @dev Registry-only. Reuses the SAME per-approver own-stake leg as the
    ///      verdict path (`_slashOne`) and the same sink; the two paths differ
    ///      only in who may drive them and which instant anchors the basis.
    /// @dev THE RATE IS THE LOCK, SCALED BY SEVERITY. `GuardianRegistry.resolveReview`
    ///      supplies, per approver, `ceil(lockBps x severityBps / 10_000)` where
    ///      `lockBps` is the approver's WOOD lock for the reviewed proposal over
    ///      its slash basis at review open (`ExposureLedger.slashBpsForAt` — the
    ///      same `_slashableAt` this leg multiplies, so the two cannot drift) and
    ///      `severityBps` is the deterministic block-decisiveness ramp. So
    ///      `_slashOne`'s `mulDiv(basis, bps, 10_000)` burns AT MOST the lock,
    ///      never a rate of the whole bond: a guardian holding 2,000 WOOD that
    ///      locked 500 behind the blocked proposal loses at most 500 and keeps
    ///      1,500 staked behind its other locks. No arithmetic in this contract
    ///      changed for that — the lock/basis ratio is exactly what a
    ///      bps-of-basis leg expects. The adversary is a guardian who backed a bad
    ///      proposal with a small lock while holding a large bond: it loses the
    ///      lock scaled by severity, and never less than the floor below.
    /// @dev NO LIVE ENVELOPE ON THIS PATH, IN EITHER DIRECTION. Both bounds are
    ///      the REGISTRY's job, against the envelope it SNAPSHOTTED at review
    ///      open (`Review.minSlashBpsAtOpen` / `maxSlashBpsAtOpen` — pashov
    ///      review finding #11). Flooring against the live `minSlashBps` here
    ///      would let the owner raise what an ALREADY-DECIDED review costs the
    ///      cohort that voted under the old terms; capping against the live
    ///      `maxSlashBps` is the same hole mirrored — the owner zeroes the
    ///      ceiling between open and resolve and the burn is nullified, which
    ///      `test_finding11_severityUsesAtOpenEnvelope_notLiveSlots` pins. A
    ///      "guardian-protective" live ceiling is not protective when the same
    ///      multisig owns the registry. The one cap kept is arithmetic:
    ///      `_slashOne` multiplies by `bps / 10_000`, so a rate above 100%
    ///      would burn more than the basis; saturating at 10_000 is a constant
    ///      no role controls. Per element, never hoisted: the envelope is a
    ///      per-guardian bound, and one approver's rate must not set everyone's.
    ///      `slashVerdict` keeps its full live clamp; its caller has no at-open
    ///      snapshot to floor against.
    /// @dev `minSlashBps` REMAINS THE SINGLE DETERRENCE FLOOR OF THE LOCK MODEL —
    ///      applied upstream by `GuardianRegistry._reviewSlashRates` from the
    ///      at-open snapshot. An approver who locked 1 wei behind a blocked
    ///      proposal (rate rounds up to 1 bps) still pays the at-open
    ///      `minSlashBps` of everything it holds. A token declaration buys no
    ///      quorum weight and no token penalty, which is why the ledger needs no
    ///      separate declaration floor. Zero stays exempt: zero is the absence of
    ///      liability rather than a small amount of it — a guardian whose lock
    ///      was released by a vote change, or whose approval locked nothing, is
    ///      named in the batch and owes nothing.
    /// @dev LENGTH IS CHECKED, DUPLICATES ARE NOT. Positional alignment is the
    ///      only thing binding a guardian to its rate, so a length mismatch is a
    ///      caller bug that would otherwise slash the tail of the batch at a
    ///      stranger's rate — it reverts `SlashBpsLengthMismatch`. There is no
    ///      pairwise dedup here, unlike `slashVerdict`: the registry is the sole
    ///      caller and both approver lists it can hand over (its own vote set and
    ///      the ledger's lock set) are index-backed and unique by construction, so
    ///      the O(n^2) scan would guard against a caller that cannot exist.
    /// @param reviewKey   keccak256(abi.encode(governor, proposalId)); feeds the
    ///        `GuardianSlashed` topic.
    /// @param openedAt    The review's open anchor, ALREADY `-1`-hardened by the
    ///        registry (`Review.openedAt = block.timestamp - 1`); passed to
    ///        `_slashOne` verbatim, so the basis burned against is byte-for-byte
    ///        the one the registry sized the rates from.
    /// @param approvers   The approver addresses to slash.
    /// @param slashBpsPer Per-approver slash fractions in bps, positionally
    ///        aligned with `approvers`, already clamped by the registry into
    ///        the at-open `[minSlashBps, maxSlashBps]` envelope; saturated at
    ///        10_000 here (never the live slots); zero skips.
    /// @return total      Total WOOD burned across all approvers.
    function slashGuardians(
        bytes32 reviewKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer
    ) external onlyRegistry returns (uint256 total) {
        if (slashBpsPer.length != approvers.length) revert SlashBpsLengthMismatch();
        for (uint256 i = 0; i < approvers.length; i++) {
            // ZERO IS NOT A SEVERITY — see the natspec. Skips the cap entirely.
            uint256 requested = slashBpsPer[i];
            if (requested == 0) continue;
            // NO LIVE ENVELOPE HERE, in either direction. The registry already
            // clamped the rate into the envelope snapshotted at review open
            // (pashov review #11): re-applying the live floor would let the
            // owner raise what a decided review costs, and re-applying the
            // live CEILING would let the same owner zero `maxSlashBps` between
            // open and resolve and nullify the burn — the mirror of #11, which
            // `test_finding11_severityUsesAtOpenEnvelope_notLiveSlots` pins.
            // The only cap is the arithmetic one: `_slashOne` multiplies by
            // `bps / 10_000`, so a rate above 100% would burn more than the
            // basis. That saturation is a constant, owned by no one.
            uint256 bps = Math.min(requested, 10_000);
            total += _slashOne(reviewKey, openedAt, approvers[i], bps);
        }
        if (total == 0) return 0;
        // Checkpoint the aggregate total-stake drop once after the loop.
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));
        _burnWood(total);
    }

    /// @notice Verdict-driven slash whose proceeds are BURNED.
    /// @dev Reuses the SAME per-approver own-stake leg as the review path
    ///      (`_slashOne`) AND the same sink; the two paths differ only in who may
    ///      drive them. The slash pays no one.
    /// @dev SEVERITY ENVELOPE. Every element of `slashBpsPer` is clamped to
    ///      `[minSlashBps, maxSlashBps]` here, so the verdict path enforces the
    ///      SAME envelope as the review path. Without the clamp this would be the
    ///      one entrypoint that takes severity straight from its caller, letting a
    ///      compromised `authorizedSlasher` exceed a ceiling governance set. The
    ///      envelope binds per VERDICT, not per call: `_verdictSlashed` gives each
    ///      (caseKey, approver) pair exactly one slash, so the ceiling cannot be
    ///      compounded past by splitting one verdict across transactions.
    /// @dev THE RATE IS THE LOCK. `ExposureLedger.slashBpsFor` supplies each
    ///      approver's WOOD lock for the case over its slash basis
    ///      (`slashableStakeAt(approver, openedAt)` — the same `_slashableAt`
    ///      `_slashOne` multiplies), rounded up and saturating at 10_000. So
    ///      `_slashOne`'s `mulDiv(basis, bps, 10_000)` burns `min(lock, basis)`,
    ///      never a rate of the whole bond: a guardian holding 2,000 WOOD that
    ///      locked 500 on the convicted proposal loses 500 and keeps 1,500 staked
    ///      behind its other locks. No arithmetic in this contract changed for
    ///      that — the lock/basis ratio is exactly what a bps-of-basis leg
    ///      expects. The adversary is a guardian who backed a bad proposal with a
    ///      small lock while holding a large bond: it loses the lock, and never
    ///      less than the floor below.
    /// @dev `minSlashBps` IS A PUNITIVE FLOOR, NOT A PROPORTIONALITY RULE — AND
    ///      THE SINGLE DETERRENCE FLOOR OF THE LOCK MODEL. Any non-zero derived
    ///      rate is raised to it, so an approver who locked 1 wei behind a
    ///      convicted proposal (rate rounds up to 1 bps) still pays `minSlashBps`
    ///      of everything it holds. A token declaration buys no quorum weight and
    ///      no token penalty, which is why the ledger needs no separate
    ///      declaration floor. Deliberate: below the floor the recovery would not
    ///      cover the cost of running the case. Zero stays exempt, because zero is
    ///      the absence of liability rather than a small amount of it. The
    ///      over-slash multiple is `minSlashBps / derivedRate` and is UNBOUNDED as
    ///      the lock shrinks — one point on a hyperbola, not a cap. It no longer
    ///      moves with the WOOD price: lock and basis are both WOOD.
    /// @dev TIMESTAMP BOUND — WHAT IT DOES AND DOES NOT GUARANTEE. `openedAt` must
    ///      not be in the future. This is an HONEST-CALLER sanity bound: it catches
    ///      a mis-built verdict and keeps the `uint32` checkpoint lookup from
    ///      wrapping. It does NOT constrain a COMPROMISED `authorizedSlasher`,
    ///      which can always pass `openedAt = block.timestamp`; the integrity of
    ///      `openedAt` is exactly as trustworthy as `authorizedSlasher` itself.
    ///      Burning removes the payout a chosen-instant attack would have aimed at:
    ///      there is no snapshot and no apportionment, so a compromised slasher can
    ///      still slash the wrong people but can no longer PAY ITSELF for it.
    /// @param caseKey  Composite verdict key; feeds the `GuardianSlashed` topic.
    /// @param openedAt The verdict's open timestamp — the at-open anchor the
    ///        own-stake leg is sized against.
    /// @param approvers The approver addresses to slash.
    /// @param slashBpsPer Per-approver slash fractions in bps, positionally aligned
    ///        with `approvers` and each clamped independently. The array stays
    ///        per-approver even though the production feed supplies one uniform
    ///        rate: the clamp is a PER-GUARDIAN envelope, and zero remains
    ///        meaningful as this-approver-underwrote-nothing.
    /// @return total  Total WOOD burned across all approvers.
    function slashVerdict(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer
    ) external onlyAuthorizedSlasher returns (uint256 total) {
        if (openedAt > block.timestamp) revert VerdictNotPast();
        // DEFENSE-IN-DEPTH. `openedAt == 0` looks up `_slashableAt(., 0)`, which has
        // no checkpoint at key 0 on any real chain and so silently returns 0 for
        // every named approver: the call succeeds, emits nothing, and slashes
        // nothing. A real verdict never legitimately anchors at the zero timestamp,
        // so this can only fire on a mis-built or malicious input — but failing
        // loudly is strictly cheaper than a verdict that silently voided itself.
        if (openedAt == 0) revert InvalidParameter();
        // Positional alignment is the only thing tying a guardian to their rate,
        // so a mismatch is a caller bug, not something to absorb.
        if (slashBpsPer.length != approvers.length) revert SlashBpsLengthMismatch();
        // NO VAULT MEMBERSHIP CHECK. The factory lookup that used to stand here
        // existed to keep the escrow's ERC20Votes
        // apportionment on vaults with OZ semantics. Nothing is apportioned any
        // more — the proceeds burn — so the slash no longer needs an opinion
        // about which vault the verdict concerned, and does not take one as a
        // parameter.

        // Namespace the verdict key before it feeds the shared `GuardianSlashed`
        // topic: a raw caller-chosen `caseKey` could be crafted to collide with
        // a review path `reviewKey`, making a verdict slash indistinguishable
        // from a review slash to the off-chain process that drives the owner's
        // `refundSlash`. `VerdictSlashRouted` still carries the RAW `caseKey`,
        // so indexers join the two deterministically.
        bytes32 slashKey = keccak256(abi.encodePacked("sherwood.verdict", caseKey));

        // SAME-BLOCK TOP-UP HARDENING — see `slashableStakeAt`'s natspec.
        // `openedAt` here is a RAW instant with no caller-side `-1` pre-offset
        // (unlike `slashGuardians`' `openedAt`, which the registry already stamps
        // as `block.timestamp - 1`), so THIS caller must do the offsetting itself.
        // Computed once, outside the loop; `openedAt == 0` already reverted above.
        uint256 lookupAnchor = openedAt - 1;

        // INTRA-CALL DEDUP. Each `_slashOne` pass re-applies its clamped rate to the
        // ALREADY-REDUCED live stake, so N repeats of one approver compound to
        // `1-(1-bps)^N`, above any ceiling governance set. Pairwise over calldata
        // rather than requiring sorted input: the production feed is vote-ordered
        // and positionally rate-aligned, and approver sets are quorum-sized, so
        // O(n^2) here (2.30M gas at the cap, against ~27M for the slash itself) is
        // cheaper than every caller co-sorting two paired arrays. Zero-rate entries
        // are NOT exempt — a zero slot must not smuggle a duplicate address past.
        //
        // This bounds ONE array. The same compounding across SEPARATE calls is
        // bounded by `_verdictSlashed` below, which is the half that actually binds
        // in production, since a full-quorum batch must be split to fit in a block.
        for (uint256 i = 0; i < approvers.length; i++) {
            for (uint256 j = i + 1; j < approvers.length; j++) {
                if (approvers[i] == approvers[j]) revert DuplicateApprover();
            }
        }

        for (uint256 i = 0; i < approvers.length; i++) {
            // ZERO IS NOT A SEVERITY — it is the absence of liability, so it skips
            // the envelope entirely. `minSlashBps` is a floor on how hard a guilty
            // approver is hit, NOT a statement that everyone named in the batch owes
            // something: running 0 through the clamp would slash a guardian whose
            // commitment was released by a vote change, or whose approval landed
            // after coverage was already met.
            uint256 requested = slashBpsPer[i];
            if (requested == 0) continue;
            // PERSISTENT DEDUP. The pairwise scan above bounds one array;
            // this bounds the VERDICT. Checked after the zero-skip on
            // purpose: a zero rate takes nothing, so it must not consume the
            // approver's one slash and block a later real one.
            if (_verdictSlashed[caseKey][approvers[i]]) revert ApproverAlreadySlashed();
            // Clamped per element, not once for the batch: the envelope is a
            // per-guardian ceiling/floor on severity, so it has to bind each
            // approver's own rate. Hoisting it would let one approver's rate set
            // the envelope for everyone.
            uint256 bps = Math.min(Math.max(requested, minSlashBps), maxSlashBps);
            uint256 amt = _slashOne(slashKey, lookupAnchor, approvers[i], bps);
            // MARK ONLY A SLASH THAT LANDED. `_slashOne` returns 0 when the approver
            // has no live stake at slash time — already emptied by a concurrent
            // conviction, or exited. Writing the mark there consumes the verdict's
            // one slash on a no-op, so a retry after the guardian re-stakes (the
            // at-open basis is unchanged, so it WOULD recover) reverts and the valid
            // verdict is permanently foreclosed. The ceiling still cannot compound:
            // the mark is set on the first call that takes anything.
            if (amt == 0) continue;
            _verdictSlashed[caseKey][approvers[i]] = true;
            total += amt;
        }
        // Nothing recovered: nothing to pay, nothing to burn.
        if (total == 0) return 0;

        // NO LEG LEAVES TO A NAMED ADDRESS, and that is exactly what lets the rate
        // be punitive. A sink with no counterparty cannot over-pay anyone, so the
        // slash is free to exceed the loss. Any payee here would re-impose the
        // windfall constraint that capped it at 1x, which is why the prosecutor is
        // paid from the proposer's forfeited bond instead.
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));

        // THE SINK. Every wei taken burns. `slashGuardians` and `slashOwnerBond`
        // have always burned outright; this path used to route to a compensation
        // escrow and burn only as a fallback. With the escrow gone the fallback
        // became the rule, and the external call went with it — no allowance dance,
        // no selector allowlist deciding which reverts may burn, no child-call gas
        // to reserve, and no way for a vault read to hold a conviction hostage.
        //
        // `_burnWood` is failure-tolerant by design: a WOOD transfer that reverts or
        // returns false parks the amount in `_pendingBurn` for a permissionless
        // `flushBurn` retry. The slash accounting has already landed, so only the
        // transfer is at risk and a hostile token cannot brick a conviction.
        _burnWood(total);
        emit VerdictSlashBurned(caseKey, total);
    }

    /// @dev THE SHARED SLASH BASIS. Returns exactly what `_slashOne` recovers from
    ///      `guardian`'s own stake at `anchor`:
    ///      `min(max(liability at anchor, votableStake at anchor), liveStake)`.
    ///      LIABILITY, NOT VOTABILITY, for the snapshot leg — the liability trace is
    ///      not zeroed by `requestUnstakeGuardian`, so an approver cannot
    ///      pre-position an exit before the drain it voted for and make its own
    ///      conviction recover nothing. Maxed with the votable trace so the read
    ///      degrades gracefully over history written before the liability trace
    ///      existed, and clamped to LIVE stake so a concurrent slash is not
    ///      double-recovered. One implementation for both the verdict slash and the
    ///      public view, so what a coverage reader books and what a conviction takes
    ///      cannot drift apart.
    /// @dev SAME-BLOCK TOP-UP HARDENING LIVES AT THE CALLERS, NOT HERE. This stays a
    ///      PLAIN, inclusive lookup at whatever `anchor` it is given, which is
    ///      exactly right for a caller whose `anchor` is ALREADY the instant
    ///      strictly before the event it guards — e.g. `slashGuardians`' `openedAt`,
    ///      stamped as `block.timestamp - 1` upstream. Baking a SECOND `- 1` in here
    ///      would double-shift that already-hardened anchor, wrongly excluding a
    ///      checkpoint that genuinely existed at it.
    function _slashableAt(address guardian, uint256 anchor) internal view returns (uint256) {
        uint256 live = _guardians[guardian].stakedAmount;
        uint256 snapOwnRaw = Math.max(
            _liabilityCheckpoints[guardian].upperLookupRecent(uint32(anchor)),
            _stakeCheckpoints[guardian].upperLookupRecent(uint32(anchor))
        );
        return Math.min(snapOwnRaw, live);
    }

    /// @notice The WOOD a verdict slash anchored at `anchor` could recover from
    ///         `guardian`'s own stake right now. Byte-for-byte the basis `_slashOne`
    ///         sizes its per-approver take from — this view and the slash share
    ///         `_slashableAt`, so they cannot drift apart.
    /// @dev THE ADVERSARY THIS CLOSES: a guardian who tops up its stake AFTER
    ///      `anchor` must not have that top-up counted as coverage for a proposal
    ///      whose verdict is already anchored in the past. `ExposureLedger`'s
    ///      post-execution reads call this with `anchor = executedAt` instead of
    ///      reading live `guardianStake`. Reverts `VerdictNotPast` on a future
    ///      `anchor`, mirroring `slashVerdict`'s own guard.
    /// @param guardian The guardian whose own-stake slash basis is read.
    /// @param anchor   The past timestamp the verdict is anchored at.
    /// @dev SAME-BLOCK TOP-UP HARDENING. `anchor` here is a RAW instant with no
    ///      `-1` pre-offset baked in by the caller, unlike `slashGuardians`'
    ///      `openedAt`. `stakeAsGuardian` has no guard against landing in the SAME
    ///      block as that stamp, and `upperLookupRecent` is INCLUSIVE of
    ///      `key == anchor` — so a same-block top-up would push a checkpoint at
    ///      exactly `key == anchor` and be read back into a snapshot that is
    ///      supposed to value the guardian strictly BEFORE the drain. Looking up at
    ///      `anchor - 1` closes that window, mirroring the same pattern used twice
    ///      elsewhere in this codebase. `anchor == 0` is passed through UNCHANGED —
    ///      the documented direct-call-returns-zero landmine, which no live caller
    ///      reaches this way.
    function slashableStakeAt(address guardian, uint256 anchor) external view returns (uint256) {
        if (anchor > block.timestamp) revert VerdictNotPast();
        return _slashableAt(guardian, anchor == 0 ? 0 : anchor - 1);
    }

    /// @dev Per-approver slash, shared by `slashGuardians` and `slashVerdict` and
    ///      extracted to keep the former's stack frame shallow. Returns the WOOD
    ///      slashed from `approver`: `slashBps` of the OWN stake, sized by
    ///      `_slashableAt` at `lookupAnchor`. Age discounts VOTING POWER, not
    ///      liability: the capital at risk is the staked amount. `reviewKey` only
    ///      feeds the `GuardianSlashed` event topic.
    /// @param lookupAnchor The instant `_slashableAt` looks up at — NOT necessarily
    ///        the caller's own `openedAt` verbatim. `slashGuardians` passes its own
    ///        through (already `-1`-hardened upstream); `slashVerdict` passes
    ///        `openedAt - 1`, since its `openedAt` is a raw, unhardened instant.
    function _slashOne(bytes32 reviewKey, uint256 lookupAnchor, address approver, uint256 slashBps)
        private
        returns (uint256 amt)
    {
        Guardian storage g = _guardians[approver];
        uint256 live = g.stakedAmount;
        uint256 ownSlash = Math.mulDiv(_slashableAt(approver, lookupAnchor), slashBps, 10_000);

        if (ownSlash != 0) {
            // forge-lint: disable-next-line(unchecked-cast)
            // Safe-by-construction: `ownSlash <= live`, and `live` originates
            // from the `uint128 stakedAmount` field, so the difference fits.
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
            // Liability tracks what is recoverable regardless of votability, so
            // it re-checkpoints on BOTH branches — an unstake-requested guardian
            // that is partially slashed must not stay on the hook for the
            // pre-slash amount when the next verdict lands.
            _liabilityCheckpoints[approver].push(uint32(block.timestamp), uint224(g.stakedAmount));
        }
        amt = ownSlash;
        // Emit only when something was actually slashed — an approver with no
        // own stake produces no on-chain record. `delegatedSlash` is always 0;
        // the parameter stays for ABI compatibility.
        if (amt != 0) {
            emit GuardianSlashed(reviewKey, approver, ownSlash, 0);
        }
    }

    /// @notice Slash a vault's owner bond — burns the entire bond.
    /// @dev Registry-only. Reads the bonded amount, clears the `_ownerStakes[vault]`
    ///      slot, then burns the WOOD (CEI: the slot is cleared before the external
    ///      transfer). A no-op when the vault holds no bond.
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
    /// @dev Reads `_pendingBurn[address(this)]`, returns early when empty, zeros it
    ///      (CEI) then `safeTransfer`s to `BURN_ADDRESS`. `safeTransfer` reverts on
    ///      failure, so if WOOD is still broken the whole tx reverts and the pending
    ///      amount stays queued. sWOOD has no pause mechanism.
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
    ///      burn transfer is at risk.
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
