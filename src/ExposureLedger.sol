// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IWoodTwapOracle} from "./interfaces/IWoodTwapOracle.sol";

/// @dev Narrow sWOOD read surface (own stake, cooldown). Mirrors the
///      IGovernorMinimal pattern in GuardianRegistry — the ledger does not
///      import the full IStakedWood ABI.
interface ISwoodMinimal {
    function guardianStake(address guardian) external view returns (uint256);
    function coolDownPeriod() external view returns (uint256);
    /// @dev Issue #35: anchor-aware slash basis, shared with
    ///      `StakedWood._slashOne`. `min(max(liability at anchor,
    ///      votableStake at anchor), liveStake)`.
    function slashableStakeAt(address guardian, uint256 anchor) external view returns (uint256);
}

interface IAggregatorMinimal {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IERC20DecimalsMinimal {
    function decimals() external view returns (uint8);
}

interface ILedgerGovernorMinimal {
    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
        uint256 executeBy;
        uint256 strategyDuration;
        /// @dev 0 until the proposal has executed. Issue #35: the anchor
        ///      every post-execution coverage read (`allocatedUsd`,
        ///      `liabilityUsd`/`_effectiveTotal`, `settleCoverage`/
        ///      `_effectiveReservedTotal`) values guardians at, via
        ///      `swood.slashableStakeAt`, instead of live stake.
        uint256 executedAt;
    }

    function getProposalView(uint256 proposalId) external view returns (ProposalViewLite memory);
    function getRequiredCoverage(uint256 proposalId) external view returns (uint256);
}

interface IVaultAssetMinimal {
    function asset() external view returns (address);
}

interface IRegistryApproversMinimal {
    function getApproverWeights(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 totalApproveWeight);
    /// @dev Read by `setChallengeWindow` to floor the window at the longest
    ///      approve->execute gap a proposal can have.
    function reviewPeriod() external view returns (uint256);
}

/**
 * @title ExposureLedger
 * @notice Dollar-denominated coverage accounting for the guardian
 *         economic-security model (spec §3.3, §3.3a, §3.7).
 *
 *         `slashableBond(g)` (spec §3.3): ownStake(g) * priceHaircut. The
 *         guardian's own bond is the only slashable capital.
 *
 *         Exposure is EPOCH-BUCKETED (spec §3.4a): an approval consumes the
 *         current epoch's bucket; open exposure = the sum of all buckets young
 *         enough that their challenge window has not elapsed. Guardian
 *         commitment per approval is therefore bounded at one epoch + challenge
 *         window regardless of strategy duration.
 *
 * @dev    WOOD IS PRICED BY THE MARKET, CAPPED BY GOVERNANCE (design revision
 *         2, 2026-08-02). `woodPriceX8()` resolves:
 *
 *             sourceX8 = feed fresh ? min(feedX8, woodUsdPriceX8)
 *                      : twap fresh ? min(twapX8, woodUsdPriceX8)
 *                      :              revert NoWoodPrice
 *             price    = haircut(sourceX8), floored at 1
 *
 *         `woodUsdPriceX8` is NEVER SERVED AS A PRICE. It is only ever a cap on
 *         whatever the market reports, so the market may LOWER a bond's value
 *         and never raise it, and lowering the cap is the emergency brake.
 *
 *         The earlier arrangement — a maintained scalar as the price, with a
 *         Chainlink feed superseding it — was inverted by the 2026-08-01 audit:
 *         a manually maintained number sitting above market makes guardians
 *         look better collateralised than they are and clears
 *         `requireApproveQuorum` on collateral that does not exist, silently
 *         and for as long as nobody notices. Under the cap-only model that
 *         drift is inert: a cap above market simply stops binding, and a cap
 *         below market only under-values bonds, which is the safe direction.
 *
 *         WHAT IT COSTS: there is no longer a branch that keeps pricing when
 *         all market data is gone, so `NoWoodPrice` is reachable in production.
 *         That is deliberate and the halting semantics are chosen per consumer
 *         — see `IExposureLedger.NoWoodPrice`. In one line: votes still work,
 *         nothing new can be proposed, nothing can execute.
 *
 * @dev    ══ TRUST MODEL: THE OWNER IS UNRESTRICTED HERE, BY DESIGN ══
 *
 *         `setWoodUsdPrice` and `setWoodHaircutBps` impose NO rate limit and no
 *         per-call size ceiling. The owner may move either lever to any legal
 *         value, any number of times, within a single block.
 *
 *         THIS IS NOT AN OVERSIGHT AND IT IS NOT A REGRESSION TO FILE. Rate
 *         limiting is enforced OFF-CHAIN, by a Zodiac Delay/Roles module on the
 *         owner Safe (issue #89, owner decision 2026-08-02). Earlier revisions
 *         carried a 1-day interval plus a 2x-per-raise ceiling on the cap; both
 *         were removed together, because the interval was the only thing making
 *         the ceiling a rate limit — N calls in one multisig batch move the
 *         price 2^N — so keeping the ceiling alone would have advertised a
 *         protection its own subject can bypass.
 *
 *         The reason for moving it rather than fixing it: the interval gated
 *         BOTH directions, and after design revision 2 lowering the cap IS the
 *         emergency action. A self-limit on an already-trusted owner therefore
 *         cost crisis responsiveness — a routine morning adjustment spent the
 *         lever and left no brake that afternoon — for very little gain.
 *
 *         AUDITORS AND REVIEWERS: the control you are looking for is in the
 *         Safe's module configuration, which is invisible from this source. The
 *         requirement it must satisfy is an ASYMMETRIC delay — raises delayed,
 *         drops immediate — because a plain Delay module is symmetric and would
 *         relocate the problem rather than solve it. `DeployPlanB` asserts the
 *         owner is a contract rather than a bare EOA, which is the most this
 *         contract can check; the rest is a runbook obligation recorded in
 *         `openspec/specs/deployment-docs/spec.md`.
 */
contract ExposureLedger is Ownable2Step, IExposureLedger {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Mirrors `GovernorParameters.MAX_EXECUTION_WINDOW`. Duplicated as a
    ///      constant rather than read across, because the ledger has no handle
    ///      on any particular governor at `setChallengeWindow` time — the floor
    ///      has to hold for EVERY governor the registry serves, so it is sized
    ///      against the worst legal configuration rather than a live one. Keep
    ///      in step if the governor's ceiling ever moves.
    uint256 internal constant MAX_GOVERNOR_EXECUTION_WINDOW = 7 days;

    /// @dev How far ahead of NOW a commitment may be dated. Expressed in TIME,
    ///      not in epochs, on purpose: the bucket width is a tuning dial (see
    ///      `MAX_SCAN_BUCKETS`), and an epoch-count horizon would silently
    ///      shrink to nothing the moment someone narrowed the buckets — a 30d
    ///      strategy would start reverting `CoverageHorizonExceeded` for no
    ///      reason a reader could see. 60 days clears a 30d duration cap plus a
    ///      7d execution window with room to spare.
    uint256 internal constant MAX_COVERAGE_HORIZON = 60 days;

    /// @dev Hard ceiling on how many buckets `openExposureUsd` may walk, so the
    ///      bucket width can be tuned for precision without unbounding the
    ///      loop: narrower buckets release a guardian's short commitments
    ///      without waiting on their long ones, at the cost of a longer scan.
    uint256 internal constant MAX_SCAN_BUCKETS = 16;

    /// @dev Floor on `woodHaircutBps`. Valuing bonds below half of market is a
    ///      mis-set parameter, not a conservatism policy.
    uint256 internal constant MIN_WOOD_HAIRCUT_BPS = 5_000;

    bytes32 public constant PARAM_CHALLENGE_WINDOW = keccak256("challengeWindow");
    bytes32 public constant PARAM_K_NUMERATOR = keccak256("kNumerator");
    bytes32 public constant PARAM_COVERED_TVL_CAP = keccak256("coveredTvlCapUsd");
    bytes32 public constant PARAM_QUORUM_TIER_THRESHOLD = keccak256("quorumTierThreshold");
    bytes32 public constant PARAM_PROPOSER_BOND_BPS = keccak256("proposerBondBps");

    ISwoodMinimal public immutable swood;
    /// @notice Epoch length (spec §5: 28d initial). Immutable — changing it
    ///         would shift every existing bucket index.
    uint256 public immutable epochLength;
    uint256 public immutable epochGenesis;

    /// @notice CAP on the WOOD→USD price, 8 decimals. Never served as a price.
    ///
    /// @dev    SEED IT ABOVE MARKET. Its whole job is to bound how far a market
    ///         source can be manipulated UPWARD; kept within `M×` of market,
    ///         upward manipulation is capped at `M×`. A cap set BELOW market —
    ///         the old "conservative, ≤ 30-day low" reading — binds
    ///         permanently, pins every bond at the cap, and makes the market
    ///         source inert, which is precisely the arrangement design revision
    ///         2 replaced.
    ///
    ///         It no longer needs ACCURACY, because it is never the valuation;
    ///         a monthly review is sufficient, since drift degrades the cap
    ///         gradually and never mis-prices anything. It does still need
    ///         MAINTENANCE — it is the only thing bounding upward manipulation
    ///         of a ~$438k pool.
    uint256 public woodUsdPriceX8;
    /// @notice Post-epoch challenge window (spec §5: 14d initial, single window
    ///         in v1 — per-tier windows are a later refinement).
    uint256 public challengeWindow = 14 days;
    /// @notice k multiplier for the exposure cap (spec §5: k = 1).
    uint256 public kNumerator = 1;
    /// @notice Hard per-vault covered-TVL ceiling in USD-18 (spec §3.7). A
    ///         proposal whose coverage exceeds this cannot be opened. Zero =
    ///         cap unset = NOTHING can be proposed through a wired governor —
    ///         fail-closed until governance seeds it.
    uint256 public coveredTvlCapUsd;
    /// @notice Minimum envelopeTier at which the approve quorum is fail-closed
    ///         (spec §3.3a + §4 gate 2). Launch value 0: every tier.
    ///
    /// @dev    Coverage sizing is per-tier (`requiredCoverage = maxCapital ×
    ///         Σ boundBps / 10_000`), so a closed-loop adapter that can leak 1%
    ///         requires 1% of coverage. Zero makes the guardian layer mandatory
    ///         for every tier rather than advisory below the threshold.
    ///
    ///         `requiredCoverage == 0` still passes optimistically at every
    ///         tier — that carve-out lives at the governor call site, not here:
    ///         a proposal that can extract nothing has nothing to underwrite.
    uint8 public quorumTierThreshold = 0;
    /// @notice Proposer bond as bps of USD coverage (spec §3.9/§5). Default 1%.
    uint256 public proposerBondBps = 100;

    /// @notice Chainlink WOOD/USD feed. Once wired it is the PREFERRED market
    ///         source; the TWAP oracle serves only while it is unset or
    ///         degraded. Still capped by `woodUsdPriceX8` like every source.
    /// @dev    Reuses the same `AssetFeed` shape and staleness handling as the
    ///         vault-asset feeds, so WOOD is priced by the machinery already
    ///         exercised by `coverageUsd` rather than a parallel path.
    ///         Expected to stay UNSET on chain 4663 — there is no WOOD/USD
    ///         aggregator there — which is why the TWAP oracle is not an
    ///         optional extra but the live source.
    AssetFeed internal _woodFeed;

    /// @notice The WOOD/WETH TWAP oracle (`IWoodTwapOracle`), or zero.
    /// @dev    Not `immutable` and not a constructor argument: the ledger is
    ///         deployed before the oracle has a completed averaging window, and
    ///         a bad oracle must be rotatable without redeploying the ledger.
    ///         Every read of it is defensive — see `_twapPriceX8`.
    address public woodTwapOracle;

    /// @notice Haircut applied to whichever market source won, in bps.
    ///
    /// @dev    Collateral wants a floor, not a quote — an unhaircut oracle
    ///         tracks WOOD UP and inflates every bond exactly when the market is
    ///         frothy. Default 10_000 (no haircut) so wiring a source alone does
    ///         not silently change valuations; governance sets it deliberately.
    ///
    /// @dev    THIS PARAMETER IS LOAD-BEARING (owner decision 2026-08-02). It is
    ///         the compensating control for the two exposures this design
    ///         deliberately ACCEPTS rather than eliminates, and once a price has
    ///         cleared the cap it is the only thing standing under either:
    ///
    ///           1. NON-CONTEMPORANEOUS LEGS in `WoodTwapOracle`. The WOOD/ETH
    ///              average is near-real-time; the ETH/USD answer may be up to
    ///              one heartbeat old (~10.7h measured on 4663, WHILE HEALTHY).
    ///              During an ETH drawdown inside that heartbeat the product
    ///              reads HIGH by roughly the ETH move — no attacker capital
    ///              involved. Constraining it would force a ~12-hour averaging
    ///              window, which is worse; see that contract's ACCEPTED RISK
    ///              note.
    ///           2. RESIDUAL CRASH LAG of up to `twapWindow + maxTwapAge`,
    ///              inherent to averaging and the price of manipulation
    ///              resistance.
    ///
    ///         Both OVERSTATE bond value — the dangerous direction — and the
    ///         haircut is what pre-funds an allowance against them. AT THE
    ///         10_000 DEFAULT THAT ALLOWANCE IS ZERO. 5_000 (the floor) absorbs
    ///         a 50% error. Shipping at the default is a deliberate choice to
    ///         run with no margin, not a neutral one.
    uint256 public woodHaircutBps = BPS_DENOMINATOR;

    // `lastPriceUpdateAt` and `lastHaircutUpdateAt` were REMOVED with the
    // in-contract rate limit (issue #89). They stamped the two setters for the
    // 1-day interval and nothing else read them — not this contract, not
    // `IExposureLedger`, not any script or test. Safe to delete rather than
    // leave as dead slots because `ExposureLedger` is NOT upgradeable
    // (constructor + immutables, deployed directly by `DeployPlanB`, no proxy)
    // and is not among the four layouts `script/check-layout-goldens.sh` pins,
    // so no deployed lineage stores state at these offsets.

    address public guardianRegistry;

    /// @dev Per-asset USD feed config. `assetDecimals` cached at registration so
    ///      the hot path makes no external metadata call.
    struct AssetFeed {
        address feed;
        uint64 maxDelay;
        uint8 assetDecimals;
        uint8 feedDecimals;
    }

    mapping(address asset => AssetFeed) internal _assetFeeds;

    struct RecordedExposure {
        uint192 usd;
        uint64 epoch;
    }

    mapping(address guardian => mapping(uint256 epoch => uint256 usd)) internal _buckets;
    mapping(bytes32 reviewKey => mapping(address guardian => RecordedExposure)) internal _recorded;

    /// @dev Total USD RESERVED by all approvers of a proposal — runs to A x
    ///      coverage while the review is open, NOT to `coverage`, because each
    ///      approver reserves up to the whole thing in case it ends up
    ///      carrying the proposal alone.
    ///
    ///      Stays the reservation total for the life of the key; only
    ///      `recordApproval` and `releaseApproval` move it. Settlement derives
    ///      from this and `_reservedUsd` rather than overwriting it, so a
    ///      settlement pass is always re-derivable from unchanged inputs.
    mapping(bytes32 reviewKey => uint256 usd) internal _committedUsd;

    /// @dev The reservation `recordApproval` booked, preserved verbatim while
    ///      the approver is listed.
    ///
    ///      `_recorded[key][g].usd` is the guardian's CURRENT booking, which
    ///      `settleCoverage` rewrites; this is the immutable input that rewrite
    ///      is derived FROM. Keeping the two apart is what makes settlement
    ///      re-runnable rather than a latch.
    mapping(bytes32 reviewKey => mapping(address guardian => uint256 usd)) internal _reservedUsd;

    /// @dev Whether `settleCoverage` has run at least once for a proposal.
    ///      OBSERVABILITY ONLY — it does not gate. `_reservedUsd` keeps the
    ///      pledge basis, so a re-run recomputes from the same inputs instead
    ///      of compounding.
    mapping(bytes32 reviewKey => bool) internal _settled;

    /// @dev The ledger's own approver list per proposal. Read by
    ///      `requireApproveQuorum` INSTEAD of the guardian registry: the ledger
    ///      books commitments itself, so the ledger's and governor's registry
    ///      pointers can never disagree about who approved.
    mapping(bytes32 reviewKey => address[]) internal _approversOf;
    /// @dev 1-INDEXED position in `_approversOf`; 0 means "not listed". Carries
    ///      the index rather than a bare flag so `releaseApproval` can
    ///      swap-and-pop in O(1), keeping the array bounded by currently-active
    ///      approvers rather than growing with everyone who ever approved.
    mapping(bytes32 reviewKey => mapping(address guardian => uint256)) internal _approverIndex;

    /// @notice The one address permitted to freeze a proposal's coverage — the
    ///         ChallengeGame (spec §3.4). Owner-set.
    address public coverageFreezer;

    /// @dev Proposals whose committed coverage is pinned by a live challenge.
    mapping(bytes32 reviewKey => bool) internal _frozen;

    /// @dev Which guardians a given frozen key is holding, so `unfreezeCoverage`
    ///      releases exactly what `freezeCoverage` took and the per-guardian
    ///      counter below cannot drift.
    mapping(bytes32 reviewKey => mapping(address guardian => bool)) internal _frozenFor;

    /// @dev How many frozen proposals name this guardian. Non-zero is what
    ///      makes the freeze load-bearing: sWOOD reads it on the unstake claim,
    ///      so a guardian under live accusation cannot walk its collateral out
    ///      after its epoch bucket ages out. A COUNT rather than a USD sum on
    ///      purpose — the claim gate's question is binary, and summing would
    ///      double-count against the live buckets and silently tighten the
    ///      batching cap, which is a different control.
    mapping(address guardian => uint256) internal _frozenCommitments;
    /// @notice The latest instant through which a guardian's coverage is
    ///         pinned open, independent of whether any challenge naming them
    ///         is currently LIVE (issue #95).
    /// @dev A MAX, not a per-key value. A guardian can be pinned by more than
    ///      one accusation at once, and `pinCoverageUntil` only ever raises
    ///      this — so a later accusation's deadline correctly outlives an
    ///      earlier one's, and once the LATEST of them elapses, so does the
    ///      pin for everyone it covered. No release call is needed: unlike
    ///      `_frozenCommitments`, which requires an explicit `unfreezeCoverage`
    ///      to clear, this decays on its own by wall-clock — the same way
    ///      `openExposureUsd`'s epoch buckets do, and for the same reason: a
    ///      value nobody has to remember to unwind cannot be forgotten.
    mapping(address guardian => uint256) internal _pinnedCoverageUntil;

    /// @dev How many proposals are frozen right now, across every guardian.
    ///      Lets `setCoverageFreezer` refuse a rotation that would orphan a
    ///      live freeze.
    uint256 internal _frozenKeyCount;

    /// @notice EXACT, NON-WALL-CLOCK-DECAYING sum of `_recorded[key][guardian]
    ///         .usd` across every key currently listing `guardian` as an
    ///         approver (Pashov re-audit of #158, finding 2, confidence 85).
    ///
    /// @dev    THE SHARED-STAKE DENOMINATOR, BOOKING BASIS. Before this,
    ///         `_sharedSlashableUsd` divided by `openExposureUsd(guardian)` —
    ///         a rolling WALL-CLOCK bucket scan — as a proxy for "sum of this
    ///         guardian's live open reservations." The proxy silently went
    ///         stale in at least five distinct ways (ordinary bucket aging
    ///         with no release, a frozen/pinned proposal outliving its own
    ///         bucket, an owner `setChallengeWindow` shrink, a
    ///         `ChallengeGame` `Inconclusive` re-arm outliving the bucket, and
    ///         a `_recorded`/`_reservedUsd` entry that plain never gets
    ///         released) while the NUMERATOR (`_recorded[key][g].usd`, read by
    ///         `_effectiveTotal`/`allocatedUsd`/`requireApproveQuorum`) has no
    ///         wall-clock decay of its own — it is cleared ONLY by an explicit
    ///         `releaseApproval` or a `_rebook` write. A denominator that ages
    ///         out while the numerator terms it is supposed to sum do not is
    ///         exactly the double-count Finding 2 (D9) was written to close,
    ///         reopened at the seam between two independently-decaying clocks.
    ///
    ///         This mapping instead mirrors `_buckets`' own writes exactly —
    ///         incremented in `recordApproval`, decremented in
    ///         `releaseApproval`, adjusted by `_rebook`'s delta in both
    ///         directions — but with NO wall-clock scan and NO expiry. It is
    ///         therefore, by construction, always EXACTLY `Σ over every key
    ///         still listing guardian as an approver of _recorded[key]
    ///         [guardian].usd`, which is precisely what `_sharedSlashableUsd`'s
    ///         safety argument (`Σ reserved_i == denominator`) requires when
    ///         `reserved_i` is read on the booking basis.
    ///
    ///         `openExposureUsd` ITSELF IS UNCHANGED and keeps its wall-clock
    ///         decay — it remains the correct, DELIBERATE basis for
    ///         `recordApproval`'s and `_rebook`'s BATCHING cap (issue #110):
    ///         that cap's whole point is to let a guardian's budget recycle
    ///         once a commitment ages past challengeability. The shared-stake
    ///         denominator and the batching-cap denominator answer different
    ///         questions ("what does this guardian's stake currently, really,
    ///         back?" vs. "how much of this guardian's stake may still be
    ///         newly committed?") and must not share one wall-clock-coupled
    ///         implementation, which is the root cause this mapping removes.
    ///
    ///         KNOWN, ACCEPTED TRADE-OFF: a guardian with an approval that is
    ///         never released and never settled (both permissionless,
    ///         "safe to skip" by design) stays counted here FOREVER, even long
    ///         after its own challenge window has elapsed and it is no longer
    ///         legally slashable. This is not a new problem: `_recorded[key]
    ///         [g].usd` — the numerator every sharing consumer already reads —
    ///         has the identical property today, for the identical reason
    ///         (only `releaseApproval`/`_rebook` clear it). Making the
    ///         denominator match the numerator's existing staleness is
    ///         strictly more correct than the wall-clock proxy it replaces,
    ///         never less; it does not introduce a new staleness class, it
    ///         removes an INCONSISTENT one.
    mapping(address guardian => uint256) internal _liveBookedUsd;

    /// @notice EXACT, NON-WALL-CLOCK-DECAYING sum of `_reservedUsd[key]
    ///         [guardian]` (the PLEDGE, not the current booking) across every
    ///         key currently listing `guardian` as an approver.
    ///
    /// @dev    THE SHARED-STAKE DENOMINATOR, PLEDGE BASIS — used only where
    ///         the numerator is also read on the pledge basis
    ///         (`_effectiveReservedTotal`/`settleCoverage`). `_reservedUsd` is
    ///         written exactly once per key (`recordApproval`) and cleared
    ///         exactly once (`releaseApproval`) — `_rebook`/`settleCoverage`
    ///         never touch it — so this accumulator only ever moves at those
    ///         two sites, mirroring `_reservedUsd`'s own lifecycle exactly.
    ///
    ///         WHY TWO ACCUMULATORS RATHER THAN ONE (Pashov re-audit of #158,
    ///         finding 4, confidence 75). `_effectiveReservedTotal` used to
    ///         divide the frozen PLEDGE numerator by the live BOOKING
    ///         denominator (`openExposureUsd`, which tracks `_recorded`, not
    ///         `_reservedUsd`) — a basis mismatch that could push the "shares
    ///         sum to <= 1" partition-of-unity property above 1 once a prior
    ///         `settleCoverage` pass had diverged the two bases on some OTHER
    ///         proposal sharing this guardian. Keeping a dedicated
    ///         pledge-basis accumulator for the pledge-basis callers (this
    ///         one) and a dedicated booking-basis accumulator
    ///         (`_liveBookedUsd`) for the booking-basis callers makes every
    ///         `_sharedSlashableUsd` call site divide by a denominator built
    ///         from EXACTLY the same basis as its own numerator, closing
    ///         finding 4 as a side effect of closing finding 2 rather than
    ///         needing a second, targeted fix — see design.md D10 for the
    ///         full reasoning and the regression test that proves it.
    mapping(address guardian => uint256) internal _livePledgedUsd;

    // ── Modifiers / helpers ──

    modifier onlyRegistry() {
        if (msg.sender != guardianRegistry) revert NotGuardianRegistry();
        _;
    }

    modifier onlyFreezer() {
        if (msg.sender != coverageFreezer) revert NotCoverageFreezer();
        _;
    }

    function _reviewKey(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId)); // same derivation as GuardianRegistry
    }

    constructor(address initialOwner, address swood_, uint256 epochLength_) Ownable(initialOwner) {
        if (swood_ == address(0)) revert ZeroAddress();
        if (epochLength_ == 0) revert InvalidParameter();
        // Deploy-time invariants on the DEFAULT challenge window — the same
        // bounds setChallengeWindow enforces: W <= L, and the unstake delay
        // must cover epoch + challenge window (spec §5).
        _requireScanBounded(challengeWindow, epochLength_);
        // `StakedWood.claimUnstakeGuardian` guards the exit directly via
        // `openExposureUsd`, so no cooldown-length invariant is enforced here.
        // The gate fails open if sWOOD's `exposureLedger` pointer is unset, so
        // deploy wiring must assert it is set.
        swood = ISwoodMinimal(swood_);
        epochLength = epochLength_;
        epochGenesis = block.timestamp;
    }

    // ── Views ──

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - epochGenesis) / epochLength;
    }

    /// @inheritdoc IExposureLedger
    function slashableBondUsd(address guardian) public view returns (uint256) {
        // LIVE (anchor = 0): no proposal-specific verdict exists at this
        // call, so there is nothing to anchor against — see
        // `_slashableBondUsd`'s natspec.
        return _slashableBondUsd(guardian, woodPriceX8(), 0);
    }

    /// @notice The WOOD/USD price every bond is valued at, 8 decimals.
    ///
    /// @dev    MARKET-PRICED, GOVERNANCE-CAPPED. A live source tracks a crash
    ///         immediately, which is the direction where lag actually hurts:
    ///         under a manual number somebody has to notice and transact while
    ///         bonds stay over-valued in the meantime. The cap is what keeps
    ///         the market source from being trusted UPWARD — the WOOD/WETH pool
    ///         is ~$438k deep, so an unbounded read from it would make that pool
    ///         the valuation basis for every guardian bond in the protocol.
    ///
    ///         REVERTS `NoWoodPrice` when no source can price WOOD. See
    ///         `IExposureLedger.NoWoodPrice` for why that is fail-safe rather
    ///         than a halt, and which single consumer catches it.
    function woodPriceX8() public view returns (uint256) {
        (uint256 price,,) = _woodPrice();
        return price;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Exists because both degraded states are otherwise invisible: there
    ///      is no event on either, and `woodUsdPriceX8` carries no `updatedAt`
    ///      of its own, so "TWAP healthy" and "cap has drifted under market and
    ///      has been pinning every bond for a month" read identically from
    ///      outside. §6 monitoring cannot alert on a condition it cannot
    ///      observe.
    function woodPriceDetail() external view returns (uint256 price, bool fromFeed, bool capBinding) {
        return _woodPrice();
    }

    /// @dev THE RESOLUTION ORDER, and why each branch is where it is:
    ///
    ///        cap == 0                 -> revert (finding 7)
    ///        feed fresh               -> min(feed, cap)
    ///        else twap fresh          -> min(twap, cap)
    ///        else                     -> revert NoWoodPrice
    ///
    ///      ZERO CAP IS A REVERT, NOT "UNCAPPED". Treating it as "no ceiling"
    ///      would make the single most likely misconfiguration — a ledger
    ///      deployed before governance seeded the number — the one state in
    ///      which a ~$438k pool prices every bond without bound. Fail-closed is
    ///      the only safe reading, and `DeployPlanB` asserts the cap
    ///      post-broadcast so the revert is a configuration guard rather than a
    ///      live failure mode.
    ///
    ///      THE `min` IS THE WHOLE SAFETY ARGUMENT. Push the market source UP
    ///      and the `min` ignores it — the attack is inert. Push it DOWN and
    ///      bonds are valued lower and quorums get harder: a denial of service
    ///      with no payoff. This is the invariant the change exists for, and it
    ///      is only a real bound because the cap is maintained ABOVE market.
    ///
    ///      NEITHER SOURCE FALLS BACK TO THE CAP. That was revision 1's error:
    ///      the cap is chosen high and non-binding, so serving it as a price
    ///      when market data stops arriving fails in the dangerous direction at
    ///      exactly the moment there is nothing to check it against.
    function _woodPrice() internal view returns (uint256 price, bool fromFeed, bool capBinding) {
        uint256 cap = woodUsdPriceX8;
        if (cap == 0) revert NoWoodPrice();

        uint256 marketX8;
        (marketX8, fromFeed) = _feedPriceX8();
        if (!fromFeed) {
            bool twapOk;
            (marketX8, twapOk) = _twapPriceX8();
            if (!twapOk) revert NoWoodPrice();
        }

        capBinding = cap < marketX8;
        uint256 sourceX8 = capBinding ? cap : marketX8;
        price = _haircut(sourceX8);
        // FLOOR AT 1 (finding 6). `_haircut` truncates, so a source small
        // enough — below 2 wei-X8 at the 5,000 bps floor — resolves to a price
        // of exactly zero, and zero is not "very cheap" to the consumers: it
        // reverts `WoodPriceUnset` in `ChallengeGame.file` and makes
        // `proposerBondWood` revert `InvalidParameter`. One wei-X8 keeps those
        // paths alive at a valuation that is still, correctly, negligible.
        // Guarded on `sourceX8 != 0` so a genuinely zero source stays zero
        // rather than being invented into existence.
        if (price == 0 && sourceX8 != 0) price = 1;
    }

    /// @dev The Chainlink WOOD/USD leg, normalised to 8 decimals. EVERY failure
    ///      mode reports unavailable rather than reverting, including a bare
    ///      revert from `latestRoundData`: a reverting aggregator must fall
    ///      through to the TWAP, not take the price path down with it.
    ///
    ///      `code.length` is checked FIRST because Solidity's extcodesize guard
    ///      on a high-level call to a codeless address reverts in THIS frame,
    ///      which `try` cannot catch — the same reason `setGuardianRegistry`
    ///      guards its tolerant read that way.
    function _feedPriceX8() internal view returns (uint256 priceX8, bool ok) {
        AssetFeed storage f = _woodFeed;
        address feed = f.feed;
        if (feed == address(0) || feed.code.length == 0) return (0, false);
        try IAggregatorMinimal(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return (0, false);
            uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
            if (age > f.maxDelay) return (0, false);
            // Normalise to 8 decimals. `answer > 0` checked above.
            // forge-lint: disable-next-line(unsafe-typecast)
            return ((uint256(answer) * 1e8) / (10 ** f.feedDecimals), true);
        } catch {
            return (0, false);
        }
    }

    /// @dev The TWAP leg. A LOW-LEVEL STATICCALL, not a typed `try`, and the
    ///      `ok` flag is decoded as a `uint256`.
    ///
    ///      `abi.decode(ret, (uint256, bool))` REVERTS — uncatchably, in this
    ///      frame — on any second word that is not 0 or 1. A wired contract
    ///      whose `consult()` returns a dirty word would therefore take the
    ///      entire price path down, which is exactly the failure this defensive
    ///      wrapper exists to prevent. Decoding both words as `uint256` and
    ///      comparing the flag against 1 cannot revert on any return data, and
    ///      treats anything that is not a clean `true` as unavailable.
    ///
    ///      `code.length` first, for the same extcodesize reason as
    ///      `_feedPriceX8`; a short return is rejected before decoding; and a
    ///      zero price is rejected because `min(0, cap)` would drag every bond
    ///      to nothing exactly as silently as the failure this replaced.
    function _twapPriceX8() internal view returns (uint256 priceX8, bool ok) {
        address oracle = woodTwapOracle;
        if (oracle == address(0) || oracle.code.length == 0) return (0, false);
        (bool success, bytes memory ret) = oracle.staticcall(abi.encodeCall(IWoodTwapOracle.consult, ()));
        if (!success || ret.length < 64) return (0, false);
        (uint256 twapX8, uint256 flag) = abi.decode(ret, (uint256, uint256));
        if (flag != 1 || twapX8 == 0) return (0, false);
        return (twapX8, true);
    }

    /// @dev THE HAIRCUT APPLIES TO WHATEVER SOURCE WON, and to the cap when the
    ///      cap is what bound. Applying it to only one of them would make one
    ///      branch less conservative than the other for no reason a reader
    ///      could see; applying it after the `min` keeps a single discount on a
    ///      single number.
    function _haircut(uint256 priceX8) internal view returns (uint256) {
        return (priceX8 * woodHaircutBps) / BPS_DENOMINATOR;
    }

    /// @dev `slashableBondUsd` with the loop-invariant price passed in, so a
    ///      multi-approver quorum reads it once instead of once per approver.
    ///
    ///      ANCHOR-AWARE (issue #35). `anchor == 0` reads LIVE
    ///      `guardianStake` — the pre-execution basis, used where no verdict
    ///      anchor exists yet (`recordApproval`'s budget cap,
    ///      `requireApproveQuorum`'s execute-time gate, and the public
    ///      `slashableBondUsd` view) and where any stake present is still
    ///      reachable. `anchor != 0` reads `swood.slashableStakeAt(guardian,
    ///      anchor)` instead — `min(snapshot at anchor, live)`, exactly what a
    ///      verdict slash anchored at that instant (`StakedWood._slashOne`)
    ///      can recover — so a guardian who tops up stake AFTER the anchor
    ///      is never counted as coverage the conviction cannot reach. Every
    ///      post-execution ledger read (`allocatedUsd`, `_effectiveTotal`,
    ///      `settleCoverage`, `_effectiveReservedTotal`) passes
    ///      `pv.executedAt` as the anchor.
    function _slashableBondUsd(address guardian, uint256 priceX8, uint256 anchor) internal view returns (uint256) {
        uint256 stake = anchor == 0 ? swood.guardianStake(guardian) : swood.slashableStakeAt(guardian, anchor);
        return (stake * priceX8) / 1e8;
    }

    // ── Owner setters ──

    /// @notice Set the price CAP. This is the emergency brake: lowering it
    ///         lowers every bond's valuation immediately, in the safe
    ///         direction, without bound and without delay.
    ///
    /// @dev ══ NO RATE LIMIT HERE, AND THAT IS DELIBERATE (issue #89) ══
    ///
    ///      THIS FUNCTION IMPOSES NO RATE LIMIT AND NO SIZE CEILING. An owner
    ///      may set any value, any number of times, in the same block. Rate
    ///      limiting is enforced OFF-CHAIN, by a Zodiac Delay/Roles module on
    ///      the owner Safe. A reader looking for the self-limit that used to be
    ///      here should look at the Safe's module configuration, not at this
    ///      contract — see `openspec/specs/deployment-docs/spec.md`.
    ///
    ///      WHAT WAS REMOVED, AND WHY BOTH HAD TO GO TOGETHER. There was a
    ///      1-day `MIN_PRICE_UPDATE_INTERVAL` plus a `newPriceX8 <= current * 2`
    ///      ceiling on upward moves. The interval was what made the ceiling a
    ///      rate limit at all — a 2x cap with no time component is not one,
    ///      since N calls in a single multisig batch move the price 2^N. So the
    ///      ceiling could not be kept alone: it would have advertised a
    ///      protection that the exact party it constrains can trivially bypass,
    ///      which is worse than no protection, because a reviewer stops looking.
    ///
    ///      WHY IT WENT RATHER THAN BEING FIXED. The interval gated BOTH
    ///      directions while the size ceiling gated only one, so the code
    ///      limited the size of a move by direction but its timing regardless.
    ///      After design revision 2, lowering this cap IS the emergency action,
    ///      so the limit sat directly on crisis response: a routine morning
    ///      adjustment spent the lever and left no brake that afternoon. A
    ///      self-limit on an already-trusted owner bought little and cost
    ///      exactly the responsiveness it most needed to preserve.
    ///
    ///      WHAT THE OFF-CHAIN CONTROL MUST PRESERVE: the delay has to be
    ///      ASYMMETRIC — raises delayed, drops immediate. A plain Zodiac Delay
    ///      module is symmetric and would relocate this bug rather than fix it.
    ///
    ///      ZERO IS STILL ALLOWED, and under design revision 2 it is a HARD
    ///      STOP rather than a $0 valuation: `_woodPrice` reverts `NoWoodPrice`
    ///      on a zero cap, so proposing and executing halt while votes continue
    ///      to land. Rejecting zero would not prevent stopping the protocol —
    ///      1 wei-X8 comes close enough — and would strand the cap with no way
    ///      back up.
    function setWoodUsdPrice(uint256 newPriceX8) external onlyOwner {
        uint256 current = woodUsdPriceX8;
        emit WoodUsdPriceSet(current, newPriceX8);
        woodUsdPriceX8 = newPriceX8;
    }

    /// @notice Wire (or UNWIRE) the Chainlink WOOD/USD feed.
    ///
    /// @dev    ZERO IS THE UNWIRE SWITCH and it is load-bearing: it is the
    ///         governance path back from a bad aggregator, since every coverage
    ///         path prices bonds through `_woodPrice`.
    ///
    ///         Unwiring is safe ONLY WHILE A TWAP ORACLE IS WIRED — it drops to
    ///         that source, capped on the same terms. With neither wired there
    ///         is no market data and every price read reverts `NoWoodPrice`, so
    ///         an operator clearing a bad aggregator must confirm
    ///         `woodTwapOracle` is live first.
    ///
    ///         UNWIRING MUST BE SPELLED `setWoodFeed(address(0), 0)`. `maxDelay`
    ///         is REQUIRED to be zero rather than merely ignored, so a mis-typed
    ///         feed address paired with a real delay reverts instead of
    ///         silently dropping the ledger onto the governance price.
    function setWoodFeed(address feed, uint256 maxDelay) external onlyOwner {
        if (feed == address(0)) {
            // `maxDelay` must be zero too: a mis-typed address paired with a real
            // delay then reverts instead of silently unwiring the feed.
            if (maxDelay != 0) revert InvalidParameter();
            delete _woodFeed;
            emit WoodFeedSet(address(0), 0);
            return;
        }
        if (maxDelay == 0 || maxDelay > type(uint64).max) revert InvalidParameter();
        uint8 feedDecimals = IAggregatorMinimal(feed).decimals();
        // maxDelay bounded to type(uint64).max above; cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        _woodFeed = AssetFeed({
            feed: feed,
            maxDelay: uint64(maxDelay),
            assetDecimals: 18, // WOOD
            feedDecimals: feedDecimals
        });
        emit WoodFeedSet(feed, maxDelay);
    }

    /// @inheritdoc IExposureLedger
    ///
    /// @dev THE PAIR IS VALIDATED BEFORE IT IS TRUSTED. Four WOOD/WETH Uniswap
    ///      V3 pools exist on chain 4663 and all four are initialised-but-never-
    ///      traded shells: `getPool` returns a non-zero address, so "does the
    ///      pool exist?" passes and the price read comes back garbage. The V2
    ///      analogue — an oracle pointed at a pair of the right shape holding
    ///      the wrong tokens, or holding nothing — would price guardian
    ///      collateral off an unrelated market. `validatePair()` re-checks the
    ///      token ordering, both reserves and the accumulator, and wiring is
    ///      refused unless it answers a clean `true`.
    ///
    ///      PROBED, NOT CALLED TYPED, and the answer decoded as a `uint256`.
    ///      Identical reasoning to `_twapPriceX8` and to `DeployPlanB`'s
    ///      delegation probe: `abi.decode` into a `bool` reverts on any word
    ///      that is not 0 or 1, so a malformed answer would become an
    ///      undecodable revert instead of the refusal it should be. Anything
    ///      that is not exactly 1 is refused.
    ///
    ///      `code.length` FIRST — the extcodesize guard on a high-level call to
    ///      a codeless address reverts in this frame, which no `try` can catch.
    ///
    ///      UNWIRING TO ZERO IS ACCEPTED and validates nothing, because there
    ///      is nothing to validate. It is not a safe resting state on 4663; see
    ///      the interface note.
    function setWoodTwapOracle(address oracle) external onlyOwner {
        if (oracle != address(0)) {
            if (oracle.code.length == 0) revert InvalidParameter();
            (bool success, bytes memory ret) = oracle.staticcall(abi.encodeCall(IWoodTwapOracle.validatePair, ()));
            if (!success || ret.length < 32) revert InvalidParameter();
            if (abi.decode(ret, (uint256)) != 1) revert InvalidParameter();
        }
        emit WoodTwapOracleSet(woodTwapOracle, oracle);
        woodTwapOracle = oracle;
    }

    /// @dev BOUNDED, BUT NOT RATE-LIMITED (issue #89). The `[MIN_WOOD_HAIRCUT_BPS,
    ///      BPS_DENOMINATOR]` range stays — a haircut below the floor values
    ///      every bond under half of market, which is a mis-set parameter
    ///      rather than a policy, and above 100% would value bonds ABOVE market
    ///      and overstate coverage. Those are VALUE bounds and they cost
    ///      nothing in a crisis.
    ///
    ///      The 1-day interval that used to sit here is GONE, for the same
    ///      reason it left `setWoodUsdPrice`: rate limiting is enforced
    ///      off-chain by a Zodiac module on the owner Safe, and this contract
    ///      deliberately imposes none. The interval was doubly awkward here —
    ///      it gated the two levers independently, so spending one did not
    ///      unlock the other, and tightening the haircut is a safe-direction
    ///      move that a crisis is exactly when you want.
    function setWoodHaircutBps(uint256 newBps) external onlyOwner {
        if (newBps < MIN_WOOD_HAIRCUT_BPS || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParameterChangeFinalized(keccak256("woodHaircutBps"), woodHaircutBps, newBps);
        woodHaircutBps = newBps;
    }

    function setGuardianRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        // RE-CHECKS THE FLOOR: `setChallengeWindow` skips it while no registry
        // is wired, so an owner could set a short window before wiring a
        // registry whose `reviewPeriod` makes the floor longer, leaving the
        // window under-floored with nothing revalidating.
        //
        // Tolerant read on purpose — this guards against an ordering mistake by
        // the owner, not an adversary: a registry that cannot answer
        // `reviewPeriod()` is let through rather than bricking the wiring
        // transaction; one that does answer is held to the floor.
        //
        // `registry.code.length` first: Solidity's extcodesize guard on a
        // high-level call to an EOA reverts in THIS frame, which `try` cannot
        // catch, so the check must be skipped before it is attempted.
        if (registry != address(0) && registry.code.length != 0) {
            try IRegistryApproversMinimal(registry).reviewPeriod() returns (uint256 rp) {
                if (challengeWindow < rp + MAX_GOVERNOR_EXECUTION_WINDOW) revert InvalidParameter();
            } catch {}
        }
        emit GuardianRegistrySet(guardianRegistry, registry);
        guardianRegistry = registry;
    }

    /// @dev The window applies RETROACTIVELY to already-booked buckets:
    ///      shrinking it instantly expires buckets recorded under the longer
    ///      window (frees coverage early); growing it re-counts buckets that
    ///      had already expired (conservative). Governance should change it
    ///      between epochs or at low open exposure.
    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        // Zero would free coverage instantly. The upper bound is whatever keeps
        // `openExposureUsd`'s walk inside `MAX_SCAN_BUCKETS`.
        if (newWindow == 0) revert InvalidParameter();
        _requireScanBounded(newWindow, epochLength);
        // LOWER BOUND: the anti-batching property depends on a bucket outliving
        // the proposal it backs. A window shorter than the approve->execute gap
        // lets one bond cover two live drains — approve #1 just before an epoch
        // boundary, let the bucket expire while #1 is still Approved and inside
        // its execution window, then approve #2 at full budget; both quorums
        // pass, both execute.
        address reg = guardianRegistry;
        if (
            reg != address(0)
                && newWindow < IRegistryApproversMinimal(reg).reviewPeriod() + MAX_GOVERNOR_EXECUTION_WINDOW
        ) {
            revert InvalidParameter();
        }
        emit ParameterChangeFinalized(PARAM_CHALLENGE_WINDOW, challengeWindow, newWindow);
        challengeWindow = newWindow;
    }

    /// @dev REFUSED WHILE ANYTHING IS FROZEN. `unfreezeCoverage` is
    ///      `onlyFreezer` and the challenge game is its only caller, so
    ///      rotating this role mid-challenge would strand every live freeze:
    ///      the old game's `resolve()` could never call the new freezer, both
    ///      bonds would be stuck with no withdrawal path, and every accused
    ///      approver would be permanently barred from `claimUnstakeGuardian`.
    ///
    ///      Zero is still legal as the unwire switch; it just cannot be thrown
    ///      while it would strand a live freeze. The only reachable order is to
    ///      drain live challenges first, then re-point.
    function setCoverageFreezer(address freezer) external onlyOwner {
        if (_frozenKeyCount != 0) revert CoverageFrozen();
        emit CoverageFreezerSet(coverageFreezer, freezer);
        coverageFreezer = freezer;
    }

    function setKNumerator(uint256 newK) external onlyOwner {
        if (newK == 0) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_K_NUMERATOR, kNumerator, newK);
        kNumerator = newK;
    }

    function setCoveredTvlCapUsd(uint256 newCap) external onlyOwner {
        emit ParameterChangeFinalized(PARAM_COVERED_TVL_CAP, coveredTvlCapUsd, newCap);
        coveredTvlCapUsd = newCap;
    }

    function setQuorumTierThreshold(uint8 newThreshold) external onlyOwner {
        if (newThreshold > 3) revert InvalidParameter(); // 3 = quorum disabled for all tiers
        emit ParameterChangeFinalized(PARAM_QUORUM_TIER_THRESHOLD, quorumTierThreshold, newThreshold);
        quorumTierThreshold = newThreshold;
    }

    function setProposerBondBps(uint256 newBps) external onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_PROPOSER_BOND_BPS, proposerBondBps, newBps);
        proposerBondBps = newBps;
    }

    /// @notice Register the Chainlink USD feed for a vault asset. Vault assets on
    ///         Robinhood have live feeds (USDG/USD, USDC/USD, ETH/USD —
    ///         chains/4663.json); WOOD deliberately does NOT go through this path
    ///         (governance haircut price instead, spec §8).
    function setAssetFeed(address asset, address feed, uint256 maxDelay) external onlyOwner {
        if (asset == address(0) || feed == address(0)) revert ZeroAddress();
        if (maxDelay == 0 || maxDelay > type(uint64).max) revert InvalidParameter();
        uint8 assetDec = IERC20DecimalsMinimal(asset).decimals();
        uint8 feedDec = IAggregatorMinimal(feed).decimals();
        // maxDelay bounded to type(uint64).max above; cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 maxDelay64 = uint64(maxDelay);
        _assetFeeds[asset] =
            AssetFeed({feed: feed, maxDelay: maxDelay64, assetDecimals: assetDec, feedDecimals: feedDec});
        emit AssetFeedSet(asset, feed, maxDelay, assetDec);
    }

    /// @inheritdoc IExposureLedger
    /// @dev USD-18 value of `amount` of `asset`. Fail-closed on unconfigured
    ///      asset or stale feed — a proposal in an unpriceable asset cannot be
    ///      coverage-checked and therefore cannot proceed.
    ///      All conversions FLOOR (sub-wei dust, accepted), and so does
    ///      `proposerBondWood`, which floors twice on top of this. Floor is
    ///      accepted there too: a coverage small enough to floor the bond to
    ///      zero (below ~1e-14 USD at the shipped bps/price scales) has
    ///      negligible extractable value, so nothing meaningful goes unbonded.
    ///      Accepted v1 risks: Chainlink aggregators clamp at min/maxAnswer,
    ///      so a clamped price understates coverage (anti-conservative); and
    ///      Robinhood 4663 has no L2 sequencer-uptime feed to gate reads.
    ///      Both accepted for v1 — revisit when a sequencer feed exists.
    function coverageUsd(address asset, uint256 amount) public view returns (uint256) {
        AssetFeed storage f = _assetFeeds[asset];
        if (f.feed == address(0)) revert FeedNotConfigured();
        (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(f.feed).latestRoundData();
        if (answer <= 0) revert StalePrice();
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > f.maxDelay) revert StalePrice();
        // answer > 0 checked above; int256 -> uint256 cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (amount * uint256(answer) * 1e18) / (10 ** f.assetDecimals) / (10 ** f.feedDecimals);
    }

    /// @inheritdoc IExposureLedger
    /// @notice WOOD amount of the risk-scaled proposer bond for a proposal with
    ///         `requiredCoverage` in `asset` (spec §3.9/§5: "fraction of
    ///         maxExtractable — honest proposers not priced out, a rug forfeits
    ///         meaningfully"). Zero when the bond bps is zero; reverts
    ///         (fail-closed) when the WOOD price is unset.
    /// @dev    ALSO REVERTS `NoWoodPrice` when no source can price WOOD, and
    ///         that halt is deliberate: `SyndicateGovernor.propose` sizes the
    ///         proposer bond through this view, so an unpriceable WOOD means no
    ///         new risk can be admitted. Halting proposal CREATION costs
    ///         nothing that cannot wait; admitting an unbonded proposal does.
    function proposerBondWood(address asset, uint256 requiredCoverage) external view returns (uint256) {
        uint256 usd = (coverageUsd(asset, requiredCoverage) * proposerBondBps) / BPS_DENOMINATOR;
        if (usd == 0) return 0;
        uint256 px = woodPriceX8();
        if (px == 0) revert InvalidParameter();
        return (usd * 1e8) / px;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Called by GuardianRegistry.voteOnProposal on the approve side.
    ///
    ///      An approver RESERVES `min(free bond, the proposal's full
    ///      coverage)` — not merely what is still uncovered. Reserving less
    ///      would let the first approver absorb the whole coverage while later
    ///      ones book zero and are never listed, so flipping the first approver
    ///      to Block releases the entire commitment with nobody left to cover
    ///      it — a costless veto by a single guardian.
    ///
    ///      Reserving per approver costs budget — A approvers tie up A x
    ///      coverage until `settleCoverage` runs — and buys the property that
    ///      there is nothing to squat. The real split is the pro-rata
    ///      `allocatedUsd`, so §3.3a's *aggregate* quorum still aggregates: two
    ///      guardians holding $600k each jointly cover a $1M proposal, because a
    ///      conviction slashes EVERY approver of that proposal and recovery is
    ///      the SUM of their bonds (spec §2: "coalition loss >= Σ dollar value
    ///      of slashable approver stake").
    ///
    ///      TWO DIFFERENT RULES. §3.3's cap exists to stop ONE guardian backing
    ///      MANY proposals ("approve N drains in one window, lose one bond
    ///      once"). It does NOT require one guardian to single-handedly cover
    ///      ONE proposal. Reserving the full coverage per approver enforces the
    ///      cap without imposing the second reading, because the reservation is
    ///      an upper bound on liability and `allocatedUsd` is the actual
    ///      per-guardian split.
    ///
    ///      Consequence: an under-bonded guardian is not rejected at vote time —
    ///      it commits what it can, and the proposal fails the execute-time
    ///      quorum unless other approvers make up the rest. A guardian with NO
    ///      free budget books nothing and returns; the cap is enforced by
    ///      committing zero, not by reverting the vote.
    function recordApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
        bytes32 key = _reviewKey(governor, proposalId);
        // Idempotent (vote-change round trip). Keyed on the PLEDGE, not the live
        // booking: `settleCoverage` can write a booking down to zero without the
        // guardian having left, and keying on `_recorded` there would let a
        // repeat call re-book and double-count `_committedUsd`.
        if (_reservedUsd[key][guardian] != 0) return;
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        address asset = IVaultAssetMinimal(pv.vault).asset();
        // ANY PRICING FAILURE BOOKS NOTHING RATHER THAN REVERTING — missing
        // feed, stale feed, or any other `coverageUsd` revert. Reverting here
        // would take the APPROVE vote down with it while Block votes still
        // work, turning the review block-only: guardians could veto but never
        // endorse, and the proposal would pass optimistically anyway. Failing
        // closed on the coverage (booking nothing, so the execute-time quorum
        // cannot be met) is the conservative half; failing the vote is the
        // harmful one.
        //
        // Called externally so the revert can be caught; `coverageUsd` is a view
        // on this same contract, and a same-contract call cannot be wrapped.
        uint256 needUsd;
        try this.coverageUsd(asset, gov.getRequiredCoverage(proposalId)) returns (uint256 v) {
            needUsd = v;
        } catch {
            return; // unpriceable right now: book nothing, let the quorum decide
        }
        if (needUsd == 0) return; // zero-coverage: nothing to book

        // RESERVATION, NOT ALLOCATION: books the MOST this guardian could ever
        // carry (the whole proposal, if every other approver walks away); the
        // final split is computed at read time by `allocatedUsd`. This makes
        // the batching cap STRICTER — every approval consumes budget up to the
        // full coverage rather than the leftover — but the excess is not
        // stranded: it clears when the epoch bucket expires, or immediately on
        // a vote change.
        //
        // AN UNPRICEABLE WOOD BOOKS NOTHING RATHER THAN REVERTING — the same
        // treatment, and the same argument, as the `coverageUsd` wrap above.
        // Under design revision 2 `_woodPrice` REVERTS `NoWoodPrice` when no
        // market source can price WOOD (there is no fallback scalar any more),
        // and that revert reaches here through `slashableBondUsd`. Letting it
        // propagate would fail the APPROVE vote while Block votes kept landing,
        // turning the review block-only: guardians could veto but never
        // endorse, and the proposal would pass optimistically anyway. That is
        // the failure reviews M3, N1 and N4 each removed, and it must not be
        // reintroduced by the price path.
        //
        // Booking nothing is the conservative half: this guardian commits no
        // coverage, so `requireApproveQuorum` cannot be met at execute and
        // fails loudly there — where reverting is the safe direction.
        //
        // Called through `this` so the revert is catchable; a same-contract
        // call cannot be wrapped. Only the PRICE is wrapped, not the sWOOD
        // read: a reverting `guardianStake` is a broken core dependency, not an
        // oracle outage, and should not be silently absorbed.
        uint256 priceX8;
        try this.woodPriceX8() returns (uint256 p) {
            priceX8 = p;
        } catch {
            return; // no WOOD price right now: book nothing, let the quorum decide
        }

        // Free budget = k * bond - open exposure. Zero free budget is the
        // batching attack's boundary: this guardian's bond is already fully
        // spoken for by its other open approvals, so it cannot back another drain.
        // LIVE (anchor = 0): pre-execution, no verdict anchor exists yet.
        uint256 capUsd = kNumerator * _slashableBondUsd(guardian, priceX8, 0);
        uint256 open = openExposureUsd(guardian);
        // NO FREE BUDGET -> BOOK NOTHING, DON'T REVERT. Reverting here would
        // silence the approve side entirely for a guardian whose budget is
        // spent, while Block votes still work — disenfranchisement, not a cap.
        // The cap still binds: this guardian commits nothing, so its bond still
        // cannot back two drains; enforcement moves to `requireApproveQuorum` at
        // execute, which fails loudly with the shortfall visible.
        if (open >= capUsd) return;
        uint256 free = capUsd - open;

        uint256 share = free < needUsd ? free : needUsd;
        // Truncation in the uint192 store below would book phantom (smaller)
        // exposure — fail loudly instead.
        if (share > type(uint192).max) revert InvalidParameter();
        // BOOK INTO THE BUCKET THAT OUTLIVES SETTLEMENT, not the one the vote
        // happened to land in. The commitment must survive until the drain it
        // backs can no longer be challenged:
        //
        //     risk ends at   executeBy + strategyDuration + challengeWindow
        //     bucket expires at   bucketEnd + challengeWindow
        //
        // so the bucket must contain `executeBy + strategyDuration`. Keying on
        // `currentEpoch()` would release a guardian's budget as early as
        // `approval + challengeWindow` — before the challenge window on their
        // own approval had closed.
        //
        // `executeBy` rather than `executedAt`: at approve time the proposal has
        // not executed and may never, so the deadline is the conservative
        // anchor. Horizon failures book nothing rather than reverting —
        // `SyndicateGovernor.propose` rejects an out-of-horizon duration up
        // front, so this is the belt to that braces.
        (uint256 epoch, bool withinHorizon) = _coverageEpochOrSkip(pv);
        if (!withinHorizon) return;
        _buckets[guardian][epoch] += share;
        // share bounded to uint192 above; epoch = elapsed / epochLength cannot
        // approach 2^64 on any realistic timescale.
        // forge-lint: disable-next-line(unsafe-typecast)
        _recorded[key][guardian] = RecordedExposure({usd: uint192(share), epoch: uint64(epoch)});
        // The same number in two places on purpose: `_recorded` is the live
        // booking and `settleCoverage` rewrites it, `_reservedUsd` is the
        // pledge and nothing but a release clears it.
        _reservedUsd[key][guardian] = share;
        _committedUsd[key] += share;
        // Mirrors `_buckets[guardian][epoch] += share` above, but WITHOUT the
        // wall-clock window — see the invariant note on `_liveBookedUsd`
        // (Pashov re-audit of #158, finding 2). Both accumulators start equal
        // to `share` here; they diverge only once `_rebook` writes the
        // booking away from the pledge.
        _liveBookedUsd[guardian] += share;
        _livePledgedUsd[guardian] += share;
        // The ledger keeps its OWN approver list: the quorum reads this, never
        // the registry, so the ledger's registry pointer and the governor's can
        // never disagree about who covered a proposal.
        if (_approverIndex[key][guardian] == 0) {
            _approversOf[key].push(guardian);
            _approverIndex[key][guardian] = _approversOf[key].length; // 1-indexed
        }
        emit ExposureRecorded(guardian, key, share, epoch);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Vote-change Approve→Block (or any registry-side unwind). Releases
    ///      exactly what was committed, from the bucket it was committed into.
    ///      No-op when nothing is recorded — never underflows. The address is
    ///      SWAP-AND-POPPED out of `_approversOf`, so the list is bounded by the
    ///      cohort of currently-active approvers rather than growing with every
    ///      guardian that ever approved — that loop runs on the execute path.
    function releaseApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
        bytes32 key = _reviewKey(governor, proposalId);
        // A live challenge pins this coverage (§3.4): the guardian may not
        // release it and recycle the budget while under challenge.
        if (_frozen[key]) revert CoverageFrozen();
        uint256 reserved = _reservedUsd[key][guardian];
        if (reserved == 0) return;
        RecordedExposure memory r = _recorded[key][guardian];
        delete _recorded[key][guardian];
        delete _reservedUsd[key][guardian];
        // The BUCKET releases the live booking, `_committedUsd` releases the
        // PLEDGE — the two diverge once `settleCoverage` has run, and each
        // counter has to be unwound with the number that was added to it.
        _buckets[guardian][r.epoch] -= r.usd;
        _committedUsd[key] -= reserved;
        // Mirrors the two lines above exactly, on the two accumulators
        // `_sharedSlashableUsd` divides by (Pashov re-audit of #158, finding
        // 2): the booking-basis accumulator unwinds by the booking (`r.usd`),
        // the pledge-basis one by the pledge (`reserved`) — same pairing as
        // `_buckets`/`_committedUsd` just above.
        _liveBookedUsd[guardian] -= r.usd;
        _livePledgedUsd[guardian] -= reserved;

        // Swap-and-pop out of the approver list, so it stays bounded by the
        // cohort rather than growing with every guardian that ever approved.
        // Order carries no meaning: every consumer sums over the list or
        // returns it alongside per-guardian values.
        uint256 idx = _approverIndex[key][guardian];
        if (idx != 0) {
            address[] storage list = _approversOf[key];
            uint256 last = list.length;
            if (idx != last) {
                address moved = list[last - 1];
                list[idx - 1] = moved;
                _approverIndex[key][moved] = idx;
            }
            list.pop();
            delete _approverIndex[key][guardian];
        }

        emit ExposureReleased(guardian, key, r.usd, r.epoch);
    }

    /// @inheritdoc IExposureLedger
    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory committedUsd)
    {
        bytes32 key = _reviewKey(governor, proposalId);
        approvers = _approversOf[key];
        committedUsd = new uint256[](approvers.length);
        for (uint256 i = 0; i < approvers.length; i++) {
            committedUsd[i] = _recorded[key][approvers[i]].usd;
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev The same list `approversOf` returns, paired with the PLEDGE
    ///      (`_reservedUsd`) instead of the live booking (`_recorded.usd`).
    ///      The two numbers are equal until `settleCoverage` first runs and
    ///      diverge afterwards, which is the entire reason this view exists
    ///      separately: `settleCoverage` is permissionless, re-runnable and
    ///      deliberately NOT freeze-gated, so the booking is a number anyone
    ///      may move while a challenge is live. The pledge is not —
    ///      `recordApproval` is its only writer and `releaseApproval` its only
    ///      eraser, and a live challenge blocks the latter outright
    ///      (`CoverageFrozen`).
    ///
    ///      A caller asking "did this guardian underwrite this proposal?" must
    ///      ask it of the pledge. `TokenCourt._recordAccused` — which decides
    ///      who may not vote on the case their own approval caused — asked it
    ///      of the booking, so a guardian convicted on a SEPARATE, concurrent
    ///      challenge could be settled down to a zero booking on THIS one by
    ///      anyone and drop straight out of the accused set (issue #83).
    function pledgedOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory pledgedUsd)
    {
        bytes32 key = _reviewKey(governor, proposalId);
        approvers = _approversOf[key];
        pledgedUsd = new uint256[](approvers.length);
        for (uint256 i = 0; i < approvers.length; i++) {
            pledgedUsd[i] = _reservedUsd[key][approvers[i]];
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev Spec §3.4 freeze scope: this pins ONE proposal's committed
    ///      coverage. It deliberately does not touch the guardian's stake or
    ///      its other open approvals — a challenge freezes the coverage it
    ///      accuses, not the guardian.
    /// @dev THE FREEZE PINS THE UNSTAKE CLAIM. `openExposureUsd` sums epoch
    ///      buckets on pure wall-clock, so a guardian's exposure ages out
    ///      `challengeWindow` after its epoch whether or not it is under
    ///      accusation — and a disputed challenge can outlive that. Counting
    ///      frozen commitments per guardian closes the gap: while any proposal
    ///      naming them is frozen, sWOOD refuses the unstake claim and the
    ///      collateral cannot walk out from under a live accusation.
    ///
    ///      Idempotent on both sides — the counters move only when the flag
    ///      actually flips, so a repeated freeze/unfreeze cannot drift them.
    function freezeCoverage(address governor, uint256 proposalId) external onlyFreezer {
        bytes32 key = _reviewKey(governor, proposalId);
        if (!_frozen[key]) {
            _frozen[key] = true;
            _frozenKeyCount++;
            address[] storage listed = _approversOf[key];
            for (uint256 i = 0; i < listed.length; i++) {
                address g = listed[i];
                if (_recorded[key][g].usd == 0) continue;
                if (_frozenFor[key][g]) continue;
                _frozenFor[key][g] = true;
                _frozenCommitments[g]++;
            }
        }
        emit CoverageFrozenSet(governor, proposalId, true);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Walks the SAME list `freezeCoverage` walked and clears only the
    ///      entries it actually set, so the two are exactly symmetric even if
    ///      the list moved. It cannot move while frozen in any case:
    ///      `releaseApproval` is the only path that shrinks it, and that is the
    ///      path the freeze blocks.
    function unfreezeCoverage(address governor, uint256 proposalId) external onlyFreezer {
        bytes32 key = _reviewKey(governor, proposalId);
        if (_frozen[key]) {
            _frozen[key] = false;
            _frozenKeyCount--;
            address[] storage listed = _approversOf[key];
            for (uint256 i = 0; i < listed.length; i++) {
                address g = listed[i];
                if (!_frozenFor[key][g]) continue;
                _frozenFor[key][g] = false;
                _frozenCommitments[g]--;
            }
        }
        emit CoverageFrozenSet(governor, proposalId, false);
    }

    /// @inheritdoc IExposureLedger
    function hasFrozenCoverage(address guardian) external view returns (bool) {
        return _frozenCommitments[guardian] != 0 || _pinnedCoverageUntil[guardian] > block.timestamp;
    }

    /// @inheritdoc IExposureLedger
    /// @dev EXTENDS THE FREEZE'S REACH PAST ITS OWN RELEASE (issue #95).
    ///      `unfreezeCoverage` drops the moment no challenge against this key
    ///      is LIVE — but `ChallengeGame` can re-arm a legal re-challenge
    ///      window (`challengeableUntil`) that outlives the live challenge
    ///      that just resolved `Inconclusive`. Without this, both of sWOOD's
    ///      unstake gates (`openExposureUsd`, which ages out on its own
    ///      wall-clock tied to `challengeWindow` from EXECUTION, not from any
    ///      re-arm) and `hasFrozenCoverage` (which just went false) can read
    ///      clean while a conviction is still legally reachable — the accused
    ///      claims its stake, and the eventual verdict recovers nothing.
    ///
    ///      Walks the SAME `_approversOf[key]` list `freezeCoverage` walks,
    ///      for the same reason: only guardians who actually committed
    ///      coverage to this proposal are the ones a still-open accusation
    ///      can slash. `deadline` only ever RAISES `_pinnedCoverageUntil`,
    ///      mirroring `challengeableUntil`'s own monotonic-raise semantics one
    ///      layer up — a later, larger extension must not be shadowed by an
    ///      earlier, smaller one still in effect.
    function pinCoverageUntil(address governor, uint256 proposalId, uint256 deadline) external onlyFreezer {
        bytes32 key = _reviewKey(governor, proposalId);
        address[] storage listed = _approversOf[key];
        for (uint256 i = 0; i < listed.length; i++) {
            address g = listed[i];
            if (_recorded[key][g].usd == 0) continue;
            if (deadline > _pinnedCoverageUntil[g]) _pinnedCoverageUntil[g] = deadline;
        }
        emit CoveragePinned(governor, proposalId, deadline);
    }

    /// @inheritdoc IExposureLedger
    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool) {
        return _frozen[_reviewKey(governor, proposalId)];
    }

    /// @inheritdoc IExposureLedger
    function frozenCoverageCount() external view returns (uint256) {
        return _frozenKeyCount;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Spec §3.7: hard per-vault ceiling on coverage-consuming proposals,
    ///      denominated in dollars. Zero cap fails closed (nothing proposable)
    ///      until governance seeds it. Called by SyndicateGovernor.propose.
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view {
        if (coverageUsd(asset, requiredCoverage) > coveredTvlCapUsd) revert CoveredTvlCapExceeded();
    }

    /// @inheritdoc IExposureLedger
    /// @dev Refuses a proposal whose settlement lands beyond the ledger's
    ///      booking horizon, AT PROPOSE. Otherwise `recordApproval` cannot book
    ///      it, leaving a block-only review where guardians can veto but never
    ///      endorse. Failing here puts the error on the proposer, who chose the
    ///      duration and can change it, instead of on a cohort that cannot.
    ///
    ///      Reachable at defaults: `ProtocolConfig.maxStrategyDuration` ships
    ///      UNSET, so a vault owner may seat any duration up to
    ///      `ABSOLUTE_MAX_STRATEGY_DURATION`.
    function requireWithinCoverageHorizon(uint256 executeBy, uint256 strategyDuration) external view {
        if (executeBy + strategyDuration > block.timestamp + MAX_COVERAGE_HORIZON) {
            revert CoverageHorizonExceeded();
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev Spec §3.3a: execution requires the covering approvers' AGGREGATE
    ///      bond to meet the proposal's coverage. Each approver contributes
    ///      `min(what it committed at vote time, what its bond is worth NOW)`:
    ///
    ///        - the committed leg is what makes the aggregate meaningful — a
    ///          guardian only ever backs a proposal up to the free budget it
    ///          actually pledged, so the same bond cannot cover two drains
    ///          (the batching attack);
    ///        - the LIVE leg keeps the dollar requirement honest — a bond that
    ///          shrank since the vote (unstaking, or a WOOD price crash) counts
    ///          at its shrunken value, so coverage must still hold in dollars
    ///          at execution.
    ///
    ///      Approvers come from the ledger's OWN `_approversOf` list, never from
    ///      the registry: the ledger booked the commitments itself, so the
    ///      ledger's and governor's registry pointers can never diverge about
    ///      who approved. The list is bounded by the registry's own
    ///      `MAX_APPROVERS_PER_PROPOSAL`.
    ///
    ///      Zero committed coverage ALWAYS reverts, even at zero required
    ///      coverage — a tier-gated proposal requires an identified signer.
    ///      Called by `SyndicateGovernor.executeProposal` for proposals with
    ///      `envelopeTier >= quorumTierThreshold`.
    ///
    /// @dev THIS IS AN ELIGIBILITY FLOOR, NOT AN INDEMNITY. The inequality
    ///      `Σ min(live_i, reserved_i) >= needUsd` answers "are these approvers
    ///      bonded enough to be trusted with this tier?" — it does NOT promise
    ///      that a later slash recovers the loss, and nothing downstream tries
    ///      to. Slash proceeds are burned, not paid to anyone harmed, and the
    ///      protocol makes no compensation promise to depositors.
    ///
    ///      Read `requiredCoverage` accordingly: it is the price of admission
    ///      to a tier, expressed in the same dollars the loss would be, because
    ///      that is the natural scale for "how much skin should this decision
    ///      require" — not because the two are meant to net out.
    ///
    ///      RESOLVED BY THE BURN — the `maxSlashBps` shortfall no
    ///      longer applies. That finding observed that this gate does not price
    ///      in `maxSlashBps`, so a cohort clearing it could still be slashed
    ///      `1 - maxSlashBps/10_000` short of the loss (80% recovery against a
    ///      $2,000 loss at a ceiling of 8,000). It was a real defect while the
    ///      protocol owed depositors a recovery. It is now a non-sequitur:
    ///      there is no recovery to fall short of, and `slashBpsFor` no longer
    ///      derives a rate from `needUsd` at all. What the ceiling governs is
    ///      how hard the punishment bites, which is a deterrence-calibration
    ///      question (how large must a bond be to outweigh the extractable
    ///      value?) rather than a solvency one.
    ///
    ///      Zero committed coverage still ALWAYS reverts, even at zero required
    ///      coverage. That rule survives the reframe unchanged: R1 wants an
    ///      identified, bonded signer behind anything tier-gated into this
    ///      check, and an unbonded approver is exactly what the punitive slash
    ///      has no grip on.
    ///
    /// @dev LETS `NoWoodPrice` PROPAGATE, deliberately. This gate runs at
    ///      execution, where reverting is the safe direction: with no source
    ///      able to price WOOD there is no proof that anyone's bond covers
    ///      anything, and executing on an unprovable coverage claim is the
    ///      exact outcome the gate exists to refuse. `recordApproval` is the
    ///      one consumer that catches instead — see `IExposureLedger`.
    ///
    /// @dev SHARED ACROSS OPEN PROPOSALS TOO (Pashov re-audit of #158, finding
    ///      1, confidence 88 — the HIGHEST-severity gap in that re-audit).
    ///      This is the ACTUAL execute-time gate — `SyndicateGovernor.
    ///      executeProposal` calls exactly this to decide whether a proposal
    ///      may execute at all — and it was the one post-execution consumer
    ///      of a guardian's slashable bond that hardening #35's shared-stake
    ///      fix (D9) never reached: it kept computing `live =
    ///      _slashableBondUsd(g, priceX8, 0)` and clamping only
    ///      `min(live, reserved)` for THIS ONE proposal, with no awareness of
    ///      what the same live stake was simultaneously backing on every
    ///      OTHER open proposal. Two proposals sole-approved by the same
    ///      guardian could therefore EACH independently pass this gate and
    ///      execute against a stake that, once shared, covers only one of
    ///      them — the exact double-count D9 exists to prevent, reopened at
    ///      the one call site that actually gates execution. The natspec
    ///      comment on the old `live` read ("provably equal to the anchored
    ///      read every OTHER post-execution consumer takes") was true and
    ///      irrelevant: it establishes temporal/price consistency for THIS
    ///      proposal's own anchor, and says nothing about a SECOND proposal
    ///      reading the same guardian's stake with nothing decremented
    ///      between the two checks.
    ///
    ///      FIX: route through `_sharedSlashableUsd` exactly like every other
    ///      consumer, on the BOOKING basis (`reserved` is `_recorded[key]
    ///      [g].usd` here, so the denominator is `_liveBookedUsd[g]`) — see
    ///      the dev-note on `_sharedSlashableUsd`. `_sharedSlashableUsd`
    ///      already clamps its return to `reserved`, so the old manual
    ///      `live < reserved ? live : reserved` becomes redundant and is
    ///      dropped. `anchor = 0` (live) is unchanged and still correct for
    ///      the reason stated above — this fix only closes the missing
    ///      sharing, not the anchor basis, which was never in question.
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view
    {
        uint256 needUsd = coverageUsd(asset, requiredCoverage);
        bytes32 key = _reviewKey(governor, proposalId);
        address[] storage approvers = _approversOf[key];
        uint256 n = approvers.length;
        if (n == 0) revert InsufficientApproveCoverage();

        // Hoisted: loop-invariant — `slashableBondUsd` would otherwise
        // re-read it once per approver.
        uint256 priceX8 = woodPriceX8();

        // Summed over RESERVATIONS, not allocations. The question here is
        // "can the approvers who are still committed cover this?", and a
        // reservation is exactly each one's answer. Summing allocations instead
        // would be circular AND wrong: they are scaled to total `needUsd` and
        // round down, so a fully-subscribed proposal would fail its own quorum
        // by the truncation dust.
        uint256 haveUsd;
        for (uint256 i = 0; i < n; i++) {
            address g = approvers[i];
            uint256 reserved = _recorded[key][g].usd;
            if (reserved == 0) continue; // released via a vote change
            // LIVE (anchor = 0), DELIBERATELY — see the invariant note on
            // `SyndicateGovernor.executeProposal`'s `executedAt` stamp: this
            // gate runs in the same transaction, immediately after the
            // stamp, so the live read here is provably equal to the
            // anchored read every OTHER post-execution consumer takes.
            //
            // SHARED, NOT MERELY LIVE (Pashov re-audit of #158, finding 1) —
            // see the `@dev` block above this function.
            haveUsd += _sharedSlashableUsd(g, reserved, priceX8, 0, _liveBookedUsd[g]);
            if (haveUsd >= needUsd) return; // early exit
        }
        // The loop early-returns on success — reaching here means the covering
        // approvers' aggregate never met the required coverage.
        revert InsufficientApproveCoverage();
    }

    /// @inheritdoc IExposureLedger
    /// @dev PUNITIVE, NOT COMPENSATORY. Every approver still holding a live
    ///      commitment is slashed at the severity ceiling. The rate does not
    ///      depend on the size of the loss, on the proposal's required
    ///      coverage, or on any per-approver allocation of either.
    ///
    ///      This is the deliberate consequence of burning slash proceeds
    ///      instead of routing them to a compensation escrow. A compensatory
    ///      sink cannot pay a victim more than their loss without creating a
    ///      windfall, which bounded the slash at 1x damages and left an
    ///      approver of a value-`V` attack roughly break-even. A burn has no
    ///      counterparty, so the bound is gone and the rate can be set where it
    ///      deters: the whole bond. Deterrence now reads "bond exceeds
    ///      maximum extractable value", not "slash covers the realized loss".
    ///
    ///      A corollary worth stating: because the rate ignores
    ///      `getRequiredCoverage`, a proposal that UNDERSTATES what it can
    ///      actually extract no longer shrinks its approvers' slash. Under the
    ///      allocation this view used to perform, mis-declaring coverage was a
    ///      direct discount on the penalty.
    ///
    ///      RETURNS `BPS_DENOMINATOR`, NOT `maxSlashBps`. `_slashOne` already
    ///      clamps every incoming rate into `[minSlashBps, maxSlashBps]`, so
    ///      the ceiling is applied at exactly one governance-controlled site.
    ///      Reading sWOOD's ceiling here as well would duplicate that authority
    ///      and let the two drift — the divergence class where this site and
    ///      the coverage gate price the same bond differently.
    ///
    ///      NO PRICE READ, AND THAT IS A LIVENESS FIX. The allocation this
    ///      replaced priced BOTH operands: the numerator through `coverageUsd`
    ///      (a Chainlink read behind a `StalePrice` gate) and the denominator
    ///      through `woodPriceX8()`. A stale asset feed therefore made a
    ///      conviction UNPRICEABLE and reverted this view — and feed outages
    ///      correlate with exactly the market stress a drain happens in. The
    ///      slash path no longer has a feed dependency of its own. The coverage
    ///      GATE (`requireApproveQuorum`) still prices, but it runs at
    ///      execution, where reverting is the safe direction.
    ///
    ///      Approvers come from the ledger's OWN `_approversOf`, exactly as
    ///      `requireApproveQuorum` does and for the same reason. A guardian holding a zero commitment — released by a vote
    ///      change, or an approval that landed after coverage was already met —
    ///      yields 0 bps and is slashed nothing. That is unchanged and remains
    ///      the intended semantics: liability follows the commitment, and an
    ///      approver who consumed none of their budget underwrote none of it.
    ///
    ///      The saturating cases the allocation needed — `committed >= live`
    ///      and `live == 0` — are gone with the division. Both pinned the rate
    ///      at 100%, which is now simply the rate. `_slashOne` still clamps to
    ///      live stake, so a shrunken bond yields whatever remains of it.
    function slashBpsFor(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory bps)
    {
        bytes32 key = _reviewKey(governor, proposalId);
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        approvers = new address[](n);
        bps = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            approvers[i] = g;
            // The ONLY thing consulted. A live commitment means the guardian
            // underwrote this proposal and is slashed at the ceiling; a
            // released one means they did not and owe nothing. Nothing about
            // the SIZE of the loss enters the rate.
            if (_recorded[key][g].usd == 0) continue;
            bps[i] = BPS_DENOMINATOR;
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev What `guardian` actually carries on this proposal, as opposed to
    ///      what `recordApproval` reserved. Reservations are deliberately
    ///      over-sized (each approver reserves up to the FULL coverage), so the
    ///      real split is this pro-rata scale-back, computed at read time from
    ///      whoever is still an approver right now.
    ///
    ///      Computing it lazily rather than writing it down closes the
    ///      squat-then-release veto: there is no stored allocation for an
    ///      attacker to capture early and hand back late. Flipping to Block
    ///      deletes the reservation, `_committedUsd` drops, and every remaining
    ///      approver's allocation scales UP on the next read — a departing
    ///      approver hands their share to the others instead of voiding the
    ///      proposal.
    ///
    ///      It also means no keeper is required: execution reads the allocation
    ///      directly, so a settlement transaction can never be withheld to
    ///      strand a proposal.
    /// @dev ORACLE ASYMMETRY, AND IT IS DELIBERATE. `recordApproval` books
    ///      nothing when the price is unreadable; this function REVERTS. The
    ///      conservative direction is opposite on each path: booking nothing
    ///      merely declines to extend coverage, whereas returning a made-up
    ///      number here would size a SLASH off a price nobody can vouch for.
    ///
    ///      Operational consequence: a conviction cannot be computed while the
    ///      asset feed is stale. That is a delay UNLESS the outage outlasts the
    ///      remaining challenge window — bucket expiry is pure wall-clock and
    ///      does not pause for an outage, and `claimUnstakeGuardian` releases
    ///      the stake the instant it reads zero. A long enough outage converts
    ///      the delay into a loss with no attacker involved.
    function allocatedUsd(address governor, uint256 proposalId, address guardian) public view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 reserved = _recorded[key][guardian].usd;
        if (reserved == 0) return 0;
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        address asset = IVaultAssetMinimal(pv.vault).asset();
        uint256 needUsd = coverageUsd(asset, gov.getRequiredCoverage(proposalId));
        uint256 priceX8 = woodPriceX8();
        // ANCHORED (issue #35): once executed, a post-execution top-up must
        // not inflate what this guardian carries — see `_slashableBondUsd`.
        // SHARED ACROSS OPEN PROPOSALS (Pashov audit finding 2, hardening
        // #35): `_sharedSlashableUsd` additionally pro-rates this guardian's
        // slashable basis against every OTHER proposal it currently backs, so
        // this proposal cannot claim more of the guardian's one bond than its
        // own share of it — see the invariant note above `_sharedSlashableUsd`.
        uint256 mine = _sharedSlashableUsd(guardian, reserved, priceX8, pv.executedAt, _liveBookedUsd[guardian]);
        if (mine == 0) return 0;
        return _allocate(mine, _effectiveTotal(key, priceX8, pv.executedAt), needUsd);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Mirrors `slashBpsFor`'s own basis exactly — the same `needUsd`, the
    ///      same `_effectiveTotal` — so the figure a challenger is charged
    ///      against and the figure a conviction takes cannot drift apart.
    ///      `ChallengeGame.file()` must not sum the RESERVATION while slashing
    ///      prices the ALLOCATION.
    ///
    ///      ANCHORED AT `executedAt` (issue #35), not live. Without the
    ///      anchor, an accused cohort could permissionlessly top up its
    ///      stake AFTER the drain to price up its own filing bond with
    ///      capital the eventual verdict slash (itself anchored at
    ///      `executedAt`, `StakedWood._slashOne`) can never reach. Once both
    ///      sides read the same anchor, they cannot drift apart.
    ///
    ///      Reverts rather than returning a stale figure when the asset feed is
    ///      down, inheriting `coverageUsd`'s `StalePrice` gate. A caller that
    ///      must stay live through a feed outage has to say so explicitly — see
    ///      `ChallengeGame.file()`, which catches and falls back.
    function liabilityUsd(address governor, uint256 proposalId) external view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        // ANCHORED (issue #35): sizes the challenger's filing bond off what
        // the verdict slash can actually reach, not off post-drain top-ups
        // an accused cohort adds to price up its own prosecution.
        uint256 effectiveTotal = _effectiveTotal(key, woodPriceX8(), pv.executedAt);
        if (effectiveTotal == 0) return 0;

        uint256 needUsd = coverageUsd(IVaultAssetMinimal(pv.vault).asset(), gov.getRequiredCoverage(proposalId));
        return needUsd < effectiveTotal ? needUsd : effectiveTotal;
    }

    /// @inheritdoc IExposureLedger
    /// @dev UNSHARED, DELIBERATELY (Pashov re-audit of #158, finding 3,
    ///      confidence 78). `liabilityUsd` above is the right basis for
    ///      pricing what a CONVICTION on this proposal can actually recover —
    ///      it is MEANT to shrink under D9's pro-rata sharing once the same
    ///      guardian(s) also back other open proposals, because a conviction
    ///      can only ever take one real, shared bond no matter how many
    ///      proposals claim a piece of it.
    ///
    ///      `ChallengeGame.file()`'s challenger bond is a DIFFERENT quantity:
    ///      an anti-frivolous-filing deterrent sized off what THIS FILING
    ///      freezes for THIS accused cohort. It must NOT shrink merely
    ///      because the same guardians happen to be juggling other open
    ///      commitments under `kNumerator > 1` — an entirely ordinary,
    ///      legitimate operating condition that D9's sharing fix exists
    ///      specifically to accommodate elsewhere, not a reason to charge
    ///      less to accuse THIS cohort. Feeding the shared figure into the
    ///      bond let a guardian's own, unrelated multi-proposal activity
    ///      dilute the deterrent against filing on any ONE of its proposals —
    ///      and `slashVerdict`'s actual punitive take is NOT pro-rated
    ///      either, so the bond tracked something smaller than what a
    ///      conviction can still actually take.
    ///
    ///      Same shape as `liabilityUsd` — `min(needUsd, Σ over approvers of
    ///      min(reserved, slashableBondUsd(g, anchor)))` — but through
    ///      `_unsharedEffectiveTotal` instead of `_effectiveTotal`: exactly
    ///      `_effectiveTotal`'s PRE-D9 behaviour, i.e. the figure
    ///      `liabilityUsd` itself returned before the shared-stake fix.
    ///      `ChallengeGame.file` is the intended caller; every other
    ///      consumer of a guardian's recoverable bond keeps reading the
    ///      shared figure via `liabilityUsd`/`allocatedUsd`.
    function unsharedLiabilityUsd(address governor, uint256 proposalId) external view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        uint256 effectiveTotal = _unsharedEffectiveTotal(key, woodPriceX8(), pv.executedAt);
        if (effectiveTotal == 0) return 0;

        uint256 needUsd = coverageUsd(IVaultAssetMinimal(pv.vault).asset(), gov.getRequiredCoverage(proposalId));
        return needUsd < effectiveTotal ? needUsd : effectiveTotal;
    }

    /// @dev Sum of `min(reserved, slashable bond)` across a proposal's
    ///      approvers — what the cohort can ACTUALLY pay, not what it
    ///      pledged.
    ///
    ///      Using raw `_committedUsd` as the denominator would let a guardian
    ///      who unstaked or was devalued after approving keep diluting
    ///      everyone else's share, so the recoverable total would fall short
    ///      of the loss by more than rounding. `requireApproveQuorum` already
    ///      discounts by `min(live, reserved)`; this applies the same discount
    ///      to the split, so the two agree about the same guardian.
    ///
    ///      ANCHORED (issue #35): `anchor` is `pv.executedAt`, threaded from
    ///      the caller rather than re-read per guardian — 0 (unexecuted)
    ///      keeps every term on the live basis, unchanged from before this
    ///      change. Once executed, the "slashable bond" term is
    ///      `min(snapshot at executedAt, live)` rather than raw live stake, so
    ///      the adversary this closes — an accused approver topping up AFTER
    ///      the drain to inflate its own share of `needUsd` — is priced at
    ///      what the verdict can reach, not at what it can stake.
    ///
    /// @dev SHARED ACROSS OPEN PROPOSALS (Pashov audit finding 2, hardening
    ///      #35): each term now goes through `_sharedSlashableUsd` instead of
    ///      a bare `min(live, reserved)` — see the invariant note there. A
    ///      guardian backing only this one proposal sees no change.
    function _effectiveTotal(bytes32 key, uint256 priceX8, uint256 anchor) internal view returns (uint256 total) {
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            uint256 reserved = _recorded[key][g].usd;
            if (reserved == 0) continue;
            // BOOKING BASIS: `reserved` is `_recorded[key][g].usd`, so the
            // denominator must be the accumulator built from the SAME writes
            // — `_liveBookedUsd`, not `_livePledgedUsd`. See the `@dev` on
            // `_sharedSlashableUsd` (Pashov re-audit of #158, findings 2/4).
            total += _sharedSlashableUsd(g, reserved, priceX8, anchor, _liveBookedUsd[g]);
        }
    }

    /// @dev `_effectiveTotal`'s PRE-D9 computation — `min(reserved,
    ///      slashableBondUsd(g, anchor))` per approver, with NO cross-proposal
    ///      sharing — kept alive exclusively for `unsharedLiabilityUsd`. See
    ///      the invariant note there (Pashov re-audit of #158, finding 3) for
    ///      why `ChallengeGame.file`'s bond basis must NOT go through
    ///      `_sharedSlashableUsd`: the challenger bond prices what this one
    ///      filing freezes for this one accused cohort, and must not shrink
    ///      just because the same guardians also back other open proposals.
    function _unsharedEffectiveTotal(bytes32 key, uint256 priceX8, uint256 anchor)
        internal
        view
        returns (uint256 total)
    {
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            uint256 reserved = _recorded[key][g].usd;
            if (reserved == 0) continue;
            uint256 slashable = _slashableBondUsd(g, priceX8, anchor);
            total += slashable < reserved ? slashable : reserved;
        }
    }

    /// @dev THE SHARED-STAKE INVARIANT (Pashov audit finding 2, hardening
    ///      #35). Before this, `_effectiveTotal`/`_effectiveReservedTotal`
    ///      (and `allocatedUsd`/`settleCoverage`'s own per-guardian clamps)
    ///      computed a guardian's contribution to ONE proposal independently
    ///      as `min(reserved, slashableBondUsd(g, anchor))` — using the
    ///      guardian's CURRENT total live/anchored stake with zero awareness
    ///      of what that SAME stake is simultaneously backing on every OTHER
    ///      still-open, already-executed proposal it also approved. Two
    ///      individually-correct anchored reads can therefore sum to more
    ///      than the guardian's one, finite, shared recoverable pool: PROVEN
    ///      (guardian stakes 1,000 WOOD, books $400 + $400 legally across two
    ///      proposals under the k-multiplier sharing design, is then slashed
    ///      $400 elsewhere leaving only $600 live — yet both proposals
    ///      independently reported $400 "recoverable", $800 claimed against
    ///      $600 real). This requires no privileged action at all: it fires
    ///      from ordinary, legitimate multi-proposal operation combined with
    ///      an unrelated conviction landing in between.
    ///
    ///      INVARIANT THIS ENFORCES: for any guardian g, the sum over all
    ///      currently-open anchored proposals of that proposal's
    ///      claimed-recoverable-from-g must never exceed g's actual
    ///      live/anchored recoverable stake.
    ///
    ///      HOW (option (a), pro-rata distribution — chosen over an explicit
    ///      escrow ledger or first-settled-wins because it reuses bookkeeping
    ///      shape this contract already pays for elsewhere, rather than
    ///      adding an unbounded new ledger): the caller passes `liveTotal`, an
    ///      EXACT, non-wall-clock-decaying sum (`_liveBookedUsd[g]` or
    ///      `_livePledgedUsd[g]`, see the dedicated dev-note below) of every
    ///      still-open reservation this SAME guardian holds, on the same
    ///      basis as `reserved`. That sum is exactly the shared denominator
    ///      g's slashable stake must be split across: `share = slashable *
    ///      reserved / liveTotal`, clamped to `reserved`. Two proposals
    ///      reading independently read the SAME `liveTotal`, so their shares
    ///      can sum to at most `slashable` — never more than the one bond
    ///      that actually backs both. Generalizes to N simultaneously-open
    ///      proposals for the same guardian, since the accumulator already
    ///      sums over all of them (O(1) storage read, no scan).
    ///
    ///      ORIGINALLY (`hardening #35`) this reused `openExposureUsd(g)`'s
    ///      existing wall-clock bucket scan directly instead of a dedicated
    ///      accumulator, on the theory that it already summed exactly this
    ///      guardian's open reservations. A Pashov re-audit of that version
    ///      (#158) found the reuse unsound in five distinct ways — see the
    ///      dev-note below — which is why the denominator is now a
    ///      caller-supplied EXACT accumulator instead.
    ///
    ///      A GUARDIAN WITH ONLY ONE OPEN PROPOSAL SEES NO CHANGE: `reserved
    ///      == liveTotal` exactly, so `share` reduces algebraically to
    ///      `slashable` un-scaled — identical to the pre-fix `min(reserved,
    ///      slashable)`. The sharing only ever bites when a guardian is
    ///      genuinely juggling more than one open commitment, which is
    ///      exactly the case the invariant exists for.
    ///
    ///      `liveTotal == 0` falls back to the un-shared `min(reserved,
    ///      slashable)` rather than dividing by zero; unreachable in practice
    ///      (every caller only invokes this with `reserved != 0`, and
    ///      `liveTotal` — `_liveBookedUsd[guardian]` or
    ///      `_livePledgedUsd[guardian]`, see the caller — is by construction
    ///      >= `reserved` whenever `reserved` is itself a live summand of it),
    ///      kept as a defensive floor rather than an assumed invariant.
    ///
    /// @dev DENOMINATOR IS CALLER-SUPPLIED, ON PURPOSE (Pashov re-audit of
    ///      #158, findings 2 and 4). This used to read `openExposureUsd
    ///      (guardian)` internally — a single, WALL-CLOCK-DECAYING bucket
    ///      scan reused as the denominator for every caller regardless of
    ///      which basis (booking vs. pledge) that caller's own `reserved`
    ///      term was read on. Two problems followed from sharing one
    ///      denominator across two bases: (1) the scan's wall-clock decay let
    ///      a proposal's OWN contribution silently exit the sum while its
    ///      `_recorded`/`_reservedUsd` entry — and therefore its numerator
    ///      claim — stayed fully live (finding 2); (2) `_effectiveReservedTotal`
    ///      fed this function a PLEDGE numerator against a BOOKING
    ///      denominator, breaking the "shares sum to <= 1" partition-of-unity
    ///      property whenever a sibling proposal's settlement had diverged
    ///      the two bases (finding 4). Requiring the caller to pass its own
    ///      basis-matched, non-decaying accumulator (`_liveBookedUsd` for
    ///      booking-basis callers, `_livePledgedUsd` for pledge-basis ones)
    ///      fixes both at once: every call site now divides a `reserved` term
    ///      by a `liveTotal` built from EXACTLY the same underlying writes,
    ///      so `Σ reserved_i == liveTotal` holds by construction for that
    ///      basis, and `Σ share_i <= slashable` follows algebraically. See
    ///      design.md D10 for the full comparison against the audit's Option
    ///      A/B framing and the regression tests that prove each trigger.
    function _sharedSlashableUsd(address guardian, uint256 reserved, uint256 priceX8, uint256 anchor, uint256 liveTotal)
        internal
        view
        returns (uint256)
    {
        uint256 slashable = _slashableBondUsd(guardian, priceX8, anchor);
        uint256 share = liveTotal == 0 ? slashable : (slashable * reserved) / liveTotal;
        return share < reserved ? share : reserved;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Returns the over-reservation once the approver set is FINAL.
    ///
    ///      `recordApproval` reserves up to the whole coverage from every
    ///      approver, since at vote time any one of them might end up carrying
    ///      it alone — there is no leftover to squat, but it means A approvers
    ///      tie up A x coverage of aggregate cohort budget for the whole bucket
    ///      lifetime, which can exhaust a busy cohort's approve capacity.
    ///
    ///      Once the review window shuts, nobody can join or leave, so the
    ///      worst case each approver was reserving against can no longer
    ///      happen. This collapses each reservation to its actual pro-rata
    ///      allocation and hands the difference back — over-reservation now
    ///      lasts the REVIEW WINDOW rather than the coverage window (days
    ///      instead of weeks), since the bottleneck is budget being unavailable
    ///      for the NEXT proposal.
    ///
    ///      Deliberately NOT "reserve only the uncovered remainder, top
    ///      survivors up on release": that reserves everything against the
    ///      FIRST approver and nothing against later ones, reintroducing
    ///      first-mover-takes-the-line — under a coverage-weighted premium the
    ///      whole payment goes to whoever is fastest. Keeping equal
    ///      reservations and settling afterwards buys the same budget relief
    ///      without the ordering race, and keeps the loop off the vote path.
    ///
    ///      PERMISSIONLESS and SAFE TO SKIP: if nobody ever calls it, the budget
    ///      stays over-reserved until the bucket expires — conservative, never
    ///      unsafe. No keeper is load-bearing.
    ///
    /// @dev RE-RUNNABLE, AND THAT IS THE SECURITY PROPERTY. There is no instant
    ///      that is right in advance for a write-down: the split depends on a
    ///      WOOD price and an asset price that both keep moving after settling,
    ///      so any single pass is only a guess at that moment. `_reservedUsd`
    ///      keeps the pledges the pass divides, so every call re-derives the
    ///      whole split from unchanged inputs at the CURRENT price, up or down,
    ///      and no earlier pass can bind a later one — a settlement taken at a
    ///      trough is a stale number anyone can refresh.
    ///
    ///      DELIBERATELY NOT GATED ON `_frozen`. Freezing the numbers during a
    ///      challenge sounds protective and is backwards here: a trough pass
    ///      happens BEFORE the challenge exists (the drain has to happen
    ///      first), so a freeze gate would latch exactly the figure that needs
    ///      correcting, at exactly the moment correcting it matters.
    ///      Re-derivation is monotone-optimal instead — each run books every
    ///      approver at `min(live bond, pledge)` scaled to the need, the most
    ///      the cohort can pay at that instant — so an adversarial re-run never
    ///      helps: at a trough the live bonds are low too, and the slash clamps
    ///      to them either way.
    ///
    ///      The remaining cost of re-running is that a booking can grow again,
    ///      re-consuming budget and holding the exit gate. It is bounded by the
    ///      guardian's own pledge — exactly what they would be holding had
    ///      nobody ever settled — so it can only walk back toward the
    ///      un-settled baseline and never past it.
    ///
    ///      THE PLEDGE IS NOT THE ONLY BOUND, because the guardian may have
    ///      spent the freed budget in the meantime. `_rebook` clamps every
    ///      upward move to `kNumerator * slashableBondUsd` less the guardian's
    ///      exposure elsewhere (issue #110) — without it, a re-run could push a
    ///      guardian past the batching cap that `recordApproval` enforces, using
    ///      nothing but gas. The clamp binds only when the guardian genuinely
    ///      over-committed elsewhere; with no competing exposure the walk-up is
    ///      unrestricted and the repair property above is untouched.
    function settleCoverage(address governor, uint256 proposalId) external {
        bytes32 key = _reviewKey(governor, proposalId);

        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        // The set must be FINAL. Settling mid-review would hand budget back to
        // approvers who could still be left carrying the proposal alone.
        //
        // GATED ON `executeBy`, NOT `reviewEnd`. Before it, each approver holds
        // a full-coverage reservation, so `requireApproveQuorum` sums an A-fold
        // cushion; settling collapses that to EXACTLY `needUsd` priced at settle
        // time, while the quorum re-derives `needUsd` from the live feed at
        // execute. Settling right after review close would let any price rise
        // before `executeBy` fail the quorum and brick an otherwise-covered
        // proposal. Nothing needs the relief before `executeBy`: by then the
        // proposal has executed or expired, so collapsing its reservations can
        // no longer change any quorum.
        //
        // STRICTLY AFTER `executeBy`: a proposal is executable while
        // `block.timestamp <= executeBy`, so settling must not overlap that
        // last executable instant.
        if (pv.executeBy == 0 || block.timestamp <= pv.executeBy) revert ReviewNotClosed();

        uint256 reservedTotal = _committedUsd[key];
        if (reservedTotal == 0) {
            _settled[key] = true;
            return;
        }

        uint256 needUsd;
        try this.coverageUsd(IVaultAssetMinimal(pv.vault).asset(), gov.getRequiredCoverage(proposalId)) returns (
            uint256 v
        ) {
            needUsd = v;
        } catch {
            return; // unpriceable right now; retry later rather than mis-settle
        }

        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        uint256 assigned;
        // Same effective basis as `allocatedUsd`: a guardian whose bond has
        // gone must not dilute the survivors' shares. Summed over the PLEDGES
        // rather than the live bookings, since the bookings are what this
        // function is about to rewrite — dividing by them would make each pass
        // depend on the last.
        // REVERTS ON `NoWoodPrice` rather than settling at a price nobody can
        // vouch for. Settlement is permissionless and safe to skip — a pass
        // that does not happen leaves the budget over-reserved, which is the
        // conservative state — so an outage costs a retry, not a stuck
        // proposal. Contrast `recordApproval`, where declining to act would
        // disenfranchise a voter rather than merely delay a refund.
        uint256 priceX8 = woodPriceX8();
        // ANCHORED (issue #35): `pv.executedAt` is 0 for a proposal that
        // never executed (expired unexecuted, window merely closed) — the
        // live basis then, unchanged from before this change. For an
        // executed proposal, every booking below is capped at what the
        // verdict slash can actually reach.
        uint256 effectiveTotal = _effectiveReservedTotal(key, priceX8, pv.executedAt);
        if (effectiveTotal == 0) {
            _settled[key] = true;
            return;
        }

        // Per-approver room left between the allocation and what that approver
        // could actually pay. The residue below may not exceed it.
        uint256[] memory headroom = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            uint256 reserved = _reservedUsd[key][g];
            if (reserved == 0) continue; // released via a vote change

            // SHARED ACROSS OPEN PROPOSALS (Pashov audit finding 2, hardening
            // #35) — see `_sharedSlashableUsd`: this guardian's slashable
            // basis is pro-rated against every other proposal it currently
            // backs, not clamped to this proposal's reservation alone.
            // PLEDGE BASIS: `reserved` here is `_reservedUsd[key][g]`, so the
            // denominator must be `_livePledgedUsd`, not `_liveBookedUsd`
            // (Pashov re-audit of #158, finding 4 — a pledge numerator over a
            // booking denominator is exactly the basis mismatch that finding
            // proved).
            uint256 mine = _sharedSlashableUsd(g, reserved, priceX8, pv.executedAt, _livePledgedUsd[g]);
            uint256 alloc = _allocate(mine, effectiveTotal, needUsd);
            // BOOKED, NOT ALLOCATED. `_rebook` clamps an upward move to the
            // guardian's free budget (issue #110), so what it returns can be
            // below `alloc`. Accruing the allocation instead would overstate
            // `assigned`, understate the residue, and put a number in
            // `CoverageSettled` that no bucket holds.
            uint256 booked = _rebook(key, g, alloc, priceX8);
            assigned += booked;
            // `_allocate` never scales up (alloc <= mine) and the clamp only
            // lowers, so booked <= mine.
            headroom[i] = mine - booked;
        }

        // Truncation leaves the total a few wei under `needUsd`. Hand the
        // residue out rather than leaving it short: the quorum compares this
        // same aggregate against `needUsd`, so a rounded-down sum would make a
        // fully-subscribed proposal fail its own coverage check after settling.
        //
        // BOUNDED BY EACH HOLDER'S OWN HEADROOM. The residue is dust only when
        // `effectiveTotal > needUsd`. When the cohort's live value has fallen
        // BELOW the need, `_allocate` returns `mine` for everyone, `assigned`
        // is the whole `effectiveTotal`, and the "residue" is the entire
        // COHORT SHORTFALL — handing that to one guardian would scale its
        // booking above its own pledge and past `k x bond`, inventing
        // collateral nobody pledged.
        //
        // Capping each top-up at `mine - alloc` bounds the booking by
        // `min(slashable bond, pledge)` — the most a conviction could ever
        // take from it, TRUE again under the anchored basis (issue #35):
        // once executed, `mine` is already capped at
        // `min(snapshot at executedAt, live)`, so this residue credit cannot be
        // inflated by a stake top-up an accused approver adds after the
        // drain. Crediting past that bound would consume budget that buys no
        // recovery.
        // In the shortfall case every headroom is zero, so nothing is handed
        // out and the aggregate lands UNDER `needUsd`: `requireApproveQuorum`
        // sums `min(live, booked)`, the same `effectiveTotal` it would have
        // summed had this never run, so the proposal fails its coverage check
        // exactly as it already would have. Settling neither creates nor
        // destroys coverage — it only stops over-reserving for it.
        if (assigned < needUsd) {
            uint256 residue = needUsd - assigned;
            for (uint256 i = 0; i < n && residue != 0; i++) {
                uint256 room = headroom[i];
                if (room == 0) continue;
                uint256 take = room < residue ? room : residue;
                address g = listed[i];
                // AND BOUNDED A SECOND TIME BY THE BATCHING CAP. `room` bounds
                // the top-up by what this guardian could PAY; `_rebook`'s clamp
                // bounds it by what this guardian may still UNDERWRITE (issue
                // #110). Credit only what the bucket actually took, or a
                // guardian already at its cap would silently swallow the residue
                // and starve the approvers behind it in the list.
                uint256 before = uint256(_recorded[key][g].usd);
                uint256 gained = _rebook(key, g, before + take, priceX8) - before;
                residue -= gained;
                assigned += gained;
            }
        }

        _settled[key] = true;
        emit CoverageSettled(key, reservedTotal, assigned);
    }

    /// @dev Move a guardian's live booking to `target`, keeping its epoch bucket
    ///      in step, and return what was ACTUALLY booked. Both directions:
    ///      settlement is re-runnable, so a booking that was written down at a
    ///      bad price has to be able to walk back up.
    ///
    ///      `target` is bounded by `_reservedUsd[key][g]`, which `recordApproval`
    ///      bounded to `uint192`, so neither the cast nor the bucket arithmetic
    ///      can misbehave — the bucket was incremented by the pledge and every
    ///      subsequent booking is a fraction of it. The RETURN VALUE may be
    ///      strictly below `target`; see the clamp.
    ///
    /// @dev THE BATCHING CAP IS RE-CHECKED ON THE WAY UP (issue #110).
    ///      `_buckets` is §3.3's state — `openExposureUsd(g) <= kNumerator *
    ///      slashableBondUsd(g)` is a property of it — and this function is the
    ///      only writer of it besides `recordApproval`. Enforcing the cap only at
    ///      approve time left a hole, because the pledge a settlement pass walks
    ///      a booking back up to was checked against the guardian's exposure AS
    ///      IT WAS AT THE VOTE, and an earlier pass may have freed budget the
    ///      guardian has since legally spent elsewhere:
    ///
    ///        1. g1 and g2 each reserve the full coverage of P1; g1 is at its cap.
    ///        2. Anyone settles P1: both bookings are written DOWN pro-rata and
    ///           half of g1's budget comes free.
    ///        3. g1 approves P2 with it. Legal — `recordApproval`'s check passes.
    ///        4. g2 is slashed to zero on an unrelated conviction.
    ///        5. Anyone re-runs settlement on P1. `_effectiveReservedTotal` sums
    ///           over LIVE bonds, so it has fallen, so `_allocate` hands g1 more
    ///           and this function books it — g1 now backs 1.5x its own bond.
    ///
    ///      Step 5 is permissionless and step 4 is ordinary operation, so the
    ///      state `recordApproval`'s natspec calls unreachable was reachable
    ///      without capital, manipulation, or a privileged role.
    ///
    ///      CLAMPED, NOT REVERTED, matching `recordApproval`: a guardian with no
    ///      free budget books nothing there rather than taking the vote down, and
    ///      a settlement that reverted would be one an adversary could brick for
    ///      a whole cohort by parking exposure on a single approver. The clamp
    ///      costs an `openExposureUsd` bucket scan, so it is paid ONLY on the
    ///      upward branch — shrinking a booking can never breach the cap, and the
    ///      first pass on any proposal is all shrink.
    ///
    ///      `openExposureUsd(g)` ALREADY counts this key's current booking, so
    ///      the bound is `current + (cap - open)` and not `cap - open`;
    ///      subtracting the booking twice would clamp repairs that breach
    ///      nothing. This also keeps the clamp a CLAMP rather than a freeze: with
    ///      no competing exposure `open == current`, the bound is the full cap,
    ///      and a written-down booking still walks all the way back to its
    ///      pledge.
    ///
    ///      A clamp can leave the cohort's aggregate under `needUsd`. That is the
    ///      same honest shortfall the residue top-up already produces when the
    ///      cohort's live value has fallen below the need: `requireApproveQuorum`
    ///      sums the bookings and fails loudly at execute. Settling still neither
    ///      creates nor destroys coverage.
    function _rebook(bytes32 key, address g, uint256 target, uint256 priceX8) internal returns (uint256) {
        RecordedExposure memory r = _recorded[key][g];
        uint256 current = uint256(r.usd);
        if (target > current) {
            // LIVE (anchor = 0), DELIBERATELY (issue #35, design D6). This is
            // the #110 BATCHING cap — how much of this guardian's bond is
            // free across ALL its open proposals right now — not a
            // per-proposal verdict-recovery bound, so it stays on the same
            // basis `recordApproval`'s original cap uses. Anchoring it would
            // change #110's re-check semantics, which this change is
            // designed not to disturb.
            uint256 capUsd = kNumerator * _slashableBondUsd(g, priceX8, 0);
            uint256 open = openExposureUsd(g);
            uint256 headroom = capUsd > open ? capUsd - open : 0;
            uint256 maxTarget = current + headroom;
            if (target > maxTarget) target = maxTarget;
        }
        if (target == current) return current;
        if (target < current) {
            _buckets[g][r.epoch] -= (current - target);
            // Mirrors the bucket write on the SAME delta — keeps
            // `_liveBookedUsd` (the booking-basis shared-stake denominator,
            // Pashov re-audit of #158 finding 2) exactly equal to `Σ
            // _recorded[key][g].usd` at every instant, in both directions.
            // `_livePledgedUsd`/`_reservedUsd` are untouched here: settlement
            // never rewrites the pledge, only the booking.
            _liveBookedUsd[g] -= (current - target);
        } else {
            _buckets[g][r.epoch] += (target - current);
            _liveBookedUsd[g] += (target - current);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _recorded[key][g].usd = uint192(target);
        return target;
    }

    /// @dev `_effectiveTotal` over the PLEDGES rather than the live bookings.
    ///      The two coincide until `settleCoverage` first runs and diverge
    ///      afterwards; settlement needs this one, because it is rewriting the
    ///      very numbers `_effectiveTotal` reads and must divide by an input its
    ///      own previous passes did not move.
    ///
    ///      ANCHORED (issue #35): same `anchor` threading as `_effectiveTotal`
    ///      — `pv.executedAt`, 0 (live) for a proposal that never executed.
    ///
    /// @dev SHARED ACROSS OPEN PROPOSALS (Pashov audit finding 2, hardening
    ///      #35): same `_sharedSlashableUsd` treatment as `_effectiveTotal`,
    ///      see the invariant note there.
    function _effectiveReservedTotal(bytes32 key, uint256 priceX8, uint256 anchor)
        internal
        view
        returns (uint256 total)
    {
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            uint256 reserved = _reservedUsd[key][g];
            if (reserved == 0) continue;
            // PLEDGE BASIS — see the matching note in `settleCoverage`'s own
            // loop; both callers reading `_reservedUsd` must divide by
            // `_livePledgedUsd`, never `_liveBookedUsd`.
            total += _sharedSlashableUsd(g, reserved, priceX8, anchor, _livePledgedUsd[g]);
        }
    }

    /// @dev Pro-rata scale-back of one reservation. Under-subscribed
    ///      (`reservedTotal <= needUsd`) every approver carries its whole
    ///      reservation and the quorum fails on the aggregate — scaling UP to
    ///      cover a shortfall would invent collateral nobody pledged.
    ///
    ///      Rounds DOWN, and the residue is deliberate: allocations must never
    ///      sum above `needUsd`, or approvers would jointly owe more than the
    ///      loss and the surplus would have no claimant. The truncated dust
    ///      leaves the aggregate a few wei short of `needUsd`, which the caller
    ///      absorbs — `requireApproveQuorum` compares against the same rounded
    ///      sum it just built, so the comparison stays self-consistent.
    ///
    ///      TWO REGIMES, and `settleCoverage`'s residue top-up must not conflate
    ///      them. Above `needUsd` the shortfall this leaves really is dust, at
    ///      most one wei per approver. At or below it the function returns
    ///      `reserved` untouched, `assigned` comes out equal to the cohort's
    ///      whole effective total, and the gap to `needUsd` is the cohort
    ///      SHORTFALL rather than rounding — not something a top-up may paper
    ///      over, because the collateral to cover it does not exist.
    function _allocate(uint256 reserved, uint256 reservedTotal, uint256 needUsd) internal pure returns (uint256) {
        if (reservedTotal <= needUsd) return reserved;
        return (reserved * needUsd) / reservedTotal;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Bucket `e` (covering [genesis + e·L, genesis + (e+1)·L)) counts until
    ///      its challenge window elapses at `genesis + (e+1)·L + W` — exact
    ///      expiry, so the coverage budget recycles every challenge window
    ///      (spec §3.3). First counted bucket: e such that (e+1)·L + W > elapsed,
    ///      i.e. from = (elapsed - W) / L when elapsed > W. from <= cur always
    ///      (W > 0), so the loop is bounded by ceil(W/L) + 1 iterations.
    function openExposureUsd(address guardian) public view returns (uint256 total) {
        uint256 elapsed = block.timestamp - epochGenesis;
        uint256 from = elapsed > challengeWindow ? (elapsed - challengeWindow) / epochLength : 0;
        // Scans FORWARD as well as back. Approvals are booked into the bucket
        // covering settlement, which is in the future at vote time, so a
        // backward-only sum would miss every live commitment and report a
        // guardian's budget as free while it is fully pledged — the batching cap
        // would then wave through exactly what it exists to stop.
        // `MAX_COVERAGE_HORIZON` bounds the span, and `_coverageEpoch` refuses to
        // book beyond it, so the two together keep this loop fixed-width.
        uint256 to = (elapsed + MAX_COVERAGE_HORIZON) / epochLength;
        for (uint256 e = from; e <= to; e++) {
            total += _buckets[guardian][e];
        }
    }

    /// @dev Both ends of `openExposureUsd`'s walk in one place: `challengeWindow`
    ///      behind the current bucket, `MAX_COVERAGE_HORIZON` ahead of it, plus
    ///      the partial bucket at each edge.
    function _requireScanBounded(uint256 window, uint256 length) internal pure {
        if (length == 0) revert InvalidParameter();
        if ((window + MAX_COVERAGE_HORIZON) / length + 2 > MAX_SCAN_BUCKETS) revert InvalidParameter();
    }

    /// @dev The bucket whose expiry covers this proposal's settlement, floored
    ///      at the current epoch (a proposal already past its deadline must not
    ///      book into the past, where the bucket may have expired already).
    ///
    ///      Reverts rather than clamping when settlement lands beyond
    ///      `MAX_COVERAGE_HORIZON`. Clamping would silently under-cover the tail
    ///      of a long strategy, which is the very bug this replaced; refusing
    ///      the approval instead surfaces a mis-set duration ceiling as a failed
    ///      vote rather than as a hole nobody sees. At the shipped 28d epoch
    ///      this permits ~84 days of horizon, comfortably above the 30d duration
    ///      cap plus a 7d execution window.
    /// @dev `_coverageEpoch` without the revert — returns `(epoch, false)` when
    ///      settlement lands beyond the horizon so `recordApproval` can decline
    ///      to book instead of taking the vote down with it.
    function _coverageEpochOrSkip(ILedgerGovernorMinimal.ProposalViewLite memory pv)
        internal
        view
        returns (uint256, bool)
    {
        uint256 coverUntil = pv.executeBy + pv.strategyDuration;
        if (coverUntil > block.timestamp + MAX_COVERAGE_HORIZON) return (0, false);
        return (_coverageEpoch(pv), true);
    }

    function _coverageEpoch(ILedgerGovernorMinimal.ProposalViewLite memory pv) internal view returns (uint256) {
        uint256 coverUntil = pv.executeBy + pv.strategyDuration;
        uint256 cur = currentEpoch();
        if (coverUntil <= epochGenesis) return cur;
        uint256 target = (coverUntil - epochGenesis) / epochLength;
        if (target <= cur) return cur;
        if (coverUntil > block.timestamp + MAX_COVERAGE_HORIZON) revert CoverageHorizonExceeded();
        return target;
    }
}
