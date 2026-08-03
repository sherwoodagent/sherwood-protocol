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
    function openExposureUsd(address guardian) external view returns (uint256);
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

    /// @notice `slashVerdict` rejected because `approvers` names the same
    ///         address twice. Without dedup, repeating one approver N times
    ///         re-applies its clamped rate to the already-reduced stake,
    ///         compounding past the `maxSlashBps` ceiling. Checked pairwise
    ///         over calldata rather than requiring sorted input, since the
    ///         production feed emits vote-order arrays positionally aligned
    ///         with their rates.
    /// @dev Mirrors `IStakedWood.DuplicateApprover`.
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

    /// @notice The incoming owner has not consented to having their prepared
    ///         stake bound to this vault.
    /// @dev Adversary: the owner of a vault whose bond slot is empty, rotating
    ///      that vault onto a third party purely to SPEND the third party's
    ///      escrowed prepared stake. `SyndicateFactory.rotateOwner` authorizes
    ///      only its own caller; `newOwner` is a bare parameter checked solely
    ///      against `address(0)`. Without this guard the victim's escrow
    ///      becomes bound to a vault they never chose: `cancelPreparedStake`
    ///      reverts `PreparedStakeNotFound`, their own `createSyndicate` is
    ///      blocked (`canCreateVault` false), and the bond is exposed to
    ///      `GuardianRegistry._resolveEmergency` → `slashOwnerBond` for the
    ///      whole `requestUnstakeOwner` → cooldown → `claimUnstakeOwner`
    ///      recovery. Consent lives HERE, at the spend site, so every present
    ///      and future factory route into `transferOwnerStakeSlot` lands on the
    ///      guard rather than on the hazard.
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
    /// @dev Keyed by `address(this)`. A malicious / blacklisting WOOD that
    ///      reverts or returns false on `transfer(BURN_ADDRESS, ...)` must
    ///      not be able to brick `slashGuardians` / `slashOwnerBond` (the
    ///      slash accounting has already happened — only the burn transfer
    ///      is at risk). The amount accumulates here and `flushBurn` retries
    ///      it.
    mapping(address => uint256) internal _pendingBurn;

    /// @dev Reserves upgrade headroom for this leaf contract.
    ///      RE-BASELINED 2026-07-26 (DPoS delegation removal, pre-mainnet):
    ///      the `StakedWoodDelegation` base contract — every delegation slot
    ///      that used to precede this contract's storage — was deleted, along
    ///      with `maxDelegatedSlashBps` and `delegatedWeightCapX` here, and
    ///      the whole layout re-baselined (goldens regenerated in the same
    ///      PR; no mainnet 4663 deployment exists, testnets are redeployable).
    ///      Decremented 6 → 5 in the Plan C round-3 merge: `_verdictSlashed`
    ///      consumes one slot, so the total size stays stable.
    ///      DECLARATION ORDER IS DELIBERATE:
    ///      Plan C's three fields sit BETWEEN the gap and Plan B's
    ///      `exposureLedger`, so shrinks come off the END of the gap and the
    ///      fields behind it never shift. From the first mainnet deploy onward
    ///      changes must be append-only, carved off the FRONT of this gap.
    ///      Decremented 5 → 4 for `_liabilityCheckpoints`,
    ///      declared immediately below so the shrink comes off the END of the
    ///      gap and every field after it keeps its slot.
    ///      INCREMENTED 4 → 5 by the burn-slash-proceeds change: the
    ///      `compensationEscrow` slot was REMOVED, not deprecated. It sat after
    ///      this gap, so deleting it shifts every following field up one slot
    ///      and the gap grows to hold total size stable — the same convention
    ///      as the shrinks above, run in reverse. Legitimate only because no
    ///      mainnet 4663 deployment exists (testnets are redeployable), exactly
    ///      as in the 2026-07-26 re-baseline; from the first mainnet deploy
    ///      onward a removal like this is no longer available.
    ///      Decremented 5 → 4 for `approvedBindVault`, declared immediately
    ///      below so the shrink comes off the END of the gap and every field
    ///      after it keeps its slot (same convention as
    ///      `_liabilityCheckpoints`).
    ///      Decremented 4 → 3 for `_anchorCheckpoints` (issue #82, ballot
    ///      growth-gated min), declared immediately below so the shrink comes
    ///      off the END of the gap and `approvedBindVault` (slot 21) and
    ///      every field after it keeps its slot (same convention as
    ///      `_liabilityCheckpoints` / `approvedBindVault` above).
    uint256[3] private __gap;

    /// @notice Per-guardian history of the `stakedAt` anchor, so a historical
    ///         `getPastVotes` read can apply `_ageFactorBps` against the
    ///         anchor AS IT STOOD at the queried timestamp instead of the
    ///         live one.
    /// @dev Issue #82. `stakedAt` on `Guardian` is a plain live field with no
    ///      history of its own; a past `getPastVotes` read used to apply the
    ///      LIVE anchor, which only ever moves forward — so a later top-up or
    ///      unstake-request re-anchor could silently deflate an
    ///      already-past read (the previously-documented "deflation-only
    ///      drift"). This trace makes historical reads exact instead.
    ///      Pushed `uint224(g.stakedAt)` at every anchor WRITE site,
    ///      same-transaction as the existing raw `_stakeCheckpoints` push:
    ///      first stake (`stakeAsGuardian`'s `wasInactive` branch),
    ///      top-up re-anchor (`stakeAsGuardian`'s weighted-average branch),
    ///      and unstake-request re-anchor (`requestUnstakeGuardian`).
    ///      Deliberately NOT pushed at `cancelUnstakeGuardian` (does not
    ///      write the anchor — restores `unstakeRequestedAt` and
    ///      `totalGuardianStake` only), at `claimUnstakeGuardian` (the raw
    ///      trace already reads 0 from the request instant onward, so any
    ///      historical read between claim and a re-stake is `0 x f = 0`
    ///      regardless of the anchor; a subsequent re-stake lands in the
    ///      `wasInactive` branch and pushes a fresh anchor there), or on any
    ///      slash path (slashing never writes `stakedAt`).
    ///      An empty trace (read before a guardian's first ever anchor push)
    ///      resolves to 0 via `upperLookupRecent`, and `_ageFactorBps(0, ts)`
    ///      returns `ageFloorBps` — consistent, because the raw checkpoint
    ///      trace is empty there too, so the product is 0 regardless.
    mapping(address guardian => Checkpoints.Trace224) internal _anchorCheckpoints;

    /// @notice The single vault an address consents to have its PREPARED owner
    ///         stake bound to via `transferOwnerStakeSlot`. Zero = no consent.
    /// @dev Issue #98. The slot transfer spends `_prepared[newOwner]`, but its
    ///      only caller (`SyndicateFactory.rotateOwner`) authorizes `msg.sender`
    ///      alone — so without an opt-in recorded BY the incoming owner, any
    ///      owner of an empty-slot vault could bind a stranger's escrow. This
    ///      mapping is that opt-in.
    ///
    ///      At most one approved vault per address, deliberately: an address
    ///      can hold at most one prepared escrow (`PreparedStakeAlreadyExists`),
    ///      so an approval set spanning several vaults would model a consent
    ///      the escrow cannot honor. Approving again overwrites.
    ///
    ///      SCOPED TO ONE ESCROW LIFETIME. Cleared on the successful bind
    ///      (consumed), on `cancelPreparedStake`, and on a fresh
    ///      `prepareOwnerStake`. Without the last two, an approval given for a
    ///      rotation that was then abandoned would still be standing when the
    ///      approver later escrows a NEW stake for their own vault — and the
    ///      vault owner could bind that new escrow against the stale consent.
    ///
    ///      An approval on its own moves nothing and locks nothing: the
    ///      approver keeps `cancelPreparedStake` at all times before the bind,
    ///      and a standing approval with no live escrow is inert (the
    ///      prepared-stake guards still reject the transfer).
    mapping(address owner => address vault) public approvedBindVault;

    /// @dev Per-guardian OWN-STAKE LIABILITY history: what the guardian is on
    ///      the hook for at a past instant, as distinct from what it could VOTE
    ///      with. `_stakeCheckpoints` answers the votability question and is
    ///      zeroed by `requestUnstakeGuardian`; this one is not — sharing one
    ///      trace would let an approver discharge its liability with a
    ///      reversible `requestUnstakeGuardian` sent BEFORE the drain it voted
    ///      for executes, zeroing the slash basis while the coverage gate
    ///      still credits the full bond (it prices off live `guardianStake()`,
    ///      which a request does not move).
    ///
    ///      Pushed on stake, on slash and on claim — every event that changes
    ///      what is actually recoverable. Deliberately NOT pushed on
    ///      request/cancel, which change only votability.
    mapping(address guardian => Checkpoints.Trace224) internal _liabilityCheckpoints;

    /// @notice The one address permitted to drive the VERDICT slash path
    ///         (`slashVerdict`). Deliberately distinct from `onlyRegistry`,
    ///         which drives the block-quorum review slash: the paths must stay
    ///         separate so the registry's `refundSlash` reserve can never
    ///         refund a proven-malice verdict. Owner-set, which makes a
    ///         verdict a governance action.
    address public authorizedSlasher;

    /// @dev One slash per (verdict, approver) — the persistent half of the
    ///      severity envelope. Keyed by the RAW `caseKey`
    ///      the caller passed, so a slasher can read `verdictSlashed` with the
    ///      same key it will pass back in.
    ///
    ///      Why persistence is needed at all: `_slashOne` applies its rate to
    ///      the LIVE stake but sizes off the `openedAt` checkpoint, so repeats
    ///      compound geometrically — N calls at `bps` take `1-(1-bps)^N`. The
    ///      intra-call pairwise dedup bounds one array; it says nothing about
    ///      the next transaction. And splitting IS the expected shape here: a
    ///      100-approver quorum slash costs ~27M gas, more than an Ethereum
    ///      mainnet block, so the batch has to be split to land at all.
    ///      Without this map, the workaround for the gas limit silently voids
    ///      the ceiling governance set.
    mapping(bytes32 caseKey => mapping(address approver => bool)) private _verdictSlashed;

    /// @notice Coverage ledger consulted before releasing a guardian's stake.
    /// @dev    Asks the ledger directly whether a guardian's obligations have
    ///         cleared, rather than sizing `coolDownPeriod` to the worst-case
    ///         obligation any guardian could hold.
    ///
    ///         FAIL-OPEN WHEN UNSET: `claimUnstakeGuardian` behaves as if this
    ///         gate did not exist. Failing closed on a zero pointer would
    ///         brick withdrawals over a missed configuration step, so deploy
    ///         scripts must assert the wiring as a pre-flight instead.
    address public exposureLedger;

    /// @notice Slashed WOOD is sent here — permanently out of circulation.
    /// @dev Burning via a transfer to a known-dead address keeps WOOD's
    ///      `totalSupply` semantics intact (no `burn` dependency on the token).
    ///
    ///      WHAT "BURN" MEANS HERE, PRECISELY. WOOD exposes no `burn()` /
    ///      `ERC20Burnable`, so this is a SUPPLY SINK, not a supply reduction:
    ///      `totalSupply` never falls. The effect is on CIRCULATING supply, and
    ///      only for anyone who treats this address as outside circulation.
    ///      State any deflation claim in those terms — a claim about
    ///      `totalSupply` would be false.
    ///
    ///      Nothing in this protocol reads WOOD's `totalSupply`, so the
    ///      accumulating dead balance pollutes no internal denominator (no
    ///      quorum, rate, or price derives from it). The exposure is purely
    ///      external reporting: if a data provider does not exclude
    ///      `0x...dEaD`, the burn is real on-chain and invisible everywhere a
    ///      holder would look for it.
    ///
    ///      Volume is CONVICTION-DRIVEN, not continuous. A healthy protocol
    ///      burns nothing; the supply curve steps down exactly when the
    ///      protocol is being successfully attacked. That is the correct
    ///      incentive and a poor growth narrative, and the two should not be
    ///      confused. There is no continuous WOOD burn source to complement it
    ///      — the only protocol fee is the agent performance fee, denominated
    ///      in the VAULT's asset (see `FeeConstants`), not in WOOD.
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

    /// @dev Active iff the guardian holds stake >= `minGuardianStake` and has no
    ///      pending unstake request.
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
            // Weighted-average age re-anchor: a top-up ages in pro-rata
            // instead of inheriting the old tranche's full age — closes the
            // "stake dust early, top up the whale position later, inherit
            // full maturity" hole. Ceil-divide so rounding moves toward
            // `now`: never grants free age. Overflow-safe:
            // `amount` is a raw uint256 arg (not a bounded field), but the
            // checked `*` reverts on overflow rather than wrapping, and for
            // any realistic WOOD supply (< 2^128) both `stakedAmount *
            // stakedAt` and `amount * block.timestamp` stay < 2^192, so the
            // checked add cannot overflow uint256.
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

    /// @dev Linear discount-to-par age factor (bps of raw stake). Weight
    ///      ramps from `ageFloorBps` at age 0 to 10_000 (par) at
    ///      `maturationPeriod`, then plateaus — never exceeds raw stake, so
    ///      the raw checkpointed totals remain a valid (conservative) quorum
    ///      denominator. `stakedAt_` is now always the anchor AS OF the
    ///      queried timestamp (`getPastVotes` resolves it from
    ///      `_anchorCheckpoints`, issue #82) rather than a live, only-forward
    ///      field, so `ts < stakedAt_` no longer arises for a historical
    ///      read: `upperLookupRecent` never returns a checkpoint later than
    ///      the timestamp it is queried at. The formerly-documented
    ///      "deflation-only drift" (a forward re-anchor after `ts` silently
    ///      shrinking an already-past `getPastVotes(g, ts)` read) is removed
    ///      along with the behaviour that caused it.
    function _ageFactorBps(uint64 stakedAt_, uint256 ts) internal view returns (uint256) {
        if (stakedAt_ == 0) return ageFloorBps; // never staked in this era
        uint256 age = ts > stakedAt_ ? ts - uint256(stakedAt_) : 0;
        uint256 m = maturationPeriod;
        if (age >= m) return 10_000;
        return ageFloorBps + ((10_000 - ageFloorBps) * age) / m;
    }

    /// @notice A guardian's total votable weight at a past timestamp.
    /// @dev Votes = AGE-WEIGHTED own checkpointed stake at `timestamp`: the
    ///      raw checkpoint discounted by `_ageFactorBps` (linear ramp from
    ///      `ageFloorBps` at stake time to par at `maturationPeriod`); drops
    ///      to 0 once the guardian requests unstake. Totals
    ///      (`getPastTotalVotes`, `getPastTotalSupply`) deliberately stay RAW
    ///      — aging only shrinks numerators, so the raw denominator is
    ///      conservative.
    /// @dev ANCHOR-EXACT HISTORICAL READS (issue #82). The age factor is
    ///      applied against `_anchorCheckpoints[guardian]` AS OF `timestamp`,
    ///      not the live `_guardians[guardian].stakedAt` — so a later top-up
    ///      or unstake-request re-anchor can neither inflate nor deflate an
    ///      already-past read. At the current timestamp the checkpointed
    ///      anchor IS the live anchor, so `getVotes` (which delegates here at
    ///      `block.timestamp`) is bit-identical to before this change. A
    ///      timestamp before the guardian's first anchor checkpoint reads an
    ///      empty trace (anchor 0); the raw checkpoint is empty there too, so
    ///      the product is 0 regardless of `_ageFactorBps(0, ts) ==
    ///      ageFloorBps`. One qualification carried over unchanged from
    ///      before this anchor trace existed: `_ageFactorBps` itself still
    ///      reads the LIVE `ageFloorBps` / `maturationPeriod` parameters, so a
    ///      historical evaluation uses today's parameter values, exactly as
    ///      every historical read always has — this is an existing,
    ///      owner-timelocked exposure the anchor trace does not change either
    ///      way (see `TokenCourt`'s issue #84 setter-invariant guard, which
    ///      is what keeps that exposure from opening a floor deadlock for
    ///      the growth-gated ballot min).
    function getPastVotes(address guardian, uint256 timestamp) public view returns (uint256) {
        uint256 rawOwn = _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp));
        uint64 anchor = uint64(_anchorCheckpoints[guardian].upperLookupRecent(uint32(timestamp)));
        return rawOwn * _ageFactorBps(anchor, timestamp) / 10_000;
    }

    /// @notice A guardian's RAW votable own stake at a past timestamp — the same
    ///         basis `getPastTotalVotes` is a sum of.
    /// @dev    ITS COUNTERPART `getPastVotes` IS NOT: that one applies
    ///         `_ageFactorBps` on top, so it is WOOD-scaled but is not a term
    ///         of the total — two different measures of the same stake.
    ///
    ///         `TokenCourt._participationFloor` subtracts the accused cohort
    ///         from the electorate using this getter rather than
    ///         `getPastVotes`, so the accused sum can never exceed the total
    ///         AT THE SAME TIMESTAMP — both traces are pushed in the same
    ///         transaction at every mutation site (stake, request, cancel,
    ///         slash). The court reduces the accused sum against this
    ///         same-instant total ONLY, before ever looking at the 30-day
    ///         lookback: `reduced = total(snapshotTs) - accusedWeight`,
    ///         clamped at zero (defence-in-depth for an out-of-band
    ///         `setStakedWood` re-point, not a path this same-source getter
    ///         can reach). The lookback min is a separate later step —
    ///         `min(reduced, total(snapshotTs - 30 days))` — and the accused
    ///         cohort is never subtracted from the earlier electorate at all.
    ///         Using the raw basis also denies the accused a lever on
    ///         its own conviction threshold: an aged basis would let an
    ///         accused approver call `requestUnstakeGuardian` between the
    ///         drain and `refer`, re-anchoring its `stakedAt` and flooring its
    ///         own contribution to `ageFloorBps` — shrinking the subtrahend,
    ///         raising the participation floor, and pushing a case the
    ///         accused was certain to lose into `Inconclusive`. This getter
    ///         is immune: it reads the checkpointed amount directly, with no
    ///         live, re-anchorable factor for a pending unstake request to
    ///         move.
    function getPastStake(address guardian, uint256 timestamp) public view returns (uint256) {
        return _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp));
    }

    /// @notice Total guardian vote weight (quorum denominator) at a past timestamp.
    /// @dev Reads the global total-active-stake checkpoint trace.
    function getPastTotalVotes(uint256 timestamp) public view returns (uint256) {
        return _totalStakeCheckpoint.upperLookupRecent(uint32(timestamp));
    }

    // ── Snapshot-compatible vote-read surface ──
    //
    // `getVotes` / `getPastVotes` / `getPastTotalSupply` give Snapshot's
    // `erc20-votes` strategy the read surface it consumes, since `WoodToken`
    // does not inherit `ERC20Votes`. sWOOD intentionally does NOT
    // implement the full OZ `IVotes` interface (no `delegate` / `delegates` /
    // `delegateBySig`). Vote weight = AGE-WEIGHTED own staked WOOD (linear
    // discount-to-par via `_ageFactorBps`; votable — zero once unstake is
    // requested). Totals stay raw (conservative denominator).

    /// @notice An account's CURRENT vote weight — the live counterpart of
    ///         `getPastVotes`.
    /// @dev Delegates to `getPastVotes(account, block.timestamp)`. The
    ///      checkpoint traces are pushed on every votable-weight change with
    ///      key `uint32(block.timestamp)`, and `upperLookupRecent` includes a
    ///      checkpoint written in the current block — so a same-block lookup
    ///      returns the live value. A guardian with a pending unstake request
    ///      has a 0 own-stake checkpoint, so its weight is 0.
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

    /// @notice True iff `guardian` has an active stake and no pending unstake.
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
    /// @dev Owner-only. Enforces the absolute `[1 days, 30 days]` bounds AND
    ///      the `coolDownPeriod >= reviewPeriod` cross-contract invariant:
    ///      once the registry is wired, the cooldown may not drop below the
    ///      registry's review window. This invariant closes slash-evasion for
    ///      guardian OWN stake only — a guardian cannot unstake and escape
    ///      the slash before `resolveReview` runs. The cross-call is guarded
    ///      behind `registry != address(0)` so a not-yet-wired sWOOD
    ///      (deploy-time, before `setRegistry`) does not revert.
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
    ///      Any nonzero value still floors at 1_000 WOOD so a token-dust bond
    ///      can't be set by mistake.
    function setMinOwnerStake(uint256 v) external onlyOwner {
        if (v != 0 && v < 1_000 * 1e18) revert InvalidParameter();
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

        // Unstake-requested stake is not votable. Push 0 so getPastStake
        // reflects the on-cooldown state accurately.
        // `_liabilityCheckpoints` IS DELIBERATELY NOT PUSHED HERE. A request
        // revokes voting power; it does not settle what the guardian already
        // underwrote, and the WOOD is still in this contract —
        // `claimUnstakeGuardian` is the moment it stops being recoverable, and
        // that is where liability drops.
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
        // GATE ON THE CLAIM, NOT THE REQUEST. Requesting stays open at any
        // time and is behaviour to encourage: it marks the guardian inactive
        // immediately, so they take on no NEW commitments while the existing
        // ones run down. It is the moment the stake actually leaves that has
        // to wait for the obligations to clear.
        //
        // The cooldown above still earns its place — it covers the REVIEW path
        // (`coolDownPeriod >= reviewPeriod`), where a guardian who voted in an
        // unresolved review is slashable and which the ledger knows nothing
        // about. This check covers the challenge path. Neither subsumes the
        // other.
        address ledger = exposureLedger;
        if (ledger != address(0)) {
            // TWO QUESTIONS, NOT ONE. `openExposureUsd` sums epoch buckets
            // and a bucket ages out `challengeWindow` after its epoch on pure
            // wall-clock — it does not pause because the guardian is under
            // accusation. The challenge game's disputed tail (up to
            // `disputeTimeout`) outlives that by design, so an accused
            // approver could request at execution, wait out the cooldown, and
            // claim its whole bond before the challenge could resolve: the
            // conviction then priced maximum guilt and recovered nothing,
            // silently. A frozen commitment is the accusation itself, and it
            // does not expire on a clock.
            ILedgerExposureMinimal l = ILedgerExposureMinimal(ledger);
            if (l.openExposureUsd(msg.sender) != 0 || l.hasFrozenCoverage(msg.sender)) {
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

    /// @notice Consent to having your prepared owner stake bound to `vault` by
    ///         a factory owner-rotation.
    /// @dev THE OPT-IN THIS GUARD EXISTS FOR (issue #98). `rotateOwner` names
    ///      the incoming owner as a bare parameter and is authorized against
    ///      the OUTGOING owner only. Adversary: the owner of a vault with an
    ///      empty bond slot rotates it onto whoever currently holds a prepared
    ///      stake, spending that stranger's escrow — locking it behind the
    ///      owner-unstake cooldown on a vault they never chose and exposing it
    ///      to `slashOwnerBond` throughout. Recording the approval here, from
    ///      the escrow holder's own `msg.sender`, is what makes the bind
    ///      consensual.
    ///
    ///      One approved vault per address; calling again overwrites. The
    ///      approval survives until it is consumed by the bind, revoked, or
    ///      cleared by the escrow lifecycle — including across a front-run
    ///      revoke: if the rotation lands first, it lands on a consent that was
    ///      granted and not yet withdrawn, which is a consented outcome and not
    ///      the attack above. `requestUnstakeOwner` remains the exit.
    /// @dev nonReentrant omitted — no external calls, no value movement.
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
    ///      Called by `SyndicateFactory.createSyndicate` after the vault address
    ///      is known. Reverts if the prepared amount is below `minOwnerStake` —
    ///      at factory-creation time `totalAssets()` is 0, so only the floor applies.
    /// @dev Zero-bond onboarding: the amount==0 guard is folded into the floor
    ///      check below. At `minOwnerStake > 0` a zero (or short) prepared stake
    ///      still reverts `OwnerBondInsufficient` — and `p.amount == 0` is
    ///      unreachable anyway (`prepareOwnerStake` requires `amount >=
    ///      minOwnerStake`), so this is behavior-preserving for any real bond.
    ///      At `minOwnerStake == 0` a 0-WOOD creator who never prepared binds a
    ///      zero bond (owner recorded; the empty prepared slot is NOT consumed,
    ///      so they can open more vaults). `canCreateVault` already passes at
    ///      floor 0, so the factory reaches this path.
    /// @dev DEFENCE IN DEPTH — `PriorStakeNotCleared`. Without this guard,
    ///      binding over a vault that already holds a live owner bond would
    ///      drop the prior owner's record on the floor, and their WOOD would
    ///      be unreclaimable (`requestUnstakeOwner`/`claimUnstakeOwner` both
    ///      key on `s.owner == msg.sender`, and the slot now names someone
    ///      else). Unreachable today — the sole call site is
    ///      `SyndicateFactory.createSyndicate`, against a freshly derived CREATE3
    ///      address that cannot already carry a bond — so this costs one SLOAD
    ///      to make a fund-stranding overwrite impossible rather than merely
    ///      unreached, and any future factory-side "re-bind" entry point (see
    ///      `claimUnstakeOwner`) lands on the guard instead of on the hazard.
    ///      A zero-bond slot (`stakedAmount == 0`, incl. one cleared by
    ///      `claimUnstakeOwner` or a full slash) still binds, so floor-0
    ///      onboarding and multi-vault creators are unchanged.
    /// @dev NO `approvedBindVault` CHECK HERE, deliberately. Consent is
    ///      STRUCTURAL on this path: `createSyndicate` passes its own
    ///      `msg.sender` as `owner_`, so the stake being bound always belongs
    ///      to the account that initiated the call. The consent guard in
    ///      `transferOwnerStakeSlot` exists because THAT path takes the
    ///      incoming owner as a parameter chosen by someone else. Requiring an
    ///      approval here would only add a second transaction to a flow that
    ///      cannot bind a stranger's escrow.
    /// @dev nonReentrant dropped — no external calls after state write.
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
    /// @dev Blocked while the vault has any open proposal (Pending /
    ///      GuardianReview / Approved / Executed) to prevent rage-quit around
    ///      malicious executions. Immediately stamps `unstakeRequestedAt`; WOOD
    ///      stays escrowed until `claimUnstakeOwner`.
    ///
    ///      `openProposalCount` tracks every non-terminal state — a
    ///      `getActiveProposal` check alone would only cover Executed and let a
    ///      malicious owner propose a draining strategy and rage-quit before
    ///      execution. The OR against `getActiveProposal` is belt-and-braces so
    ///      any stale-cache window still reverts.
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

    /// @notice Claim a vault owner's bond after the cooldown has elapsed.
    /// @dev After `coolDownPeriod` from `unstakeRequestedAt`, releases WOOD to
    ///      the recorded owner and deletes `_ownerStakes[vault]` entirely — the
    ///      vault then enters grace-period state (`ownerStaked == false`). New
    ///      proposals cannot be created until the slot is re-funded.
    /// @dev RE-FUNDING THE SLOT. `bindOwnerStake` is reachable only from
    ///      `SyndicateFactory.createSyndicate`, i.e. once per vault at birth.
    ///      The single route back to a funded slot on a LIVE vault is
    ///      `SyndicateFactory.rotateOwner` → `transferOwnerStakeSlot`, which
    ///      consumes the incoming owner's `prepareOwnerStake` — and the
    ///      incoming owner may be the outgoing one.
    /// @dev nonReentrant dropped — CEI: struct deleted before transfer.
    function claimUnstakeOwner(address vault) external {
        OwnerStake storage s = _ownerStakes[vault];
        if (s.owner != msg.sender || s.stakedAmount == 0) revert NoActiveStake();
        if (s.unstakeRequestedAt == 0) revert UnstakeNotRequested();
        // Use cooldown frozen at request time.
        if (block.timestamp < uint256(s.unstakeRequestedAt) + uint256(s.cooldownAtRequest)) {
            revert CooldownNotElapsed();
        }
        // Re-check open proposals at claim time. The
        // gate in `requestUnstakeOwner` only fires once; without this
        // re-check an owner who is also a registered agent could call
        // `requestUnstakeOwner` when clean, wait through cooldown, then in
        // a single transaction `propose` a draining strategy + claim their
        // bond. Slash would then find `stakedAmount == 0` and burn nothing.
        // Symmetric with the request-time gate.
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
    /// @dev Reassigns `_ownerStakes[vault]` to `newOwner`'s prepared stake after
    ///      the previous owner's stake has been slashed or fully unstaked
    ///      (guarded by `stakedAmount == 0`). `newOwner` must have called
    ///      `prepareOwnerStake` with >= `minOwnerStake`. Reverts with
    ///      `PriorStakeNotCleared` if the prior owner still has residual stake
    ///      (they must first complete `requestUnstakeOwner` →
    ///      `claimUnstakeOwner`, or be slashed, before the slot can be
    ///      transferred).
    /// @dev CONSENT REQUIRED (issue #98). `newOwner` must have called
    ///      `approveOwnerStakeBinding(vault)` on this contract first, else
    ///      `BindingNotApproved`. The caller of the factory's `rotateOwner` is
    ///      the OUTGOING owner, so `newOwner` is a parameter picked by someone
    ///      else — see `BindingNotApproved` for the spend this blocks. The
    ///      approval is single-use: it is consumed here, so a second transfer
    ///      naming the same incoming owner needs a fresh one. UX consequence:
    ///      a rotation is two transactions across two contracts (approve on
    ///      sWOOD, then rotate on the factory).
    /// @dev nonReentrant dropped — no external calls after state write.
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

    /// @notice The owner bond a vault must hold.
    /// @dev TVL scaling is not implemented in V1; the bond is unconditionally
    ///      `minOwnerStake`. The `vault` parameter is retained for ABI /
    ///      forward-compatibility. Declared as an explicit view so callers
    ///      (`GovernorEmergency`, `SyndicateFactory`) can repoint registry →
    ///      sWOOD without depending on storage-variable visibility.
    function requiredOwnerBond(address vault) external view returns (uint256) {
        vault; // unused — bond is the flat `minOwnerStake` floor in V1.
        return minOwnerStake;
    }

    /// @notice A vault's bound owner stake.
    function ownerStake(address v) external view returns (uint256) {
        return _ownerStakes[v].stakedAmount;
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

    /// @notice Slash a set of approvers for a blocked proposal.
    /// @dev Registry-only. For each approver, burns `slashBps` of their OWN
    ///      guardian stake, sized by the raw own-stake checkpoint at
    ///      `openedAt` and clamped to live stake (see `_slashOne`). The
    ///      aggregate total-stake checkpoint is pushed once after the loop;
    ///      the slashed WOOD is burned in a single transfer.
    /// @param reviewKey  Composite review key keccak256(abi.encode(governor, proposalId)).
    /// @param openedAt   The review's open timestamp. `_slashOne` reads the
    ///                   approver's raw own-stake checkpoint at this instant.
    /// @param approvers  The approver addresses to slash.
    /// @param slashBps   Slash fraction in basis points out of `10_000`.
    /// @return total     Total WOOD burned across all approvers.
    function slashGuardians(bytes32 reviewKey, uint256 openedAt, address[] calldata approvers, uint256 slashBps)
        external
        onlyRegistry
        returns (uint256 total)
    {
        for (uint256 i = 0; i < approvers.length; i++) {
            total += _slashOne(reviewKey, openedAt, approvers[i], slashBps);
        }
        if (total == 0) return 0;
        // Checkpoint the aggregate total-stake drop once after the loop.
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));
        _burnWood(total);
    }

    /// @notice Verdict-driven slash whose proceeds are BURNED (spec §3.8 + §4
    ///         authorized-slasher entrypoint).
    /// @dev Reuses the SAME per-approver own-stake leg as the review path
    ///      (`_slashOne`) AND the same sink. The two paths differ now only in
    ///      who may drive them (`onlyAuthorizedSlasher` vs `onlyRegistry`).
    ///      The compensation case that used to distinguish them is gone, and
    ///      so is the conviction bounty: the slash pays no one.
    /// @dev SEVERITY ENVELOPE. Every element of `slashBpsPer` is clamped to
    ///      `[minSlashBps, maxSlashBps]` here, so the verdict path enforces
    ///      the SAME envelope as the review path, where `GuardianRegistry`'s
    ///      `_severityBps` clamps to those exact bounds before calling
    ///      `slashGuardians` — sWOOD never sees a raw bps from the review
    ///      side. Without the clamp the verdict path would be the one
    ///      entrypoint that takes severity straight from its caller, letting
    ///      a compromised `authorizedSlasher` exceed a ceiling governance set
    ///      (or dodge a floor it set) at will.
    ///
    ///      The envelope binds per VERDICT, not per call: `_verdictSlashed`
    ///      gives each (caseKey, approver) pair exactly one slash, so the
    ///      ceiling cannot be compounded past by splitting one verdict across
    ///      transactions.
    ///
    /// @dev `minSlashBps` IS A PUNITIVE FLOOR, NOT A PROPORTIONALITY RULE. Any
    ///      non-zero derived rate is raised to it, so an approver who
    ///      underwrote $10 of a $1,000 bond (a 100-bps rate) pays
    ///      `minSlashBps` of the bond — 10× what they insured at a 1,000-bps
    ///      floor. That is deliberate: below the floor the recovery would not
    ///      cover the cost of running the case, and a severity that rounds to
    ///      nothing is not a deterrent — this is not an attempt to make the
    ///      loss whole in proportion to what was underwritten. Zero stays
    ///      exempt (see the loop) because zero is the absence of liability,
    ///      not a small amount of it. The over-slash multiple
    ///      (`minSlashBps / derivedRate`) is unbounded as the allocation
    ///      shrinks, and `derivedRate` itself moves with the WOOD price
    ///      (`ExposureLedger.slashBpsFor` prices bonds via `woodPriceX8()`),
    ///      so a price move alone can push a small allocation's rate under
    ///      the floor. The per-verdict guard above stops concurrent small
    ///      convictions from stacking those floors.
    ///
    ///      THE SHAPE, NOT JUST THE DATA POINT: the over-slash
    ///      multiple is `minSlashBps / derivedRate` and is UNBOUNDED as the
    ///      allocation shrinks — the 10× above is one point on a hyperbola, not
    ///      a cap. And `derivedRate` itself moves with the WOOD price
    ///      (`ExposureLedger.slashBpsFor` prices bonds via `woodPriceX8()`), so
    ///      a price move alone can push a small allocation's rate under the
    ///      floor and put its holder on the punitive branch.
    ///
    /// @dev TIMESTAMP BOUND — WHAT IT DOES AND DOES NOT GUARANTEE.
    ///      `openedAt` must not be in the future
    ///      (`VerdictNotPast`). This is an HONEST-CALLER sanity bound: it
    ///      catches a mis-built verdict and keeps the `uint32` checkpoint
    ///      lookup in `_slashOne` from wrapping. It does NOT constrain a
    ///      COMPROMISED `authorizedSlasher`, which can always pass
    ///      `openedAt = block.timestamp`. Until the slasher is Plan D's
    ///      challenge game passing timestamps from a REGISTERED verdict record
    ///      rather than caller arguments, the integrity of `openedAt` is
    ///      exactly as trustworthy as `authorizedSlasher` itself (today: the
    ///      owner multisig).
    ///
    ///      THE F1 SNAPSHOT ATTACK IS GONE WITH THE ESCROW. The companion
    ///      bound this doc used to carry — `snapshotTimestamp` at or before
    ///      `openedAt` — guarded an apportionment: a compromised slasher could
    ///      pin a POST-drain instant at which an attacker coalition held the
    ///      vault's supply and have the escrow hand the attacker back its own
    ///      slash. Burning removes the payout that attack aimed at. There is no
    ///      snapshot, no apportionment, and nothing for a chosen instant to
    ///      redirect; a compromised slasher can still slash the wrong people,
    ///      but it can no longer PAY ITSELF for doing so.
    ///
    /// @param caseKey  Composite verdict key; feeds the `GuardianSlashed` topic.
    /// @param openedAt The verdict's open timestamp — the at-open anchor the
    ///        own-stake leg is sized against (see `_slashOne`).
    /// @param approvers The approver addresses to slash.
    /// @param slashBpsPer Per-approver slash fractions in bps, positionally
    ///        aligned with `approvers` and each clamped to
    ///        `[minSlashBps, maxSlashBps]` independently. The array stays
    ///        per-approver even though the production feed now supplies one
    ///        uniform rate: the clamp is a PER-GUARDIAN envelope, and zero
    ///        remains meaningful as "this approver underwrote nothing" (see the
    ///        loop). Collapsing it to a batch-wide scalar would lose that
    ///        distinction and force every named address to be slashed.
    /// @return total  Total WOOD burned across all approvers — the figure
    ///         `VerdictSlashBurned` reports. The slash pays no one.
    function slashVerdict(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer
    ) external onlyAuthorizedSlasher returns (uint256 total) {
        if (openedAt > block.timestamp) revert VerdictNotPast();
        // DEFENSE-IN-DEPTH (Pashov audit, rejected-but-real hardening item).
        // `openedAt == 0` looks up `_slashableAt(., 0)`, which has no
        // checkpoint at key 0 on any real chain and so silently returns 0 for
        // every named approver: the call "succeeds" (no revert, no
        // `GuardianSlashed`/`VerdictSlashBurned` event) while slashing
        // nothing. A real verdict never legitimately anchors at the zero
        // timestamp, so this can only fire on a mis-built or malicious
        // `authorizedSlasher` input — not reachable by any honest caller —
        // but failing loudly here is strictly cheaper than leaving a verdict
        // that silently voided itself.
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

        // SAME-BLOCK TOP-UP HARDENING (Pashov audit finding 1, hardening #35)
        // — see `slashableStakeAt`'s natspec for the full mechanism. `openedAt`
        // here is a RAW instant with no caller-side `-1` pre-offset (unlike
        // `slashGuardians`' `openedAt`, which `GuardianRegistry.openReview`
        // already stamps as `ts1 = block.timestamp - 1`), so THIS caller must
        // do the offsetting itself before it ever reaches `_slashableAt`.
        // Computed once, outside the loop: `openedAt == 0` already reverted
        // above, so this is always a genuine nonzero instant minus one.
        uint256 lookupAnchor = openedAt - 1;

        // INTRA-CALL DEDUP. Each `_slashOne` pass
        // re-applies its clamped rate to the ALREADY-REDUCED live stake, so N
        // repeats of one approver compound to `1-(1-bps)^N` — above any
        // `maxSlashBps` ceiling governance set. Pairwise over calldata rather
        // than requiring sorted input: the production feed
        // (`ExposureLedger.slashBpsFor`) is vote-ordered and positionally
        // rate-aligned, and approver sets are quorum-sized, so O(n²) here
        // (2.30M gas at the 100-approver cap, against ~27M for the slash
        // itself) is cheaper than every caller co-sorting two paired arrays.
        // Zero-rate entries are NOT exempt — a zero slot must not smuggle a
        // duplicate address past the check.
        //
        // This bounds ONE array. The same compounding across SEPARATE calls
        // is bounded by `_verdictSlashed` in the loop below — which is the
        // half that actually binds in production, since a full-quorum batch
        // has to be split across transactions to fit in a block at all.
        for (uint256 i = 0; i < approvers.length; i++) {
            for (uint256 j = i + 1; j < approvers.length; j++) {
                if (approvers[i] == approvers[j]) revert DuplicateApprover();
            }
        }

        for (uint256 i = 0; i < approvers.length; i++) {
            // ZERO IS NOT A SEVERITY — it is the absence of liability, so it
            // skips the envelope entirely. `minSlashBps` is a floor on how hard
            // a guilty approver is hit, NOT a statement that everyone named in
            // the batch owes something. Running 0 through the clamp would floor
            // it to `minSlashBps` and slash a guardian who underwrote nothing:
            // `ExposureLedger.slashBpsFor` returns 0 for an approver whose
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
            // MARK ONLY A SLASH THAT LANDED. `_slashOne`
            // returns 0 when the approver has no live stake at slash time —
            // already emptied by a concurrent conviction, or exited. Writing
            // the mark there consumes the verdict's one slash on a no-op, so a
            // retry after the guardian re-stakes (the at-open basis is
            // unchanged, so it WOULD recover) reverts `ApproverAlreadySlashed`
            // and the valid verdict is permanently foreclosed. A zero take is
            // like the zero-rate skip above: nothing bound, nothing consumed.
            // The ceiling still cannot compound — the mark is set on the first
            // call that takes anything, and a zero take reduces nothing.
            if (amt == 0) continue;
            _verdictSlashed[caseKey][approvers[i]] = true;
            total += amt;
        }
        // Nothing recovered: nothing to pay, nothing to burn.
        if (total == 0) return 0;

        // NO LEG LEAVES TO A NAMED ADDRESS, and that is exactly what lets the
        // rate be punitive. A sink with no counterparty cannot over-pay anyone,
        // so the slash is free to exceed the loss — which is the whole reason
        // the verdict rate is the severity ceiling rather than a share of the
        // damages. Any payee here would re-impose the windfall constraint that
        // capped it at 1x, which is why the prosecutor is paid from the
        // proposer's forfeited bond instead of from this.
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));

        // THE SINK. Every wei taken burns — the slash pays no one. The
        // prosecutor is paid from the convicted proposer's bond instead, the
        // one pot a prosecutor cannot fund for itself.
        //
        // ONE SINK, THREE PATHS. `slashGuardians` and `slashOwnerBond` have
        // always burned outright. This path used to route to a compensation
        // escrow and burn only as a FALLBACK, for vaults the escrow could not
        // apportion against (missing ERC20Votes reads, block-number clock
        // mode). With the escrow gone the fallback became the rule, and the
        // external call went with it — no allowance dance, no selector
        // allowlist deciding which reverts may burn, no child-call gas to
        // reserve, and no way for a vault read to hold a conviction hostage.
        //
        // `_burnWood` is failure-tolerant by design: a WOOD transfer that
        // reverts or returns false parks the amount in `_pendingBurn` for a
        // permissionless `flushBurn` retry. The slash accounting has already
        // landed at this point, so only the transfer is at risk — a hostile or
        // blacklisting token cannot brick a conviction.
        _burnWood(total);
        emit VerdictSlashBurned(caseKey, total);
    }

    /// @dev THE SHARED SLASH BASIS (issue #35). Returns exactly what
    ///      `_slashOne` recovers from `guardian`'s own stake at `anchor`:
    ///      `min(max(liability at anchor, votableStake at anchor), liveStake)`.
    ///      LIABILITY, NOT VOTABILITY, for the snapshot leg — the liability
    ///      trace, which `requestUnstakeGuardian` does not zero, so an
    ///      approver cannot pre-position an exit before the drain it voted
    ///      for and make its own conviction recover nothing. Maxed with the
    ///      votable trace so the read degrades gracefully over history
    ///      written before the liability trace existed. Clamped to LIVE
    ///      stake so a concurrent slash that already reduced live stake below
    ///      the at-anchor checkpoint is not double-recovered. One
    ///      implementation for both the verdict slash (`_slashOne`) and the
    ///      public view (`slashableStakeAt`), so the WOOD a coverage reader
    ///      books and the WOOD a conviction actually takes cannot drift
    ///      apart — see `ExposureLedger._slashableBondUsd`.
    ///
    /// @dev SAME-BLOCK TOP-UP HARDENING LIVES AT THE CALLERS, NOT HERE
    ///      (Pashov audit finding 1, hardening #35) — see `slashableStakeAt`
    ///      and `slashVerdict` for why. This function stays a PLAIN, inclusive
    ///      lookup at whatever `anchor` it is given: `Checkpoints.Trace224.
    ///      upperLookupRecent` is INCLUSIVE of `key == anchor`, and that is
    ///      exactly right for a caller whose `anchor` is ALREADY the instant
    ///      strictly before the event it guards — e.g. `slashGuardians`'
    ///      `openedAt`, which `GuardianRegistry.openReview` stamps as
    ///      `ts1 = block.timestamp - 1` before ever calling in here. Baking a
    ///      SECOND `- 1` into this shared function would double-shift that
    ///      already-hardened anchor by one extra second, wrongly excluding a
    ///      checkpoint that genuinely existed AT `ts1` — proven by six
    ///      pre-existing `StakedWoodSlashing.t.sol` tests that stake, capture
    ///      `openedAt` at that same instant, and assert the checkpoint counts.
    function _slashableAt(address guardian, uint256 anchor) internal view returns (uint256) {
        uint256 live = _guardians[guardian].stakedAmount;
        uint256 snapOwnRaw = Math.max(
            _liabilityCheckpoints[guardian].upperLookupRecent(uint32(anchor)),
            _stakeCheckpoints[guardian].upperLookupRecent(uint32(anchor))
        );
        return Math.min(snapOwnRaw, live);
    }

    /// @notice The WOOD a verdict slash anchored at `anchor` could recover
    ///         from `guardian`'s own stake right now: `min(max(liability at
    ///         anchor, votableStake at anchor), liveStake)`. Byte-for-byte the basis
    ///         `_slashOne` sizes its per-approver take from — this view and
    ///         the slash share `_slashableAt`, so they cannot drift apart.
    /// @dev THE ADVERSARY THIS CLOSES (issue #35): a guardian who tops up its
    ///      stake AFTER `anchor` must not have that top-up counted as
    ///      coverage for a proposal whose verdict is already anchored in the
    ///      past — the verdict can only ever reach the at-anchor checkpoint,
    ///      clamped to live. `ExposureLedger`'s post-execution reads
    ///      (`allocatedUsd`, `liabilityUsd`, `settleCoverage`) call this with
    ///      `anchor = executedAt` instead of reading live `guardianStake`.
    ///      Reverts `VerdictNotPast` on a future `anchor`, mirroring
    ///      `slashVerdict`'s own guard — an honest caller only ever anchors
    ///      at a real past instant, and the guard keeps the `uint32`
    ///      checkpoint lookup from wrapping.
    /// @param guardian The guardian whose own-stake slash basis is read.
    /// @param anchor   The past timestamp the verdict is anchored at (e.g.
    ///                 a proposal's `executedAt`).
    ///
    /// @dev SAME-BLOCK TOP-UP HARDENING (Pashov audit finding 1, hardening
    ///      #35, confidence 90). `anchor` here is a RAW instant — e.g.
    ///      `SyndicateGovernor.executeProposal`'s `executedAt` stamp,
    ///      forwarded verbatim through `ExposureLedger._slashableBondUsd` —
    ///      with no `-1` pre-offset baked in by the caller, unlike
    ///      `slashGuardians`' `openedAt` (see `_slashableAt`'s natspec).
    ///      `stakeAsGuardian` has no guard against landing in the SAME block
    ///      as that stamp, and `Checkpoints.Trace224.upperLookupRecent` is
    ///      INCLUSIVE of `key == anchor` — so a same-block top-up would push
    ///      a checkpoint at exactly `key == anchor` and get read back into a
    ///      snapshot that is supposed to value the guardian strictly BEFORE
    ///      the drain, defeating issue #35's whole premise. Looking up at
    ///      `anchor - 1` instead closes that window: a same-block-or-later
    ///      checkpoint can never backdate into it. Mirrors the identical
    ///      pattern already used twice elsewhere in this codebase to close
    ///      the same class of same-block inflation:
    ///      `SyndicateGovernor._initPendingProposal`/`approveCollaboration`'s
    ///      `block.timestamp - 1` snapshot (same-block flash-delegate) and
    ///      `GuardianRegistry.openReview`'s `ts1 = block.timestamp - 1`
    ///      (same-block flash-stake). `anchor == 0` is passed through
    ///      UNCHANGED — that is the documented, pre-existing "direct call
    ///      returns ~0" landmine (no live caller reaches it this way; see
    ///      `ExposureLedger._slashableBondUsd`'s live/anchored branch), not
    ///      something this hardening is scoped to touch.
    function slashableStakeAt(address guardian, uint256 anchor) external view returns (uint256) {
        if (anchor > block.timestamp) revert VerdictNotPast();
        return _slashableAt(guardian, anchor == 0 ? 0 : anchor - 1);
    }

    /// @dev Per-approver slash. Shared by both `slashGuardians` and
    ///      `slashVerdict` — extracted to keep `slashGuardians`'s stack frame
    ///      shallow. Returns the WOOD slashed from `approver`: `slashBps` of
    ///      the OWN stake, sized by `_slashableAt` at `lookupAnchor`. Age
    ///      discounts VOTING POWER, not liability: the capital at risk is the
    ///      staked amount.
    ///      `reviewKey` only feeds the `GuardianSlashed` event topic.
    /// @param lookupAnchor The instant `_slashableAt` looks up at — NOT
    ///        necessarily the caller's own `openedAt` verbatim. `slashGuardians`
    ///        passes its `openedAt` straight through (already `-1`-hardened
    ///        upstream by `GuardianRegistry.openReview`'s `ts1`); `slashVerdict`
    ///        passes `openedAt - 1` (its own `openedAt` is a raw, unhardened
    ///        instant — see `slashableStakeAt`'s natspec for why the two paths
    ///        need different treatment here).
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
    ///      and transfer are atomic). sWOOD has no pause mechanism (pausing
    ///      is a registry-only concern).
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
