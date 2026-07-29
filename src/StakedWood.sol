// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICompensationEscrow} from "./interfaces/ICompensationEscrow.sol";

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
///         the `coolDownPeriod >= reviewPeriod` cross-contract invariant
///         (Sherlock #16) from the sWOOD side.
interface IRegistryReviewPeriod {
    function reviewPeriod() external view returns (uint256);
}

/// @title StakedWood (sWOOD)
/// @notice Non-transferable vote-escrow contract. Sole WOOD custodian:
///         guardian stake, owner bonds, vote checkpoints, slashing + burn.
///         See spec 2026-05-21-swood-staking-split-design.md.
/// @dev DPoS delegation (share pools, commission, unbonding escrow —
///      `StakedWoodDelegation`) was REMOVED/postponed before mainnet: vote
///      weight is aged own stake only, and slashing has exactly one leg (the
///      guardian's own bond). Re-introduction is a fresh design, not a revert.
/// @dev Narrow ExposureLedger read surface. Mirrors the `ISwoodMinimal` pattern
///      the ledger uses in the other direction — neither contract imports the
///      other's full ABI. Both directions are views, so the mutual reference
///      carries no reentrancy concern.
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

    /// @notice `slashToEscrow` called before the owner wired a compensation
    ///         escrow. The verdict path has no sink without one, and sWOOD
    ///         deliberately does NOT accept an escrow address from the caller
    ///         (see `compensationEscrow`).
    /// @dev Mirrors `IStakedWood.CompensationEscrowNotSet`.
    error CompensationEscrowNotSet();

    /// @notice `slashToEscrow` rejected because the requested compensation
    ///         snapshot is LATER than the verdict's own open timestamp.
    /// @dev Mirrors `IStakedWood.SnapshotAfterVerdict`.
    error SnapshotAfterVerdict();

    /// @notice `slashToEscrow` rejected because the per-approver rate array is
    ///         not the same length as `approvers`. Positional alignment is the
    ///         only thing tying a guardian to their own rate.
    /// @dev Mirrors `IStakedWood.SlashBpsLengthMismatch`.
    error SlashBpsLengthMismatch();

    /// @notice `slashToEscrow` rejected because `openedAt` is in the future.
    ///         The at-open anchor `_slashOne` sizes the legs against must be a
    ///         real past instant (also keeps the `uint32` checkpoint lookup
    ///         from wrapping on an absurd value).
    /// @dev Mirrors `IStakedWood.VerdictNotPast`.
    error VerdictNotPast();

    /// @notice `slashToEscrow` rejected because `approvers` names the same
    ///         address twice. Without dedup, repeating one approver N times
    ///         re-applies its clamped rate to the already-reduced stake —
    ///         effective severity `1-(1-bps)^N`, unbounded above the
    ///         `maxSlashBps` ceiling governance set (PR #24 review 🟠4). The
    ///         review path is immune by construction (the registry's
    ///         `_approvers` dedups at vote time); this path takes the array
    ///         straight from the slasher, so it must enforce its own. A
    ///         pairwise scan rather than a strictly-increasing requirement:
    ///         the production feed (`ExposureLedger.slashBpsFor`) emits
    ///         vote-order arrays positionally aligned with their rates, and
    ///         forcing every caller to co-sort two paired arrays on-chain is a
    ///         worse deal than O(n²) over a quorum-sized calldata array.
    /// @dev Mirrors `IStakedWood.DuplicateApprover`.
    error DuplicateApprover();

    /// @dev Mirrors `IStakedWood.ApproverAlreadySlashed`.
    error ApproverAlreadySlashed();

    /// @dev Mirrors `IStakedWood.VaultNotFactoryDeployed`.
    error VaultNotFactoryDeployed();

    /// @notice Insufficient WOOD to satisfy a stake minimum.
    /// @dev Relocated from `IGuardianRegistry` alongside `stakeAsGuardian`.
    error InsufficientStake();

    // ── Errors absorbed from the removed `StakedWoodDelegation` base (shared
    //    by the guardian/owner unstake flows) ──

    /// @notice Caller has no active stake to operate on.
    error NoActiveStake();

    /// @notice An unstake request is already pending.
    error UnstakeAlreadyRequested();

    /// @notice No pending unstake request to cancel or claim.
    error UnstakeNotRequested();

    /// @notice `claim*` called before `coolDownPeriod` elapsed.
    error CooldownNotElapsed();

    /// @notice Parameter setter argument failed bounds validation.
    /// @dev Relocated verbatim from `IGuardianRegistry`.
    error InvalidParameter();
    /// @notice Sherlock #16: `setCooldownPeriod` rejected because the new
    ///         cooldown is shorter than the registry's `reviewPeriod`. The
    ///         `coolDownPeriod >= reviewPeriod` invariant closes slash-evasion
    ///         for guardian OWN stake (the `isActiveGuardian` voting gate).
    error CooldownBelowReviewPeriod();

    /// @notice `claimUnstakeGuardian` refused: the guardian still backs a
    ///         proposal whose drain could yet be challenged. REQUESTING the
    ///         unstake stays open; only the release waits.
    error CoverageStillOpen();

    event ExposureLedgerSet(address indexed ledger);

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
    /// @dev Deterministic slash severity — floor of the registry's
    ///      decisiveness ramp (spec 2026-07-19 Part D).
    bytes32 public constant PARAM_MIN_SLASH_BPS = keccak256("minSlashBps");

    /// @notice Parameter key for `maxSlashBps`.
    /// @dev Deterministic slash severity — ceiling of the registry's
    ///      decisiveness ramp (spec 2026-07-19 Part D).
    bytes32 public constant PARAM_MAX_SLASH_BPS = keccak256("maxSlashBps");

    /// @notice Parameter key for `ageFloorBps`.
    bytes32 public constant PARAM_AGE_FLOOR_BPS = keccak256("ageFloorBps");

    /// @notice Parameter key for `maturationPeriod`.
    bytes32 public constant PARAM_MATURATION_PERIOD = keccak256("maturationPeriod");

    /// @notice Emitted when the owner rewires the verdict-slash role.
    /// @dev Mirrors `IStakedWood.AuthorizedSlasherSet`.
    event AuthorizedSlasherSet(address indexed slasher);

    /// @notice Emitted when the owner rewires the compensation escrow that
    ///         `slashToEscrow` funds.
    /// @dev Mirrors `IStakedWood.CompensationEscrowSet`.
    event CompensationEscrowSet(address indexed escrow);

    /// @notice Emitted when a verdict slash funds a compensation case.
    /// @dev Correlates the verdict (`caseKey`, `vault`) with the escrow case it
    ///      produced, so Plan D and indexers can join the two without scraping
    ///      the escrow's own `CaseOpened` log and guessing which slash it came
    ///      from. `total` is the WOOD routed; `caseId` is the escrow's id.
    ///      `total` is NET of any conviction bounty (spec 2026-07-29 §2) — it
    ///      is exactly what the escrow's own `proceeds` for this case equal.
    ///      Mirrors `IStakedWood.VerdictSlashRouted`.
    event VerdictSlashRouted(bytes32 indexed caseKey, address indexed vault, uint256 total, uint256 caseId);

    /// @notice Emitted when a verdict slash could NOT fund a compensation case
    ///         — `openCase` reverted (a vault without the
    ///         ERC20Votes read surface, block-number clock mode) — and the
    ///         proceeds were burned instead. The guardian is still slashed;
    ///         the victims of THIS case go uncompensated (PR #24 review 🟡5:
    ///         a bad vault must not brick the verdict).
    /// @dev Mirrors `IStakedWood.VerdictSlashUncompensated`. `total` here is
    ///      also NET of the conviction bounty, which is paid regardless of
    ///      whether `openCase` succeeds (spec 2026-07-29 §2 burn-fallback
    ///      decision): depositors recover 0% of `total` on this path either
    ///      way, so paying the bounty first costs them nothing.
    event VerdictSlashUncompensated(bytes32 indexed caseKey, address indexed vault, uint256 total);

    /// @notice A conviction bounty was paid out of a verdict slash before the
    ///         remainder opened a compensation case (spec 2026-07-29 §2).
    /// @dev Mirrors `IStakedWood.ConvictionBountyPaid`.
    event ConvictionBountyPaid(bytes32 indexed caseKey, address indexed bountyTo, uint256 amount);

    /// @notice Emitted once per approver actually slashed for a blocked proposal.
    /// @dev A slash is a significant value-destroying change; the appeal flow
    ///      (`refundSlash`) and indexers need on-chain records. Emitted only
    ///      when `ownSlash != 0`. `delegatedSlash` is retained in the ABI for
    ///      indexer compatibility but is ALWAYS 0 — DPoS delegation was
    ///      removed/postponed, so the own bond is the only slashable leg.
    event GuardianSlashed(
        bytes32 indexed reviewKey, address indexed approver, uint256 ownSlash, uint256 delegatedSlash
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

    /// @notice SyndicateFactory — resolves the per-vault governor via
    ///         `factory.governorOf(vault)` in the owner-unstake proposal gate.
    ///         (The old singleton `governor` slot was removed with the per-vault
    ///         governor beacon refactor — there is no protocol-wide governor.)
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

    /// @notice Floor (bps) of the deterministic slash severity.
    /// @dev The registry's `_severityBps` ramps quadratically with block-side
    ///      decisiveness from this floor (at a scraped block quorum) to
    ///      `maxSlashBps` (at 2/3 supermajority) — spec 2026-07-19 Part D.
    ///      A non-zero floor preserves the deterrent. See spec §6/§7.
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
    /// @dev Keyed by `address(this)` — relocated verbatim from
    ///      `GuardianRegistry._pendingBurn`. A malicious / blacklisting WOOD
    ///      that reverts or returns false on `transfer(BURN_ADDRESS, ...)` must
    ///      not be able to brick `slashGuardians` / `slashOwnerBond` (the slash
    ///      accounting has already happened — only the burn transfer is at
    ///      risk). The amount accumulates here and `flushBurn` retries it.
    mapping(address => uint256) internal _pendingBurn;

    /// @dev Reserves upgrade headroom for this leaf contract.
    ///      RE-BASELINED 2026-07-26 (DPoS delegation removal, pre-mainnet):
    ///      the `StakedWoodDelegation` base contract — every delegation slot
    ///      that used to precede this contract's storage — was deleted, along
    ///      with `maxDelegatedSlashBps` and `delegatedWeightCapX` here, and
    ///      the whole layout re-baselined (goldens regenerated in the same
    ///      PR; no mainnet 4663 deployment exists, testnets are redeployable).
    ///      Decremented 6 → 5 in the Plan C round-3 merge: `_verdictSlashed`
    ///      (PR #24 review 🟠N2) consumes one slot, so the total size stays
    ///      stable. DECLARATION ORDER IS DELIBERATE (PR #24 review F-F):
    ///      Plan C's three fields sit BETWEEN the gap and Plan B's
    ///      `exposureLedger`, so shrinks come off the END of the gap and the
    ///      fields behind it never shift. From the first mainnet deploy onward
    ///      changes must be append-only, carved off the FRONT of this gap.
    ///      Decremented 5 → 4 for `_liabilityCheckpoints` (PR #25 review 🔴F1b),
    ///      declared immediately below so the shrink comes off the END of the
    ///      gap and every field after it keeps its slot.
    uint256[4] private __gap;

    /// @dev Per-guardian OWN-STAKE LIABILITY history: what the guardian is on
    ///      the hook for at a past instant, as distinct from what it could VOTE
    ///      with. `_stakeCheckpoints` answers the votability question and is
    ///      zeroed by `requestUnstakeGuardian`; this one is not.
    ///
    ///      THE TWO ARE DIFFERENT QUESTIONS (PR #25 review 🔴F1b). Sharing one
    ///      trace let an approver discharge its liability with a reversible
    ///      transaction it could send BEFORE the drain it voted for ever
    ///      executed: approve while active, `requestUnstakeGuardian`, let the
    ///      proposal execute. The coverage gate still credited the full bond —
    ///      `ExposureLedger._slashableBondUsd` prices it off live
    ///      `guardianStake()`, which a request does not move — while every slash
    ///      basis at or after `executedAt` read the request's zero, so a 100%
    ///      conviction recovered nothing.
    ///
    ///      Pushed on stake, on slash and on claim — every event that changes
    ///      what is actually recoverable. Deliberately NOT pushed on
    ///      request/cancel, which change only votability.
    mapping(address guardian => Checkpoints.Trace224) internal _liabilityCheckpoints;

    /// @notice The one address permitted to drive the VERDICT slash path
    ///         (`slashToEscrow`). Deliberately distinct from `onlyRegistry`,
    ///         which drives the block-quorum review slash: the paths must stay
    ///         separate so the registry's `refundSlash` reserve can never refund
    ///         a proven-malice verdict (spec §4). Set to Plan D's challenge game
    ///         once it exists; owner-set meanwhile, which means a verdict is a
    ///         governance action until then.
    address public authorizedSlasher;

    /// @notice The `CompensationEscrow` that `slashToEscrow` funds.
    /// @dev OWNER-SET STATE, deliberately NOT a `slashToEscrow` parameter.
    ///      sWOOD custodies every WOOD bond in the protocol; letting the
    ///      slasher name an arbitrary destination for THIS SINK would hand it
    ///      an ERC20 allowance against that whole balance. Pinning the sink to
    ///      an owner-configured address means a compromised `authorizedSlasher`
    ///      can misdirect the ESCROW PORTION of a slash only INTO the honest
    ///      escrow — where it is still bound to a snapshot-gated case — never
    ///      to an address of its own choosing. Zero disables the verdict path
    ///      (`CompensationEscrowNotSet`).
    ///
    ///      CORRECTED (2026-07-29 review): this no longer describes the WHOLE
    ///      slash. `slashToEscrow`'s `bountyTo`/`bountyBps` is a SEPARATE,
    ///      deliberately caller-chosen channel — the bounty recipient must be
    ///      caller-named, because it is the challenger who caused THIS
    ///      conviction, a fact sWOOD has no way to know on its own. What stays
    ///      true, and is the actual guarantee: a compromised `authorizedSlasher`
    ///      can divert AT MOST `MAX_CONVICTION_BOUNTY_BPS` of any one slash to
    ///      a caller-named address; the remainder can only ever reach this
    ///      owner-set escrow or, on the burn fallback, `BURN_ADDRESS` — never
    ///      an arbitrary destination of the slasher's own choosing. The bound
    ///      on the bounty channel is what makes that remainder-side guarantee
    ///      still hold; see `MAX_CONVICTION_BOUNTY_BPS`.
    address public compensationEscrow;

    /// @dev One slash per (verdict, approver) — the persistent half of the
    ///      severity envelope (PR #24 review 🟠N2). Keyed by the RAW `caseKey`
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
    ///
    /// @dev    Replaces a blunt timer with the question the timer stood in for.
    ///         `coolDownPeriod` had to be at least as long as the LONGEST
    ///         obligation any guardian could hold (~42d at defaults) or an
    ///         approver could exit from under a pending challenge — which
    ///         charged every guardian the worst case, including one who never
    ///         insured anything. Asking the ledger directly is exact.
    ///
    ///         FAIL-OPEN WHEN UNSET: `claimUnstakeGuardian` then behaves exactly
    ///         as it did before this existed. There is necessarily a window at
    ///         deploy, and again on a UUPS upgrade, where the pointer is still
    ///         zero; failing closed there would brick withdrawals over a missed
    ///         configuration step. The cost is that a permanently-unwired
    ///         deployment has no gate and still looks healthy, so `DeployPlanB`
    ///         asserts the wiring as a pre-flight — the failure surfaces as a
    ///         refused deploy rather than as a hole nobody sees.
    ///
    /// @dev    Declared AFTER Plan C's three fields, preserving the Plan C
    ///         merge order (review F-F, see the `__gap` natspec); the
    ///         DPoS-removal re-baseline shifted every absolute slot, and the
    ///         regenerated golden pins where it landed.
    address public exposureLedger;

    /// @notice Slashed WOOD is sent here — permanently out of circulation.
    /// @dev Burning via a transfer to a known-dead address keeps WOOD's
    ///      `totalSupply` semantics intact (no `burn` dependency on the token).
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Ceiling on `slashToEscrow`'s `bountyBps` (spec 2026-07-29 §2:
    ///         "bounded [0, 2_000]").
    /// @dev ENFORCED HERE, NOT ONLY IN THE CALLER. `ChallengeGame` pins its own
    ///      `convictionBountyBps` to this same range at filing, but sWOOD is
    ///      the contract that actually moves the WOOD — the same reason
    ///      `slashBpsPer` is re-clamped to `[minSlashBps, maxSlashBps]` here
    ///      instead of trusted from `ExposureLedger.slashBpsFor`. A compromised
    ///      or simply buggy `authorizedSlasher` must not be able to name an
    ///      arbitrary `bountyBps` and route the whole slash to a caller-chosen
    ///      address; capping it here means the WORST a bad slasher can do
    ///      through this parameter is redirect `MAX_CONVICTION_BOUNTY_BPS` of
    ///      any one slash — the rest still lands only in the honest escrow or
    ///      the burn address, never at the slasher's discretion.
    uint256 public constant MAX_CONVICTION_BOUNTY_BPS = 2_000;

    /// @notice Grouped `initialize` arguments. A struct keeps the call site
    ///         keyword-addressed — a prior review flagged the positional arg
    ///         list as swap-prone.
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
    ///      pending unstake request. Relocated verbatim from `GuardianRegistry`.
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
    ///      design (spec §4, decision D4) — the review slash and the verdict
    ///      slash must never share a caller role, so the registry's appeal
    ///      reserve can never refund a proven-malice verdict.
    modifier onlyAuthorizedSlasher() {
        if (msg.sender != authorizedSlasher) revert NotAuthorizedSlasher();
        _;
    }

    // ── Guardian staking (relocated verbatim from GuardianRegistry) ──

    /// @notice Stake WOOD as a guardian (or top up an existing stake).
    /// @dev Idempotent top-up: on first stake records `agentId` and activates
    ///      the guardian; on subsequent calls the `agentId` arg is ignored.
    ///      A top-up re-anchors `stakedAt` to the stake-weighted average
    ///      timestamp (spec 2026-07-19 §4) — new WOOD matures pro-rata rather
    ///      than inheriting the position's age. Relocated from
    ///      `GuardianRegistry.stakeAsGuardian`.
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
        if (wasInactive) {
            g.stakedAt = uint64(block.timestamp);
            g.agentId = agentId; // recorded once; ignored on top-ups
        } else {
            // Weighted-average age re-anchor (spec 2026-07-19 §4): a top-up
            // ages in pro-rata instead of inheriting the old tranche's full
            // age — closes the "stake dust early, top up the whale position
            // later, inherit full maturity" hole. Ceil-divide so rounding
            // moves toward `now`: never grants free age. Overflow-safe:
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
    ///      denominator. `ts < stakedAt_` (a past read after a forward
    ///      re-anchor) saturates to age 0 — drift is deflation-only.
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
    ///      `ageFloorBps` at stake time to par at `maturationPeriod` — spec §4
    ///      of 2026-07-19-slash-cap-age-weighted-voting-design.md); drops to 0
    ///      once the guardian requests unstake. Totals (`getPastTotalVotes`,
    ///      `getPastTotalSupply`) deliberately stay RAW — aging only shrinks
    ///      numerators, so the raw denominator is conservative (spec §5).
    ///      (The DPoS delegated-inbound term and its k-cap were removed with
    ///      the delegation postponement.)
    function getPastVotes(address guardian, uint256 timestamp) public view returns (uint256) {
        uint256 rawOwn = _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp));
        return rawOwn * _ageFactorBps(_guardians[guardian].stakedAt, timestamp) / 10_000;
    }

    /// @notice A guardian's RAW votable own stake at a past timestamp — the same
    ///         basis `getPastTotalVotes` is a sum of.
    /// @dev    ITS COUNTERPART `getPastVotes` IS NOT (review 🔴F17). That one
    ///         applies `_ageFactorBps` on top, so it is WOOD-scaled but is not a
    ///         term of the total — two different measures of the same stake.
    ///
    ///         Re-graded after the DPoS-delegation removal: `getPastVotes` used
    ///         to add k-capped delegated inbound, which put an account's weight
    ///         in a 20x band around its own contribution and let the accused
    ///         drive `TokenCourt`'s participation floor to zero. Aging only ever
    ///         SHRINKS, so weight is now bounded above by raw stake and that is
    ///         unreachable. The residual bias is one-directional: too little
    ///         subtracted, so the floor comes out too high.
    ///
    ///         The note on `getPastVotes` — "aging and the k-cap only shrink
    ///         numerators, so the raw denominator is conservative" — is sound
    ///         where it was written, about vote COUNTING. It INVERTS under a
    ///         subtraction: `TokenCourt._participationFloor` subtracts the accused
    ///         cohort from the electorate, and there the k-cap term is not
    ///         conservative at all — it is the term that can drive the floor to
    ///         zero. This getter exists so that subtraction has a same-basis
    ///         operand, after which the accused sum can never exceed the total
    ///         by construction: both traces are pushed in the same transaction
    ///         at every mutation site (stake, request, cancel, slash).
    function getPastStake(address guardian, uint256 timestamp) public view returns (uint256) {
        return _stakeCheckpoints[guardian].upperLookupRecent(uint32(timestamp));
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
    ///      age-weighted `getPastVotes` values sum to AT MOST this total, so it
    ///      remains a valid quorum denominator (spec §5 of
    ///      2026-07-19-slash-cap-age-weighted-voting-design.md).
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256) {
        return getPastTotalVotes(timestamp);
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
    ///      The cross-call is guarded behind
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
    /// @dev Owner-only. Relocated from `GuardianRegistry.setMinOwnerStake`.
    ///      `v == 0` is the deliberate open-onboarding sentinel — a 0-WOOD
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
        // Age clock re-anchors to the request timestamp (spec 2026-07-19 §4):
        // pre-request age is forfeited, but maturation DOES keep accruing from
        // this instant onward — including through the cooldown. So a request →
        // (wait) → cancel round-trip returns a stake aged from the request,
        // not from the original stake and not from the cancel: waiting out the
        // cooldown is not penalized, only the pre-request age is dropped.
        g.stakedAt = uint64(block.timestamp);
        totalGuardianStake -= g.stakedAmount;

        // Unstake-requested stake is not votable. Push 0 so getPastStake
        // reflects the on-cooldown state accurately.
        // `_liabilityCheckpoints` IS DELIBERATELY NOT PUSHED HERE (PR #25 review
        // 🔴F1b). A request revokes voting power; it does not settle what the
        // guardian already underwrote, and the WOOD is still in this contract —
        // `claimUnstakeGuardian` is the moment it stops being recoverable, and
        // that is where liability drops.
        _stakeCheckpoints[msg.sender].push(uint32(block.timestamp), 0);
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));

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
        // Sherlock run #2 #14: use cooldown frozen at request time.
        if (block.timestamp < uint256(g.unstakeRequestedAt) + uint256(g.cooldownAtRequest)) {
            revert CooldownNotElapsed();
        }
        // GATE ON THE CLAIM, NOT THE REQUEST (ADR 2026-07-26). Requesting stays
        // open at any time and is behaviour to encourage: it marks the guardian
        // inactive immediately, so they take on no NEW commitments while the
        // existing ones run down. It is the moment the stake actually leaves
        // that has to wait for the obligations to clear.
        //
        // The cooldown above still earns its place — it covers the REVIEW path
        // (`coolDownPeriod >= reviewPeriod`), where a guardian who voted in an
        // unresolved review is slashable and which the ledger knows nothing
        // about. This check covers the challenge path. Neither subsumes the
        // other.
        address ledger = exposureLedger;
        if (ledger != address(0)) {
            // TWO QUESTIONS, NOT ONE (PR #25 review 🔴F2). `openExposureUsd`
            // sums epoch buckets and a bucket ages out `challengeWindow` after
            // its epoch on pure wall-clock — it does not pause because the
            // guardian is under accusation. The challenge game's disputed tail
            // (up to `disputeTimeout`) outlives that by design, so an accused
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
    /// @dev Zero-bond onboarding: the amount==0 guard is folded into the floor
    ///      check below. At `minOwnerStake > 0` a zero (or short) prepared stake
    ///      still reverts `OwnerBondInsufficient` — and `p.amount == 0` is
    ///      unreachable anyway (`prepareOwnerStake` requires `amount >=
    ///      minOwnerStake`), so this is behavior-preserving for any real bond.
    ///      At `minOwnerStake == 0` a 0-WOOD creator who never prepared binds a
    ///      zero bond (owner recorded; the empty prepared slot is NOT consumed,
    ///      so they can open more vaults). `canCreateVault` already passes at
    ///      floor 0, so the factory reaches this path.
    /// @dev nonReentrant dropped — no external calls after state write.
    function bindOwnerStake(address owner_, address vault) external onlyFactory {
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
    ///      any stale-cache window still reverts. Relocated verbatim from
    ///      `GuardianRegistry`.
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

    /// @notice Wire the coverage ledger that gates unstake claims.
    /// @dev Settable to zero deliberately — that is the documented fail-open
    ///      state, and an operator must be able to reach it if the ledger is
    ///      ever replaced or found broken. `DeployPlanB` asserts it is non-zero
    ///      at deploy, so the safe configuration is enforced where a mistake is
    ///      still cheap to correct.
    function setExposureLedger(address ledger) external onlyOwner {
        exposureLedger = ledger;
        emit ExposureLedgerSet(ledger);
    }

    /// @notice Set the address permitted to drive `slashToEscrow`.
    /// @dev Owner-only, and deliberately NOT `setRegistry`'s set-once shape:
    ///      the role is handed to Plan D's challenge game once it deploys.
    ///      Zero is a valid value — it disables the verdict path entirely.
    function setAuthorizedSlasher(address slasher) external onlyOwner {
        authorizedSlasher = slasher;
        emit AuthorizedSlasherSet(slasher);
    }

    /// @notice Set the `CompensationEscrow` that `slashToEscrow` funds.
    /// @dev Owner-only, mirroring `setAuthorizedSlasher`. The escrow is state
    ///      rather than a `slashToEscrow` argument on purpose: an
    ///      argument-named destination would let the slasher point sWOOD's
    ///      allowance — against the protocol's entire WOOD custody — at any
    ///      address it liked. Zero is a valid value: it disables the verdict
    ///      path (`CompensationEscrowNotSet`).
    function setCompensationEscrow(address escrow) external onlyOwner {
        compensationEscrow = escrow;
        emit CompensationEscrowSet(escrow);
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

    /// @notice Verdict-driven slash whose proceeds fund victim compensation
    ///         instead of burning (spec §3.8 + §4 authorized-slasher entrypoint).
    /// @dev Reuses the SAME per-approver own-stake leg as the review path
    ///      (`_slashOne`) — only the SINK differs. Proceeds are approved to
    ///      the escrow and booked as a compensation case pinned to
    ///      `snapshotTimestamp`, so pre-drain holders redeem them (§3.8)
    ///      instead of the WOOD burning.
    /// @dev SEVERITY ENVELOPE. Every element of `slashBpsPer` is clamped to
    ///      `[minSlashBps, maxSlashBps]` here, so the verdict path enforces the
    ///      SAME envelope as the review path — where `GuardianRegistry`'s
    ///      `_severityBps` clamps to those exact bounds before calling
    ///      `slashGuardians`, meaning sWOOD never sees a raw bps from the
    ///      review side. Without the clamp the verdict path would be the one
    ///      entrypoint that takes severity straight from its caller, letting a
    ///      compromised `authorizedSlasher` exceed a ceiling governance set (or
    ///      dodge a floor it set) at will.
    ///
    ///      The envelope binds per VERDICT, not per call: `_verdictSlashed`
    ///      gives each (caseKey, approver) pair exactly one slash, so the
    ///      ceiling cannot be compounded past by splitting one verdict across
    ///      transactions (🟠N2).
    ///
    /// @dev `minSlashBps` IS A PUNITIVE FLOOR, NOT A PROPORTIONALITY RULE
    ///      (PR #24 review 🟡N6). Any non-zero derived rate is raised to it, so
    ///      an approver who underwrote $10 of a $1,000 bond (a 100-bps rate)
    ///      pays `minSlashBps` of the bond — 10× what they insured at a 1,000-bps
    ///      floor. That is deliberate: below the floor the recovery would not
    ///      cover the cost of running the case, and a severity that rounds to
    ///      nothing is not a deterrent. It is NOT an attempt to make the loss
    ///      whole in proportion to what was underwritten. Zero stays exempt
    ///      (see the loop) because zero is the absence of liability, not a
    ///      small amount of it. Governance sets the floor knowing this:
    ///      raising `minSlashBps` raises the over-slash multiple on every
    ///      small allocation, and the per-verdict guard above is what stops
    ///      concurrent small convictions from stacking those floors.
    ///
    ///      THE SHAPE, NOT JUST THE DATA POINT (review round 3): the over-slash
    ///      multiple is `minSlashBps / derivedRate` and is UNBOUNDED as the
    ///      allocation shrinks — the 10× above is one point on a hyperbola, not
    ///      a cap. And `derivedRate` itself moves with the WOOD price
    ///      (`ExposureLedger.slashBpsFor` prices bonds via `woodPriceX8()`), so
    ///      a price move alone can push a small allocation's rate under the
    ///      floor and put its holder on the punitive branch.
    ///
    /// @dev TIMESTAMP BOUNDS — WHAT THEY DO AND DO NOT GUARANTEE (PR #24
    ///      review 🟠2). `openedAt` must not be in the future (`VerdictNotPast`)
    ///      and `snapshotTimestamp` must be at or before `openedAt`
    ///      (`SnapshotAfterVerdict`). These are HONEST-CALLER sanity bounds:
    ///      they catch a mis-built verdict and keep the `uint32` checkpoint
    ///      lookup in `_slashOne` from wrapping. They do NOT constrain a
    ///      COMPROMISED `authorizedSlasher`, which can always pass
    ///      `openedAt = block.timestamp` and pin any past snapshot — including
    ///      a post-drain instant at which an attacker coalition holds the
    ///      supply, handing the attacker back its own slash (F1). Until the
    ///      slasher is Plan D's challenge game passing timestamps from a
    ///      REGISTERED verdict record rather than caller arguments, the
    ///      integrity of `(openedAt, snapshotTimestamp)` is exactly as
    ///      trustworthy as `authorizedSlasher` itself (today: the owner
    ///      multisig).
    ///
    /// @param caseKey  Composite verdict key; feeds the `GuardianSlashed` topic.
    /// @param openedAt The verdict's open timestamp — the at-open anchor the
    ///        own-stake leg is sized against (see `_slashOne`), and the
    ///        latest snapshot the case may be pinned to.
    /// @param approvers The approver addresses to slash.
    /// @param slashBpsPer Per-approver slash fractions in bps, positionally
    ///        aligned with `approvers` and each clamped to
    ///        `[minSlashBps, maxSlashBps]` independently. One rate per approver
    ///        rather than one for the batch: an approver's liability is what
    ///        they UNDERWROTE, and `ExposureLedger` books that per guardian
    ///        (`slashBpsFor` derives this array). A single batch-wide rate
    ///        forced the ledger to assume any one approver might carry the whole
    ///        loss, which is what made coverage un-nettable — a flat 100% takes
    ///        the entire bond once, so a second concurrent conviction against
    ///        the same guardian recovers nothing.
    /// @param vault The vault whose pre-drain holders are compensated. Supplied
    ///        by the caller because a `caseKey` cannot yield it.
    /// @param snapshotTimestamp The pre-drain snapshot the escrow apportions
    ///        against. Chosen by the CALLER within the bound above (§3.8): the
    ///        block before the drain proposal executed for predicates 1-4, the
    ///        epoch-N opening checkpoint for a per-epoch drawdown conviction.
    /// @param bountyTo  Recipient of the conviction bounty (spec 2026-07-29
    ///        §2), or `address(0)` to disable it. Never storage — the caller
    ///        (`ChallengeGame`) decides per settle whether this path pays at
    ///        all, so sWOOD gains no state variable for it and this stays a
    ///        plain UUPS upgrade.
    /// @param bountyBps Slice of the recovered total paid to `bountyTo`, in
    ///        bps. `0` disables the bounty even with a non-zero `bountyTo`.
    ///        Clamped to `[0, MAX_CONVICTION_BOUNTY_BPS]` — NOT trusted from
    ///        the caller, for the same reason `slashBpsPer` is re-clamped here
    ///        rather than trusted from `ExposureLedger`: `ChallengeGame` pins
    ///        its own rate to this range at filing, but sWOOD is the contract
    ///        that actually moves the WOOD, so it enforces its own ceiling
    ///        rather than relying on the caller's. Anything above
    ///        `MAX_CONVICTION_BOUNTY_BPS` (in particular any value `>= 10_000`,
    ///        which would otherwise be able to route the ENTIRE slash to
    ///        `bountyTo`) reverts `InvalidParameter`.
    /// @return total  Total WOOD routed to the escrow across all approvers,
    ///         NET of the conviction bounty. Also what `VerdictSlashRouted` and
    ///         `VerdictSlashUncompensated` report as `total` — both are NET.
    /// @return caseId The escrow case funded, or 0 when nothing was recovered.
    function slashToEscrow(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer,
        address vault,
        uint256 snapshotTimestamp,
        address bountyTo,
        uint256 bountyBps
    ) external onlyAuthorizedSlasher returns (uint256 total, uint256 caseId) {
        address escrow = compensationEscrow;
        if (escrow == address(0)) revert CompensationEscrowNotSet();
        if (openedAt > block.timestamp) revert VerdictNotPast();
        if (snapshotTimestamp > openedAt) revert SnapshotAfterVerdict();
        // Positional alignment is the only thing tying a guardian to their rate,
        // so a mismatch is a caller bug, not something to absorb.
        if (slashBpsPer.length != approvers.length) revert SlashBpsLengthMismatch();
        // BOUNTY RATE IS NOT TRUSTED FROM THE CALLER (2026-07-29 review). Same
        // reasoning as clamping `slashBpsPer` below to `[minSlashBps,
        // maxSlashBps]` instead of trusting `ExposureLedger`: `ChallengeGame`
        // pins `convictionBountyBps` to `[0, 2_000]` at filing, but that bound
        // lives in the CALLER. Left unchecked here, a compromised or buggy
        // `authorizedSlasher` could pass `bountyBps` up to just under 10_000
        // and route almost the entire slash to a `bountyTo` of its own
        // choosing — the exact one-address-of-its-own-choosing outcome
        // `compensationEscrow`'s natspec says sWOOD does not allow. Enforcing
        // the ceiling here, unconditionally (even when `bountyTo == address(0)`
        // and the rate would never be spent), keeps that guarantee true
        // regardless of what the caller does.
        if (bountyBps > MAX_CONVICTION_BOUNTY_BPS) revert InvalidParameter();
        // FACTORY MEMBERSHIP (PR #24 round-4 N-4). The escrow apportions against
        // `vault`'s ERC20Votes checkpoints, and the F-A analysis of
        // `EmptySnapshot` holds only for OZ semantics — a nonstandard
        // `getPastTotalSupply` is the one escape hatch it names. Asserting the
        // vault is factory-deployed converts that scoping sentence from prose
        // about the slasher into code here. Unconditional: `factory` is required
        // non-zero at `initialize`, so there is no unwired window to fail open
        // for.
        if (IFactoryGovernorLookup(factory).governorOf(vault) == address(0)) {
            revert VaultNotFactoryDeployed();
        }

        // Namespace the verdict key before it feeds the shared `GuardianSlashed`
        // topic: a raw caller-chosen `caseKey` could be crafted to collide with
        // a review path `reviewKey`, making a verdict slash indistinguishable
        // from a review slash to the off-chain process that drives the owner's
        // `refundSlash` (PR #24 review, minor 4). `VerdictSlashRouted` still
        // carries the RAW `caseKey`, so indexers join the two deterministically.
        bytes32 slashKey = keccak256(abi.encodePacked("sherwood.verdict", caseKey));

        // INTRA-CALL DEDUP (PR #24 review 🟠4). Each `_slashOne` pass
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
        // This bounds ONE array. The same compounding across SEPARATE calls is
        // bounded by `_verdictSlashed` in the loop below (🟠N2) — which is the
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
            // PERSISTENT DEDUP (PR #24 review 🟠N2). The pairwise scan above
            // bounds one array; this bounds the VERDICT. Checked after the
            // zero-skip on purpose: a zero rate takes nothing, so it must not
            // consume the approver's one slash and block a later real one.
            if (_verdictSlashed[caseKey][approvers[i]]) revert ApproverAlreadySlashed();
            // Clamped per element, not once for the batch: the envelope is a
            // per-guardian ceiling/floor on severity, so it has to bind each
            // approver's own rate. Hoisting it would let one approver's rate set
            // the envelope for everyone.
            uint256 bps = Math.min(Math.max(requested, minSlashBps), maxSlashBps);
            uint256 amt = _slashOne(slashKey, openedAt, approvers[i], bps);
            // MARK ONLY A SLASH THAT LANDED (PR #24 review F-C). `_slashOne`
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
        // Nothing recovered: no case to open (the escrow rejects zero proceeds).
        if (total == 0) return (0, 0);

        // THE BOUNTY COMES OFF THE TOP, BEFORE THE ESCROW SEES THE MONEY
        // (spec 2026-07-29 §2). Paying the prosecutor out of what the
        // prosecution recovered is what makes filing rational: a correct but
        // unanswered challenge otherwise LOSES `settleBurnBps` of its bond, so
        // nobody outside the drained vault has a reason to watch. Deducting
        // here rather than inside the escrow keeps `proceeds` honest - the
        // number a claimant redeems against is the number actually present -
        // and keeps a non-victim payout out of the contract whose only job is
        // victim compensation.
        uint256 bounty;
        if (bountyTo != address(0) && bountyBps != 0) {
            bounty = total * bountyBps / 10_000;
            if (bounty != 0) {
                total -= bounty;
                wood.safeTransfer(bountyTo, bounty);
                emit ConvictionBountyPaid(caseKey, bountyTo, bounty);
            }
        }

        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));
        // Effects are complete; hand the proceeds over and open the case.
        // `forceApprove` tolerates non-standard tokens that reject a non-zero
        // to non-zero approve; the allowance is zeroed straight after so the
        // escrow never holds a standing claim on sWOOD's custody balance.
        //
        // BURN FALLBACK (PR #24 review 🟡5): `openCase` is the slash's only
        // sink, and it reverts on a vault the escrow cannot apportion against
        // (missing ERC20Votes reads, block-number clock mode).
        // Letting that revert bubble would make the SLASH hostage to a vault
        // read — a bad vault would mean the guilty guardian keeps its stake.
        // Instead the slash stands and the proceeds burn, exactly like the
        // review path's sink; `VerdictSlashUncompensated` marks the case as
        // never funded so Plan D / indexers see the victims went unpaid.
        //
        // NARROWED FROM A BARE CATCH (PR #24 review 🟡N8). The burn is
        // irreversible and takes the victims' compensation with it, so it must
        // answer only the failure it was written for: the vault cannot be
        // apportioned against, and no retry will change that. Every revert the
        // escrow raises about its OWN inputs is a recoverable caller or wiring
        // mistake — a `snapshotTimestamp` that is not strictly past (or that
        // predates the vault's first deposit: `EmptySnapshot`, review F-A), a
        // zero vault, an escrow mid-rewire that no longer recognises sWOOD as
        // its funder — and each of those is fixable by resubmitting. Those
        // bubble. The slash is idempotent per (caseKey, approver), so a bubbled
        // revert costs nothing but the gas: the whole transaction rolls back,
        // including `_verdictSlashed`, and the corrected call runs clean.
        IERC20(wood).forceApprove(escrow, total);
        try ICompensationEscrow(escrow).openCase(vault, snapshotTimestamp, total) returns (uint256 id) {
            caseId = id;
            IERC20(wood).forceApprove(escrow, 0);
            emit VerdictSlashRouted(caseKey, vault, total, caseId);
        } catch (bytes memory reason) {
            if (_isRecoverableOpenCaseFailure(reason)) {
                // Not our failure mode — surface it instead of burning.
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            IERC20(wood).forceApprove(escrow, 0);
            // `total` here is already NET of the bounty: it left in the branch
            // above, before this fallback could ever run. Burning the gross
            // would double-count it — the bounty recipient keeps its cut
            // either way, so only what was actually destined for the escrow
            // burns.
            //
            // THE BOUNTY IS DELIBERATELY NOT CLAWED BACK HERE (spec 2026-07-29
            // §2 decision). On this path `openCase` never ran, so depositors
            // recover 0% of `total` EITHER WAY — paying the bounty first does
            // not take anything away from them, because there was never a
            // funded case to divide. The bounty comes out of what would
            // otherwise simply burn, not out of anyone's recovery, so the
            // prosecutor still gets paid even when the vault turns out to be
            // unpriceable.
            _burnWood(total);
            caseId = 0;
            emit VerdictSlashUncompensated(caseKey, vault, total);
        }
    }

    /// @dev Does this `openCase` revert describe a fixable input/wiring mistake
    ///      rather than a vault the escrow can never apportion against?
    ///      (PR #24 review 🟡N8.)
    ///
    ///      Recognised as RECOVERABLE (re-reverted, nothing burns):
    ///        - `SnapshotNotPast`     — reachable from here: `slashToEscrow`
    ///          allows `snapshotTimestamp == block.timestamp`, the escrow
    ///          requires strictly past. Pure caller arithmetic.
    ///        - `ZeroAddress`         — `vault` was zero.
    ///        - `NothingToCompensate` — zero proceeds; unreachable today
    ///          (`total != 0` above) but listed so a future refactor cannot
    ///          turn it into a silent burn.
    ///        - `NotAuthorizedFunder` — the escrow is mid-reconfiguration and
    ///          no longer accepts sWOOD. Rewire and resubmit.
    ///        - `EmptySnapshot` — the votes read SUCCEEDED and returned zero
    ///          supply (review F-A). The vault demonstrably implements the
    ///          ERC20Votes surface, so this is not the vault-capability failure
    ///          the burn answers: on a real conviction a drain implies
    ///          pre-drain holders, so a zero-supply snapshot means the
    ///          TIMESTAMP is wrong (pre-first-deposit typo, wrong epoch
    ///          anchor) — pure caller arithmetic, fixable by resubmitting with
    ///          the corrected instant. Burning here would consume
    ///          `_verdictSlashed` and strand the victims permanently on a
    ///          recoverable input error. The classifier keys on RETRYABILITY,
    ///          not on which contract raised the error.
    ///
    ///          WHY "PERMANENTLY EMPTY" CANNOT HAPPEN ON A REAL VAULT (PR #24
    ///          review F-A objection, answered): OZ `Votes._transferVotingUnits`
    ///          pushes `_totalCheckpoints` on every mint UNCONDITIONALLY —
    ///          `getPastTotalSupply` counts total supply, NOT delegated votes
    ///          ("Votes that have not been delegated are still part of total
    ///          supply", OZ natspec). So a pre-`_update`-upgrade vault whose
    ///          holders never delegated reads zero VOTES per holder (the 🟠N4
    ///          caveat — case opens, claims strand to the backstop) but NEVER
    ///          zero SUPPLY after its first deposit. A vault where
    ///          `EmptySnapshot` is permanent despite holders would have to
    ///          override `getPastTotalSupply` to mean delegated-sum — a
    ///          nonstandard vault no reachable caller path supplies (v1b: the
    ///          owner names factory vaults; Plan D: the vault comes from a
    ///          registered proposal, factory-deployed, OZ semantics).
    ///
    ///      Everything else BURNS: any unrecognised or empty returndata — a
    ///      vault missing the ERC20Votes selectors, a block-number clock mode,
    ///      or an out-of-gas child. Empty returndata deliberately falls through
    ///      to the burn: that is the shape of the missing-selector case, which
    ///      is precisely 🟡5's motivating failure.
    ///
    ///      REQUIREMENT ON THE SLASHER (Plan D): an out-of-gas child is
    ///      RETRYABLE but indistinguishable here from a missing selector, so a
    ///      gas-starved `openCase` burns the victims' compensation
    ///      irreversibly. The exposure is NOT tx-level gas (PR #24 review
    ///      round-4 N-3): the `openCase` call carries no `{gas:}` modifier, so
    ///      an EOA-initiated call that starves the 63/64 child also leaves the
    ///      parent unable to afford the burn branch — the whole transaction
    ///      reverts, which is the safe outcome. The regime that burns is a
    ///      slasher doing `slashToEscrow{gas: g}` with attacker-influenced
    ///      `g`, where the same 63/64 arithmetic runs one frame up and `g` is
    ///      chosen directly. (`_burnWood`'s `_pendingBurn` fallback widens the
    ///      set of gas configurations in which the slash "succeeds" without
    ///      funding a case, so degraded-burn accounting is no comfort here.)
    ///      Today's callers are trusted (owner multisig), but a challenge-game
    ///      slasher that forwards user-influenced gas MUST pin a gas floor
    ///      before calling `slashToEscrow` — nothing in THIS contract enforces
    ///      one; the obligation is recorded here and on the Plan D checklist,
    ///      not implemented by the machine.
    function _isRecoverableOpenCaseFailure(bytes memory reason) private pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
        return selector == ICompensationEscrow.SnapshotNotPast.selector
            || selector == ICompensationEscrow.ZeroAddress.selector
            || selector == ICompensationEscrow.NothingToCompensate.selector
            || selector == ICompensationEscrow.NotAuthorizedFunder.selector
            || selector == ICompensationEscrow.EmptySnapshot.selector;
    }

    /// @dev Per-approver slash. Extracted to keep `slashGuardians`'s stack
    ///      frame shallow. Returns the WOOD slashed from `approver` — a single
    ///      leg since the DPoS-delegation removal: `slashBps` of the OWN stake,
    ///      sized by the raw own-stake checkpoint at `openedAt` and clamped to
    ///      live stake (a concurrent slash may have already reduced live stake
    ///      below the at-open checkpoint — PR #359 review #8). Age discounts
    ///      VOTING POWER, not liability: the capital at risk is the staked
    ///      amount (spec 2026-07-19 §5).
    ///      `reviewKey` only feeds the `GuardianSlashed` event topic.
    function _slashOne(bytes32 reviewKey, uint256 openedAt, address approver, uint256 slashBps)
        private
        returns (uint256 amt)
    {
        Guardian storage g = _guardians[approver];
        uint256 live = g.stakedAmount;
        // LIABILITY, NOT VOTABILITY (PR #25 review 🔴F1b). Reads the liability
        // trace, which `requestUnstakeGuardian` does not zero, so an approver
        // cannot pre-position an exit before the drain it voted for and make its
        // own conviction recover nothing. Maxed with the votable trace so the
        // read degrades to the pre-fix basis over history written before the
        // liability trace existed.
        uint256 snapOwnRaw = Math.max(
            _liabilityCheckpoints[approver].upperLookupRecent(uint32(openedAt)),
            _stakeCheckpoints[approver].upperLookupRecent(uint32(openedAt))
        );
        uint256 ownSlash = Math.mulDiv(Math.min(snapOwnRaw, live), slashBps, 10_000);

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
        // own stake produces no on-chain record. `delegatedSlash` is always 0
        // post delegation-removal; the parameter stays for ABI compatibility.
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
