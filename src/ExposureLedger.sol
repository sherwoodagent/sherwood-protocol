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
        ///      every post-execution coverage read (`coverageUsdOf`,
        ///      `liabilityUsd`/`_recoverableTotalUsd`, `slashBpsFor`) values
        ///      guardians at, via `swood.slashableStakeAt`, instead of live
        ///      stake.
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
 * @notice WOOD-denominated coverage accounting for the guardian
 *         economic-security model.
 *
 *         A guardian who approves a proposal DECLARES a WOOD amount, and the
 *         ledger locks `min(declared, kNumerator x slashableStake - openExposure)`
 *         — one figure per (proposal, guardian) that is at once the guardian's
 *         booking against the batching cap, its pledge to the proposal, and the
 *         base a conviction burns. There is NO cohort cap: locks may sum above
 *         the proposal's requirement, so nothing is ever pro-rated or written
 *         down, and the only path that moves a lock after `recordApproval` is
 *         its own release or retirement. The adversary that shape removes is
 *         anyone who could move a guardian's slash base after the fact
 *         (SHE-212/SHE-225: the A-fold reservation plus a permissionless
 *         collapse that had no sound moment to run).
 *
 *         `slashableBondUsd(g)` is `ownStake(g) * priceHaircut`; a guardian's
 *         own bond is the only slashable capital. USD enters at exactly two
 *         places: the execute-time quorum (`requireApproveQuorum`) and the
 *         liability/fee views. Capacity, locks and slash rates are pure WOOD.
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

    /// @dev Hard ceiling on how many buckets `openExposure` may walk, so the
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

    /// @dev THE ONE FIGURE. `wood` is the guardian's lock on this proposal —
    ///      simultaneously its booking (what `_buckets` holds against the
    ///      batching cap), its pledge (what `pledgedOf`/`freezeCoverage`/
    ///      `TokenCourt` ask "did this guardian underwrite it?"), and its slash
    ///      base (`slashBpsFor`). Written once by `recordApproval`, erased only
    ///      by `_unwindApproval` (release or retire). Because it is one storage
    ///      slot rather than a booking family and a pledge family, the divergence
    ///      class SHE-212 belonged to cannot be expressed. `epoch` is the bucket
    ///      it was booked into, so the unwind can subtract from exactly the
    ///      bucket the record added to.
    struct LockRecord {
        uint192 wood;
        uint64 epoch;
    }

    /// @dev Per-guardian epoch buckets, in WOOD. `openExposure` walks them.
    mapping(address guardian => mapping(uint256 epoch => uint256 wood)) internal _buckets;
    mapping(bytes32 reviewKey => mapping(address guardian => LockRecord)) internal _locks;

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

    /// @notice Per-(reviewKey, guardian) counterpart of `_pinnedCoverageUntil`.
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
        // `openExposure`, so no cooldown-length invariant is enforced here.
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

    /// @dev `slashableBondUsd` with the price passed in. ANCHOR-AWARE through
    ///      `_slashBasis` — see that helper for the live/anchored split.
    function _slashableBondUsd(address guardian, uint256 priceX8, uint256 anchor) internal view returns (uint256) {
        return (_slashBasis(guardian, anchor) * priceX8) / 1e8;
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
        // `openExposure`'s walk inside `MAX_SCAN_BUCKETS`.
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
        //
        // STRICT READ (SHE-214), unlike the registry bound above. This is a
        // security floor, and a wired game that cannot answer is refused rather
        // than declining to floor: `setCoverageFreezer` mirrors the same check on
        // the incoming address, so any wired freezer answered once and an
        // unreadable one is a fault, not an ordering mistake. Liveness survives
        // because the unwire switch (`setCoverageFreezer(0)`) has no window check.
        // The lowering order the pair permits is game first, then ledger —
        // `ChallengeGame.setChallengeWindow` floors under the LIVE ledger window,
        // this floors over the LIVE game window, so the reverse order reverts here.
        _requireWindowCoversFreezer(coverageFreezer, newWindow);
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
    /// @dev MIRRORS THE WINDOW FLOOR ON THE INCOMING GAME (SHE-214). The ledger
    ///      must keep coverage slashable at least as long as the game admits a
    ///      filing: `retireApproval`'s sweep opens at
    ///      `bucketEnd + ledger.challengeWindow` while `ChallengeGame.file`
    ///      closes at `executedAt + strategyDuration + game.challengeWindow`,
    ///      so `game.challengeWindow <= ledger.challengeWindow` is the
    ///      invariant. The game checks it at construction and in its two
    ///      setters; `setChallengeWindow` re-checks it when THIS window moves;
    ///      this setter was the fourth corner. Without it the three-step
    ///      `setCoverageFreezer(0)` -> `setChallengeWindow(small)` ->
    ///      `setCoverageFreezer(game)` walked through every other check
    ///      (`DeployPlanD` wires the freezer LAST, so the unwired state is
    ///      ordinary), and once seated nothing detected the inversion.
    ///
    ///      HISTORY. This check landed in #220, was reverted in 88872ed citing
    ///      "design.md D2", and is restored here. D2 there is the proposer-bond
    ///      reclaim design (`reclaimProposerBond`'s gate is a `max` of both
    ///      deadlines), which makes the BOND robust to a divergence — it says
    ///      nothing about the ledger having to ACCEPT one, and it does not
    ///      reach the approver sweep this invariant protects. The fixture that
    ///      broke (`test_reclaimBond_gameWindowAboveTheLedgers_waitsForTheGame`)
    ///      now raises the stub game's window AFTER wiring, which is the only
    ///      route to that state that a real game cannot take either.
    ///
    ///      Same strict shape as `setChallengeWindow`'s bound: zero skips (the
    ///      unwire switch), anything else must answer `challengeWindow()`.
    function setCoverageFreezer(address freezer) external onlyOwner {
        if (_frozenKeyCount != 0) revert CoverageFrozen();
        _requireWindowCoversFreezer(freezer, challengeWindow);
        emit CoverageFreezerSet(coverageFreezer, freezer);
        coverageFreezer = freezer;
    }

    /// @inheritdoc IExposureLedger
    /// @dev THE ONE KNOB THAT DECIDES WHETHER PROPOSALS CONTAMINATE EACH OTHER.
    ///      The per-guardian budget is `kNumerator x slashableStake`, in WOOD, so
    ///      at `k = 1` the bucket scan guarantees `sum of live locks <= stake`.
    ///      Burning one proposal's lock `L_A` then leaves
    ///      `stake - L_A >= sum over j != A of L_j`: every OTHER proposal the
    ///      guardian backs is still fully covered by what remains. That is the
    ///      containment property, and it holds with no pro-rata bookkeeping
    ///      because nothing is ever shared — each lock is its own collateral.
    ///
    ///      ANY `k > 1` IS DELIBERATE LEVERAGE THAT TRADES EXACTLY THAT AWAY. A
    ///      guardian may then lock more WOOD across proposals than it holds, and
    ///      a conviction on one may leave the others under-covered by precisely
    ///      the excess — the execute-time quorum still values each at
    ///      `min(lock, live stake)`, so the shortfall surfaces there, but only
    ///      for proposals that have not yet executed. The adversary is a future
    ///      operator raising `k` for capital efficiency without understanding
    ///      that it reintroduces cross-proposal contagion; this note is the
    ///      record that the default of 1 is a safety property, not a placeholder.
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
    ///      against `vault`, reporting `ok == false` on any failure rather than
    ///      reverting, so `recordApproval` can lock nothing instead of taking the
    ///      approve vote down.
    ///
    ///      HOISTED OUT OF ANY `try`'s ARGUMENT LIST, DELIBERATELY. Solidity
    ///      evaluates a call's argument expressions in the CALLER's frame,
    ///      strictly before the call a `try` around it actually guards, so a
    ///      revert from `IVaultAssetMinimal(pv.vault).asset()` or from
    ///      `gov.getRequiredCoverage(proposalId)` written inline propagated
    ///      straight through the `catch` as if the `try` were not there. Each read
    ///      is now resolved through its OWN try/catch, ahead of and independent
    ///      from the `coverageUsd` try the caller still performs.
    ///
    ///      `vault.code.length` is checked FIRST: a call that succeeds against a
    ///      codeless address returns no data, and Solidity does not route the
    ///      resulting ABI-decode failure through `catch`. `governor` needs no
    ///      matching guard — the caller only reaches this via a `pv` already
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
    ///      THE GUARDIAN DECLARES, THE LEDGER CLAMPS. `lockWood` is what this
    ///      guardian chooses to put behind the proposal; the ledger locks
    ///      `min(lockWood, free budget)` where free budget is
    ///      `kNumerator x slashableStake - openExposure`, all in WOOD. Nothing
    ///      here is priced: the lock is WOOD and the cap is WOOD, so a WOOD-feed
    ///      outage — the failure mode the old USD reservation had to book nothing
    ///      through — is simply not a case on this path. The adversary a
    ///      price-dependent capacity check hands a lever to is whoever can starve
    ///      or inflate that feed; this path gives them nothing to push on.
    ///
    ///      NO COHORT CAP, DELIBERATELY. The lock is NOT clamped to the proposal's
    ///      requirement or to the still-uncovered remainder. Clamping to the
    ///      remainder would let the first approver absorb the whole coverage
    ///      while later ones lock zero and are never listed, so flipping the first
    ///      approver to Block releases the entire commitment with nobody left to
    ///      cover it — a costless veto by a single guardian. Clamping to the
    ///      requirement per approver (the old A-fold reservation) then needs a
    ///      later collapse to pro-rata, and that collapse has no sound moment to
    ///      run (SHE-212/SHE-225). With neither clamp, over-subscription is a
    ///      well-covered proposal and every lock is exactly what its owner will
    ///      lose on conviction. The execute-time quorum still aggregates, so a
    ///      guardian never has to single-handedly cover a proposal.
    ///
    ///      Consequence: an under-bonded guardian is not rejected at vote time —
    ///      it locks what it can, and the proposal fails the execute-time quorum
    ///      unless other approvers make up the rest. The cap is enforced by
    ///      locking zero, not by reverting the vote.
    function recordApproval(address governor, uint256 proposalId, address guardian, uint256 lockWood)
        external
        onlyRegistry
    {
        bytes32 key = _reviewKey(governor, proposalId);
        // Idempotent (vote-change round trip). A live lock means this guardian
        // already underwrote the proposal; a second call must not double-book
        // the bucket.
        if (_locks[key][guardian].wood != 0) return;
        // A zero declaration locks nothing and is not an error: the guardian is
        // voting on the merits without underwriting, exactly as a guardian with
        // no free budget does below. Returning before the governor reads keeps
        // this the cheapest path.
        if (lockWood == 0) return;
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        // A ZERO-COVERAGE PROPOSAL LOCKS NOTHING, and ANY FAILURE TO PRICE THE
        // REQUIREMENT ALSO LOCKS NOTHING RATHER THAN REVERTING — missing asset
        // feed, stale feed, an unreadable vault or required-coverage read.
        // Reverting here would take the APPROVE vote down while Block votes
        // still work, turning the review block-only: guardians could veto but
        // never endorse, and the proposal would pass optimistically anyway. This
        // is the one asset-price read left on the approval path, kept only to
        // recognise "nothing to underwrite"; the lock itself needs no price.
        (address asset, uint256 requiredCoverage, bool resolved) = _tryResolveCoverageInputs(gov, proposalId, pv.vault);
        if (!resolved) return; // unreadable right now: lock nothing, let the quorum decide
        //
        // Called externally so the revert can be caught; `coverageUsd` is a view
        // on this same contract, and a same-contract call cannot be wrapped.
        uint256 needUsd;
        try this.coverageUsd(asset, requiredCoverage) returns (uint256 v) {
            needUsd = v;
        } catch {
            return; // unpriceable right now: lock nothing, let the quorum decide
        }
        if (needUsd == 0) return; // zero-coverage: nothing to underwrite

        // Free budget = k * stake - open exposure, in WOOD. Zero free budget is
        // the batching attack's boundary: this guardian's stake is already fully
        // spoken for by its other open locks. LIVE stake, deliberately: this is
        // the pre-execution capacity question, and no verdict anchor exists yet.
        // The sWOOD read is NOT wrapped — a reverting `guardianStake` is a broken
        // core dependency, not an oracle outage, and must not be absorbed.
        uint256 cap = kNumerator * swood.guardianStake(guardian);
        uint256 open = openExposure(guardian);
        // NO FREE BUDGET -> LOCK NOTHING, DON'T REVERT. Reverting would silence
        // the approve side entirely for a guardian whose budget is spent while
        // Block votes still work — disenfranchisement, not a cap. The cap still
        // binds, and enforcement moves to `requireApproveQuorum` at execute.
        if (open >= cap) return;
        uint256 free = cap - open;

        uint256 lock = lockWood < free ? lockWood : free;
        // Truncation in the uint192 store below would book a phantom (smaller)
        // lock — fail loudly instead. Unreachable at any sane `kNumerator`
        // (stake is uint128), kept as the belt to that brace.
        if (lock > type(uint192).max) revert InvalidParameter();
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
        _buckets[guardian][epoch] += lock;
        // lock bounded to uint192 above; epoch = elapsed / epochLength cannot
        // approach 2^64 on any realistic timescale.
        // forge-lint: disable-next-line(unsafe-typecast)
        _locks[key][guardian] = LockRecord({wood: uint192(lock), epoch: uint64(epoch)});
        // The ledger keeps its OWN approver list: the quorum reads this, never
        // the registry, so the ledger's registry pointer and the governor's can
        // never disagree about who covered a proposal.
        if (_approverIndex[key][guardian] == 0) {
            _approversOf[key].push(guardian);
            _approverIndex[key][guardian] = _approversOf[key].length; // 1-indexed
        }
        emit ExposureRecorded(guardian, key, lock, epoch);
    }

    /// @dev SHARED UNWIND, used by both `releaseApproval` and `retireApproval` so
    ///      the vote-change unwind and the post-window sweep cannot drift apart.
    ///      Clears the lock, subtracts it from the bucket it was booked into, and
    ///      swap-and-pops the guardian out of the approver list.
    ///
    ///      PRECONDITION, NOT ENFORCED HERE: callers must already hold `r` from
    ///      BEFORE this call, and freeze/pin/window checks are each caller's own
    ///      responsibility — the two gate on different conditions.
    function _unwindApproval(bytes32 key, address guardian, LockRecord memory r) internal {
        delete _locks[key][guardian];
        // The bucket was credited with exactly `r.wood` at exactly `r.epoch`
        // and nothing has moved either since — there is no second accumulator
        // to keep in step, which is the point of a single lock.
        _buckets[guardian][r.epoch] -= r.wood;

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
    ///      exactly the lock, from the bucket it was booked into. No-op when
    ///      nothing is locked — never underflows.
    function releaseApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
        bytes32 key = _reviewKey(governor, proposalId);
        // A live challenge pins this coverage (§3.4): the guardian may not
        // release it and recycle the budget while under challenge. This is also
        // what makes the lock a sound slash base — a filed challenge blocks the
        // only registry-side path that could erase it.
        if (_frozen[key]) revert CoverageFrozen();
        LockRecord memory r = _locks[key][guardian];
        if (r.wood == 0) return;
        _unwindApproval(key, guardian, r);
        emit ExposureReleased(guardian, key, r.wood, r.epoch);
    }

    /// @inheritdoc IExposureLedger
    /// @dev PERMISSIONLESS RETIREMENT OF A DEAD COMMITMENT. `releaseApproval` has
    ///      exactly ONE caller in the system, gated on `block.timestamp <
    ///      reviewEnd`, so once a review closes there is no release path left —
    ///      the lock would otherwise sit in `_locks` and in `_approversOf`
    ///      forever. `openExposure` (the batching-cap denominator) DOES decay on
    ///      wall clock, so the BUDGET recycles without this; what does not is the
    ///      listing itself, which `freezeCoverage`/`pinCoverageUntil` and every
    ///      accused-set derivation walk. Retiring keeps those lists bounded by
    ///      commitments that can still be collected on.
    ///
    ///      Anyone may sweep a key/guardian pair once it is provably inert:
    ///        - `!_frozen[key]`, identically to `releaseApproval`'s own guard;
    ///        - `_pinnedUntil[key][guardian] < block.timestamp` — PER-KEY, not the
    ///          per-guardian max: a pin against some OTHER stale proposal the same
    ///          guardian once approved must not block sweeping this one, or a
    ///          single routine `Inconclusive` anywhere in its history blocks
    ///          retirement of the entire book;
    ///        - `block.timestamp` past the SAME expiry `openExposure` uses for
    ///          this booked epoch.
    ///      It then performs `releaseApproval`'s exact unwind, so the two cannot
    ///      diverge.
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
        LockRecord memory r = _locks[key][guardian];
        if (r.wood == 0) return; // nothing to retire; mirrors releaseApproval's no-op
        if (_frozen[key]) revert CoverageFrozen();
        if (_pinnedUntil[key][guardian] >= block.timestamp) revert CoveragePinnedActive();
        // Same expiry `openExposure` uses for this exact bucket: bucket
        // `r.epoch` counts until its challenge window elapses at
        // `genesis + (r.epoch + 1) * L + W`. Keyed on the BOOKED epoch, not
        // `currentEpoch()`, because a long-duration strategy books into a future
        // epoch.
        if (block.timestamp <= epochGenesis + (uint256(r.epoch) + 1) * epochLength + challengeWindow) {
            revert ChallengeWindowOpen();
        }
        _unwindApproval(key, guardian, r);
        emit ExposureRetired(guardian, key, r.wood, r.epoch);
    }

    /// @inheritdoc IExposureLedger
    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory lockedWood)
    {
        return _approversWithLocks(_reviewKey(governor, proposalId));
    }

    /// @inheritdoc IExposureLedger
    /// @dev IDENTICAL TO `approversOf` BY CONSTRUCTION. The two views used to
    ///      pair the list with different numbers — the live booking and the
    ///      pledge — because `settleCoverage` could move the former while a
    ///      challenge was live. There is now one figure, so both read the same
    ///      storage. Kept as a separate selector because `ChallengeGame.file` and
    ///      `TokenCourt._recordAccused` ask their question of it by name ("did
    ///      this guardian underwrite the proposal?"), and that question still
    ///      wants a name that says PLEDGE rather than BOOKING.
    function pledgedOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory lockedWood)
    {
        return _approversWithLocks(_reviewKey(governor, proposalId));
    }

    function _approversWithLocks(bytes32 key)
        internal
        view
        returns (address[] memory approvers, uint256[] memory lockedWood)
    {
        approvers = _approversOf[key];
        lockedWood = new uint256[](approvers.length);
        for (uint256 i = 0; i < approvers.length; i++) {
            lockedWood[i] = _locks[key][approvers[i]].wood;
        }
    }

    /// @inheritdoc IExposureLedger
    function lockOf(address governor, uint256 proposalId, address guardian) external view returns (uint256) {
        return _locks[_reviewKey(governor, proposalId)][guardian].wood;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Freeze scope: this pins ONE proposal's committed coverage. It
    ///      deliberately does not touch the guardian's stake or its other open
    ///      approvals — a challenge freezes the coverage it accuses, not the
    ///      guardian.
    /// @dev THE FREEZE PINS THE UNSTAKE CLAIM. `openExposure` sums epoch
    ///      buckets on pure wall-clock, so a guardian's exposure ages out
    ///      `challengeWindow` after its epoch whether or not it is under
    ///      accusation — and a disputed challenge can outlive that. While any
    ///      proposal naming them is frozen, sWOOD refuses the unstake claim.
    ///      Idempotent on both sides: the counters move only when the flag
    ///      actually flips.
    /// @dev GATED ON THE LOCK. The lock is written once by `recordApproval` and
    ///      erased only by `_unwindApproval`, whose two callers this freeze
    ///      blocks (`releaseApproval`) or whose gate it fails (`retireApproval`),
    ///      so nothing can transit a listed guardian's figure through zero while
    ///      the challenge naming them is live. The old booking/pledge split
    ///      existed precisely because one of the two COULD (audit-181 finding A).
    function freezeCoverage(address governor, uint256 proposalId) external onlyFreezer {
        bytes32 key = _reviewKey(governor, proposalId);
        if (!_frozen[key]) {
            _frozen[key] = true;
            _frozenKeyCount++;
            address[] storage listed = _approversOf[key];
            for (uint256 i = 0; i < listed.length; i++) {
                address g = listed[i];
                if (_locks[key][g].wood == 0) continue;
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
    ///      GATED ON THE LOCK — identical reasoning to `freezeCoverage` above.
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
            if (_locks[key][g].wood == 0) continue;
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
    /// @dev Measures whether the covering approvers' AGGREGATE lock meets the
    ///      proposal's coverage, returning the raised and required figures instead
    ///      of gating all-or-nothing — the caller derives a coverage-proportional
    ///      effective capital from the ratio rather than being refused outright on
    ///      a shortfall. Each approver contributes `min(lock, live slashable
    ///      stake) x woodPriceX8()`: the lock is what makes the aggregate
    ///      meaningful (the same stake cannot be locked twice — `recordApproval`
    ///      clamps to the free budget), and the live leg keeps the dollar
    ///      requirement honest (a stake that shrank since the vote counts at its
    ///      shrunken value). The adversary the live leg answers is a guardian
    ///      whose lock has become worth less than it declared — through an
    ///      unstake request or a WOOD price fall — who MUST count at the live
    ///      figure.
    ///
    ///      THIS IS THE ONE PLACE WOOD BECOMES USD FOR COVERAGE. Locks and
    ///      capacity are WOOD everywhere else; the requirement is a USD question
    ///      and it is answered here, at execute, where reverting on a missing
    ///      price is the safe direction.
    ///
    ///      Approvers come from the ledger's OWN `_approversOf` list, never from
    ///      the registry: the ledger booked the locks itself, so the ledger's
    ///      and governor's registry pointers cannot diverge about who approved.
    ///      The list is bounded by `MAX_APPROVERS_PER_PROPOSAL`.
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
    ///      to price WOOD there is no proof anyone's stake covers anything.
    ///
    /// @dev NO CROSS-PROPOSAL SHARING IS NEEDED HERE. At `kNumerator == 1` the
    ///      bucket scan in `recordApproval` guarantees a guardian's live locks sum
    ///      to at most its stake, so `min(lock, stake)` per proposal cannot claim
    ///      the same WOOD twice across proposals — the invariant the old pro-rata
    ///      `_sharedSlashableUsd` had to enforce by division falls out of the
    ///      lock itself. Above 1 it is deliberately traded away (see
    ///      `setKNumerator`).
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

        // Hoisted: loop-invariant — one price read for the whole cohort.
        uint256 priceX8 = woodPriceX8();

        uint256 haveUsd;
        for (uint256 i = 0; i < n; i++) {
            address g = approvers[i];
            uint256 lock = _locks[key][g].wood;
            if (lock == 0) continue; // defensive; a released guardian is swap-popped out
            // ANCHORED AT `block.timestamp`, NOT LIVE. `anchor = 0` reads live
            // `guardianStake`, while every conviction values the SAME guardian
            // through `swood.slashableStakeAt(g, c.executedAt)`, resolving to
            // `_slashableAt(g, openedAt - 1)`. `upperLookupRecent` is INCLUSIVE of
            // `key == anchor`, so a same-block top-up staked at
            // `block.timestamp == executedAt` was COUNTED by the live read and
            // EXCLUDED by the verdict's lookup — the gate could certify coverage a
            // conviction could never collect. Passing `block.timestamp` excludes
            // it on both sides identically.
            haveUsd += _recoverableUsd(g, lock, priceX8, block.timestamp);
            if (haveUsd >= requiredCoverageUsd) return (haveUsd, requiredCoverageUsd); // early exit
        }
        // The loop early-returns on full coverage, so reaching here means the
        // aggregate fell short. A genuinely zero aggregate is still an error; any
        // nonzero-but-partial one is reported to the caller instead of reverting,
        // so execution can size to the coverage actually raised.
        if (haveUsd == 0) revert InsufficientApproveCoverage();
        return (haveUsd, requiredCoverageUsd);
    }

    /// @inheritdoc IExposureLedger
    /// @dev THE RATE IS THE LOCK OVER THE SLASH BASIS, ROUNDED UP. For each
    ///      listed approver: `ceil(lock x 10_000 / basis)`, saturating at
    ///      `BPS_DENOMINATOR` when `lock >= basis` or `basis == 0`, and 0 for a
    ///      zero lock. `StakedWood._slashOne` burns `mulDiv(basis, bps, 10_000)`,
    ///      so feeding it this rate burns `min(lock, basis)` — rounded UP by at
    ///      most `basis / 10_000`, never down, so truncation can never leave a
    ///      convicted guardian owing less than it locked. The staking envelope
    ///      `[minSlashBps, maxSlashBps]` is then applied by `_slashOne`'s callers,
    ///      at exactly one governance-controlled site; it is NOT applied here,
    ///      so the two cannot drift.
    ///
    ///      `basis` IS THE SAME NUMBER THE CONVICTION SIZES FROM. Once the
    ///      proposal has executed it is `swood.slashableStakeAt(g, executedAt)` —
    ///      `min(stake at the anchor, live stake)` — byte-for-byte what
    ///      `slashVerdict(., executedAt, .)` hands `_slashOne`. Dividing by LIVE
    ///      stake instead would let a convicted guardian shrink its own burn by
    ///      topping up AFTER the drain: the top-up raises the denominator but is
    ///      excluded from the anchored basis the burn multiplies, so a guardian
    ///      that doubled its stake post-execution would pay half its lock. Using
    ///      the anchored basis for both makes the burn `min(lock, basis)`
    ///      regardless of anything staked after the anchor. Pre-execution
    ///      (`executedAt == 0`, no verdict anchor exists) the basis is live
    ///      stake.
    ///
    ///      THE BASIS IS THE LOCK AND NOTHING ELSE — never a pro-rata allocation,
    ///      never a live-priced share. The adversary is anyone able to move a
    ///      slash basis while a challenge is live. Under the previous model the
    ///      booking `_recorded[key][g].usd` was rewritten in both directions by a
    ///      permissionless, re-runnable, un-freeze-gated `settleCoverage`, so
    ///      pashov review finding #13 moved this predicate onto the pledge and
    ///      made the rate a binary `BPS_DENOMINATOR`-or-nothing: a proportional
    ///      rate on a number a stranger could recompute at will was the whole
    ///      difference between losing 100% of a live stake and losing nothing.
    ///      THAT REASONING NO LONGER APPLIES because the number it defended
    ///      against no longer exists: there is no booking distinct from the
    ///      pledge, `settleCoverage` and `_rebook` are gone, and the lock is
    ///      written once by `recordApproval` and erased only by `releaseApproval`
    ///      (blocked outright by `CoverageFrozen` for the life of a challenge) or
    ///      `retireApproval` (refused while frozen or pinned). A proportional
    ///      rate on the lock is therefore a rate on a figure nobody but the
    ///      guardian's own vote change could ever have moved, and that path shut
    ///      the moment the challenge was filed.
    ///
    ///      NO PRICE READ, AND THAT IS A LIVENESS PROPERTY. Lock and basis are
    ///      both WOOD, so a conviction never waits on a feed — and feed outages
    ///      correlate with exactly the market stress a drain happens in. The
    ///      coverage GATE still prices, but it runs at execution, where reverting
    ///      is the safe direction.
    ///
    ///      `minSlashBps` IS THE SINGLE DETERRENCE FLOOR. A guardian who locks 1
    ///      wei contributes ~nothing to the quorum and still owes at least
    ///      `minSlashBps` of everything it holds on conviction, because the
    ///      envelope is applied downstream to whatever non-zero rate this returns
    ///      (1 wei rounds UP to 1 bps, which the floor then raises). A token
    ///      declaration does not buy a token penalty, and no separate
    ///      declaration floor is needed to make that so.
    function slashBpsFor(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory bps)
    {
        // The anchor every conviction on this proposal sizes from. Read once
        // for the cohort; the governor is a protocol contract, not an oracle.
        uint256 anchor = ILedgerGovernorMinimal(governor).getProposalView(proposalId).executedAt;
        return slashBpsForAt(governor, proposalId, anchor);
    }

    /// @inheritdoc IExposureLedger
    /// @dev ONE FORMULA FOR BOTH SLASH PATHS. `slashBpsFor` is this view at the
    ///      verdict anchor (`executedAt`); `GuardianRegistry.resolveReview` calls
    ///      it directly at the review-open instant, because a review-path block
    ///      lands BEFORE execution, when `executedAt` is still zero and the live
    ///      basis `slashBpsFor` would fall back to is not the one
    ///      `StakedWood.slashGuardians` burns against. Exposing the anchor rather
    ///      than letting the registry re-derive `ceil(lock / basis)` is what keeps
    ///      the two paths from drifting: the registry contributes only the
    ///      severity multiplier, never a second copy of the rate.
    ///
    ///      `anchor` IS A RAW INSTANT. `_slashBasis` hands it to
    ///      `swood.slashableStakeAt`, which applies the same-block top-up `-1`
    ///      itself — so a caller holding an ALREADY-hardened stamp (the registry's
    ///      `Review.openedAt == open block - 1`) must pass the raw open instant
    ///      (`openedAt + 1`) to land the lookup on the checkpoint `_slashOne`
    ///      will multiply. `anchor == 0` reads live stake (no verdict anchor
    ///      exists yet). Reverts `VerdictNotPast` through sWOOD on a future
    ///      anchor.
    function slashBpsForAt(address governor, uint256 proposalId, uint256 anchor)
        public
        view
        returns (address[] memory approvers, uint256[] memory bps)
    {
        bytes32 key = _reviewKey(governor, proposalId);
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        approvers = new address[](n);
        bps = new uint256[](n);
        if (n == 0) return (approvers, bps);

        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            approvers[i] = g;
            uint256 lock = _locks[key][g].wood;
            if (lock == 0) continue; // released, or an approval that locked nothing: owes 0
            uint256 basis = _slashBasis(g, anchor);
            if (basis == 0 || lock >= basis) {
                // Nothing beyond the basis is reachable; the shortfall is the
                // residual after the execute-time quorum, not a gate hole.
                bps[i] = BPS_DENOMINATOR;
            } else {
                // ceil(lock * 10_000 / basis), basis > lock > 0 here so the
                // result is in [1, 9_999].
                bps[i] = (lock * BPS_DENOMINATOR + basis - 1) / basis;
            }
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev THE FEE-WEIGHT VIEW. `GuardianRegistry.getApproverCoverage` pays
    ///      coverage-weighted guardian fees off this. UNCAPPED at the proposal's
    ///      need, deliberately: a guardian who locked more took more risk — its
    ///      whole lock burns on conviction, not a pro-rata share — and earns fee
    ///      in proportion. Capping here would pay an over-subscribing cohort as
    ///      if they had each risked less than they did.
    ///
    ///      `min(lock, slashable stake at the anchor)`, priced: a guardian whose
    ///      stake has since fallen below its lock is paid on what a conviction
    ///      could actually have recovered from it, the same discount
    ///      `requireApproveQuorum` applies.
    ///
    /// @dev ORACLE ASYMMETRY, DELIBERATE. `recordApproval` needs no WOOD price;
    ///      this REVERTS `NoWoodPrice` without one. The registry's caller wraps
    ///      it in a try/catch and reports `priced == false` — the signal to
    ///      retry rather than pay zero to everyone through a feed outage.
    function coverageUsdOf(address governor, uint256 proposalId, address guardian) external view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 lock = _locks[key][guardian].wood;
        if (lock == 0) return 0;
        uint256 anchor = ILedgerGovernorMinimal(governor).getProposalView(proposalId).executedAt;
        return _recoverableUsd(guardian, lock, woodPriceX8(), anchor);
    }

    /// @inheritdoc IExposureLedger
    /// @dev `min(needUsd, sum over approvers of min(lock_i, slashable stake_i) x
    ///      price)`. The sum is what a conviction can ACTUALLY take across the
    ///      cohort for this proposal; the cap at `needUsd` is what a challenger
    ///      should have to post a bond against. The adversary the cap answers is
    ///      a cohort that over-subscribes a proposal precisely to inflate the
    ///      bond a challenger must post: with the cap, surplus locks cost the
    ///      challenger nothing. THE CAP BINDS BOND SIZING ONLY — on conviction
    ///      every approver's full lock still burns (`slashBpsFor` reads no need).
    ///
    ///      ANCHORED AT `executedAt`, not live: without the anchor, an accused
    ///      cohort could permissionlessly top up its stake AFTER the drain to
    ///      price up its own filing bond with capital the verdict slash can never
    ///      reach.
    ///
    ///      REVERTS on an unpriceable WOOD feed or a stale asset feed rather than
    ///      returning a stale figure. Sizing a challenger's bond off a price
    ///      nobody can vouch for is the unsafe direction; `ChallengeGame.file`
    ///      maps the revert to `WoodPriceUnset` and the filing waits.
    function liabilityUsd(address governor, uint256 proposalId) external view returns (uint256) {
        return _liabilityUsd(governor, proposalId);
    }

    /// @inheritdoc IExposureLedger
    /// @dev SAME FIGURE AS `liabilityUsd`. The two views diverged when
    ///      `liabilityUsd` pro-rated each guardian's stake across every other
    ///      proposal it backed and the challenger bond needed the un-shared sum.
    ///      With no cohort cap nothing is pro-rated, so there is no distinct
    ///      shared basis left to differ from. Kept as a selector because
    ///      `ChallengeGame.file` names it; both answer "what can a conviction on
    ///      THIS proposal recover, capped at what THIS proposal needs".
    function unsharedLiabilityUsd(address governor, uint256 proposalId) external view returns (uint256) {
        return _liabilityUsd(governor, proposalId);
    }

    function _liabilityUsd(address governor, uint256 proposalId) internal view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        uint256 recoverable = _recoverableTotalUsd(key, woodPriceX8(), pv.executedAt);
        if (recoverable == 0) return 0;

        uint256 needUsd = coverageUsd(IVaultAssetMinimal(pv.vault).asset(), gov.getRequiredCoverage(proposalId));
        return needUsd < recoverable ? needUsd : recoverable;
    }

    /// @dev Sum of `min(lock, slashable stake)` across a proposal's approvers,
    ///      priced — what the cohort can ACTUALLY pay on this proposal, not what
    ///      it locked. `requireApproveQuorum` applies the same per-guardian
    ///      discount, so the figure a challenger is charged against and the
    ///      figure the quorum certified are the same arithmetic.
    ///
    ///      ANCHORED: `anchor` is `pv.executedAt`, threaded from the caller — 0
    ///      (unexecuted) keeps every term live. Once executed, the slashable term
    ///      is `min(snapshot at executedAt, live)`, so an accused approver topping
    ///      up AFTER the drain is priced at what the verdict can reach.
    function _recoverableTotalUsd(bytes32 key, uint256 priceX8, uint256 anchor) internal view returns (uint256 total) {
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            uint256 lock = _locks[key][g].wood;
            if (lock == 0) continue;
            total += _recoverableUsd(g, lock, priceX8, anchor);
        }
    }

    /// @dev `min(lock, slash basis at anchor) x priceX8 / 1e8` — one guardian's
    ///      recoverable contribution to one proposal, in USD-18. The lock caps
    ///      what THIS proposal may claim; the basis caps what a conviction
    ///      anchored at `anchor` could take from the guardian at all.
    function _recoverableUsd(address guardian, uint256 lock, uint256 priceX8, uint256 anchor)
        internal
        view
        returns (uint256)
    {
        uint256 basis = _slashBasis(guardian, anchor);
        uint256 wood = basis < lock ? basis : lock;
        return (wood * priceX8) / 1e8;
    }

    /// @dev The WOOD a conviction anchored at `anchor` can reach from `guardian`.
    ///      `anchor == 0` reads LIVE `guardianStake` — the pre-execution basis,
    ///      used where no verdict anchor exists yet. `anchor != 0` reads
    ///      `swood.slashableStakeAt(guardian, anchor)`: `min(snapshot at anchor,
    ///      live)`, exactly what `StakedWood._slashOne` sizes a verdict slash
    ///      from — so a guardian who tops up stake AFTER the anchor is never
    ///      counted as coverage the conviction cannot reach. Every
    ///      post-execution ledger read passes `pv.executedAt`.
    function _slashBasis(address guardian, uint256 anchor) internal view returns (uint256) {
        return anchor == 0 ? swood.guardianStake(guardian) : swood.slashableStakeAt(guardian, anchor);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Bucket `e` (covering [genesis + e·L, genesis + (e+1)·L)) counts until
    ///      its challenge window elapses at `genesis + (e+1)·L + W` — exact
    ///      expiry, so the coverage budget recycles every challenge window
    ///      (spec §3.3). First counted bucket: e such that (e+1)·L + W > elapsed,
    ///      i.e. from = (elapsed - W) / L when elapsed > W. from <= cur always
    ///      (W > 0), so the loop is bounded by ceil(W/L) + 1 iterations.
    function openExposure(address guardian) public view returns (uint256 total) {
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

    /// @dev Both ends of `openExposure`'s walk in one place: `challengeWindow`
    ///      behind the current bucket, `MAX_COVERAGE_HORIZON` ahead of it, plus
    ///      the partial bucket at each edge.
    function _requireScanBounded(uint256 window, uint256 length) internal pure {
        if (length == 0) revert InvalidParameter();
        if ((window + MAX_COVERAGE_HORIZON) / length + 2 > MAX_SCAN_BUCKETS) revert InvalidParameter();
    }

    /// @dev `game.challengeWindow <= ledgerWindow`, read off `freezer` (the game
    ///      address) — shared by `setChallengeWindow` (wired freezer, candidate
    ///      window) and `setCoverageFreezer` (candidate freezer, stored window).
    ///      Zero is the unwire switch and skips. Otherwise a raw staticcall in
    ///      `_feedPriceX8`'s shape — `code.length` first (a typed call to an EOA
    ///      reverts in THIS frame), short returndata rejected before decoding —
    ///      and, being a security gate, it FAILS CLOSED: an unreadable game
    ///      reverts `CoverageFreezerUnreadable` rather than declining to floor.
    function _requireWindowCoversFreezer(address freezer, uint256 ledgerWindow) internal view {
        if (freezer == address(0)) return;
        if (freezer.code.length == 0) revert CoverageFreezerUnreadable();
        (bool ok, bytes memory ret) =
            freezer.staticcall(abi.encodeCall(IChallengeGameWindowMinimal.challengeWindow, ()));
        if (!ok || ret.length < 32) revert CoverageFreezerUnreadable();
        if (ledgerWindow < abi.decode(ret, (uint256))) revert InvalidParameter();
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
