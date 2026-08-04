// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev Narrow read of the ledger's own `guardianRegistry` pointer, used only by
///      `setExposureLedger` to check the reciprocal grant. Declared locally
///      rather than widening `IExposureLedger`, the same way sibling contracts
///      narrow their own cross-contract reads.
interface ILedgerRegistryPointer {
    function guardianRegistry() external view returns (address);
}

/// @title GuardianRegistry
/// @notice UUPS-upgradeable registry for guardian review votes, emergency
///         review lifecycle, and the slash-appeal reserve. Holds zero assets —
///         the guardian fee is paid out off-chain (buyback-WOOD via weekly
///         Merkl); `getApproverWeights` exposes the per-proposal approver
///         split for the bot. Guardian stake, owner bonds, DPoS vote
///         checkpoints, and slashing live in `StakedWood` (sWOOD); the
///         registry reads vote weight from sWOOD and calls sWOOD to slash.
///         See `openspec/specs/guardian-staking/spec.md`.
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

    /// @dev Mirrors `GovernorParameters.MAX_EXECUTION_WINDOW` and the ledger's
    ///      copy of it. Duplicated for the same reason the ledger duplicates it:
    ///      the floor must hold for EVERY governor the registry serves, so it is
    ///      sized against the worst legal configuration rather than a live one.
    uint256 internal constant MAX_GOVERNOR_EXECUTION_WINDOW = 7 days;
    /// @notice Block decisiveness (bps of at-open total weight) at which the
    ///         deterministic severity hits `maxSlashBps`. 2/3 supermajority.
    uint256 public constant SUPERMAJORITY_BPS = 6_667;
    uint256 public constant MAX_REFUND_PER_EPOCH_BPS = 2000;
    uint256 public constant DEADMAN_UNPAUSE_DELAY = 7 days;
    uint256 public constant MAX_CALLS_PER_PROPOSAL = 64;
    /// @notice How far BEFORE the review-open instant (`ts1`) the block-quorum
    ///         denominator's electorate base is cross-checked. The base fed to
    ///         `openReview`/`openEmergency` is the SMALLER of the electorate at
    ///         `ts1` and the electorate this long before it, so stake younger
    ///         than this cannot inflate the denominator a block vote is measured
    ///         against.
    /// @dev Mirrors `TokenCourt.FLOOR_LOOKBACK` and `_participationFloor`'s
    ///      lookback-min construction, including its bootstrap fallback — read
    ///      that function first if touching this. Without the floor,
    ///      `stakeAsGuardian` has no cap or allowlist gate, so anyone can park
    ///      fresh, never-voting stake just before a review opens and raise the
    ///      absolute weight an honest cohort must clear to block a proposal. A
    ///      `constant`, since an owner-tunable lookback could be shrunk to zero
    ///      immediately before the attack it exists to close.
    uint256 public constant FLOOR_LOOKBACK = 30 days;

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
        /// @dev Snapshot of the block-quorum threshold at `openReview` so the
        ///      owner cannot shift it mid-review and flip the resolution
        ///      outcome. Read by `resolveReview` + `cancelReview` instead of
        ///      the live `blockQuorumBps` slot.
        uint16 blockQuorumBpsAtOpen;
        /// @dev Review-window timestamps pushed by the governor at propose
        ///      time via `registerReview`. The registry reads these stored
        ///      fields directly instead of calling back into the governor;
        ///      `voteEnd != 0` doubles as the "already registered" sentinel.
        uint64 voteEnd;
        uint64 reviewEnd;
        /// @dev Snapshot of the sWOOD slash-severity envelope at `openReview`,
        ///      for exactly the reason `blockQuorumBpsAtOpen` above is
        ///      snapshotted (pashov review finding #11). Only half of the
        ///      mid-review-immutability defence was in place: the THRESHOLD a
        ///      review is judged against was frozen at open, but the PENALTY
        ///      that decision carries was still read live from
        ///      `swood.minSlashBps()` / `maxSlashBps()` at resolve time, and
        ///      neither setter carries an open-review guard.
        ///
        ///      That let the owner commit an already-decided review at severity
        ///      ZERO — every branch of `_severityBps` returns `lo`, `hi`, or a
        ///      ramp between them, so `lo == hi == 0` collapses all three, and
        ///      `_slashOne`'s `ownSlash` is then 0, skipping the burn entirely
        ///      — or at 10_000, taking every approver's whole stake. Either
        ///      way irreversibly, since `resolveReview` commits `r.resolved`
        ///      before the slash call and short-circuits on re-entry.
        ///
        ///      Appended at the END of the struct and packed into the free
        ///      bytes of its existing final slot, so no field declared above
        ///      moves and no top-level slot shifts.
        uint16 minSlashBpsAtOpen;
        uint16 maxSlashBpsAtOpen;
        /// @dev Value of `pauseShiftTotal` when this review's clock was registered
        ///      (pashov review finding #7). `_effNow` subtracts only the pause
        ///      time accumulated SINCE this instant, so a review gets back
        ///      exactly the span its own window lost and no more — a review
        ///      registered after a pause ended is unaffected by it.
        uint64 clockShiftAtRegister;
    }

    mapping(bytes32 => Review) internal _reviews;
    mapping(bytes32 => mapping(address => GuardianVoteType)) internal _votes;
    /// @dev Per-(key, voter) snapshot of the voter's vote weight at the
    ///      instant their review vote was recorded. Read by the off-chain Merkl
    ///      bot via `getApproverWeights` to attribute the (off-chain) guardian
    ///      fee. Vote accounting only — slashing is sized on sWOOD from its
    ///      own raw own-stake checkpoint at `openedAt`.
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
        /// @dev Legacy round marker, bumped on open/cancel. NO LONGER the key
        ///      `_emergencyBlockVotes` is keyed on (see `round` below): a `uint8`
        ///      bumped twice per cycle wraps after 128 cycles and would silently
        ///      recur onto a round whose block-vote flags were never cleared,
        ///      permanently `AlreadyVoted`-locking any guardian who blocked that
        ///      earlier round while `blockStakeWeight` restarted at 0. Kept as an
        ///      informational counter; changing its width would reshuffle every
        ///      field below it in this struct's packed storage.
        uint8 nonce;
        uint64 openedAt; // timestamp for checkpoint lookup of vote weight
        bool cohortTooSmall;
        /// @dev Snapshot of the block-quorum threshold at `openEmergency` so
        ///      the owner cannot shift it mid-review. Read by
        ///      `cancelEmergency` + `_resolveEmergency`.
        uint16 blockQuorumBpsAtOpen;
        /// @dev Set to msg.sender at openEmergency; read by _resolveEmergency
        ///      to resolve the vault from `vaultOf[governor]` for the owner-bond
        ///      slash.
        address governor;
        /// @dev The LOAD-BEARING round marker: `_emergencyBlockVotes` is keyed on
        ///      this, not on `nonce`. Incremented in-place at both
        ///      `openEmergency` and `cancelEmergency`, exactly where `nonce` used
        ///      to be bumped — the only difference is the width. `uint256` cannot
        ///      wrap in any realistic number of cycles, so a round value can never
        ///      recur for this key. Appended at the end of the struct, so existing
        ///      entries read it as the default zero and no packed layout moves.
        uint256 round;
        /// @dev Value of `pauseShiftTotal` when this emergency's clock started
        ///      (pashov review finding #7). Same device as
        ///      `Review.clockShiftAtRegister`: `voteBlockEmergencySettle` is
        ///      `whenNotPaused` while `er.reviewEnd` ran on wall clock, so a
        ///      pause spanning the window left `blockStakeWeight` at zero and
        ///      `_resolveEmergency` scored that as NOT blocked — no
        ///      `slashOwnerBond`, and the owner-supplied call batch executing
        ///      with no per-call caps. Appended at the end of the struct, so no
        ///      existing field moves.
        uint64 clockShiftAtOpen;
    }

    mapping(bytes32 => EmergencyReview) internal _emergencyReviews;
    // Keyed by (bytes32 key, round, guardian) so cancelling + re-opening
    // starts a fresh round; prior-round votes are invisible to the new round.
    // `round` is `EmergencyReview.round` — a per-key counter that is bumped,
    // never reset, and wide enough to never recur (#25), unlike the old
    // per-key `nonce` it replaces here.
    mapping(bytes32 => mapping(uint256 => mapping(address => bool))) internal _emergencyBlockVotes;

    /// @dev Emergency call array — stored by governor via `openEmergency`,
    ///      returned on `finalizeEmergency`, cleared on cancel/finalize.
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
    /// @dev Set of authorized governor addresses. Added by `addGovernor`
    ///      (factory-only).
    EnumerableSet.AddressSet private _authorizedGovernors;
    /// @dev Unused internally; `SyndicateFactory.setGuardianRegistry` reads
    ///      this getter as a misconfig check, and it is part of the deployed
    ///      proxy storage layout. Do not remove.
    address public factory;

    /// @notice The StakedWood (sWOOD) contract — sole WOOD custodian. The
    ///         registry reads vote weight from sWOOD
    ///         and calls sWOOD to slash. Set in `initialize`.
    IStakedWood public swood;

    /// @dev Vault served by each authorized governor (1:1, factory-wired at
    ///      `addGovernor`); the slash path resolves the vault from this trusted
    ///      mapping so a compromised governor cannot misdirect `slashOwnerBond`.
    /// @dev Appended immediately before `__gap` so no pre-existing field moves.
    mapping(address => address) public vaultOf;

    /// @notice Exposure ledger consulted on every approve-side review vote.
    ///         address(0) = not wired = hooks skipped. Owner-set via
    ///         `setExposureLedger`.
    /// @dev Appended immediately before `__gap`, consumes one gap slot; no
    ///      pre-existing field moves.
    IExposureLedger public exposureLedger;

    /// @notice Total seconds this registry has spent paused, accumulated at
    ///         each `unpause` (pashov review finding #7). Review deadlines are
    ///         compared against `_effNow`, which subtracts the share of this
    ///         that accrued while a given review's clock was already running —
    ///         so a pause DEFERS review windows instead of consuming them.
    /// @dev Declared after every pre-existing named field and immediately
    ///      before `__gap`, so no existing field moves — append-only, as the
    ///      layout gate requires. It costs no gap slot either: solc packs it
    ///      into the 12 free trailing bytes of `exposureLedger`'s slot (a
    ///      20-byte address), so `__gap` keeps both its slot and its full
    ///      length. Deliberately NOT placed next to `paused`/`pausedAt`, which
    ///      it would also fit: that slot sits mid-layout, and the append-only
    ///      rule is worth more than the marginally tidier grouping.
    uint64 public pauseShiftTotal;

    /// @dev Reserved storage for future upgrades; each new field consumes
    ///      one slot from here.
    uint256[48] private __gap;

    /// @notice Per-deployment hard floor for `reviewPeriod` (impl-time immutable;
    ///         mainnet 6h). Lives in bytecode, not storage, so the layout is
    ///         unchanged and the value resolves through the UUPS proxy. A testnet
    ///         impl may deploy a lower floor; the 7-day ceiling and the
    ///         `reviewPeriod <= sWOOD.coolDownPeriod()` invariant still hold.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable minReviewPeriod;

    /// @notice Absolute floor-of-floors: no deploy may seat a review floor below this.
    uint256 internal constant ABSOLUTE_MIN_REVIEW_FLOOR = 1 minutes;

    // ── Initializer ──
    /// @param minReviewPeriod_ Per-deployment `reviewPeriod` floor (mainnet 6h).
    /// @dev Bounded `[1 minutes, 3 days]` so an arg-less deploy reverts rather than
    ///      silently seating a 0 floor (which would let `setReviewPeriod(0)` disable
    ///      the review window).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint256 minReviewPeriod_) {
        if (minReviewPeriod_ < ABSOLUTE_MIN_REVIEW_FLOOR || minReviewPeriod_ > 3 days) revert InvalidParameter();
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
        // Mirrors `setReviewPeriod`'s bounds: a zero `reviewPeriod` would make
        // the governor skip `registerReview` (window collapses to
        // `reviewEnd == voteEnd`), leaving every proposal unresolvable and the
        // vault permanently bound. Fail loudly at deploy instead.
        if (reviewPeriod_ < minReviewPeriod || reviewPeriod_ > 3 days) revert InvalidParameter();
        // Mirrors `setBlockQuorumBps`'s bounds. A zero `blockQuorumBps` makes
        // `_isBlocked` true unconditionally — every non-cohort-too-small review
        // resolves Blocked and slashes every approver, and every emergency settle
        // slashes the owner bond, regardless of how anyone actually voted.
        if (blockQuorumBps_ < 1_000 || blockQuorumBps_ > 10_000) revert InvalidParameter();
        // The cooldown >= review invariant is enforced at the setters only —
        // the deploy script seeds compatible values, and skipping the
        // init-time check saves ~10 bytes under EIP-170.

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

    /// @notice Register an additional governor and the vault it serves.
    ///         Factory-only — called immediately after a new per-vault governor
    ///         is deployed.
    /// @param gov The per-vault governor being authorized.
    /// @param vault The vault `gov` serves; recorded in `vaultOf` so the slash
    ///        path resolves the vault from trusted factory-wired state.
    function addGovernor(address gov, address vault) external {
        // Factory-only: letting the registry owner authorize an arbitrary
        // governor would let an attacker-controlled vault reach
        // slashOwnerBond(anyVault).
        if (msg.sender != factory) revert UnauthorizedGovernor();
        if (gov == address(0) || vault == address(0)) revert ZeroAddress();
        _authorizedGovernors.add(gov);
        vaultOf[gov] = vault;
        emit GovernorAdded(gov);
    }

    /// @notice Governor push of a proposal's review-window timestamps at propose
    ///         time. The governor is the single source of the window and pushes
    ///         it once; the registry then reads the stored fields and never
    ///         calls back.
    /// @dev Keyed by `(msg.sender, proposalId)` so each governor owns its own
    ///      namespace. `voteEnd == 0` is the unregistered sentinel, so a zero
    ///      `voteEnd` is rejected; re-registration is rejected to keep the window
    ///      immutable once set.
    function registerReview(uint256 proposalId, uint256 voteEnd, uint256 reviewEnd) external onlyGovernor {
        if (voteEnd == 0 || reviewEnd <= voteEnd) revert InvalidReviewWindow();
        Review storage r = _reviews[_reviewKey(msg.sender, proposalId)];
        if (r.voteEnd != 0) revert ReviewAlreadyRegistered();
        // forge-lint: disable-next-line(unsafe-typecast)
        r.voteEnd = uint64(voteEnd);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.reviewEnd = uint64(reviewEnd);
        // Baseline for `_effNow` — see `Review.clockShiftAtRegister` and the
        // block in `unpause` (pashov review finding #7). Captured here, not at
        // `openReview`, because the window this review is judged against is
        // defined here: a pause landing between propose and open would
        // otherwise eat into `[voteEnd, reviewEnd)` uncredited.
        r.clockShiftAtRegister = pauseShiftTotal;
        emit ReviewRegistered(msg.sender, proposalId, uint64(voteEnd), uint64(reviewEnd));
    }

    /// @notice The pushed review window for a `(governor, proposalId)` pair.
    ///         `(0, 0)` if never registered.
    function reviewWindow(address governor, uint256 proposalId)
        external
        view
        returns (uint64 voteEnd, uint64 reviewEnd)
    {
        Review storage r = _reviews[_reviewKey(governor, proposalId)];
        return (r.voteEnd, r.reviewEnd);
    }

    /// @dev The instant a review's WINDOW is judged against: wall clock less
    ///      the registry downtime that accrued after this review's clock
    ///      started (pashov review finding #7). Every writer into a review
    ///      window is `whenNotPaused`, so without this a pause spanning
    ///      `[voteEnd, reviewEnd)` silently consumed the whole window and both
    ///      resolution readers scored the resulting emptiness as `Cleared` —
    ///      approving a proposal no guardian could have opened or voted on.
    ///
    ///      Deliberately NOT used for `openedAt`, which must stay a real
    ///      timestamp because sWOOD checkpoint lookups are keyed on it, nor for
    ///      the `DEADMAN_UNPAUSE_DELAY` check, whose entire purpose is to
    ///      measure real elapsed pause time.
    function _effNow(uint64 clockShiftAtStart) private view returns (uint256) {
        return block.timestamp - (uint256(pauseShiftTotal) - uint256(clockShiftAtStart));
    }

    /// @dev Composite key isolating per-(governor, proposalId) review state.
    ///      `abi.encode` pads both fields to 32 bytes — no (addr, id) collision.
    function _reviewKey(address gov, uint256 proposalId) private pure returns (bytes32) {
        return keccak256(abi.encode(gov, proposalId));
    }

    /// @dev Single block-quorum predicate shared by `outcomeOf` (view) and
    ///      `resolveReview` (economic commit) so the view can never drift from
    ///      the committed result. Callers must apply the `!opened` /
    ///      `cohortTooSmall` short-circuits (both mean not-blocked) BEFORE this;
    ///      it evaluates only the at-open block-quorum comparison.
    function _isBlocked(Review storage r) private view returns (bool) {
        uint256 denom = uint256(r.totalStakeAtOpen);
        return uint256(r.blockStakeWeight) * 10_000 >= uint256(r.blockQuorumBpsAtOpen) * denom;
    }

    /// @dev Shared lookback read for `openReview` and `openEmergency`. Returns TWO
    ///      figures, both needed and NOT interchangeable:
    ///        - `total` — the LIVE electorate at `ts1`, the correct basis for
    ///          `cohortTooSmall`. Does-a-cohort-exist-right-now is the opposite
    ///          question from resist-denominator-inflation, and answering it off a
    ///          30-day-old figure makes `cohortTooSmall` a free, on-demand
    ///          off-switch for the entire guardian veto and the emergency
    ///          owner-bond slash during any period where the live cohort has grown
    ///          past the lookback figure — trivially reachable via
    ///          `requestUnstakeGuardian`/`cancelUnstakeGuardian`, which plant a
    ///          permanent low checkpoint at zero cost.
    ///        - `minTotal` — the SMALLER of `total` and the electorate
    ///          `FLOOR_LOOKBACK` before `ts1`, falling back to the bare `ts1` read
    ///          when there is no earlier checkpoint at all. This is the correct
    ///          basis for the block-quorum DENOMINATOR ONLY.
    ///      Mirrors `TokenCourt._participationFloor`'s construction, minus the
    ///      accused-weight subtraction, so `minTotal` is a plain min of two raw
    ///      `getPastTotalVotes` reads.
    function _lookbackMinTotalVotes(IStakedWood sw, uint256 ts1)
        private
        view
        returns (uint256 total, uint256 minTotal)
    {
        total = sw.getPastTotalVotes(ts1);
        uint256 lookbackTs = ts1 > FLOOR_LOOKBACK ? ts1 - FLOOR_LOOKBACK : 0;
        uint256 earlier = sw.getPastTotalVotes(lookbackTs);
        minTotal = (earlier != 0 && earlier < total) ? earlier : total;
    }

    /// @dev GROWTH-GATED MIN on a voter's OWN weight at review open, mirroring
    ///      `TokenCourt.vote`'s clamp. Adding the lookback-min to the block-quorum
    ///      DENOMINATOR while leaving this numerator raw meant fresh stake
    ///      discounted out of the denominator still counted in FULL on the
    ///      numerator — turning a mathematically impossible block (an attacker's
    ///      own stake counted symmetrically on both sides can never flip the
    ///      quorum comparison) into a cheap one reachable with ~1 second of stake
    ///      age.
    ///
    ///      Gate on RAW stake growth, strict `>`; clamp the finished
    ///      `getPastVotes` reading — byte-for-byte `TokenCourt.vote`'s
    ///      construction. The `getPastTotalVotes(lookbackTs) != 0` guard skips the
    ///      clamp during bootstrap, mirroring `_lookbackMinTotalVotes`'s own
    ///      fallback: with no history at all, every early guardian's raw stake
    ///      trivially grew from zero and would otherwise be clamped to zero.
    ///
    ///      Shared by `voteOnProposal`'s first-vote branch and
    ///      `voteBlockEmergencySettle`. The vote-CHANGE branch does not call this:
    ///      it reuses the snapshot already clamped when the first vote was cast.
    function _growthGatedVoteWeight(IStakedWood sw, address voter, uint256 openedAt) private view returns (uint256) {
        // RAW STAKE, MATCHING THE DENOMINATOR'S OWN BASIS (pashov review
        // finding #12). This weight is the block-quorum NUMERATOR, and the
        // denominator it is compared against — `r.totalStakeAtOpen`, via
        // `_lookbackMinTotalVotes` — is RAW stake frozen at open.
        // `getPastVotes` is not: it applies `StakedWood._ageFactorBps`, a
        // function of the LIVE `ageFloorBps` / `maturationPeriod` slots. Two
        // consequences, both bad:
        //
        //   - The comparison was systematically mis-scaled. A young cohort at
        //     the shipped 2500 bps age floor contributes a quarter of its raw
        //     stake to the numerator while the denominator counts all of it,
        //     so a 3000 bps block quorum could be unreachable even with every
        //     guardian blocking — the veto failing OPEN with no attacker.
        //   - `setAgeFloorBps` / `setMaturationPeriod` carry no open-review
        //     guard, so the owner could re-weight every not-yet-cast vote
        //     mid-review against a frozen denominator and flip a decided
        //     outcome — the exact mid-review mutability `blockQuorumBpsAtOpen`
        //     exists to prevent, reintroduced through the other operand. The
        //     same helper backs `voteBlockEmergencySettle`, where flipping the
        //     result decides whether a vault owner's entire bond is burned.
        //
        // The growth gate below is unchanged in shape and still compares each
        // voter against its own `FLOOR_LOOKBACK` history; only the measure is
        // now the same one the denominator uses.
        uint256 weight = sw.getPastStake(voter, openedAt);
        uint256 lookbackTs = openedAt > FLOOR_LOOKBACK ? openedAt - FLOOR_LOOKBACK : 0;
        if (
            sw.getPastStake(voter, openedAt) > sw.getPastStake(voter, lookbackTs)
                && sw.getPastTotalVotes(lookbackTs) != 0
        ) {
            uint256 weightThen = sw.getPastStake(voter, lookbackTs);
            if (weightThen < weight) weight = weightThen;
        }
        return weight;
    }

    // ── sWOOD passthrough views (lets GovernorEmergency read the owner bond via the registry) ──

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

    // ── Guardian-fee attribution (read-only) ──

    /// @inheritdoc IGuardianRegistry
    /// @dev Reads the `_approvers` / `_voteStake` accounting. Data persists
    ///      after settle (arrays are not cleared), so this is callable for
    ///      any historical proposal. The off-chain Merkl bot pulls this in a
    ///      single RPC call to attribute the guardian fee (paid out as WOOD)
    ///      to approvers.
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

    /// @inheritdoc IGuardianRegistry
    /// @dev The weight the fee should be paid on. `getApproverWeights` returns
    ///      `_voteStake` — what the approver PARKED, not what they UNDERWROTE —
    ///      so paying on that would let an approver who booked no coverage earn
    ///      beside one who booked the full amount.
    ///
    ///      The divergence is reachable: `recordApproval` deliberately books
    ///      nothing and does not revert when the guardian has no free budget, the
    ///      asset feed is unpriceable, coverage is zero, or settlement is beyond
    ///      the coverage horizon. The registry still pushes the voter into
    ///      `_approvers` before the ledger hook runs, so a guardian can spend its
    ///      whole budget on one proposal and keep approving everything else at
    ///      full stake weight, underwriting nothing further.
    ///
    ///      Returns the ledger's ALLOCATION — each approver's settled pro-rata
    ///      share — rather than their reservation, since reservations equal the
    ///      full coverage per approver and would over-pay everyone on an
    ///      over-subscribed proposal. Allocations require `settleCoverage` to have
    ///      run; it is permissionless, so the payout job should call it first.
    ///
    ///      `priced` is FALSE when the ledger could not value the coverage. The
    ///      caller MUST retry rather than treat the zeros as a result: silently
    ///      paying zero to every approver through a feed outage would be a worse
    ///      failure than the one this view exists to fix. An unwired ledger
    ///      returns all-zero with `priced == true`.
    function getApproverCoverage(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory coverageUsd, bool priced)
    {
        bytes32 key = _reviewKey(governor, proposalId);
        approvers = _approvers[key];
        uint256 n = approvers.length;
        coverageUsd = new uint256[](n);
        IExposureLedger led = exposureLedger;
        if (address(led) == address(0)) return (approvers, coverageUsd, true);
        for (uint256 i = 0; i < n; i++) {
            try led.allocatedUsd(governor, proposalId, approvers[i]) returns (uint256 v) {
                coverageUsd[i] = v;
            } catch {
                return (approvers, new uint256[](n), false);
            }
        }
        priced = true;
    }

    // ── Guardian review voting ──

    /// @inheritdoc IGuardianRegistry
    /// @dev First-vote path OR vote-change. Requires `openReview` to have been
    ///      called and `voteEnd <= now < reviewEnd`. Snapshots the caller's vote
    ///      weight at `r.openedAt`, growth-gated via `_growthGatedVoteWeight` so a
    ///      voter's own numerator weight cannot outrun the denominator's dilution
    ///      defense, and adds it to the chosen side's tally. Approvers and
    ///      Blockers are each capped. Block votes carry no proposed severity: the
    ///      slash severity is a deterministic function of block-side decisiveness
    ///      computed at `resolveReview` (see `_severityBps`).
    function voteOnProposal(address governor, uint256 proposalId, GuardianVoteType support) external whenNotPaused {
        if (support == GuardianVoteType.None) revert();
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();

        bytes32 key = _reviewKey(governor, proposalId);
        Review storage r = _reviews[key];
        if (!r.opened) revert ReviewNotOpen();
        // Defence in depth alongside `openReview`'s resolved guard: a resolved
        // review (cancelled, or already committed) accepts no further votes,
        // so no approve weight can accrue on a proposal that carries no slash
        // risk. Unreachable while `openReview` refuses to re-open — kept so a
        // future edit to either guard cannot silently arm the other.
        if (r.resolved) revert ReviewNotOpen();

        // Pause-adjusted on both bounds — see `_effNow` (pashov review
        // finding #7). This is the writer whose `whenNotPaused` gate made the
        // window consumable in the first place.
        uint256 nowEff = _effNow(r.clockShiftAtRegister);
        if (r.voteEnd == 0 || nowEff < r.voteEnd || nowEff >= r.reviewEnd) revert ReviewNotOpen();

        if (!swood.isActiveGuardian(msg.sender)) revert NotActiveGuardian();

        GuardianVoteType existing = _votes[key][msg.sender];
        if (existing == support) revert NoVoteChange();

        if (existing == GuardianVoteType.None) {
            // Apply the late-vote lockout to first-time votes too.
            uint256 reviewWindowDuration = uint256(r.reviewEnd) - uint256(r.voteEnd);
            uint256 lockoutStart = r.reviewEnd - (reviewWindowDuration * LATE_VOTE_LOCKOUT_BPS) / BPS_DENOMINATOR;
            // Pause-adjusted like every other bound measured against
            // `r.reviewEnd` — see `_effNow` (pashov review finding #7). On wall
            // clock a pause would eat the whole votable stretch and leave only
            // the locked-out tail, which is the same window-consumption defect
            // one step further in.
            if (_effNow(r.clockShiftAtRegister) >= lockoutStart) revert VoteChangeLockedOut();

            // First vote — snapshot own weight AT `r.openedAt`, growth-gated
            // to match the block-quorum denominator's own lookback-min
            // (finding A; see `_growthGatedVoteWeight`).
            uint256 weight256 = _growthGatedVoteWeight(swood, msg.sender, uint256(r.openedAt));
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
            // CEI: the external ledger call runs AFTER every state write above
            // (`_votes`, tallies, approver/blocker push) so a re-entrant
            // voteOnProposal observes committed state — do NOT move any state
            // write below this hook. Same discipline as resolveReview.
            if (support == GuardianVoteType.Approve && address(exposureLedger) != address(0)) {
                // The aggregate exposure cap is checked here, at the approve
                // vote. An over-exposed guardian books nothing rather than
                // reverting; the vote still lands and the shortfall surfaces
                // at the execute-time quorum.
                exposureLedger.recordApproval(governor, proposalId, msg.sender);
            }
            emit GuardianVoteCast(proposalId, msg.sender, support, weight);
        } else {
            // Vote-change: must be before the late lockout window.
            uint256 reviewWindowDuration = uint256(r.reviewEnd) - uint256(r.voteEnd);
            uint256 lockoutStart = r.reviewEnd - (reviewWindowDuration * LATE_VOTE_LOCKOUT_BPS) / BPS_DENOMINATOR;
            // Pause-adjusted like every other bound measured against
            // `r.reviewEnd` — see `_effNow` (pashov review finding #7). On wall
            // clock a pause would eat the whole votable stretch and leave only
            // the locked-out tail, which is the same window-consumption defect
            // one step further in.
            if (_effNow(r.clockShiftAtRegister) >= lockoutStart) revert VoteChangeLockedOut();

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
            // CEI (see first-vote branch above): ledger call is intentionally
            // after all state writes; do not move a state write below it.
            if (address(exposureLedger) != address(0)) {
                if (support == GuardianVoteType.Block) {
                    exposureLedger.releaseApproval(governor, proposalId, msg.sender);
                } else {
                    exposureLedger.recordApproval(governor, proposalId, msg.sender);
                }
            }
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
    /// @dev `whenNotPaused` MIRRORS `openReview` (pashov review finding #7).
    ///      This was the only sibling `open*` without the gate, so an emergency
    ///      could be opened while paused and its whole review window expire
    ///      before `voteBlockEmergencySettle` — itself `whenNotPaused` — was
    ///      ever callable. `_resolveEmergency` then read `blockStakeWeight == 0`
    ///      as "not blocked", skipping `slashOwnerBond` and handing back an
    ///      owner-chosen call batch that `executeGovernorBatch` runs with an
    ///      empty caps array. Belt and braces with `clockShiftAtOpen` below:
    ///      this stops the window from STARTING during a pause, that one gives
    ///      back time lost to a pause which begins after it opened.
    function openEmergency(uint256 proposalId, bytes32 callsHash, BatchExecutorLib.Call[] calldata calls)
        external
        onlyGovernor
        whenNotPaused
    {
        if (calls.length > MAX_CALLS_PER_PROPOSAL) revert EmergencyTooManyCalls();
        if (keccak256(abi.encode(calls)) != callsHash) revert EmergencyHashMismatch();

        bytes32 eKey = _reviewKey(msg.sender, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        if (er.reviewEnd > 0 && _effNow(er.clockShiftAtOpen) < er.reviewEnd) revert EmergencyAlreadyOpen();
        // Snapshot stake totals at open and flag a cold-start cohort. The
        // denominator is read at `t-1`, matching the numerator's checkpoint anchor
        // — symmetric flash-(de)stake defense — AND is the lookback-min of the
        // `t-1` and `t-1-FLOOR_LOOKBACK` reads, so fresh, never-voting stake
        // parked just before `openEmergency` cannot inflate the denominator the
        // owner's own block vote is measured against.
        //
        // `cohortTooSmall`, in contrast, is decided off the LIVE electorate, NOT
        // the lookback-min — see `_lookbackMinTotalVotes`.
        IStakedWood sw = swood;
        uint256 ts1 = block.timestamp - 1;
        (uint256 liveTotal, uint256 gs) = _lookbackMinTotalVotes(sw, ts1);

        er.governor = msg.sender; // stored before any external calls
        er.callsHash = callsHash;
        er.reviewEnd = uint64(block.timestamp + reviewPeriod);
        // Baseline for `_effNow` — see `EmergencyReview.clockShiftAtOpen`
        // (pashov review finding #7). Set wherever this clock is (re)started.
        er.clockShiftAtOpen = pauseShiftTotal;
        er.totalStakeAtOpen = uint128(gs);
        er.blockStakeWeight = 0;
        er.resolved = false;
        er.blocked = false;
        er.openedAt = uint64(ts1);
        er.cohortTooSmall = liveTotal < MIN_COHORT_STAKE_AT_OPEN;
        // Snapshot block-quorum threshold at open so the owner can't shift
        // it mid-review.
        // forge-lint: disable-next-line(unsafe-typecast)
        er.blockQuorumBpsAtOpen = uint16(blockQuorumBps);
        uint64 newReviewEnd = er.reviewEnd;
        unchecked {
            er.nonce++; // legacy counter only, see struct @dev
            // Mint a fresh round so `_emergencyBlockVotes` for THIS round is
            // guaranteed unused — `uint256` cannot wrap here in practice.
            er.round++;
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
        if (er.reviewEnd > 0 && _effNow(er.clockShiftAtOpen) >= er.reviewEnd) revert ReviewNotOpen();
        // Once block quorum is reached, the owner can't dodge.
        if (!er.cohortTooSmall) {
            uint256 denom = uint256(er.totalStakeAtOpen);
            if (uint256(er.blockStakeWeight) * 10_000 >= uint256(er.blockQuorumBpsAtOpen) * denom) {
                revert ReviewNotOpen();
            }
        }
        er.resolved = true;
        er.blocked = false;
        er.blockStakeWeight = 0;
        // Repurpose `reviewEnd` post-cancel to encode the cooldown deadline.
        er.reviewEnd = uint64(block.timestamp + reviewPeriod);
        // Baseline for `_effNow` — see `EmergencyReview.clockShiftAtOpen`
        // (pashov review finding #7). Set wherever this clock is (re)started.
        er.clockShiftAtOpen = pauseShiftTotal;
        er.callsHash = bytes32(0);
        unchecked {
            er.nonce++; // legacy counter only, see struct @dev
            // Bump the round too so any block votes cast this round go
            // stale — a future `openEmergency` on this key mints a new,
            // never-before-used round (finding #25).
            er.round++;
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
        uint256 ve = r.reviewEnd;
        if (ve > 0 && block.timestamp >= ve) revert ReviewNotOpen();
        // A never-opened review has nothing to block, and `_isBlocked` must not
        // be asked: on a zero-valued Review it evaluates `0 >= 0` and reports
        // "blocked" vacuously, which would reject a perfectly legitimate cancel
        // in the ordinary window between `voteEnd` and a keeper's `openReview`.
        // `resolveReview` and `outcomeOf` both short-circuit on `!opened`
        // before reaching the predicate — mirror them here.
        if (!r.opened) {
            r.resolved = true;
            r.blocked = false;
            emit ReviewResolved(proposalId, false, 0);
            return;
        }
        // Once block quorum is reached, the proposer can't dodge approver
        // slashing by cancelling. Mirrors `cancelEmergency`'s gate. Cold-start
        // cohorts skip the check — quorum is not meaningful when
        // `totalStakeAtOpen` is below the floor.
        if (!r.cohortTooSmall) {
            if (_isBlocked(r)) revert ReviewNotOpen();
        }
        r.resolved = true;
        r.blocked = false;
        emit ReviewResolved(proposalId, false, 0);
    }

    // Permissionless
    /// @inheritdoc IGuardianRegistry
    /// @dev Permissionless keeper entrypoint, callable once
    ///      `block.timestamp >= proposal.voteEnd`. Snapshots sWOOD's
    ///      `totalGuardianStake` into the review. Idempotent.
    /// @dev A RESOLVED review never re-opens. `cancelReview`'s never-opened
    ///      short-circuit makes `(opened == false, resolved == true)` reachable
    ///      BEFORE `reviewEnd`; without this guard a keeper could re-open a
    ///      cancelled review and guardians could mint reward-eligible approve
    ///      weight on an already-Cancelled proposal at zero slash risk.
    function openReview(address governor, uint256 proposalId) external whenNotPaused {
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();
        bytes32 key = _reviewKey(governor, proposalId);
        Review storage r = _reviews[key];
        if (r.opened || r.resolved) return; // idempotent

        uint256 ve = r.voteEnd;
        // Pause-adjusted — see `_effNow` (pashov review finding #7).
        if (ve == 0 || _effNow(r.clockShiftAtRegister) < ve) revert ReviewNotOpen();

        IStakedWood sw = swood;
        // Read the denominator at the SAME `t-1` checkpoint the numerator uses, so
        // flash-stake in the same block as `openReview` cannot asymmetrically
        // inflate the quorum denominator while the matching numerator weight stays
        // at the `t-1` snapshot. On top of that, take the lookback-min against
        // `t-1-FLOOR_LOOKBACK`: `stakeAsGuardian` has no cap or allowlist gate, so
        // otherwise fresh, never-voting stake parked just before `openReview`
        // raises the absolute weight an honest cohort must clear to block.
        //
        // `cohortTooSmall` is decided off the LIVE electorate, NOT the
        // lookback-min stored into `r.totalStakeAtOpen` — using the lookback-min
        // for does-a-cohort-exist made it a free off-switch for the guardian veto
        // during ordinary early growth.
        uint256 ts1 = block.timestamp - 1;
        (uint256 liveTotal, uint256 minTotal) = _lookbackMinTotalVotes(sw, ts1);
        uint128 totalAtOpen = uint128(minTotal);
        uint256 combinedAtOpen = uint256(totalAtOpen);
        r.opened = true;
        r.totalStakeAtOpen = totalAtOpen;
        // Snapshot block-quorum at open so the owner can't shift the
        // threshold after voters have cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.blockQuorumBpsAtOpen = uint16(blockQuorumBps);
        // Snapshot the slash-severity envelope for the same reason and at the
        // same instant (pashov review finding #11) — see `Review`. Freezing
        // the threshold but not the penalty left the owner able to rewrite
        // what a decided review COSTS at resolve time. Both sWOOD getters are
        // bps and bounded by 10_000 at their setters, so the casts cannot
        // truncate a legal value.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.minSlashBpsAtOpen = uint16(swood.minSlashBps());
        // forge-lint: disable-next-line(unsafe-typecast)
        r.maxSlashBpsAtOpen = uint16(swood.maxSlashBps());
        r.openedAt = uint64(ts1);
        if (liveTotal < MIN_COHORT_STAKE_AT_OPEN) {
            r.cohortTooSmall = true;
            emit CohortTooSmallToReview(proposalId, combinedAtOpen);
        } else {
            emit ReviewOpened(proposalId, uint128(combinedAtOpen));
        }
    }

    /// @inheritdoc IGuardianRegistry
    /// @dev Permissionless and idempotent — once resolved, returns the cached
    ///      `blocked` flag without re-slashing. Requires
    ///      `block.timestamp >= reviewEnd`. Short-circuits to `false` when
    ///      `!opened` or `cohortTooSmall`. CEI: sets `resolved`/`blocked` before
    ///      any token transfer, which is why no `nonReentrant` is needed — a
    ///      reentrant call hits the early return.
    function resolveReview(address governor, uint256 proposalId) external whenNotPaused returns (bool) {
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();
        bytes32 key = _reviewKey(governor, proposalId);
        Review storage r = _reviews[key];
        // Pause-adjusted — see `_effNow` (pashov review finding #7). Holding
        // resolution back for the deferred span is the whole point: resolving
        // on wall clock is what let a paused-out review commit as `Cleared`.
        if (r.reviewEnd == 0 || _effNow(r.clockShiftAtRegister) < r.reviewEnd) revert ReviewNotReadyForResolve();

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

        // Block-quorum decision: own stake at review open vs the at-open
        // quorum snapshot. Shared with the `outcomeOf` view via `_isBlocked`
        // so the two can never disagree.
        bool blocked_ = _isBlocked(r);

        // CEI: commit state BEFORE the external slash call.
        r.resolved = true;
        r.blocked = blocked_;

        if (blocked_) {
            // Slash every approver. The slash factor is DETERMINISTIC — a
            // quadratic ramp of block-side decisiveness from the at-open block
            // quorum to `SUPERMAJORITY_BPS`, computed by `_severityBps`. Severity
            // is not voted. Pass `r.openedAt` so sWOOD sizes each slash off the
            // approver's raw own-stake checkpoint at review open.
            swood.slashGuardians(key, uint256(r.openedAt), _approvers[key], _severityBps(r));
            _emitBlockerAttribution(key, governor, proposalId);
        }

        emit ReviewResolved(proposalId, blocked_, 0);
        return blocked_;
    }

    /// @dev Deterministic slash severity from block-side decisiveness: the winning
    ///      side of a review must not choose the losers' penalty. Quadratic ramp
    ///      from the at-open block quorum (floor — a scraped quorum is a genuinely
    ///      contested call) to `SUPERMAJORITY_BPS` (ceiling — overwhelming
    ///      condemnation). Approvers cannot lower it and blockers gain nothing by
    ///      inflating it, since slashed WOOD burns and blocker rewards are
    ///      epoch-level. Only called when the block quorum was reached, so
    ///      `bBps >= qBps` up to rounding; the other branch floors defensively.
    /// @dev READS THE AT-OPEN ENVELOPE, NOT THE LIVE SLOTS (pashov review
    ///      finding #11). See `Review.minSlashBpsAtOpen` for why a live read
    ///      here let the owner nullify or maximise an already-decided review in
    ///      the same transaction that committed it.
    function _severityBps(Review storage r) private view returns (uint256) {
        uint256 lo = uint256(r.minSlashBpsAtOpen);
        uint256 hi = uint256(r.maxSlashBpsAtOpen);
        uint256 denom = uint256(r.totalStakeAtOpen);
        if (denom == 0) return lo; // defensive: a reached quorum implies denom > 0
        uint256 bBps = uint256(r.blockStakeWeight) * 10_000 / denom;
        uint256 qBps = uint256(r.blockQuorumBpsAtOpen);
        if (qBps >= SUPERMAJORITY_BPS || bBps >= SUPERMAJORITY_BPS) return hi;
        if (bBps <= qBps) return lo;
        // t in 1e18 fixed point; severity = lo + (hi - lo) * t^2.
        // Two de-scalings: the inner `t * t / 1e18` yields t^2 still in 1e18
        // fixed point; the outer `* (hi - lo) / 1e18` then applies that t^2 as
        // a fraction of the (hi - lo) span, landing back in plain bps. When
        // hi == lo the span is 0 and the ramp term vanishes to a clean `lo`.
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
        if (er.callsHash == bytes32(0) || _effNow(er.clockShiftAtOpen) < er.reviewEnd) {
            revert ReviewNotReadyForResolve();
        }
        if (!er.resolved) _resolveEmergency(eKey, proposalId, er);
        BatchExecutorLib.Call[] memory result = _loadEmergencyCalls(eKey);
        delete _emergencyCalls[eKey];
        return (er.blocked, result);
    }

    /// @notice Permissionless keeper entrypoint — commits emergency review
    ///         resolution and slashes the vault owner if blocked. Does NOT
    ///         return or execute calls. The governor's `finalizeEmergencySettle`
    ///         must still be called to execute the calls (if not blocked).
    /// @dev Permissionless slash path so the bond deterrent works even if
    ///      the owner never calls `finalizeEmergencySettle`.
    function resolveEmergencyReview(address governor, uint256 proposalId) external whenNotPaused {
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();
        bytes32 eKey = _reviewKey(governor, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        // See finalizeEmergency: callsHash==0 = never-opened or cancelled.
        if (er.callsHash == bytes32(0) || _effNow(er.clockShiftAtOpen) < er.reviewEnd) {
            revert ReviewNotReadyForResolve();
        }
        if (er.resolved) return; // idempotent
        _resolveEmergency(eKey, proposalId, er);
    }

    /// @dev Shared resolution logic for `finalizeEmergency` and
    ///      `resolveEmergencyReview`. Commits flags and slashes the vault
    ///      owner's bond on sWOOD if blocked. Reads `er.governor` (set at
    ///      `openEmergency`) instead of the removed singleton to locate the vault.
    function _resolveEmergency(bytes32, uint256 proposalId, EmergencyReview storage er) private {
        // Cold-start cohort -> blocked=false regardless of votes.
        bool blocked_;
        if (!er.cohortTooSmall) {
            uint256 denomE = uint256(er.totalStakeAtOpen);
            if (denomE > 0) {
                blocked_ = (uint256(er.blockStakeWeight) * 10_000 >= uint256(er.blockQuorumBpsAtOpen) * denomE);
            }
        }
        er.resolved = true;
        er.blocked = blocked_;
        if (blocked_) {
            address vault = vaultOf[er.governor];
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
    /// @dev Active-guardian-only, block-only side, one vote per guardian. Weight
    ///      is read at `er.openedAt` and growth-gated via
    ///      `_growthGatedVoteWeight`: the emergency block-quorum denominator is
    ///      already the lookback-min, so a voter's own weight must be capped the
    ///      same way or fresh stake escapes on the numerator side only.
    function voteBlockEmergencySettle(address governor, uint256 proposalId) external whenNotPaused {
        if (!_authorizedGovernors.contains(governor)) revert UnauthorizedGovernor();
        bytes32 eKey = _reviewKey(governor, proposalId);
        EmergencyReview storage er = _emergencyReviews[eKey];
        // Mirrors `voteOnProposal`'s `resolved` guard. The `reviewEnd` test
        // alone is NOT sufficient here: `cancelEmergency` repurposes `reviewEnd`
        // as a post-cancel cooldown deadline, so for a whole `reviewPeriod`
        // after a cancel `block.timestamp < er.reviewEnd` still holds —
        // without this check, votes would be accepted into an
        // already-resolved review.
        if (er.resolved) revert ReviewNotOpen();
        if (er.reviewEnd == 0 || _effNow(er.clockShiftAtOpen) >= er.reviewEnd) revert ReviewNotOpen();
        if (!swood.isActiveGuardian(msg.sender)) revert NotActiveGuardian();
        uint256 round = er.round;
        if (_emergencyBlockVotes[eKey][round][msg.sender]) revert AlreadyVoted();

        uint256 weight256 = _growthGatedVoteWeight(swood, msg.sender, uint256(er.openedAt));
        if (weight256 == 0) revert NotActiveGuardian(); // no votable weight at open time
        uint128 weight = uint128(weight256);
        _emergencyBlockVotes[eKey][round][msg.sender] = true;
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
        // A PAUSE DEFERS REVIEW CLOCKS, IT DOES NOT CONSUME THEM (pashov
        // review finding #7). Review windows are wall-clock, but every writer
        // into them — `openReview`, `voteOnProposal`,
        // `voteBlockEmergencySettle` — is `whenNotPaused`. A pause spanning
        // `[voteEnd, reviewEnd)` therefore left `r.opened == false` with no
        // guardian able to change that, and BOTH readers treat that emptiness
        // as a clean bill of health rather than an undetermined one:
        // `resolveReview` short-circuits `if (!r.opened) { resolved = true;
        // return false; }` and `outcomeOf` returns `Cleared`. The proposal
        // then executed with a guardian review that structurally could not
        // happen — the veto failing OPEN, and needing no malice at all, since
        // an ordinary incident pause does it.
        //
        // Accumulating the paused span here and subtracting it in `_effNow`
        // gives every review whose clock was already running the time back,
        // while reviews registered later start from the new baseline and are
        // unaffected.
        pauseShiftTotal += uint64(block.timestamp - uint256(pausedAt));
        paused = false;
        pausedAt = 0;
        emit Unpaused(msg.sender, deadman);
    }

    // ── Parameter setters (owner-instant; owner is a multisig with external delay) ──

    /// @inheritdoc IGuardianRegistry
    /// @dev Enforces the absolute `[6 hours, 3 days]` bounds AND the
    ///      `coolDownPeriod >= reviewPeriod` cross-contract invariant: the review
    ///      window may not exceed sWOOD's guardian unstake cooldown, or an
    ///      approver could unstake and escape the slash before `resolveReview`.
    ///      The cross-call is gated behind a wired sWOOD for the pre-wiring window.
    function setReviewPeriod(uint256 v) external onlyOwner {
        if (v < minReviewPeriod || v > 3 days) revert InvalidParameter();
        IStakedWood sw = swood;
        if (address(sw) != address(0) && v > sw.coolDownPeriod()) {
            revert CooldownBelowReviewPeriod();
        }
        // MIRROR OF THE LEDGER'S FLOOR. `ExposureLedger` requires
        // `challengeWindow >= reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW`, but
        // can only enforce it when ITS setter runs. Raising `reviewPeriod` here
        // raises the floor from the other side with nothing revalidating: a window
        // seated legally at a 3d review period sits below the floor once the
        // review period reaches 7d.
        IExposureLedger led = exposureLedger;
        if (address(led) != address(0) && led.challengeWindow() < v + MAX_GOVERNOR_EXECUTION_WINDOW) {
            revert InvalidParameter();
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

    /// @inheritdoc IGuardianRegistry
    /// @notice Wire the exposure ledger (owner-instant; the owner is a multisig
    ///         with external delay).
    /// @dev Mirrors `setReviewPeriod`'s and `ExposureLedger.setGuardianRegistry`'s
    ///      enforcement of
    ///      `challengeWindow >= reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW`.
    ///      This was the fourth door on that invariant and enforced nothing —
    ///      reachable via an ordinary wiring order: seat `reviewPeriod` while
    ///      unwired, then wire a ledger whose `challengeWindow` sits below the
    ///      resulting floor, leaving a live anti-batching break nothing upstream
    ///      re-validates.
    ///
    ///      STRICT, not tolerant, on purpose — the opposite of
    ///      `ExposureLedger.setGuardianRegistry`'s guarded read. That setter can
    ///      afford to admit a registry that cannot answer, because nothing
    ///      downstream depends on the read succeeding. This one cannot: once the
    ///      ledger is set, `setReviewPeriod` calls `challengeWindow()` directly,
    ///      with no try/catch, so admitting an unanswerable ledger would
    ///      permanently freeze `reviewPeriod`. Both external reads below are
    ///      plain, unguarded calls: a ledger that cannot serve them reverts THIS
    ///      transaction instead of bricking a later, unrelated one.
    ///
    ///      Also checks the reciprocal grant: `ledger.guardianRegistry()` must be
    ///      either unset (the legitimate first-time-wiring order) or already this
    ///      registry. A ledger bound to some OTHER registry would make every
    ///      future `recordApproval` revert forever, silently turning every review
    ///      into a block-only vote with no approve-side coverage.
    function setExposureLedger(address ledger) external onlyOwner {
        if (ledger == address(0)) revert ZeroAddress();
        IExposureLedger led = IExposureLedger(ledger);
        // STRICT, unguarded reads — see the @dev block above. A ledger that
        // cannot answer `challengeWindow()` or `guardianRegistry()` (no code,
        // a CREATE2 counterfactual not yet deployed, or any other
        // non-conforming target) reverts THIS wiring transaction rather than
        // being admitted and bricking a later, unrelated one.
        uint256 cw = led.challengeWindow();
        if (cw < reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW) revert InvalidParameter();
        // Reciprocal-grant check. Only reject a ledger already bound to a
        // DIFFERENT registry — address(0) is the legitimate first-time-wiring
        // state (see the @dev block above).
        address boundRegistry = ILedgerRegistryPointer(ledger).guardianRegistry();
        if (boundRegistry != address(0) && boundRegistry != address(this)) revert InvalidParameter();
        emit ExposureLedgerSet(address(exposureLedger), ledger);
        exposureLedger = led;
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

    /// @inheritdoc IGuardianRegistry
    /// @dev Pure mirror of `resolveReview`'s committed result. Branch order:
    ///      (1) resolved -> the cached `blocked` flag; (2) before `reviewEnd`, or
    ///      unregistered -> `Unresolved`; (3) window elapsed but not committed ->
    ///      `Cleared` when the review was never opened or the cohort was too
    ///      small, else `_isBlocked` decides. The short-circuits stay OUTSIDE
    ///      `_isBlocked`, exactly as `resolveReview` applies them.
    function outcomeOf(address governor, uint256 proposalId) external view returns (ReviewOutcome) {
        Review storage r = _reviews[_reviewKey(governor, proposalId)];
        if (r.resolved) {
            return r.blocked ? ReviewOutcome.Blocked : ReviewOutcome.Cleared;
        }
        // Pause-adjusted, matching `resolveReview` — see `_effNow` (pashov
        // review finding #7). `ProposalLifecycle._afterVote` reads this, so
        // reporting `Cleared` on wall clock here would approve the proposal
        // even while `resolveReview` still considers the window open.
        if (r.reviewEnd == 0 || _effNow(r.clockShiftAtRegister) < r.reviewEnd) {
            return ReviewOutcome.Unresolved;
        }
        if (!r.opened || r.cohortTooSmall) {
            return ReviewOutcome.Cleared;
        }
        return _isBlocked(r) ? ReviewOutcome.Blocked : ReviewOutcome.Cleared;
    }
}
