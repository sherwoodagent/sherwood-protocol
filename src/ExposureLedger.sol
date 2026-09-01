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

/// @dev Narrow `ChallengeGame` read surface: just its own `challengeWindow`.
///      `coverageFreezer` IS the game address. The game enforces
///      `game.challengeWindow <= ledger.challengeWindow()` at construction and
///      in two setters, but none of those re-fire when the LEDGER's window
///      moves — `setChallengeWindow` reads this to close that gap.
interface IChallengeGameWindowMinimal {
    function challengeWindow() external view returns (uint256);
}

/**
 * @title ExposureLedger
 * @notice Dollar-denominated coverage accounting for the guardian
 *         economic-security model.
 *
 *         `slashableBond(g)` is `ownStake(g) * priceHaircut` — a guardian's own
 *         bond is the only slashable capital.
 *
 *         Exposure is EPOCH-BUCKETED: an approval consumes one bucket, and open
 *         exposure is the sum of all buckets young enough that their challenge
 *         window has not elapsed. Guardian commitment per approval is therefore
 *         bounded at one epoch plus the challenge window, whatever the strategy
 *         duration.
 *
 * @dev    WOOD IS PRICED BY THE MARKET, CAPPED BY GOVERNANCE. `woodPriceX8()`
 *         resolves:
 *
 *             sourceX8 = feed fresh ? min(feedX8, woodUsdPriceX8)
 *                      : twap fresh ? min(twapX8, woodUsdPriceX8)
 *                      :              revert NoWoodPrice
 *             price    = haircut(sourceX8), floored at 1
 *
 *         `woodUsdPriceX8` is NEVER SERVED AS A PRICE — only ever a cap, so the
 *         market may LOWER a bond's value and never raise it, and lowering the
 *         cap is the emergency brake. A maintained scalar serving AS the price
 *         makes guardians look better collateralised than they are and clears
 *         `requireApproveQuorum` on collateral that does not exist. Under the
 *         cap-only model that drift is inert.
 *
 *         WHAT IT COSTS: there is no branch that keeps pricing when all market
 *         data is gone, so `NoWoodPrice` is reachable in production. Halting
 *         semantics are chosen per consumer — see `IExposureLedger.NoWoodPrice`.
 *         In one line: votes still work, nothing new can be proposed, nothing
 *         can execute.
 *
 * @dev    TRUST MODEL: THE OWNER IS UNRESTRICTED HERE, BY DESIGN.
 *         `setWoodUsdPrice` and `setWoodHaircutBps` impose no rate limit and no
 *         per-call size ceiling. Rate limiting is enforced OFF-CHAIN, by a
 *         Zodiac Delay/Roles module on the owner Safe — the control a reviewer
 *         is looking for is in the Safe's module configuration, invisible from
 *         this source. It must implement an ASYMMETRIC delay (raises delayed,
 *         drops immediate); a plain Delay module is symmetric and would relocate
 *         the problem rather than solve it. `DeployPlanB` asserts the owner is a
 *         contract rather than a bare EOA, which is the most this contract can
 *         check; the rest is a runbook obligation in
 *         `openspec/specs/deployment-docs/spec.md`.
 */
contract ExposureLedger is Ownable2Step, IExposureLedger {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Mirrors `GovernorParameters.MAX_EXECUTION_WINDOW`. Duplicated rather
    ///      than read across: the ledger has no handle on any particular governor
    ///      at `setChallengeWindow` time, so the floor is sized against the worst
    ///      legal configuration. Keep in step if the governor's ceiling moves.
    uint256 internal constant MAX_GOVERNOR_EXECUTION_WINDOW = 7 days;

    /// @dev How far ahead of NOW a commitment may be dated. Expressed in TIME,
    ///      not epochs: the bucket width is a tuning dial, and an epoch-count
    ///      horizon would silently shrink to nothing the moment someone narrowed
    ///      the buckets. 60 days clears a 30d duration cap plus a 7d execution
    ///      window with room to spare.
    uint256 internal constant MAX_COVERAGE_HORIZON = 60 days;

    /// @dev Hard ceiling on how many buckets `openExposureUsd` may walk, so the
    ///      bucket width can be tuned for precision without unbounding the
    ///      loop: narrower buckets release a guardian's short commitments
    ///      without waiting on their long ones, at the cost of a longer scan.
    uint256 internal constant MAX_SCAN_BUCKETS = 16;

    /// @dev Floor on `woodHaircutBps`. Valuing bonds below half of market is a
    ///      mis-set parameter, not a conservatism policy.
    uint256 internal constant MIN_WOOD_HAIRCUT_BPS = 5_000;

    /// @dev Ceiling on a feed's reported `decimals()`, enforced at
    ///      `setWoodFeed`/`setAssetFeed` for the WOOD feed and every vault-asset
    ///      feed. Real Chainlink aggregators report 8 or 18; the bound stays far
    ///      below 78, where `10 ** feedDecimals` overflows `uint256` and panics
    ///      (0x11) inside `_feedPriceX8`'s and `coverageUsd`'s normalization —
    ///      taking the whole price path down instead of falling through to the
    ///      TWAP. Bounding at WRITE time closes it for every reader in one place.
    uint8 internal constant MAX_FEED_DECIMALS = 18;

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

    /// @notice CAP on the WOOD-to-USD price, 8 decimals. Never served as a price.
    ///
    /// @dev    SEED IT ABOVE MARKET. Its whole job is to bound how far a market
    ///         source can be manipulated UPWARD; kept within `M x` of market,
    ///         upward manipulation is capped at `M x`. A cap set BELOW market
    ///         binds permanently, pins every bond at the cap, and makes the
    ///         market source inert.
    ///
    ///         It does not need ACCURACY, because it is never the valuation; a
    ///         monthly review suffices. It does need MAINTENANCE — it is the only
    ///         thing bounding upward manipulation of a ~$438k pool.
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
    /// @notice Minimum envelopeTier at which the approve quorum is fail-closed.
    ///         Launch value 0: every tier.
    /// @dev    Coverage sizing is per-tier, so a closed-loop adapter that can leak
    ///         1% requires 1% of coverage. Zero makes the guardian layer mandatory
    ///         at every tier rather than advisory below the threshold.
    ///         `requiredCoverage == 0` still passes optimistically at every tier —
    ///         that carve-out lives at the governor call site: a proposal that can
    ///         extract nothing has nothing to underwrite.
    uint8 public quorumTierThreshold = 0;
    /// @notice Proposer bond as bps of USD coverage (spec §3.9/§5). Default 1%.
    uint256 public proposerBondBps = 100;

    /// @notice Chainlink WOOD/USD feed. Once wired it is the PREFERRED market
    ///         source; the TWAP oracle serves only while it is unset or degraded.
    ///         Still capped by `woodUsdPriceX8` like every source.
    /// @dev    Reuses the same `AssetFeed` shape and staleness handling as the
    ///         vault-asset feeds. Expected to stay UNSET on chain 4663 — there is
    ///         no WOOD/USD aggregator there — which is why the TWAP oracle is not
    ///         an optional extra but the live source.
    AssetFeed internal _woodFeed;

    /// @notice The WOOD/WETH TWAP oracle (`IWoodTwapOracle`), or zero.
    /// @dev    Not `immutable` and not a constructor argument: the ledger is
    ///         deployed before the oracle has a completed averaging window, and
    ///         a bad oracle must be rotatable without redeploying the ledger.
    ///         Every read of it is defensive — see `_twapPriceX8`.
    address public woodTwapOracle;

    /// @notice Haircut applied to whichever market source won, in bps.
    ///
    /// @dev    Collateral wants a floor, not a quote — an unhaircut oracle tracks
    ///         WOOD UP and inflates every bond exactly when the market is frothy.
    ///         Default 10_000 (no haircut) so wiring a source alone does not
    ///         silently change valuations.
    ///
    /// @dev    LOAD-BEARING: it is the compensating control for the two exposures
    ///         this design ACCEPTS rather than eliminates, and once a price has
    ///         cleared the cap it is the only thing standing under either.
    ///
    ///           1. NON-CONTEMPORANEOUS LEGS in `WoodTwapOracle`. The WOOD/ETH
    ///              average is near-real-time; the ETH/USD answer may be up to one
    ///              heartbeat old (~10.7h on 4663, while healthy). During an ETH
    ///              drawdown inside that heartbeat the product reads HIGH by
    ///              roughly the ETH move, with no attacker capital involved.
    ///           2. RESIDUAL CRASH LAG of up to `twapWindow + maxTwapAge`,
    ///              inherent to averaging.
    ///
    ///         Both OVERSTATE bond value — the dangerous direction. AT THE 10_000
    ///         DEFAULT THAT ALLOWANCE IS ZERO; 5_000 (the floor) absorbs a 50%
    ///         error. Shipping at the default is a deliberate choice to run with
    ///         no margin, not a neutral one.
    uint256 public woodHaircutBps = BPS_DENOMINATOR;

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

    /// @dev Total USD RESERVED by all approvers of a proposal — runs to
    ///      `A x coverage` while the review is open, NOT to `coverage`, because
    ///      each approver reserves up to the whole thing in case it ends up
    ///      carrying the proposal alone. Only `recordApproval` and
    ///      `releaseApproval` move it; settlement derives from this and
    ///      `_reservedUsd` rather than overwriting it, so a settlement pass is
    ///      always re-derivable from unchanged inputs.
    mapping(bytes32 reviewKey => uint256 usd) internal _committedUsd;

    /// @dev The reservation `recordApproval` booked, preserved verbatim while the
    ///      approver is listed. `_recorded[key][g].usd` is the guardian's CURRENT
    ///      booking, which `settleCoverage` rewrites; this is the immutable input
    ///      that rewrite is derived FROM. Keeping the two apart is what makes
    ///      settlement re-runnable rather than a latch.
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
    /// @notice The latest instant through which a guardian's coverage is pinned
    ///         open, independent of whether any challenge naming them is
    ///         currently LIVE.
    /// @dev A MAX, not a per-key value, and scoped to `hasFrozenCoverage`'s
    ///      binary question (is this guardian pinned by ANYTHING?), not to
    ///      `retireApproval`'s per-proposal question — which reads
    ///      `_pinnedUntil[key][guardian]` instead. A guardian can be pinned by
    ///      more than one accusation at once and `pinCoverageUntil` only ever
    ///      raises this, so a later deadline outlives an earlier one and the pin
    ///      decays on wall-clock with no release call to forget.
    mapping(address guardian => uint256) internal _pinnedCoverageUntil;

    /// @dev How many proposals are frozen right now, across every guardian.
    ///      Lets `setCoverageFreezer` refuse a rotation that would orphan a
    ///      live freeze.
    uint256 internal _frozenKeyCount;

    /// @notice EXACT, NON-WALL-CLOCK-DECAYING sum of `_recorded[key][guardian]
    ///         .usd` across every key currently listing `guardian` as an approver.
    ///
    /// @dev    THE SHARED-STAKE DENOMINATOR, BOOKING BASIS. Dividing instead by
    ///         `openExposureUsd(guardian)` — a rolling wall-clock bucket scan —
    ///         went stale in at least five ways (ordinary bucket aging with no
    ///         release, a frozen or pinned proposal outliving its bucket, a
    ///         `setChallengeWindow` shrink, an `Inconclusive` re-arm outliving the
    ///         bucket, and an entry that plain never gets released) while the
    ///         NUMERATOR has no wall-clock decay of its own — it is cleared ONLY
    ///         by an explicit `releaseApproval` or a `_rebook` write. A
    ///         denominator that ages out while its own numerator terms do not is
    ///         a double-count at the seam between two independently-decaying
    ///         clocks.
    ///
    ///         This mapping mirrors `_buckets`' writes exactly but with NO
    ///         wall-clock scan and no expiry, so it is by construction exactly
    ///         `sum over every live key of _recorded[key][guardian].usd` — which
    ///         is what `_sharedSlashableUsd`'s safety argument requires.
    ///
    ///         `openExposureUsd` ITSELF IS UNCHANGED and keeps its wall-clock
    ///         decay: it remains the correct basis for the BATCHING cap, whose
    ///         whole point is to let a guardian's budget recycle once a
    ///         commitment ages past challengeability. The two answer different
    ///         questions and must not share one implementation.
    ///
    ///         ACCEPTED TRADE-OFF: an approval never released and never settled
    ///         stays counted here forever, even after its challenge window has
    ///         elapsed. `_recorded[key][g].usd` — the numerator every consumer
    ///         already reads — has the identical property for the identical
    ///         reason, so this makes the denominator match the numerator's
    ///         existing staleness rather than introducing a new class of it.
    mapping(address guardian => uint256) internal _liveBookedUsd;

    /// @notice EXACT, NON-WALL-CLOCK-DECAYING sum of `_reservedUsd[key][guardian]`
    ///         (the PLEDGE, not the current booking) across every key currently
    ///         listing `guardian` as an approver.
    ///
    /// @dev    THE SHARED-STAKE DENOMINATOR, PLEDGE BASIS — used only where the
    ///         numerator is also read on the pledge basis
    ///         (`_effectiveReservedTotal`/`settleCoverage`). `_reservedUsd` is
    ///         written once per key and cleared once, and `_rebook` never touches
    ///         it, so this accumulator mirrors that lifecycle exactly.
    ///
    ///         WHY TWO ACCUMULATORS RATHER THAN ONE: dividing a frozen PLEDGE
    ///         numerator by the live BOOKING denominator is a basis mismatch that
    ///         can push the shares-sum-to-at-most-1 property above 1 once a prior
    ///         `settleCoverage` pass has diverged the two bases on some OTHER
    ///         proposal sharing this guardian. A dedicated accumulator per basis
    ///         makes every `_sharedSlashableUsd` call site divide by a denominator
    ///         built from exactly the same writes as its own numerator.
    mapping(address guardian => uint256) internal _livePledgedUsd;

    /// @notice Per-(reviewKey, guardian) counterpart of `_pinnedCoverageUntil`.
    ///         APPENDED after every pre-existing storage variable to preserve the
    ///         storage layout.
    /// @dev    Written by `pinCoverageUntil` alongside the per-guardian max, with
    ///         identical monotonic-raise semantics but scoped to the one proposal
    ///         the pin was issued for. `retireApproval` reads THIS, not the max:
    ///         its question is whether THIS proposal's commitment may be swept,
    ///         and a pin against a guardian's OTHER stale proposal must not block
    ///         that — otherwise one routine `Inconclusive` anywhere in a
    ///         guardian's history blocks retirement of its entire book, reopening
    ///         the ~1/N shared-stake decay `retireApproval` exists to close.
    ///         `hasFrozenCoverage` keeps reading the max, because its question is
    ///         genuinely guardian-scoped.
    mapping(bytes32 reviewKey => mapping(address guardian => uint256)) internal _pinnedUntil;

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
    ///         immediately, which is the direction where lag actually hurts. The
    ///         cap is what keeps the market source from being trusted UPWARD —
    ///         the WOOD/WETH pool is ~$438k deep, so an unbounded read from it
    ///         would make that pool the valuation basis for every guardian bond.
    ///
    ///         REVERTS `NoWoodPrice` when no source can price WOOD. See
    ///         `IExposureLedger.NoWoodPrice` for why that is fail-safe.
    function woodPriceX8() public view returns (uint256) {
        (uint256 price,,) = _woodPrice();
        return price;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Exists because both degraded states are otherwise invisible: there is
    ///      no event on either, and `woodUsdPriceX8` carries no `updatedAt`, so
    ///      TWAP-healthy and cap-has-drifted-under-market-for-a-month read
    ///      identically from outside.
    function woodPriceDetail() external view returns (uint256 price, bool fromFeed, bool capBinding) {
        return _woodPrice();
    }

    /// @dev THE RESOLUTION ORDER:
    ///
    ///        cap == 0                 -> revert NoWoodPrice
    ///        feed fresh               -> min(feed, cap)
    ///        else twap fresh          -> min(twap, cap)
    ///        else                     -> revert NoWoodPrice
    ///
    ///      ZERO CAP IS A REVERT, NOT UNCAPPED. Treating it as no ceiling would
    ///      make the single most likely misconfiguration — a ledger deployed
    ///      before governance seeded the number — the one state in which a ~$438k
    ///      pool prices every bond without bound.
    ///
    ///      THE `min` IS THE WHOLE SAFETY ARGUMENT. Push the market source UP and
    ///      the `min` ignores it; push it DOWN and bonds are valued lower and
    ///      quorums get harder — a denial of service with no payoff. It is only a
    ///      real bound because the cap is maintained ABOVE market.
    ///
    ///      NEITHER SOURCE FALLS BACK TO THE CAP: the cap is chosen high and
    ///      non-binding, so serving it as a price when market data stops arriving
    ///      fails in the dangerous direction at exactly the moment there is
    ///      nothing to check it against.
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
        // FLOOR AT 1. `_haircut` truncates, so a source below 2 wei-X8 at the
        // 5,000 bps floor resolves to exactly zero — and zero is not very cheap
        // to the consumers: it reverts `WoodPriceUnset` in `ChallengeGame.file`
        // and `InvalidParameter` in `proposerBondWood`. Guarded on
        // `sourceX8 != 0` so a genuinely zero source stays zero.
        if (price == 0 && sourceX8 != 0) price = 1;
    }

    /// @dev The Chainlink WOOD/USD leg, normalised to 8 decimals. EVERY failure
    ///      mode reports unavailable rather than reverting, including a bare
    ///      revert from `latestRoundData`: a reverting aggregator must fall
    ///      through to the TWAP, not take the price path down with it.
    ///
    ///      RAW STATICCALL, NOT A TYPED `try`. A typed try guards only the CALL
    ///      and its error selector — a call that SUCCEEDS but returns too little
    ///      data to decode fails at ABI-DECODING, which is a full, UNCAUGHT
    ///      revert, not a `catch`. Code inside the success block is ordinary
    ///      caller-frame code, so a panic there is equally uncatchable. Hence:
    ///      staticcall, explicit length check before any decode, and decode ONLY
    ///      into `uint256`/`int256` words — never a validity-constrained type
    ///      like `bool`, an enum, or a sub-256-bit integer, any of which the ABI
    ///      decoder can reject as malformed.
    ///
    ///      `code.length` is checked FIRST because Solidity's extcodesize guard
    ///      on a high-level call to a codeless address reverts in THIS frame,
    ///      which no wrapper can catch. A raw staticcall carries no such guard,
    ///      so the check is still needed to tell codeless apart from answered
    ///      falsy.
    ///
    ///      `feedDecimals` IS RE-CHECKED against `MAX_FEED_DECIMALS` here even
    ///      though `setWoodFeed` refuses to store a larger value: that setter is
    ///      the brace, this is the belt, and `10 ** f.feedDecimals` panics
    ///      uncatchably the instant it exceeds 77.
    ///
    ///      A POSITIVE ANSWER CAN STILL NORMALISE TO ZERO, and `ok` must track
    ///      that. Returning `(0, true)` reports the feed HEALTHY at a price of
    ///      zero: `_woodPrice` takes `fromFeed == true` to mean do not fall
    ///      through to the TWAP, and its floor-at-1 is gated on `sourceX8 != 0`,
    ///      so `woodPriceX8()` would silently resolve to 0 — halting `propose`,
    ///      `execute` and challenge filing alike, with no path back except
    ///      re-wiring the feed.
    function _feedPriceX8() internal view returns (uint256 priceX8, bool ok) {
        AssetFeed storage f = _woodFeed;
        address feed = f.feed;
        if (feed == address(0) || feed.code.length == 0) return (0, false);
        (bool success, bytes memory ret) = feed.staticcall(abi.encodeCall(IAggregatorMinimal.latestRoundData, ()));
        // latestRoundData returns (uint80, int256, uint256, uint256, uint80):
        // 5 words, 160 bytes. Short/absent data is rejected before any decode
        // is attempted, exactly as `_twapPriceX8` rejects `ret.length < 64`.
        if (!success || ret.length < 160) return (0, false);
        // Decoded as uint256/int256 throughout, NOT the narrower uint80 the
        // interface declares — a sub-256-bit unsigned type is, like `bool`,
        // validity-constrained at decode time (the ABI decoder rejects a word
        // whose unused high bits are not clean padding), which is exactly the
        // uncatchable-revert class this rewrite exists to close. uint256 and
        // int256 accept any 32-byte word, so nothing below this line can
        // revert on account of decoding.
        (, int256 answer,, uint256 updatedAt,) = abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        if (answer <= 0) return (0, false);
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > f.maxDelay) return (0, false);
        uint8 feedDecimals = f.feedDecimals;
        if (feedDecimals > MAX_FEED_DECIMALS) return (0, false);
        // Normalise to 8 decimals. `answer > 0` checked above; `feedDecimals`
        // bounded above, so `10 ** feedDecimals` cannot overflow.
        // forge-lint: disable-next-line(unsafe-typecast)
        priceX8 = (uint256(answer) * 1e8) / (10 ** feedDecimals);
        // A source that truncated to zero is reported UNAVAILABLE, not a
        // healthy zero price — see the dev-note above.
        return (priceX8, priceX8 != 0);
    }

    /// @dev The TWAP leg. A LOW-LEVEL STATICCALL, not a typed `try`, and the `ok`
    ///      flag is decoded as a `uint256`: `abi.decode(ret, (uint256, bool))`
    ///      reverts — uncatchably, in this frame — on any second word that is not
    ///      0 or 1, so a wired contract returning a dirty word would take the
    ///      entire price path down. Comparing the flag against 1 cannot revert on
    ///      any return data and treats anything but a clean `true` as unavailable.
    ///
    ///      `code.length` first, for the same extcodesize reason as
    ///      `_feedPriceX8`; a short return is rejected before decoding; and a zero
    ///      price is rejected because `min(0, cap)` would drag every bond to
    ///      nothing exactly as silently.
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
    ///      ANCHOR-AWARE. `anchor == 0` reads LIVE `guardianStake` — the
    ///      pre-execution basis, used where no verdict anchor exists yet.
    ///      `anchor != 0` reads `swood.slashableStakeAt(guardian, anchor)`:
    ///      `min(snapshot at anchor, live)`, exactly what a verdict slash anchored
    ///      at that instant can recover — so a guardian who tops up stake AFTER
    ///      the anchor is never counted as coverage the conviction cannot reach.
    ///      Every post-execution ledger read passes `pv.executedAt`.
    function _slashableBondUsd(address guardian, uint256 priceX8, uint256 anchor) internal view returns (uint256) {
        uint256 stake = anchor == 0 ? swood.guardianStake(guardian) : swood.slashableStakeAt(guardian, anchor);
        return (stake * priceX8) / 1e8;
    }

    // ── Owner setters ──

    /// @notice Set the price CAP. This is the emergency brake: lowering it lowers
    ///         every bond's valuation immediately, in the safe direction, without
    ///         bound and without delay.
    ///
    /// @dev    NO RATE LIMIT AND NO SIZE CEILING, DELIBERATELY. An owner may set
    ///         any value, any number of times, in the same block. Rate limiting is
    ///         enforced off-chain by a Zodiac Delay/Roles module on the owner
    ///         Safe — see `openspec/specs/deployment-docs/spec.md`.
    ///
    ///         A 2x-per-raise ceiling with no time component is not a rate limit
    ///         at all, since N calls in one multisig batch move the price 2^N, so
    ///         it could not be kept once the interval went: it would advertise a
    ///         protection the exact party it constrains can trivially bypass.
    ///         The interval itself gated BOTH directions, and lowering this cap IS
    ///         the emergency action — a routine morning adjustment spent the lever
    ///         and left no brake that afternoon.
    ///
    ///         WHAT THE OFF-CHAIN CONTROL MUST PRESERVE: an ASYMMETRIC delay,
    ///         raises delayed and drops immediate. A plain Zodiac Delay module is
    ///         symmetric and would relocate this problem rather than fix it.
    ///
    ///         ZERO IS STILL ALLOWED, and is a HARD STOP rather than a $0
    ///         valuation: `_woodPrice` reverts `NoWoodPrice` on a zero cap, so
    ///         proposing and executing halt while votes continue to land.
    function setWoodUsdPrice(uint256 newPriceX8) external onlyOwner {
        uint256 current = woodUsdPriceX8;
        emit WoodUsdPriceSet(current, newPriceX8);
        woodUsdPriceX8 = newPriceX8;
    }

    /// @notice Wire (or UNWIRE) the Chainlink WOOD/USD feed.
    ///
    /// @dev    ZERO IS THE UNWIRE SWITCH and it is load-bearing: it is the
    ///         governance path back from a bad aggregator. Unwiring is safe ONLY
    ///         WHILE A TWAP ORACLE IS WIRED — with neither wired there is no
    ///         market data and every price read reverts `NoWoodPrice`.
    ///
    ///         UNWIRING MUST BE SPELLED `setWoodFeed(address(0), 0)`. `maxDelay`
    ///         is REQUIRED to be zero rather than merely ignored, so a mis-typed
    ///         feed address paired with a real delay reverts instead of silently
    ///         dropping the ledger onto the governance price.
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
        // BOUNDED AT WRITE TIME: unbounded, a feed reporting `feedDecimals >= 78`
        // panics `_feedPriceX8`'s normalization instead of reporting unavailable,
        // taking `_woodPrice` down protocol-wide. See `MAX_FEED_DECIMALS`.
        if (feedDecimals > MAX_FEED_DECIMALS) revert InvalidParameter();
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
    /// @dev THE PAIR IS VALIDATED BEFORE IT IS TRUSTED. Four WOOD/WETH Uniswap V3
    ///      pools exist on chain 4663 and all four are initialised-but-never-
    ///      traded shells: `getPool` returns a non-zero address, so a pool-exists
    ///      check passes and the price read comes back garbage. `validatePair()`
    ///      re-checks the token ordering, both reserves and the accumulator, and
    ///      wiring is refused unless it answers a clean `true`.
    ///
    ///      PROBED, NOT CALLED TYPED, and the answer decoded as a `uint256`:
    ///      `abi.decode` into a `bool` reverts on any word that is not 0 or 1, so
    ///      a malformed answer would become an undecodable revert instead of the
    ///      refusal it should be. `code.length` FIRST — the extcodesize guard on a
    ///      high-level call to a codeless address reverts in this frame, which no
    ///      `try` can catch.
    ///
    ///      UNWIRING TO ZERO IS ACCEPTED and validates nothing. It is not a safe
    ///      resting state on 4663.
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

    /// @dev BOUNDED, BUT NOT RATE-LIMITED. The
    ///      `[MIN_WOOD_HAIRCUT_BPS, BPS_DENOMINATOR]` range stays: below the floor
    ///      values every bond under half of market, which is a mis-set parameter
    ///      rather than a policy, and above 100% would value bonds ABOVE market.
    ///      Those are VALUE bounds and cost nothing in a crisis. Rate limiting is
    ///      enforced off-chain — see `setWoodUsdPrice`. Tightening the haircut is
    ///      a safe-direction move a crisis is exactly when you want.
    function setWoodHaircutBps(uint256 newBps) external onlyOwner {
        if (newBps < MIN_WOOD_HAIRCUT_BPS || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParameterChangeFinalized(keccak256("woodHaircutBps"), woodHaircutBps, newBps);
        woodHaircutBps = newBps;
    }

    function setGuardianRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        // RE-CHECKS THE FLOOR: `setChallengeWindow` skips it while no registry is
        // wired, so an owner could set a short window before wiring a registry
        // whose `reviewPeriod` makes the floor longer.
        //
        // Tolerant read on purpose — this guards against an ordering mistake by
        // the owner, not an adversary: a registry that cannot answer
        // `reviewPeriod()` is let through rather than bricking the wiring
        // transaction. `registry.code.length` first, because Solidity's
        // extcodesize guard on a high-level call to an EOA reverts in THIS frame,
        // which `try` cannot catch.
        if (registry != address(0) && registry.code.length != 0) {
            try IRegistryApproversMinimal(registry).reviewPeriod() returns (uint256 rp) {
                if (challengeWindow < rp + MAX_GOVERNOR_EXECUTION_WINDOW) revert InvalidParameter();
            } catch {}
        }
        emit GuardianRegistrySet(guardianRegistry, registry);
        guardianRegistry = registry;
    }

    /// @dev The window applies RETROACTIVELY to already-booked buckets: shrinking
    ///      it instantly expires buckets recorded under the longer window (frees
    ///      coverage early); growing it re-counts buckets that had already expired
    ///      (conservative). Change it between epochs or at low open exposure.
    ///
    ///      TWO LOWER BOUNDS, BOTH TOLERANT READS OF AN EXTERNAL POINTER. Reading
    ///      a pointer STRICTLY here while `setGuardianRegistry` admits it
    ///      TOLERANTLY is a contradiction: a registry the tolerant setter admitted
    ///      (codeless, or reverting on `reviewPeriod()`) would then make this
    ///      function revert in THIS frame on every subsequent call, permanently
    ///      bricking it rather than merely declining to floor it. Liveness of a
    ///      governance setter must not depend on a foreign contract answering a
    ///      view call, so both bounds use the same `code.length` + try/catch
    ///      shape: an unanswerable pointer means no floor from that side.
    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        // Zero would free coverage instantly. The upper bound is whatever keeps
        // `openExposureUsd`'s walk inside `MAX_SCAN_BUCKETS`.
        if (newWindow == 0) revert InvalidParameter();
        _requireScanBounded(newWindow, epochLength);
        // LOWER BOUND #1: the anti-batching property depends on a bucket outliving
        // the proposal it backs. A window shorter than the approve-to-execute gap
        // lets one bond cover two live drains — approve #1 just before an epoch
        // boundary, let the bucket expire while #1 is still Approved and inside
        // its execution window, then approve #2 at full budget; both quorums pass,
        // both execute. `code.length` first, for the same extcodesize reason as
        // `setGuardianRegistry`.
        address reg = guardianRegistry;
        if (reg != address(0) && reg.code.length != 0) {
            try IRegistryApproversMinimal(reg).reviewPeriod() returns (uint256 rp) {
                if (newWindow < rp + MAX_GOVERNOR_EXECUTION_WINDOW) revert InvalidParameter();
            } catch {}
        }
        // LOWER BOUND #2: WINDOW COUPLING IS ONE-SIDED. `ChallengeGame` enforces
        // `game.challengeWindow <= ledger.challengeWindow()` in three places, but
        // all three only check at the instant they run — none re-fire when the
        // LEDGER's window moves. Shrinking it here could silently open a gap where
        // `retireApproval`'s gate (keyed off THIS window) opens before
        // `ChallengeGame.file`'s deadline (keyed off the GAME's) closes, so a
        // sweep can empty `_approversOf` while the proposal is still legally
        // filable — permanently unchallengeable the moment it happens.
        // `coverageFreezer` IS the game address.
        address freezer = coverageFreezer;
        if (freezer != address(0) && freezer.code.length != 0) {
            try IChallengeGameWindowMinimal(freezer).challengeWindow() returns (uint256 gameWindow) {
                if (newWindow < gameWindow) revert InvalidParameter();
            } catch {}
        }
        emit ParameterChangeFinalized(PARAM_CHALLENGE_WINDOW, challengeWindow, newWindow);
        challengeWindow = newWindow;
    }

    /// @dev REFUSED WHILE ANYTHING IS FROZEN. `unfreezeCoverage` is `onlyFreezer`
    ///      and the challenge game is its only caller, so rotating this role
    ///      mid-challenge would strand every live freeze: the old game could never
    ///      call the new freezer, both bonds would be stuck with no withdrawal
    ///      path, and every accused approver would be permanently barred from
    ///      `claimUnstakeGuardian`. Zero is still legal as the unwire switch; the
    ///      only reachable order is to drain live challenges first.
    /// @dev NO WINDOW CHECK HERE, DELIBERATELY. `game.challengeWindow >
    ///      ledger.challengeWindow` is a state the design ACCOMMODATES rather
    ///      than forbids — see design.md D2 and
    ///      `GovernorCoverageGates.test_reclaimBond_gameWindowAboveTheLedgers_waitsForTheGame`,
    ///      whose note says it outright: "`ExposureLedger.setChallengeWindow`
    ///      floors only against the registry's review period and has no
    ///      game-side check, so the ledger owner can drop the ledger's window
    ///      below the game's afterwards."
    ///
    ///      The divergence is handled DOWNSTREAM instead:
    ///      `reclaimProposerBond`'s gate is a `max` of both deadlines precisely
    ///      so a longer game window still holds the bond. That is why the gate
    ///      is a `max` and not `challengeableUntil` alone.
    ///
    ///      A guard was briefly added here refusing to wire a freezer whose
    ///      window exceeds this one. It broke that test's fixture and removed a
    ///      configuration the protocol is built to tolerate. If the sweep-versus-
    ///      filing gap is to be closed, it belongs at `retireApproval`'s gate —
    ///      the thing that actually opens too early — not at the wiring step.
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
        // BOUNDED AT WRITE TIME: the same `feedDecimals >= 78` overflow that
        // `setWoodFeed` guards against panics `coverageUsd`'s normalization
        // identically. `coverageUsd` is meant to revert on bad state, but meant to
        // revert cleanly and can be configured to panic are different guarantees.
        if (feedDec > MAX_FEED_DECIMALS) revert InvalidParameter();
        // maxDelay bounded to type(uint64).max above; cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 maxDelay64 = uint64(maxDelay);
        _assetFeeds[asset] =
            AssetFeed({feed: feed, maxDelay: maxDelay64, assetDecimals: assetDec, feedDecimals: feedDec});
        emit AssetFeedSet(asset, feed, maxDelay, assetDec);
    }

    /// @inheritdoc IExposureLedger
    /// @dev USD-18 value of `amount` of `asset`. Fail-closed on an unconfigured
    ///      asset or a stale feed — a proposal in an unpriceable asset cannot be
    ///      coverage-checked and therefore cannot proceed. All conversions FLOOR
    ///      (sub-wei dust, accepted), and so does `proposerBondWood`.
    ///      Accepted v1 risks: Chainlink aggregators clamp at min/maxAnswer, so a
    ///      clamped price understates coverage (anti-conservative); and Robinhood
    ///      4663 has no L2 sequencer-uptime feed to gate reads.
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

    /// @dev Resolves `(asset, requiredCoverage)` for `governor`/`proposalId`
    ///      against `vault`, book/settle-NOTHING on any failure rather than
    ///      reverting. Shared by `recordApproval` and `settleCoverage` so the
    ///      hoist-and-guard shape cannot drift between the two call sites.
    ///
    ///      HOISTED OUT OF ANY `try`'s ARGUMENT LIST, DELIBERATELY. Solidity
    ///      evaluates a call's argument expressions in the CALLER's frame,
    ///      strictly before the call a `try` around it actually guards, so a
    ///      revert from `IVaultAssetMinimal(pv.vault).asset()` or from
    ///      `gov.getRequiredCoverage(proposalId)` written inline propagated
    ///      straight through the `catch` as if the `try` were not there. Each read
    ///      is now resolved through its OWN try/catch, ahead of and independent
    ///      from the `coverageUsd` try each caller still performs.
    ///
    ///      `vault.code.length` is checked FIRST: a call that succeeds against a
    ///      codeless address returns no data, and Solidity does not route the
    ///      resulting ABI-decode failure through `catch`. `governor` needs no
    ///      matching guard — both callers only reach this via a `pv` already
    ///      produced by an earlier unwrapped call to that same `gov`.
    function _tryResolveCoverageInputs(ILedgerGovernorMinimal gov, uint256 proposalId, address vault)
        internal
        view
        returns (address asset, uint256 requiredCoverage, bool ok)
    {
        if (vault.code.length == 0) return (address(0), 0, false);
        try IVaultAssetMinimal(vault).asset() returns (address a) {
            asset = a;
        } catch {
            return (address(0), 0, false);
        }
        try gov.getRequiredCoverage(proposalId) returns (uint256 rc) {
            requiredCoverage = rc;
        } catch {
            return (address(0), 0, false);
        }
        ok = true;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Called by `GuardianRegistry.voteOnProposal` on the approve side.
    ///
    ///      An approver RESERVES `min(free bond, the proposal's full coverage)` —
    ///      not merely what is still uncovered. Reserving less would let the first
    ///      approver absorb the whole coverage while later ones book zero and are
    ///      never listed, so flipping the first approver to Block releases the
    ///      entire commitment with nobody left to cover it: a costless veto by a
    ///      single guardian.
    ///
    ///      Reserving per approver costs budget — A approvers tie up
    ///      `A x coverage` until `settleCoverage` runs — and buys the property
    ///      that there is nothing to squat. The real split is the pro-rata
    ///      `allocatedUsd`, so the aggregate quorum still aggregates: a conviction
    ///      slashes EVERY approver and recovery is the SUM of their bonds.
    ///
    ///      TWO DIFFERENT RULES. The cap exists to stop ONE guardian backing MANY
    ///      proposals; it does NOT require one guardian to single-handedly cover
    ///      ONE proposal. Reserving the full coverage per approver enforces the
    ///      cap without imposing the second reading, because the reservation is an
    ///      upper bound on liability and `allocatedUsd` is the actual split.
    ///
    ///      Consequence: an under-bonded guardian is not rejected at vote time —
    ///      it commits what it can, and the proposal fails the execute-time quorum
    ///      unless other approvers make up the rest. The cap is enforced by
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
        // ANY PRICING FAILURE BOOKS NOTHING RATHER THAN REVERTING — missing feed,
        // stale feed, an unreadable vault or required-coverage read, or any other
        // `coverageUsd` revert. Reverting here would take the APPROVE vote down
        // while Block votes still work, turning the review block-only: guardians
        // could veto but never endorse, and the proposal would pass optimistically
        // anyway. Failing closed on the coverage is the conservative half.
        (address asset, uint256 requiredCoverage, bool resolved) = _tryResolveCoverageInputs(gov, proposalId, pv.vault);
        if (!resolved) return; // unreadable right now: book nothing, let the quorum decide
        //
        // Called externally so the revert can be caught; `coverageUsd` is a view
        // on this same contract, and a same-contract call cannot be wrapped.
        uint256 needUsd;
        try this.coverageUsd(asset, requiredCoverage) returns (uint256 v) {
            needUsd = v;
        } catch {
            return; // unpriceable right now: book nothing, let the quorum decide
        }
        if (needUsd == 0) return; // zero-coverage: nothing to book

        // RESERVATION, NOT ALLOCATION: books the MOST this guardian could ever
        // carry — the whole proposal, if every other approver walks away. The
        // final split is computed at read time by `allocatedUsd`. This makes the
        // batching cap STRICTER, but the excess is not stranded: it clears when
        // the epoch bucket expires, or immediately on a vote change.
        //
        // AN UNPRICEABLE WOOD BOOKS NOTHING RATHER THAN REVERTING — same
        // treatment and same argument as the `coverageUsd` wrap above. Booking
        // nothing is the conservative half: this guardian commits no coverage, so
        // `requireApproveQuorum` cannot be met at execute and fails loudly there,
        // where reverting is the safe direction.
        //
        // Called through `this` so the revert is catchable; a same-contract call
        // cannot be wrapped. Only the PRICE is wrapped, not the sWOOD read: a
        // reverting `guardianStake` is a broken core dependency, not an oracle
        // outage, and should not be silently absorbed.
        uint256 priceX8;
        try this.woodPriceX8() returns (uint256 p) {
            priceX8 = p;
        } catch {
            return; // no WOOD price right now: book nothing, let the quorum decide
        }

        // Free budget = k * bond - open exposure. Zero free budget is the batching
        // attack's boundary: this guardian's bond is already fully spoken for by
        // its other open approvals. LIVE (anchor = 0): pre-execution, no verdict
        // anchor exists yet.
        uint256 capUsd = kNumerator * _slashableBondUsd(guardian, priceX8, 0);
        uint256 open = openExposureUsd(guardian);
        // NO FREE BUDGET -> BOOK NOTHING, DON'T REVERT. Reverting would silence
        // the approve side entirely for a guardian whose budget is spent while
        // Block votes still work — disenfranchisement, not a cap. The cap still
        // binds, and enforcement moves to `requireApproveQuorum` at execute.
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
        //     risk ends at        executeBy + strategyDuration + challengeWindow
        //     bucket expires at   bucketEnd + challengeWindow
        //
        // so the bucket must contain `executeBy + strategyDuration`. Keying on
        // `currentEpoch()` would release the budget as early as
        // `approval + challengeWindow`. `executeBy` rather than `executedAt`
        // because at approve time the proposal has not executed and may never.
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

    /// @dev SHARED UNWIND, used by both `releaseApproval` and `retireApproval` so
    ///      the vote-change unwind and the post-window sweep cannot drift apart.
    ///      Clears the booking and the pledge, unwinds both bucket/committed
    ///      counters and both shared-stake accumulators, and swap-and-pops the
    ///      guardian out of the approver list.
    ///
    ///      PRECONDITION, NOT ENFORCED HERE: callers must already hold `reserved`
    ///      and `r` from BEFORE this call, and freeze/pin/window checks are each
    ///      caller's own responsibility — the two gate on different conditions.
    function _unwindApproval(bytes32 key, address guardian, RecordedExposure memory r, uint256 reserved) internal {
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

        // Swap-and-pop out of the approver list, so it stays bounded by the cohort
        // rather than growing with every guardian that ever approved. Order
        // carries no meaning: every consumer sums over the list.
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
    }

    /// @inheritdoc IExposureLedger
    /// @dev Vote-change Approve-to-Block, or any registry-side unwind. Releases
    ///      exactly what was committed, from the bucket it was committed into.
    ///      No-op when nothing is recorded — never underflows.
    function releaseApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
        bytes32 key = _reviewKey(governor, proposalId);
        // A live challenge pins this coverage (§3.4): the guardian may not
        // release it and recycle the budget while under challenge.
        if (_frozen[key]) revert CoverageFrozen();
        uint256 reserved = _reservedUsd[key][guardian];
        if (reserved == 0) return;
        RecordedExposure memory r = _recorded[key][guardian];
        _unwindApproval(key, guardian, r, reserved);
        emit ExposureReleased(guardian, key, r.usd, r.epoch);
    }

    /// @inheritdoc IExposureLedger
    /// @dev PERMISSIONLESS RETIREMENT OF A DEAD COMMITMENT.
    ///      `_liveBookedUsd`/`_livePledgedUsd` are monotone increasing except at
    ///      two decrement sites: `releaseApproval` and `_rebook`'s downward
    ///      branch. `releaseApproval` has exactly ONE caller in the system, gated
    ///      on `block.timestamp < reviewEnd`, so once a review closes there is no
    ///      release path left — while `openExposureUsd` (the batching-cap
    ///      denominator) DOES decay on wall clock. A guardian's share of its own
    ///      live bond therefore decays as ~1/N in the number of proposals it has
    ///      EVER approved, even though a commitment older than its challenge
    ///      window carries no collectable liability at all.
    ///
    ///      Anyone may sweep a key/guardian pair once it is provably inert:
    ///        - `!_frozen[key]`, identically to `releaseApproval`'s own guard;
    ///        - `_pinnedUntil[key][guardian] < block.timestamp` — PER-KEY, not the
    ///          per-guardian max: a pin against some OTHER stale proposal the same
    ///          guardian once approved must not block sweeping this one, or a
    ///          single routine `Inconclusive` anywhere in its history blocks
    ///          retirement of the entire book;
    ///        - `block.timestamp` past the SAME expiry `openExposureUsd` uses for
    ///          this booked epoch.
    ///      It then performs `releaseApproval`'s exact unwind, so the two cannot
    ///      diverge.
    ///
    ///      GATED ON `reserved != 0`, NOT on the booking. `_rebook` can write a
    ///      guardian's BOOKING down to zero while leaving its PLEDGE and its
    ///      listing untouched, so gating on the booking would make exactly that
    ///      guardian permanently un-retirable — leaving `_livePledgedUsd` stuck
    ///      forever for the guardians most likely to need it released.
    ///
    ///      PIN BOUNDARY IS INCLUSIVE OF `deadline`. `ChallengeGame.file` refuses
    ///      a filing only STRICTLY past its deadline, so a filing at
    ///      `block.timestamp == deadline` is still legal and this read must stay
    ///      pinned through that same instant. Mixing an exclusive pin check with
    ///      an inclusive bucket check left the boundary second legal to challenge
    ///      but no longer pinned: a same-block sweep could empty `_approversOf`
    ///      out from under a `file()`, making the proposal permanently
    ///      unchallengeable.
    function retireApproval(address governor, uint256 proposalId, address guardian) external {
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 reserved = _reservedUsd[key][guardian];
        if (reserved == 0) return; // nothing to retire; mirrors releaseApproval's no-op
        if (_frozen[key]) revert CoverageFrozen();
        if (_pinnedUntil[key][guardian] >= block.timestamp) revert CoveragePinnedActive();
        RecordedExposure memory r = _recorded[key][guardian];
        // Same expiry `openExposureUsd` uses for this exact bucket: bucket
        // `r.epoch` counts until its challenge window elapses at
        // `genesis + (r.epoch + 1) * L + W`. Keyed on the BOOKED epoch, not
        // `currentEpoch()`, because a long-duration strategy books into a future
        // epoch.
        if (block.timestamp <= epochGenesis + (uint256(r.epoch) + 1) * epochLength + challengeWindow) {
            revert ChallengeWindowOpen();
        }
        _unwindApproval(key, guardian, r, reserved);
        emit ExposureRetired(guardian, key, r.usd, reserved, r.epoch);
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
    /// @dev The same list `approversOf` returns, paired with the PLEDGE instead of
    ///      the live booking. The two are equal until `settleCoverage` first runs
    ///      and diverge afterwards, which is why this view exists separately:
    ///      `settleCoverage` is permissionless, re-runnable and deliberately NOT
    ///      freeze-gated, so the booking is a number anyone may move while a
    ///      challenge is live. The pledge is not.
    ///
    ///      A caller asking whether a guardian underwrote this proposal must ask
    ///      it of the pledge: asked of the booking, a guardian convicted on a
    ///      separate concurrent challenge could be settled down to a zero booking
    ///      by anyone and drop straight out of the accused set.
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
    /// @dev Freeze scope: this pins ONE proposal's committed coverage. It
    ///      deliberately does not touch the guardian's stake or its other open
    ///      approvals — a challenge freezes the coverage it accuses, not the
    ///      guardian.
    /// @dev THE FREEZE PINS THE UNSTAKE CLAIM. `openExposureUsd` sums epoch
    ///      buckets on pure wall-clock, so a guardian's exposure ages out
    ///      `challengeWindow` after its epoch whether or not it is under
    ///      accusation — and a disputed challenge can outlive that. While any
    ///      proposal naming them is frozen, sWOOD refuses the unstake claim.
    ///      Idempotent on both sides: the counters move only when the flag
    ///      actually flips.
    /// @dev GATED ON THE PLEDGE, NOT THE BOOKING. `settleCoverage` is
    ///      permissionless, re-runnable and not freeze-gated, and rewrites the
    ///      booking in both directions including to zero. Gating on the booking
    ///      would let a guardian whose booking transits through zero during an
    ///      active challenge skip the increment entirely, so
    ///      `StakedWood.claimUnstakeGuardian`'s gate comes back clean while the
    ///      accusation naming them is still live.
    function freezeCoverage(address governor, uint256 proposalId) external onlyFreezer {
        bytes32 key = _reviewKey(governor, proposalId);
        if (!_frozen[key]) {
            _frozen[key] = true;
            _frozenKeyCount++;
            address[] storage listed = _approversOf[key];
            for (uint256 i = 0; i < listed.length; i++) {
                address g = listed[i];
                if (_reservedUsd[key][g] == 0) continue;
                if (_frozenFor[key][g]) continue;
                _frozenFor[key][g] = true;
                _frozenCommitments[g]++;
            }
        }
        emit CoverageFrozenSet(governor, proposalId, true);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Walks the SAME list `freezeCoverage` walked and clears only the
    ///      entries it actually set, so the two are exactly symmetric even if the
    ///      list moved. It cannot move while frozen in any case: `releaseApproval`
    ///      is the only path that shrinks it, and that is the path the freeze
    ///      blocks.
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
    /// @dev PIN BOUNDARY IS INCLUSIVE OF `deadline` — `>=`, not `>` — so this read
    ///      stays pinned through the same instant `ChallengeGame.file`'s own
    ///      inclusive deadline check still allows a filing, and a guardian cannot
    ///      pass the unstake gate one second before a still-legal filing could
    ///      reach it.
    function hasFrozenCoverage(address guardian) external view returns (bool) {
        return _frozenCommitments[guardian] != 0 || _pinnedCoverageUntil[guardian] >= block.timestamp;
    }

    /// @inheritdoc IExposureLedger
    /// @dev EXTENDS THE FREEZE'S REACH PAST ITS OWN RELEASE. `unfreezeCoverage`
    ///      drops the moment no challenge against this key is LIVE — but
    ///      `ChallengeGame` can re-arm a legal re-challenge window that outlives
    ///      the challenge that just resolved `Inconclusive`. Without this, both of
    ///      sWOOD's unstake gates read clean while a conviction is still legally
    ///      reachable: the accused claims its stake and the eventual verdict
    ///      recovers nothing.
    ///
    ///      Walks the SAME `_approversOf[key]` list `freezeCoverage` walks, for
    ///      the same reason. `deadline` only ever RAISES the pins, mirroring
    ///      `challengeableUntil`'s own monotonic-raise semantics one layer up.
    ///
    ///      GATED ON THE PLEDGE, NOT THE BOOKING — identical reasoning and fix to
    ///      `freezeCoverage` above.
    ///
    ///      WRITES BOTH THE PER-GUARDIAN MAX AND THE PER-KEY VALUE:
    ///      `_pinnedCoverageUntil[g]` is `hasFrozenCoverage`'s read,
    ///      `_pinnedUntil[key][g]` is `retireApproval`'s. Both are monotonic
    ///      raises from the SAME `deadline`, so they differ only in scope.
    function pinCoverageUntil(address governor, uint256 proposalId, uint256 deadline) external onlyFreezer {
        bytes32 key = _reviewKey(governor, proposalId);
        address[] storage listed = _approversOf[key];
        for (uint256 i = 0; i < listed.length; i++) {
            address g = listed[i];
            if (_reservedUsd[key][g] == 0) continue;
            if (deadline > _pinnedCoverageUntil[g]) _pinnedCoverageUntil[g] = deadline;
            if (deadline > _pinnedUntil[key][g]) _pinnedUntil[key][g] = deadline;
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
    /// @dev Refuses a proposal whose settlement lands beyond the booking horizon,
    ///      AT PROPOSE. Otherwise `recordApproval` cannot book it, leaving a
    ///      block-only review where guardians can veto but never endorse. Failing
    ///      here puts the error on the proposer, who chose the duration and can
    ///      change it, instead of on a cohort that cannot. Reachable at defaults:
    ///      `ProtocolConfig.maxStrategyDuration` ships UNSET.
    function requireWithinCoverageHorizon(uint256 executeBy, uint256 strategyDuration) external view {
        if (executeBy + strategyDuration > block.timestamp + MAX_COVERAGE_HORIZON) {
            revert CoverageHorizonExceeded();
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev Measures whether the covering approvers' AGGREGATE bond meets the
    ///      proposal's coverage, returning the raised and required figures instead
    ///      of gating all-or-nothing — the caller derives a coverage-proportional
    ///      effective capital from the ratio rather than being refused outright on
    ///      a shortfall. Each approver contributes `min(what it committed at vote
    ///      time, what its bond is worth NOW)`: the committed leg is what makes
    ///      the aggregate meaningful (the same bond cannot cover two drains), and
    ///      the live leg keeps the dollar requirement honest (a bond that shrank
    ///      since the vote counts at its shrunken value).
    ///
    ///      Approvers come from the ledger's OWN `_approversOf` list, never from
    ///      the registry: the ledger booked the commitments itself, so the
    ///      ledger's and governor's registry pointers cannot diverge about who
    ///      approved. The list is bounded by `MAX_APPROVERS_PER_PROPOSAL`.
    ///
    /// @dev THIS IS A COVERAGE MEASUREMENT WITH A ZERO FLOOR, NOT AN INDEMNITY.
    ///      `coverageRaisedUsd` answers how much bonded conviction stands behind
    ///      this proposal right now — it does NOT promise that a later slash
    ///      recovers the loss, and nothing downstream tries to: slash proceeds are
    ///      burned, not paid to anyone harmed. Read `requiredCoverage` as the
    ///      price of admission to a tier, expressed in the same dollars the loss
    ///      would be because that is the natural scale, not because the two net
    ///      out. `maxSlashBps` therefore does not enter this gate: what the
    ///      ceiling governs is how hard the punishment bites, a
    ///      deterrence-calibration question rather than a solvency one.
    ///
    ///      Zero committed coverage ALWAYS reverts, even at zero required
    ///      coverage — anything tier-gated into this check wants an identified,
    ///      bonded signer, and an unbonded approver is exactly what a punitive
    ///      slash has no grip on. A nonzero-but-partial aggregate is reported to
    ///      the caller instead, so execution can size to the coverage raised.
    ///
    /// @dev LETS `NoWoodPrice` PROPAGATE, deliberately. This gate runs at
    ///      execution, where reverting is the safe direction: with no source able
    ///      to price WOOD there is no proof anyone's bond covers anything.
    ///
    /// @dev SHARED ACROSS OPEN PROPOSALS. This is the ACTUAL execute-time gate,
    ///      and it was the one post-execution consumer of a guardian's slashable
    ///      bond the shared-stake fix never reached: it clamped only
    ///      `min(live, reserved)` for THIS proposal, with no awareness of what the
    ///      same live stake was simultaneously backing on every OTHER open one, so
    ///      two proposals sole-approved by the same guardian could EACH pass this
    ///      gate against a stake that covers only one. It now routes through
    ///      `_sharedSlashableUsd` on the BOOKING basis, which already clamps its
    ///      return to `reserved`.
    ///
    ///      The gate anchors at `block.timestamp`, not live, so a same-block stake
    ///      top-up cannot pass on collateral the matching conviction can never
    ///      reach — see the inline comment in the loop.
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view
        returns (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd)
    {
        requiredCoverageUsd = coverageUsd(asset, requiredCoverage);
        bytes32 key = _reviewKey(governor, proposalId);
        address[] storage approvers = _approversOf[key];
        uint256 n = approvers.length;
        if (n == 0) revert InsufficientApproveCoverage();

        // Hoisted: loop-invariant — `slashableBondUsd` would otherwise
        // re-read it once per approver.
        uint256 priceX8 = woodPriceX8();

        // Summed over RESERVATIONS, not allocations. The question here is whether
        // the approvers who are still committed can cover this, and a reservation
        // is exactly each one's answer. Summing allocations would be circular AND
        // wrong: they are scaled to total `needUsd` and round down, so a
        // fully-subscribed proposal would fail its own quorum by the dust.
        uint256 haveUsd;
        for (uint256 i = 0; i < n; i++) {
            address g = approvers[i];
            uint256 reserved = _recorded[key][g].usd;
            if (reserved == 0) continue; // released via a vote change
            // ANCHORED AT `block.timestamp`, NOT LIVE. `anchor = 0` reads live
            // `guardianStake`, while every conviction values the SAME guardian
            // through `swood.slashableStakeAt(g, c.executedAt)`, resolving to
            // `_slashableAt(g, openedAt - 1)`. `upperLookupRecent` is INCLUSIVE of
            // `key == anchor`, so a same-block top-up staked at
            // `block.timestamp == executedAt` was COUNTED by the live read and
            // EXCLUDED by the verdict's lookup — the gate could certify coverage a
            // conviction could never collect. Passing `block.timestamp` excludes
            // it on both sides identically.
            haveUsd += _sharedSlashableUsd(g, reserved, priceX8, block.timestamp, _liveBookedUsd[g]);
            if (haveUsd >= requiredCoverageUsd) return (haveUsd, requiredCoverageUsd); // early exit; surplus may be clamped
        }
        // The loop early-returns on full coverage, so reaching here means the
        // aggregate fell short. A genuinely zero aggregate is still an error; any
        // nonzero-but-partial one is reported to the caller instead of reverting,
        // so execution can size to the coverage actually raised.
        if (haveUsd == 0) revert InsufficientApproveCoverage();
        return (haveUsd, requiredCoverageUsd);
    }

    /// @inheritdoc IExposureLedger
    /// @dev PUNITIVE, NOT COMPENSATORY. Every approver still holding a live
    ///      commitment is slashed at the severity ceiling. The rate does not
    ///      depend on the size of the loss, on the required coverage, or on any
    ///      per-approver allocation of either.
    ///
    ///      This follows from burning slash proceeds instead of routing them to a
    ///      compensation escrow. A compensatory sink cannot pay a victim more than
    ///      their loss without creating a windfall, which bounded the slash at 1x
    ///      damages and left an approver of a value-`V` attack roughly break-even.
    ///      A burn has no counterparty, so the rate can be set where it deters:
    ///      the whole bond. A corollary: because the rate ignores
    ///      `getRequiredCoverage`, a proposal that UNDERSTATES what it can extract
    ///      no longer shrinks its approvers' slash.
    ///
    ///      RETURNS `BPS_DENOMINATOR`, NOT `maxSlashBps`. `_slashOne` already
    ///      clamps every incoming rate into `[minSlashBps, maxSlashBps]`, so the
    ///      ceiling is applied at exactly one governance-controlled site; reading
    ///      it here too would duplicate that authority and let the two drift.
    ///
    ///      NO PRICE READ, AND THAT IS A LIVENESS FIX. The allocation this
    ///      replaced priced both operands, so a stale asset feed made a conviction
    ///      unpriceable — and feed outages correlate with exactly the market
    ///      stress a drain happens in. The coverage GATE still prices, but it runs
    ///      at execution, where reverting is the safe direction.
    ///
    ///      A guardian holding a zero commitment — released by a vote change, or
    ///      an approval that landed after coverage was met — yields 0 bps and is
    ///      slashed nothing: liability follows the commitment.
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
            //
            // THE PREDICATE IS THE PLEDGE, NOT THE BOOKING (pashov review
            // finding #13) — the same correction issue #83 made to
            // `TokenCourt._recordAccused`, and audit-181 findings A/C made to
            // `freezeCoverage` and `pinCoverageUntil`. `_recorded.usd` is
            // rewritten in BOTH directions by `settleCoverage`, which is
            // permissionless, re-runnable, and deliberately NOT freeze-gated —
            // "a number anyone may move while a challenge is live", in
            // `pledgedOf`'s own words. `_reservedUsd` is written only by
            // `recordApproval` and erased only by `releaseApproval`, which a
            // filed challenge blocks outright with `CoverageFrozen`.
            //
            // This is the site that decides WHO A CONVICTION SLASHES, and the
            // rate it hands back is binary — `BPS_DENOMINATOR` or nothing — so
            // a single floored division inside `_allocate` was the whole
            // difference between a guardian losing 100% of a live stake and
            // losing nothing, on a basis a stranger could recompute at will.
            // Whether that floor is reachable today rests on operand
            // magnitudes rather than on any enforced invariant, which is the
            // wrong thing to depend on; keying the predicate to the pledge
            // removes the dependency instead of re-arguing it.
            if (_reservedUsd[key][g] == 0) continue;
            bps[i] = BPS_DENOMINATOR;
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev What `guardian` actually carries on this proposal, as opposed to what
    ///      `recordApproval` reserved. Reservations are deliberately over-sized,
    ///      so the real split is this pro-rata scale-back, computed at read time
    ///      from whoever is still an approver right now.
    ///
    ///      Computing it lazily rather than writing it down closes the
    ///      squat-then-release veto: there is no stored allocation for an attacker
    ///      to capture early and hand back late. Flipping to Block deletes the
    ///      reservation and every remaining approver's allocation scales UP on the
    ///      next read. It also means no keeper is required.
    /// @dev ORACLE ASYMMETRY, DELIBERATE. `recordApproval` books nothing when the
    ///      price is unreadable; this REVERTS. The conservative direction is
    ///      opposite on each path: booking nothing merely declines to extend
    ///      coverage, whereas returning a made-up number here would size a SLASH
    ///      off a price nobody can vouch for. Consequence: a conviction cannot be
    ///      computed while the asset feed is stale — a delay UNLESS the outage
    ///      outlasts the remaining challenge window, since bucket expiry does not
    ///      pause for an outage.
    function allocatedUsd(address governor, uint256 proposalId, address guardian) public view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 reserved = _recorded[key][guardian].usd;
        if (reserved == 0) return 0;
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        address asset = IVaultAssetMinimal(pv.vault).asset();
        uint256 needUsd = coverageUsd(asset, gov.getRequiredCoverage(proposalId));
        uint256 priceX8 = woodPriceX8();
        // ANCHORED: once executed, a post-execution top-up must not inflate what
        // this guardian carries. SHARED ACROSS OPEN PROPOSALS:
        // `_sharedSlashableUsd` pro-rates this guardian's slashable basis against
        // every OTHER proposal it currently backs, so this proposal cannot claim
        // more of the guardian's one bond than its own share of it.
        uint256 mine = _sharedSlashableUsd(guardian, reserved, priceX8, pv.executedAt, _liveBookedUsd[guardian]);
        if (mine == 0) return 0;
        return _allocate(mine, _effectiveTotal(key, priceX8, pv.executedAt), needUsd);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Mirrors `slashBpsFor`'s basis exactly — the same `needUsd`, the same
    ///      `_effectiveTotal` — so the figure a challenger is charged against and
    ///      the figure a conviction takes cannot drift apart.
    ///
    ///      ANCHORED AT `executedAt`, not live: without the anchor, an accused
    ///      cohort could permissionlessly top up its stake AFTER the drain to
    ///      price up its own filing bond with capital the verdict slash can never
    ///      reach.
    ///
    ///      Reverts rather than returning a stale figure when the asset feed is
    ///      down. A caller that must stay live through a feed outage has to say so
    ///      explicitly — see `ChallengeGame.file()`, which catches and falls back.
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
    /// @dev UNSHARED, DELIBERATELY. `liabilityUsd` is the right basis for pricing
    ///      what a CONVICTION can recover — it is MEANT to shrink under pro-rata
    ///      sharing, because a conviction can only ever take one real, shared bond
    ///      however many proposals claim a piece of it.
    ///
    ///      `ChallengeGame.file()`'s challenger bond is a DIFFERENT quantity: an
    ///      anti-frivolous-filing deterrent sized off what THIS FILING freezes for
    ///      THIS accused cohort. It must not shrink merely because the same
    ///      guardians are juggling other open commitments — an ordinary operating
    ///      condition — and `slashVerdict`'s punitive take is not pro-rated
    ///      either, so a shared-basis bond tracked something strictly smaller than
    ///      what a conviction can still take.
    ///
    ///      Same shape as `liabilityUsd` but through `_unsharedEffectiveTotal`:
    ///      exactly `_effectiveTotal`'s pre-sharing behaviour.
    function unsharedLiabilityUsd(address governor, uint256 proposalId) external view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        uint256 effectiveTotal = _unsharedEffectiveTotal(key, woodPriceX8(), pv.executedAt);
        if (effectiveTotal == 0) return 0;

        uint256 needUsd = coverageUsd(IVaultAssetMinimal(pv.vault).asset(), gov.getRequiredCoverage(proposalId));
        return needUsd < effectiveTotal ? needUsd : effectiveTotal;
    }

    /// @dev Sum of `min(reserved, slashable bond)` across a proposal's approvers —
    ///      what the cohort can ACTUALLY pay, not what it pledged. Using raw
    ///      `_committedUsd` as the denominator would let a guardian who unstaked
    ///      or was devalued after approving keep diluting everyone else's share.
    ///      `requireApproveQuorum` already discounts by `min(live, reserved)`;
    ///      this applies the same discount to the split so the two agree.
    ///
    ///      ANCHORED: `anchor` is `pv.executedAt`, threaded from the caller — 0
    ///      (unexecuted) keeps every term live. Once executed, the slashable-bond
    ///      term is `min(snapshot at executedAt, live)`, so an accused approver
    ///      topping up AFTER the drain is priced at what the verdict can reach.
    /// @dev SHARED ACROSS OPEN PROPOSALS: each term goes through
    ///      `_sharedSlashableUsd` rather than a bare `min(live, reserved)`. A
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

    /// @dev `_effectiveTotal`'s pre-sharing computation — `min(reserved,
    ///      slashableBondUsd(g, anchor))` per approver, with NO cross-proposal
    ///      sharing — kept alive exclusively for `unsharedLiabilityUsd`. See that
    ///      function for why `ChallengeGame.file`'s bond basis must not go through
    ///      `_sharedSlashableUsd`.
    ///
    ///      PLEDGE BASIS, NOT THE BOOKING. Reading `_recorded[key][g].usd` here
    ///      would defeat the entire point of this function: `settleCoverage`'s
    ///      `_rebook` writes the BOOKING down to the guardian's cross-proposal
    ///      pro-rata allocation (`_sharedSlashableUsd`), and it never touches the
    ///      pledge — see the note in `_rebook`. So once settlement has run, the
    ///      booking IS the shared figure, and an "unshared" total computed over it
    ///      silently returns exactly the diluted number `unsharedLiabilityUsd`
    ///      exists to avoid, collapsing `ChallengeGame.file`'s challenger bond to
    ///      `1/K` for a guardian backing K siblings. That is not a rare race:
    ///      `SyndicateGovernor._finishSettlement` and `reclaimProposerBond` both
    ///      call `_settleCoverageBestEffort`, so for any normally-settled proposal
    ///      the write-down has already landed before a challenger can file. Every
    ///      other challenge-path consumer is already on `_reservedUsd` for the same
    ///      reason (`slashBpsFor`, `freezeCoverage`/`pinCoverageUntil`,
    ///      `TokenCourt._recordAccused`, and `file`'s own `pledgedOf` read); this
    ///      site was the last one left on the booking.
    function _unsharedEffectiveTotal(bytes32 key, uint256 priceX8, uint256 anchor)
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
            uint256 slashable = _slashableBondUsd(g, priceX8, anchor);
            total += slashable < reserved ? slashable : reserved;
        }
    }

    /// @dev THE SHARED-STAKE INVARIANT. Computing a guardian's contribution to ONE
    ///      proposal independently as `min(reserved, slashableBondUsd(g, anchor))`
    ///      uses that guardian's CURRENT stake with zero awareness of what the
    ///      SAME stake is simultaneously backing on every other still-open
    ///      proposal. Two individually-correct anchored reads can therefore sum to
    ///      more than the guardian's one finite pool: a guardian stakes 1,000
    ///      WOOD, legally books $400 + $400 across two proposals, is then slashed
    ///      $400 elsewhere leaving $600 live — yet both proposals independently
    ///      report $400 recoverable, $800 claimed against $600 real. No privileged
    ///      action is required; it fires from ordinary multi-proposal operation
    ///      plus an unrelated conviction landing in between.
    ///
    ///      INVARIANT: for any guardian g, the sum over all currently-open
    ///      anchored proposals of that proposal's claimed-recoverable-from-g must
    ///      never exceed g's actual recoverable stake.
    ///
    ///      HOW: pro-rata distribution, chosen over an explicit escrow ledger or
    ///      first-settled-wins because it reuses bookkeeping this contract already
    ///      pays for. The caller passes `liveTotal`, an EXACT, non-decaying sum of
    ///      every still-open reservation this guardian holds ON THE SAME BASIS as
    ///      `reserved`, so `share = slashable * reserved / liveTotal` clamped to
    ///      `reserved`. Two proposals read the SAME `liveTotal`, so their shares
    ///      sum to at most `slashable`. Generalises to N proposals at O(1).
    ///
    ///      A GUARDIAN WITH ONLY ONE OPEN PROPOSAL SEES NO CHANGE: `reserved ==
    ///      liveTotal`, so `share` reduces to `slashable` un-scaled. `liveTotal ==
    ///      0` falls back to the unshared `min(reserved, slashable)` rather than
    ///      dividing by zero — unreachable in practice, kept as a defensive floor.
    ///
    /// @dev DENOMINATOR IS CALLER-SUPPLIED, ON PURPOSE. Reading
    ///      `openExposureUsd(guardian)` internally shared one WALL-CLOCK-DECAYING
    ///      scan across callers whose `reserved` terms were read on different
    ///      bases, which broke two ways: the decay let a proposal's own
    ///      contribution exit the denominator while its numerator claim stayed
    ///      live, and `_effectiveReservedTotal` fed a PLEDGE numerator against a
    ///      BOOKING denominator. Requiring each caller to pass its own
    ///      basis-matched accumulator makes `sum of reserved_i == liveTotal` hold
    ///      by construction, so `sum of share_i <= slashable` follows
    ///      algebraically.
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
    ///      approver, since at vote time any one of them might carry it alone —
    ///      but that ties up `A x coverage` of aggregate cohort budget for the
    ///      whole bucket lifetime. Once the review window shuts nobody can join or
    ///      leave, so the worst case each approver reserved against can no longer
    ///      happen: this collapses each reservation to its pro-rata allocation and
    ///      hands the difference back.
    ///
    ///      Deliberately NOT reserve-only-the-remainder-and-top-survivors-up: that
    ///      reserves everything against the FIRST approver and nothing against
    ///      later ones, reintroducing first-mover-takes-the-line.
    ///
    ///      PERMISSIONLESS and SAFE TO SKIP: if nobody calls it, the budget stays
    ///      over-reserved until the bucket expires — conservative, never unsafe.
    ///
    /// @dev RE-RUNNABLE, AND THAT IS THE SECURITY PROPERTY. No instant is right in
    ///      advance for a write-down, since the split depends on two prices that
    ///      keep moving. `_reservedUsd` keeps the pledges the pass divides, so
    ///      every call re-derives the whole split from unchanged inputs at the
    ///      current price and no earlier pass can bind a later one.
    ///
    ///      DELIBERATELY NOT GATED ON `_frozen`. Freezing the numbers during a
    ///      challenge sounds protective and is backwards: a trough pass happens
    ///      BEFORE the challenge exists, so a freeze gate would latch exactly the
    ///      figure that needs correcting. Re-derivation is monotone-optimal
    ///      instead — each run books every approver at `min(live bond, pledge)`
    ///      scaled to the need — so an adversarial re-run never helps.
    ///
    ///      The remaining cost is that a booking can grow again, re-consuming
    ///      budget. It is bounded by the guardian's own pledge, and `_rebook`
    ///      additionally clamps every upward move to `kNumerator *
    ///      slashableBondUsd` less the guardian's exposure elsewhere — without
    ///      which a re-run could push a guardian past the batching cap using
    ///      nothing but gas.
    function settleCoverage(address governor, uint256 proposalId) external {
        bytes32 key = _reviewKey(governor, proposalId);

        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        // The set must be FINAL. Settling mid-review would hand budget back to
        // approvers who could still be left carrying the proposal alone.
        //
        // GATED ON `executeBy`, NOT `reviewEnd`. Before it, each approver holds a
        // full-coverage reservation, so the quorum sums an A-fold cushion;
        // settling collapses that to EXACTLY `needUsd` priced at settle time,
        // while the quorum re-derives `needUsd` from the live feed at execute. So
        // settling right after review close would let any price rise before
        // `executeBy` fail the quorum and brick an otherwise-covered proposal.
        // STRICTLY after `executeBy`, since a proposal is executable while
        // `block.timestamp <= executeBy`.
        //
        // OR EXECUTED, WHICHEVER COMES FIRST (SHE-225). `executedAt != 0` means
        // `requireApproveQuorum` has already run its single call site
        // (`SyndicateGovernor._deriveAndStoreEffectiveCapital`, reached only from
        // `executeProposal`, once) and can never run again, so the price-drift
        // brick the `executeBy` deadline guards against is unreachable — there is
        // no later quorum left to fail. The deadline branch stays for a proposal
        // that expired unexecuted, which has no execution to hang this on.
        //
        // WITHOUT THIS the collapse is not reliably triggered at all: a proposal
        // that settles BEFORE its own `executeBy` takes
        // `_settleCoverageBestEffort`'s silent-skip branch, leaving
        // `reclaimProposerBond` — an action on the proposer's own schedule — as
        // the only remaining caller. The A-fold reservation then outlives the
        // proposal, consuming cohort capacity at N x the true rate.
        if (pv.executedAt == 0 && (pv.executeBy == 0 || block.timestamp <= pv.executeBy)) {
            revert ReviewNotClosed();
        }

        uint256 reservedTotal = _committedUsd[key];
        if (reservedTotal == 0) {
            _settled[key] = true;
            return;
        }

        // Same hoist-and-guard as `recordApproval`: the vault/required-coverage
        // reads used to sit as inline try-call arguments, evaluated in THIS
        // frame — before, and therefore outside, the `catch`.
        (address asset, uint256 requiredCoverage, bool resolved) = _tryResolveCoverageInputs(gov, proposalId, pv.vault);
        if (!resolved) return; // unreadable right now; retry later rather than mis-settle

        uint256 needUsd;
        try this.coverageUsd(asset, requiredCoverage) returns (uint256 v) {
            needUsd = v;
        } catch {
            return; // unpriceable right now; retry later rather than mis-settle
        }

        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        uint256 assigned;
        // Same effective basis as `allocatedUsd`: a guardian whose bond has gone
        // must not dilute the survivors' shares. Summed over the PLEDGES rather
        // than the live bookings, since the bookings are what this function is
        // about to rewrite.
        // REVERTS ON `NoWoodPrice` rather than settling at a price nobody can
        // vouch for. Settlement is permissionless and safe to skip, so an outage
        // costs a retry, not a stuck proposal — unlike `recordApproval`, where
        // declining to act would disenfranchise a voter.
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

            // SHARED ACROSS OPEN PROPOSALS: this guardian's slashable basis is
            // pro-rated against every other proposal it currently backs. PLEDGE
            // BASIS — `reserved` is `_reservedUsd[key][g]`, so the denominator
            // must be `_livePledgedUsd`, never `_liveBookedUsd`.
            uint256 mine = _sharedSlashableUsd(g, reserved, priceX8, pv.executedAt, _livePledgedUsd[g]);
            uint256 alloc = _allocate(mine, effectiveTotal, needUsd);
            // BOOKED, NOT ALLOCATED. `_rebook` clamps an upward move to the
            // guardian's free budget, so what it returns can be below `alloc`.
            // Accruing the allocation instead would overstate `assigned`,
            // understate the residue, and emit a number no bucket holds.
            uint256 booked = _rebook(key, g, alloc, priceX8);
            assigned += booked;
            // `_allocate` never scales up (alloc <= mine) and the clamp only
            // lowers, so booked <= mine.
            headroom[i] = mine - booked;
        }

        // Truncation leaves the total a few wei under `needUsd`. Hand the residue
        // out rather than leaving it short: the quorum compares this same
        // aggregate against `needUsd`, so a rounded-down sum would make a
        // fully-subscribed proposal fail its own coverage check after settling.
        //
        // BOUNDED BY EACH HOLDER'S OWN HEADROOM. The residue is dust only when
        // `effectiveTotal > needUsd`. When the cohort's live value has fallen
        // BELOW the need, `_allocate` returns `mine` for everyone and the residue
        // is the entire COHORT SHORTFALL — handing that to one guardian would
        // scale its booking above its own pledge and past `k x bond`, inventing
        // collateral nobody pledged. Capping each top-up at `mine - alloc` bounds
        // the booking by `min(slashable bond, pledge)`.
        //
        // In the shortfall case every headroom is zero, so nothing is handed out
        // and the aggregate lands under `needUsd` — the same figure
        // `requireApproveQuorum` would have summed had this never run. Settling
        // neither creates nor destroys coverage; it only stops over-reserving.
        if (assigned < needUsd) {
            uint256 residue = needUsd - assigned;
            for (uint256 i = 0; i < n && residue != 0; i++) {
                uint256 room = headroom[i];
                if (room == 0) continue;
                uint256 take = room < residue ? room : residue;
                address g = listed[i];
                // AND BOUNDED A SECOND TIME BY THE BATCHING CAP. `room` bounds the
                // top-up by what this guardian could PAY; `_rebook`'s clamp bounds
                // it by what it may still UNDERWRITE. Credit only what the bucket
                // actually took, or a guardian already at its cap would swallow
                // the residue and starve the approvers behind it.
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
    ///      settlement is re-runnable, so a booking written down at a bad price
    ///      has to be able to walk back up. `target` is bounded by
    ///      `_reservedUsd[key][g]`, itself bounded to `uint192`, so neither the
    ///      cast nor the bucket arithmetic can misbehave.
    ///
    /// @dev THE BATCHING CAP IS RE-CHECKED ON THE WAY UP. Enforcing it only at
    ///      approve time left a hole, because the pledge a settlement pass walks a
    ///      booking back up to was checked against the guardian's exposure AS IT
    ///      WAS AT THE VOTE:
    ///
    ///        1. g1 and g2 each reserve the full coverage of P1; g1 is at its cap.
    ///        2. Anyone settles P1: both bookings are written DOWN pro-rata and
    ///           half of g1's budget comes free.
    ///        3. g1 approves P2 with it. Legal — `recordApproval`'s check passes.
    ///        4. g2 is slashed to zero on an unrelated conviction.
    ///        5. Anyone re-runs settlement on P1. `_effectiveReservedTotal` sums
    ///           over LIVE bonds, so it has fallen, `_allocate` hands g1 more, and
    ///           g1 now backs 1.5x its own bond.
    ///
    ///      Step 5 is permissionless and step 4 is ordinary operation.
    ///
    ///      CLAMPED, NOT REVERTED, matching `recordApproval`: a settlement that
    ///      reverted would be one an adversary could brick for a whole cohort by
    ///      parking exposure on a single approver. The clamp costs a bucket scan,
    ///      so it is paid ONLY on the upward branch.
    ///
    ///      `openExposureUsd(g)` ALREADY counts this key's current booking, so the
    ///      bound is `current + (cap - open)`, not `cap - open`; subtracting the
    ///      booking twice would clamp repairs that breach nothing. That also keeps
    ///      it a CLAMP rather than a freeze: with no competing exposure the bound
    ///      is the full cap and a written-down booking walks all the way back.
    function _rebook(bytes32 key, address g, uint256 target, uint256 priceX8) internal returns (uint256) {
        RecordedExposure memory r = _recorded[key][g];
        uint256 current = uint256(r.usd);
        if (target > current) {
            // LIVE (anchor = 0), DELIBERATELY. This is the BATCHING cap — how much
            // of this guardian's bond is free across ALL its open proposals right
            // now — not a per-proposal verdict-recovery bound, so it stays on the
            // same basis `recordApproval`'s original cap uses.
            uint256 capUsd = kNumerator * _slashableBondUsd(g, priceX8, 0);
            uint256 open = openExposureUsd(g);
            uint256 headroom = capUsd > open ? capUsd - open : 0;
            uint256 maxTarget = current + headroom;
            if (target > maxTarget) target = maxTarget;
        }
        if (target == current) return current;
        if (target < current) {
            _buckets[g][r.epoch] -= (current - target);
            // Mirrors the bucket write on the SAME delta, keeping `_liveBookedUsd`
            // exactly equal to the sum of `_recorded[key][g].usd` at every instant,
            // in both directions. The pledge accumulators are untouched here:
            // settlement never rewrites the pledge, only the booking.
            _liveBookedUsd[g] -= (current - target);
        } else {
            _buckets[g][r.epoch] += (target - current);
            _liveBookedUsd[g] += (target - current);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _recorded[key][g].usd = uint192(target);
        return target;
    }

    /// @dev `_effectiveTotal` over the PLEDGES rather than the live bookings. The
    ///      two coincide until `settleCoverage` first runs and diverge afterwards;
    ///      settlement needs this one, because it is rewriting the very numbers
    ///      `_effectiveTotal` reads and must divide by an input its own previous
    ///      passes did not move. Anchored and shared exactly as `_effectiveTotal`
    ///      is.
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
    ///      Rounds DOWN, deliberately: allocations must never sum above `needUsd`,
    ///      or approvers would jointly owe more than the loss and the surplus
    ///      would have no claimant.
    ///
    ///      TWO REGIMES, which `settleCoverage`'s residue top-up must not
    ///      conflate. Above `needUsd` the shortfall really is dust, at most one wei
    ///      per approver. At or below it the function returns `reserved`
    ///      untouched and the gap to `needUsd` is the cohort SHORTFALL rather than
    ///      rounding — not something a top-up may paper over, because the
    ///      collateral to cover it does not exist.
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
        // guardian's budget as free while it is fully pledged.
        // `MAX_COVERAGE_HORIZON` bounds the span and `_coverageEpoch` refuses to
        // book beyond it, so the two keep this loop fixed-width.
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

    /// @dev The bucket whose expiry covers this proposal's settlement, floored at
    ///      the current epoch (a proposal already past its deadline must not book
    ///      into the past, where the bucket may have expired).
    ///
    ///      Reverts rather than clamping when settlement lands beyond
    ///      `MAX_COVERAGE_HORIZON`: clamping would silently under-cover the tail of
    ///      a long strategy, while refusing surfaces a mis-set duration ceiling as
    ///      a failed vote rather than a hole nobody sees.
    /// @dev `_coverageEpoch` without the revert — returns `(epoch, false)` when
    ///      settlement lands beyond the horizon so `recordApproval` can decline to
    ///      book instead of taking the vote down with it.
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
