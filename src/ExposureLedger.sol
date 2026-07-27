// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";

/// @dev Narrow sWOOD read surface (own stake, inbound delegation, delegated
///      slash cap, cooldown). Mirrors the IGovernorMinimal pattern in
///      GuardianRegistry — the ledger does not import the full IStakedWood ABI.
interface ISwoodMinimal {
    function guardianStake(address guardian) external view returns (uint256);
    function delegatedInbound(address delegate) external view returns (uint256);
    function maxDelegatedSlashBps() external view returns (uint256);
    function coolDownPeriod() external view returns (uint256);
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
 *         economic-security model (spec 2026-07-22 §3.3, §3.3a, §3.7).
 *
 *         `slashableBond(g)` (spec §3.3, precision definition):
 *             ownStake(g) * priceHaircut
 *           + delegatedInbound(g) * maxDelegatedSlashBps/10_000 * priceHaircut
 *         Delegated stake counts ONLY at the delegated-slash cap — a delegated
 *         pool cannot be slashed 100%; counting full vote weight would violate
 *         the coalition inequality at the accounting layer.
 *
 *         Exposure is EPOCH-BUCKETED (spec §3.4a): an approval consumes the
 *         current epoch's bucket; open exposure = the sum of all buckets young
 *         enough that their challenge window has not elapsed. Guardian
 *         commitment per approval is therefore bounded at one epoch + challenge
 *         window regardless of strategy duration.
 *
 * @dev    WOOD is priced by `woodPriceX8()`: a Chainlink read times
 *         `woodHaircutBps` when a feed is wired and fresh, falling back to the
 *         governance-set `woodUsdPriceX8` otherwise. The governance number was
 *         the ONLY source originally (spec §3.7/§8 — no WOOD feed existed on
 *         Robinhood Chain); it is now the degraded path and must still be
 *         MAINTAINED, because a stale feed falls back to it rather than
 *         reverting. Failing closed there would value every bond at $0 and halt
 *         approvals protocol-wide on a Chainlink hiccup.
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

    /// @dev Hard ceiling on how many buckets `openExposureUsd` may walk. This
    ///      REPLACES the old `challengeWindow <= epochLength` rule, which was
    ///      never about correctness — it was a proxy for keeping that loop
    ///      short, and as a proxy it pinned buckets at >= 14 days.
    ///
    ///      Bounding the scan directly frees the bucket width to be tuned for
    ///      precision instead: narrower buckets release a guardian's short
    ///      commitments without waiting on their long ones, because the two no
    ///      longer share a bucket. The cost is a longer walk, which is exactly
    ///      what this caps.
    uint256 internal constant MAX_SCAN_BUCKETS = 16;

    /// @dev Minimum spacing between price updates. Without it the 2x ceiling
    ///      bounds a single call and nothing bounds the number of calls.
    uint256 internal constant MIN_PRICE_UPDATE_INTERVAL = 1 days;

    /// @dev Floor on `woodHaircutBps`. Valuing bonds below half of market is a
    ///      mis-set parameter, not a conservatism policy (review N6).
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

    /// @notice Conservative WOOD→USD price, 8 decimals (spec §5 `priceHaircut`).
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
    ///         (spec §3.3a + §4 gate 2). Launch value 2: tier-2 only. Lowering
    ///         is gated on the §3.10 ROE validation — a BLOCKING launch gate.
    uint8 public quorumTierThreshold = 2;
    /// @notice Proposer bond as bps of USD coverage (spec §3.9/§5). Default 1%.
    uint256 public proposerBondBps = 100;

    /// @notice Chainlink WOOD/USD feed. Once wired it supersedes the
    ///         governance price for every bond valuation.
    /// @dev    Reuses the same `AssetFeed` shape and staleness handling as the
    ///         vault-asset feeds, so WOOD is priced by the machinery already
    ///         exercised by `coverageUsd` rather than a parallel path.
    AssetFeed internal _woodFeed;

    /// @notice Haircut applied to the feed price, in bps. The governance number
    ///         it replaces was a manually-maintained "<= 30-day low"; this is
    ///         the same conservatism expressed as a factor on a live read.
    /// @dev    Collateral wants a floor, not a quote — an unhaircut oracle
    ///         tracks WOOD UP and inflates every bond exactly when the market is
    ///         frothy. Default 10_000 (no haircut) so wiring a feed alone does
    ///         not silently change valuations; governance sets it deliberately.
    uint256 public woodHaircutBps = BPS_DENOMINATOR;

    /// @dev Stamps every `setWoodUsdPrice`. Zero means "never set" — the only
    ///      state exempt from the interval.
    uint64 public lastPriceUpdateAt;

    /// @dev Stamps every `setWoodHaircutBps`; zero means "never set".
    uint64 public lastHaircutUpdateAt;

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

    /// @dev Total USD RESERVED by all approvers of a proposal — which runs to
    ///      A x coverage while the review is open, NOT to `coverage`. Each
    ///      approver reserves up to the whole thing because any one of them
    ///      might end up carrying it alone; `settleCoverage` collapses this to
    ///      the real aggregate once the set is final. It is also the denominator
    ///      the pro-rata split divides by, so it has to reflect reservations
    ///      rather than allocations until then.
    mapping(bytes32 reviewKey => uint256 usd) internal _committedUsd;

    /// @dev The ledger's own approver list per proposal, plus a 1-indexed
    ///      POSITION (not a flag) so `releaseApproval` can swap-and-pop in O(1)
    ///      and a release/re-approve round trip cannot double-push. Read by
    ///      `requireApproveQuorum` INSTEAD of the guardian registry: the ledger
    ///      books commitments itself, so it needs no external opinion about who
    ///      approved, and the ledger's and governor's registry pointers can
    ///      therefore never disagree (review finding I-1).
    /// @dev Set once `settleCoverage` has converted reservations into
    ///      allocations for a proposal. Guards against a second pass, which
    ///      would re-divide already-settled numbers against a shrunken total.
    mapping(bytes32 reviewKey => bool) internal _settled;

    mapping(bytes32 reviewKey => address[]) internal _approversOf;
    /// @dev 1-INDEXED position in `_approversOf`; 0 means "not listed". Carries
    ///      the index rather than a bare flag so `releaseApproval` can
    ///      swap-and-pop in O(1). A flag alone left released approvers in the
    ///      array forever, so it grew with the number of guardians that ever
    ///      approved — an unbounded loop in the execute path (review M2).
    mapping(bytes32 reviewKey => mapping(address guardian => uint256)) internal _approverIndex;

    // ── Modifiers / helpers ──

    modifier onlyRegistry() {
        if (msg.sender != guardianRegistry) revert NotGuardianRegistry();
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
        // must cover epoch + challenge window (spec §5). A tiny epochLength
        // would violate W <= L, a huge one the unstake-escape invariant,
        // from genesis.
        _requireScanBounded(challengeWindow, epochLength_);
        // The `coolDownPeriod >= epochLength + challengeWindow` invariant that
        // used to sit here is GONE (ADR 2026-07-26). Two reasons, either
        // sufficient:
        //
        //   1. UNSATISFIABLE. `StakedWood.setCooldownPeriod` caps the cooldown
        //      at 30 days while this demanded 42 at defaults, so once sWOOD was
        //      deployed no governance action could ever satisfy it — only
        //      `initialize` could. `DeployPlanB`'s pre-flight told operators to
        //      "raise the sWOOD cooldown by governance FIRST", which was not a
        //      thing they could do.
        //
        //   2. SUPERSEDED. It was a timer approximating "an approver cannot
        //      exit from under a pending challenge".
        //      `StakedWood.claimUnstakeGuardian` now asks this ledger that
        //      question directly, and exactly, via `openExposureUsd`.
        //
        // What this shifts onto the deploy: the gate FAILS OPEN when sWOOD's
        // `exposureLedger` pointer is unset, so `DeployPlanB`'s post-broadcast
        // wiring assertion is now the only thing standing between a deployment
        // and no exit protection at all. It was belt-and-braces; it is now
        // load-bearing.
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
        return _slashableBondUsd(guardian, swood.maxDelegatedSlashBps(), woodPriceX8());
    }

    /// @notice The WOOD/USD price every bond is valued at, 8 decimals.
    ///
    /// @dev    FEED FIRST, GOVERNANCE AS FALLBACK. A live read tracks a crash
    ///         immediately, which is the direction where lag actually hurts:
    ///         under the manual number somebody has to notice and transact
    ///         while bonds stay over-valued in the meantime.
    ///
    ///         FALLS BACK RATHER THAN REVERTING when the feed is unset or
    ///         stale. Failing closed here would value every bond at $0 and halt
    ///         approvals protocol-wide on a Chainlink hiccup — a liveness risk
    ///         the manual price does not have. The fallback is
    ///         `woodUsdPriceX8`, which is itself a conservative floor, so the
    ///         degraded path is still safe. It does mean the governance number
    ///         must be MAINTAINED as a fallback rather than abandoned once the
    ///         feed is wired.
    function woodPriceX8() public view returns (uint256) {
        (uint256 price,) = _woodPrice();
        return price;
    }

    /// @notice The WOOD price and whether it came from the FALLBACK rather than
    ///         the feed.
    /// @dev    Exists because the degraded path was otherwise invisible: no
    ///         event, and `woodUsdPriceX8` carries no `updatedAt` of its own, so
    ///         "feed healthy" and "feed dead for three months, running on a
    ///         manual number nobody has touched" read identically from outside.
    ///         §6 monitoring cannot alert on a condition it cannot observe.
    function woodPriceDetail() external view returns (uint256 price, bool usingFallback) {
        return _woodPrice();
    }

    function _woodPrice() internal view returns (uint256 price, bool usingFallback) {
        AssetFeed storage f = _woodFeed;
        if (f.feed == address(0)) return (_haircut(woodUsdPriceX8), true);
        (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(f.feed).latestRoundData();
        if (answer <= 0) return (_haircut(woodUsdPriceX8), true);
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > f.maxDelay) return (_haircut(woodUsdPriceX8), true);
        // Normalise to 8 decimals. `answer > 0` checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 priceX8 = (uint256(answer) * 1e8) / (10 ** f.feedDecimals);
        return (_haircut(priceX8), false);
    }

    /// @dev THE HAIRCUT APPLIES TO BOTH PATHS. It originally applied only to the
    ///      feed, which was harmless while `woodHaircutBps` defaulted to
    ///      `BPS_DENOMINATOR` — and wrong the moment governance turned it on.
    ///      With a 20% haircut the healthy path valued bonds at 0.8x spot while
    ///      all three degraded paths returned `woodUsdPriceX8` raw, so enabling
    ///      the safety feature made the FALLBACK less conservative than the
    ///      primary: over-valued bonds, over-stated `slashableBondUsd`, a looser
    ///      batching cap — and precisely in the state where more margin is
    ///      wanted, not less.
    ///
    ///      The natspec's defence was that `woodUsdPriceX8` is "itself a
    ///      conservative floor", but nothing enforced that: `setWoodUsdPrice`
    ///      bounds only upward moves, deliberately, so the manual number may sit
    ///      at spot. Haircutting both makes the claim structural instead of
    ///      procedural.
    function _haircut(uint256 priceX8) internal view returns (uint256) {
        return (priceX8 * woodHaircutBps) / BPS_DENOMINATOR;
    }

    /// @dev `slashableBondUsd` with the two loop-invariant inputs passed in, so
    ///      a multi-approver quorum reads them once instead of once per
    ///      approver (review finding M-4).
    function _slashableBondUsd(address guardian, uint256 maxDelegatedSlashBps_, uint256 priceX8)
        internal
        view
        returns (uint256)
    {
        uint256 own = swood.guardianStake(guardian);
        uint256 inbound = swood.delegatedInbound(guardian);
        uint256 slashableWood = own + (inbound * maxDelegatedSlashBps_) / BPS_DENOMINATOR;
        return (slashableWood * priceX8) / 1e8;
    }

    // ── Owner setters ──

    /// @dev BOUNDED AT 2x PER CHANGE in either direction (review M4). This is
    ///      the single scalar behind every guardian's coverage, and it was the
    ///      one setter here with no bound at all:
    ///        - set it high and every quorum is trivially satisfied, so the
    ///          coverage check becomes theatre;
    ///        - set it to 0 and `capUsd` is 0, `open >= capUsd` holds at
    ///          `0 >= 0`, and EVERY approve vote protocol-wide reverts
    ///          nothing bookable at all — a global kill switch, now a quiet one.
    ///
    ///      ZERO IS STILL ALLOWED, and rejecting it would have been theatre. A
    ///      price of 1 wei-X8 shrinks every bond by ~5e6 and disables coverage
    ///      just as thoroughly, so banning the round number removes the tidiest
    ///      expression of the capability without removing the capability. The
    ///      fail-closed direction is documented as intentional (spec §3.7); the
    ///      real mitigation is owner custody, not a value check.
    ///
    ///      The FIRST price is exempt — there is no previous value to bound
    ///      against, and the contract ships at 0 by design.
    ///
    ///      ONLY THE UPWARD MOVE IS BOUNDED, deliberately, and not as the review
    ///      suggested (it proposed 2x in both directions). The two directions
    ///      are not symmetric:
    ///        - UPWARD over-values every bond, overstating coverage and making
    ///          quorums easier to clear. That is the dangerous direction and the
    ///          one worth rate-limiting.
    ///        - DOWNWARD under-values every bond, shrinking budgets and
    ///          tightening every quorum. It can only make approvals harder.
    ///      Rate-limiting the downward move would be actively harmful: this
    ///      price EXISTS to absorb a WOOD crash, and a 10x collapse capped at 2x
    ///      per transaction would leave bonds over-valued 5x for as long as it
    ///      took to walk the price down — precisely when the coverage number
    ///      matters most. Bounding it would trade a governance-error risk for a
    ///      solvency one.
    function setWoodUsdPrice(uint256 newPriceX8) external onlyOwner {
        uint256 current = woodUsdPriceX8;
        uint256 last = lastPriceUpdateAt;

        // THE INTERVAL IS WHAT MAKES THIS A RATE LIMIT (review M4). A 2x
        // ceiling with no time component is not one: N calls in a single
        // multisig batch move the price 2^N, and seven take $0.05 to $6.40.
        // Only the first-ever price is exempt, because there is nothing to
        // compare it against.
        if (last != 0 && block.timestamp < last + MIN_PRICE_UPDATE_INTERVAL) revert InvalidParameter();

        // The ceiling binds every upward move except a recovery from zero.
        //
        // Zero stays SETTABLE — it is the emergency stop, and the earlier
        // argument for banning it was wrong in both directions: banning it does
        // not prevent disabling coverage (1 wei-X8 does that just as well), and
        // it would strand the price at zero with no way back, since any
        // non-zero value exceeds `0 * 2`. What made zero dangerous was the
        // EXEMPTION being reachable in the same transaction: `set(0)` then
        // `set(anything)` walked straight through. The interval above is what
        // closes that — the round trip now costs a day rather than two calls.
        if (current != 0 && newPriceX8 > current * 2) revert InvalidParameter();

        lastPriceUpdateAt = uint64(block.timestamp);
        emit WoodUsdPriceSet(current, newPriceX8);
        woodUsdPriceX8 = newPriceX8;
    }

    /// @dev Re-pointing the registry ORPHANS exposures booked under the old
    ///      registry: releaseApproval is registry-gated, so entries recorded
    ///      by the old registry become unreleasable and only self-heal when
    ///      their buckets expire (end of epoch + challenge window). Re-point
    ///      only at low open exposure.
    function setWoodFeed(address feed, uint256 maxDelay) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        if (maxDelay == 0) revert InvalidParameter();
        uint8 feedDecimals = IAggregatorMinimal(feed).decimals();
        _woodFeed = AssetFeed({
            feed: feed,
            maxDelay: uint64(maxDelay),
            assetDecimals: 18, // WOOD
            feedDecimals: feedDecimals
        });
        emit WoodFeedSet(feed, maxDelay);
    }

    /// @dev Bounded like every other bps setter here. A zero haircut would
    ///      value bonds at $0 and brick approvals; above 100% would value them
    ///      ABOVE market, which is the direction that overstates coverage.
    /// @dev Rate-limited and floored like `setWoodUsdPrice` (review N6). After
    ///      the Chainlink path landed there were TWO unbounded multipliers on
    ///      the same quantity and only one was bounded: a legal range of
    ///      `[1, 10_000]` with no interval let the owner move every bond's
    ///      valuation 10,000x in a single transaction, which is precisely what
    ///      M4 existed to prevent. A haircut below `MIN_WOOD_HAIRCUT_BPS` is a
    ///      mis-set parameter rather than a policy.
    function setWoodHaircutBps(uint256 newBps) external onlyOwner {
        if (newBps < MIN_WOOD_HAIRCUT_BPS || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        uint256 lastH = lastHaircutUpdateAt;
        if (lastH != 0 && block.timestamp < lastH + MIN_PRICE_UPDATE_INTERVAL) revert InvalidParameter();
        lastHaircutUpdateAt = uint64(block.timestamp);
        emit ParameterChangeFinalized(keccak256("woodHaircutBps"), woodHaircutBps, newBps);
        woodHaircutBps = newBps;
    }

    function setGuardianRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        // RE-CHECK THE FLOOR (review M1). `setChallengeWindow` skips it while no
        // registry is wired, so wiring order was a bypass: set an 8d window with
        // the registry unset, then point at a registry whose `reviewPeriod`
        // makes the floor 10d, and the window sits below it with nothing
        // revalidating.
        // Tolerant read on purpose. This check catches an ORDERING MISTAKE by an
        // owner, not an adversary — `setGuardianRegistry` is owner-only, and an
        // owner who wires an address that cannot answer `reviewPeriod()` has
        // already broken the record/release path this pointer exists for. A
        // registry that does answer is held to the floor; one that does not is
        // let through rather than bricking the wiring transaction.
        // `registry.code.length` first: Solidity's extcodesize guard on a
        // high-level call to an EOA reverts in THIS frame, which `try` cannot
        // catch — so the check has to be skipped before it is attempted, not
        // after it fails.
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
        // Zero would free coverage instantly. The upper bound is no longer
        // "one epoch" — it is whatever keeps `openExposureUsd`'s walk inside
        // `MAX_SCAN_BUCKETS`, which is the property the old rule approximated.
        if (newWindow == 0) revert InvalidParameter();
        _requireScanBounded(newWindow, epochLength);
        // Cross-contract invariant (spec §5): unstake delay must cover
        // epoch + challenge window, or an approver can unstake before its
        // epoch's approvals can be challenged.
        // Cooldown invariant removed here for the same reasons as in the
        // constructor: unsatisfiable against sWOOD's 30-day setter cap, and
        // superseded by the exit gate on `claimUnstakeGuardian`.
        // LOWER BOUND (review M1). The anti-batching property depends on a
        // bucket outliving the proposal it backs. With only the upper bounds
        // above, a window shorter than the approve->execute gap lets one bond
        // cover two live drains: approve #1 just before an epoch boundary, let
        // the bucket expire while #1 is still Approved and inside its execution
        // window, then approve #2 at full budget. Both quorums pass, both
        // execute. Not reachable at shipped defaults (W = 14d), which is why it
        // was latent rather than live — but nothing enforced it.
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
    ///      coverage)` — not merely what is still uncovered. That was the
    ///      original rule and it is what C1 exploited: the first approver
    ///      absorbed everything, later ones booked zero and were not even
    ///      listed, and a flip to Block then released the lot with no way back.
    ///
    ///      Reserving per approver costs budget — A approvers tie up A x
    ///      coverage until `settleCoverage` runs (review N1) — and buys the
    ///      property that there is nothing to squat. The real split is the
    ///      pro-rata `allocatedUsd`, so §3.3a's *aggregate* quorum still
    ///      aggregates: two guardians holding $600k each jointly cover a $1M
    ///      proposal, because a conviction slashes EVERY approver of that
    ///      proposal and recovery is the SUM of their bonds —
    ///      exactly what §2's inequality states ("coalition loss >= Σ dollar
    ///      value of slashable approver stake").
    ///
    ///      TWO DIFFERENT RULES, and the distinction is what this design turns
    ///      on. §3.3's cap exists to stop ONE guardian backing MANY proposals
    ///      ("approve N drains in one window, lose one bond once"). It does NOT
    ///      require one guardian to single-handedly cover ONE proposal.
    ///
    ///      Reserving the full coverage per approver — the rule that SHIPS —
    ///      enforces the cap without imposing the second reading, because the
    ///      reservation is an upper bound on liability and `allocatedUsd` is the
    ///      actual per-guardian split. An earlier version instead sized each
    ///      booking to `min(free, still uncovered)`, which conflated the two in
    ///      the other direction: the first approver absorbed everything, later
    ///      ones booked zero, and C1's costless veto followed.
    ///
    ///      Consequence: an under-bonded guardian is no longer rejected at vote
    ///      time — it commits what it can, and the proposal simply fails the
    ///      execute-time quorum unless other approvers make up the rest. A
    ///      guardian with NO free budget books nothing and returns — the cap is
    ///      enforced by committing zero, not by reverting the vote (review N1).
    function recordApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
        bytes32 key = _reviewKey(governor, proposalId);
        if (_recorded[key][guardian].usd != 0) return; // idempotent (vote-change round trip)
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        address asset = IVaultAssetMinimal(pv.vault).asset();
        // NO FEED -> BOOK NOTHING, don't revert (review M3). This hook fires for
        // every authorized governor once the ledger is wired on the registry,
        // including governors deliberately left un-wired on their own side and
        // therefore carrying no coverage gate at all. Letting `coverageUsd`
        // revert `FeedNotConfigured` here made APPROVE votes impossible on those
        // vaults while Block votes still worked — turning their reviews
        // block-only, so guardians could veto but never endorse, and the
        // proposal passed optimistically anyway. Failing closed on the coverage
        // (booking nothing, so the execute-time quorum cannot be met) is the
        // conservative half; failing the vote was the harmful half.
        // ANY pricing failure books nothing rather than reverting (review M3).
        // Special-casing the missing feed closed only half of it: a STALE feed
        // still reverted here and took the approve vote with it, leaving the
        // review block-only — guardians able to veto but not endorse, and the
        // proposal passing optimistically anyway. A stale oracle is an
        // operational condition rather than a wiring mistake, so that half was
        // the more reachable one.
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

        // RESERVATION, NOT ALLOCATION. This books the MOST this guardian could
        // ever end up carrying — the whole proposal, if every other approver
        // walks away — and the final split is computed at read time by
        // `allocatedUsd`. Two properties fall out, and both are the point:
        //
        //   1. Nobody can squat the book. The old code let the first approver
        //      absorb the entire coverage, after which later approvers booked
        //      zero and were not even listed. Front-running the first approve
        //      and then flipping to Block released the whole commitment, while
        //      the late-vote lockout stopped the free-ridden approver from
        //      re-registering: a costless, permanent veto by a guardian holding
        //      less than block quorum. Reserving per approver removes the thing
        //      there was to squat.
        //   2. The batching cap gets STRICTER, not looser. Every approval now
        //      consumes budget up to the full coverage rather than whatever was
        //      left over, so a guardian can back fewer concurrent drains, not
        //      more. The excess is not stranded: it clears when the epoch bucket
        //      expires, and a vote change releases it immediately.
        //
        // Free budget = k * bond - open exposure. Zero free budget is the
        // batching attack's boundary: this guardian's bond is already fully
        // spoken for by its other open approvals, so it cannot back another drain.
        uint256 capUsd = kNumerator * slashableBondUsd(guardian);
        uint256 open = openExposureUsd(guardian);
        // NO FREE BUDGET -> BOOK NOTHING, don't revert (review N1). Reverting
        // here reverted `voteOnProposal` with it, so a guardian whose budget was
        // spent on an earlier proposal could not cast an approve vote AT ALL.
        // That is disenfranchisement, not a cap: it silences the approve side
        // while Block votes still work, and it made the C1 veto survivable in a
        // second form — an attacker who front-runs while the cohort is busy
        // still bricks the proposal, because the guardians who would have
        // covered it cannot participate.
        //
        // The cap itself is unchanged and still binds: this guardian commits
        // nothing, so the same bond still cannot back two drains. Enforcement
        // moves to `requireApproveQuorum` at execute, which is already the
        // enforcement point and fails loudly with the shortfall visible. Same
        // treatment as the unconfigured feed above, and for the same reason —
        // failing the coverage is conservative, failing the VOTE is harmful.
        if (open >= capUsd) return;
        uint256 free = capUsd - open;

        uint256 share = free < needUsd ? free : needUsd;
        // Truncation in the uint192 store below would book phantom (smaller)
        // exposure — fail loudly instead.
        if (share > type(uint192).max) revert InvalidParameter();
        // BOOK INTO THE BUCKET THAT OUTLIVES SETTLEMENT, not the one the vote
        // happened to land in (ADR 2026-07-26). The commitment has to survive
        // until the drain it backs can no longer be challenged:
        //
        //     risk ends at   executeBy + strategyDuration + challengeWindow
        //     bucket expires at   bucketEnd + challengeWindow
        //
        // so the bucket must contain `executeBy + strategyDuration`. Keying on
        // `currentEpoch()` released a guardian's budget as early as
        // `approval + challengeWindow` — roughly a month before the challenge
        // window on their own approval had closed. Nothing caught it because
        // every other part works: the booking, the quorum and the slash maths
        // are all correct, only the expiry date was wrong.
        //
        // `executeBy` rather than `executedAt`: at approve time the proposal has
        // not executed and may never, so the deadline is the conservative anchor.
        // Horizon failures book nothing rather than reverting (review N4).
        // `_coverageEpoch` sat outside the try/catch that guards the pricing
        // read, so a strategy settling beyond `MAX_COVERAGE_HORIZON` reverted
        // `voteOnProposal` itself — the THIRD trigger for the block-only review
        // shape M3 was filed for, and the only one reachable at defaults, since
        // `ProtocolConfig.maxStrategyDuration` ships unset. Same rule as the
        // other two: failing the coverage is conservative, failing the VOTE is
        // harmful. `SyndicateGovernor.propose` rejects such a duration up front,
        // so this is the belt to that braces.
        (uint256 epoch, bool withinHorizon) = _coverageEpochOrSkip(pv);
        if (!withinHorizon) return;
        _buckets[guardian][epoch] += share;
        // share bounded to uint192 above; epoch = elapsed / epochLength cannot
        // approach 2^64 on any realistic timescale.
        // forge-lint: disable-next-line(unsafe-typecast)
        _recorded[key][guardian] = RecordedExposure({usd: uint192(share), epoch: uint64(epoch)});
        _committedUsd[key] += share;
        // The ledger keeps its OWN approver list: the quorum reads this, never
        // the registry, so the ledger's registry pointer and the governor's can
        // never disagree about who covered a proposal (review finding I-1).
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
    ///      SWAP-AND-POPPED out of `_approversOf` (review M2): leaving it behind
    ///      with a zeroed commitment grew the list with every guardian that ever
    ///      approved, which is bounded by the cohort rather than by the
    ///      registry's approver cap, and that loop runs on the execute path.
    function releaseApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
        bytes32 key = _reviewKey(governor, proposalId);
        RecordedExposure memory r = _recorded[key][guardian];
        if (r.usd == 0) return;
        delete _recorded[key][guardian];
        _buckets[guardian][r.epoch] -= r.usd;
        _committedUsd[key] -= r.usd;

        // Swap-and-pop out of the approver list (review M2). Leaving the entry
        // behind was harmless per-iteration — every reader skips a zero
        // commitment — but the array grew with the number of guardians that
        // EVER approved, which is bounded by the cohort rather than by the
        // registry's MAX_APPROVERS_PER_PROPOSAL, so the execute-path loop had
        // no real bound. Order carries no meaning here: every consumer either
        // sums over the list or returns it alongside per-guardian values.
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
    /// @dev Spec §3.7: hard per-vault ceiling on coverage-consuming proposals,
    ///      denominated in dollars. Zero cap fails closed (nothing proposable)
    ///      until governance seeds it. Called by SyndicateGovernor.propose.
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view {
        if (coverageUsd(asset, requiredCoverage) > coveredTvlCapUsd) revert CoveredTvlCapExceeded();
    }

    /// @inheritdoc IExposureLedger
    /// @dev Refuses a proposal whose settlement lands beyond the ledger's
    ///      booking horizon, AT PROPOSE (review N4).
    ///
    ///      Without it the failure surfaced at vote: `recordApproval` could not
    ///      book, so every approve vote either reverted (before) or booked
    ///      nothing (after), leaving a block-only review in which guardians can
    ///      veto but never endorse. Failing here puts the error on the proposer,
    ///      who chose the duration and can change it, instead of on a cohort
    ///      that cannot.
    ///
    ///      Reachable at defaults, which is why it is a check rather than a
    ///      comment: `ProtocolConfig.maxStrategyDuration` ships UNSET, and unset
    ///      means no ceiling, so a vault owner may seat any duration up to
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
    ///        - the LIVE leg keeps F2's dollar requirement honest — a bond that
    ///          shrank since the vote (unstaking, or a WOOD price crash) counts
    ///          at its shrunken value, so coverage must still hold in dollars
    ///          at execution.
    ///
    ///      Approvers come from the ledger's OWN `_approversOf` list, never from
    ///      the registry: the ledger booked the commitments itself, so it needs
    ///      no external opinion about who approved. That also removes the
    ///      divergence risk between the ledger's registry pointer and the
    ///      governor's (review finding I-1). The list is bounded by the
    ///      registry's own `MAX_APPROVERS_PER_PROPOSAL`.
    ///
    ///      Zero committed coverage ALWAYS reverts, even at zero required
    ///      coverage — R1 requires an identified signer for anything tier-gated
    ///      into this check. Called by `SyndicateGovernor.executeProposal` for
    ///      proposals with `envelopeTier >= quorumTierThreshold`.
    ///
    /// @dev KNOWN GAP — THIS GATE DOES NOT PRICE IN `maxSlashBps` (PR #24
    ///      review 🟠N3). The sum checked here is
    ///      `Σ min(live_i, reserved_i) >= needUsd`. What the slash can actually
    ///      TAKE is `Σ min(live_i · maxSlashBps/10_000, allocated_i)`, because
    ///      `slashToEscrow` clamps every rate to the severity ceiling. So an
    ///      allocation that runs to the top of a bond is short by
    ///      `1 - maxSlashBps/10_000` of itself: 20% at the fixture's 8,000,
    ///      50% at 5,000 (deploy scripts ship 10,000, where the clamp never
    ///      binds — see spec §3.8). Worked case — coverage set to exactly the joint slashable
    ///      bond ($2,000 across two $1,000 own-stake bonds): this gate PASSES,
    ///      both derived rates are a correct 10,000 bps, and recovery is
    ///      $1,600 against a $2,000 loss (80%).
    ///
    ///      This is a hole in FRONT of the residual, not behind it — distinct
    ///      from the "bond shrank since the vote" case `slashBpsFor` documents
    ///      as unavoidable. It is an UNENFORCED RUNTIME INVARIANT (spec §3.8):
    ///      nothing here or in the deploy pre-flight keeps `maxSlashBps` at a
    ///      value where the clamp never binds, so the gap is real the moment
    ///      governance lowers the ceiling. Closing it is a change to the
    ///      coverage GATE (either require
    ///      `Σ min(live_i · maxSlashBps/10_000, reserved_i) >= needUsd`, or
    ///      restate spec §2's inequality as
    ///      `recovery >= loss · maxSlashBps/10_000`), and that belongs in its
    ///      own PR with its own parameter re-derivation rather than bolted onto
    ///      the slash rails. `test_recoveryCoversEveryApproversAllocation`
    ///      exercises BOTH regimes — the slack one where the clamp never fires
    ///      and the binding one above — so the shortfall is measured and pinned
    ///      rather than assumed away.
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view
    {
        uint256 needUsd = coverageUsd(asset, requiredCoverage);
        bytes32 key = _reviewKey(governor, proposalId);
        address[] storage approvers = _approversOf[key];
        uint256 n = approvers.length;
        if (n == 0) revert InsufficientApproveCoverage();

        // Hoisted: both are loop-invariant, and `slashableBondUsd` would
        // otherwise re-read them once per approver (review finding M-4).
        uint256 bps = swood.maxDelegatedSlashBps();
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
            uint256 live = _slashableBondUsd(g, bps, priceX8);
            haveUsd += live < reserved ? live : reserved;
            if (haveUsd >= needUsd) return; // early exit
        }
        // The loop early-returns on success — reaching here means the covering
        // approvers' aggregate never met the required coverage.
        revert InsufficientApproveCoverage();
    }

    /// @inheritdoc IExposureLedger
    /// @dev The bridge between what a guardian UNDERWROTE and what the verdict
    ///      path can actually take. `slashToEscrow` speaks in bps of stake; the
    ///      ledger books liability in USD. Dividing one USD quantity by the
    ///      other cancels the unit DIMENSIONALLY — but not the price
    ///      sensitivity, and an earlier version of this comment claimed the
    ///      conversion "needs no price read of its own" (PR #24 review 🟡N5).
    ///      It reads two. Both operands are priced:
    ///        - the numerator (the allocation) traces back to `coverageUsd`,
    ///          which reads a Chainlink feed behind a `StalePrice` gate — so a
    ///          stale asset feed makes a conviction UNPRICEABLE and this view
    ///          reverts. Feed outages correlate with exactly the market stress
    ///          a drain happens in, so that is a real liveness hole in the
    ///          slash path;
    ///        - the denominator (`live`, via `_slashableBondUsd`) is priced by
    ///          `woodPriceX8()` — Chainlink primary with `woodHaircutBps`,
    ///          owner-set `woodUsdPriceX8` as the degraded fallback — the SAME
    ///          read `requireApproveQuorum`, `allocatedUsd` and `settleCoverage`
    ///          use (PR #24 review F-B: this site briefly read the raw scalar,
    ///          a Plan B merge artefact, so the gate and the rail priced the
    ///          same bond differently the moment a feed was wired). In the
    ///          fallback regime governance still resizes every conviction with
    ///          one scalar.
    ///      Both are governance-trust statements of the same family as D4's,
    ///      recorded here rather than argued away.
    ///
    ///      Approvers come from the ledger's OWN `_approversOf`, exactly as
    ///      `requireApproveQuorum` does and for the same reason (review finding
    ///      I-1). A guardian holding a zero commitment — released by a vote
    ///      change, or an approval that landed after coverage was already met —
    ///      yields 0 bps and is slashed nothing. That is the intended
    ///      semantics, not an omission: liability follows the commitment, and an
    ///      approver who consumed none of their budget underwrote none of the
    ///      loss.
    ///
    ///      Two saturating cases, both deliberate:
    ///        - `committed >= live` — the bond shrank since the vote (unstake,
    ///          or a WOOD price crash) — pins the rate at 100%. The case then
    ///          under-recovers by the shortfall, which is unavoidable: the
    ///          guardian does not have it. `requireApproveQuorum` already
    ///          re-checks coverage in LIVE dollars at execution, so this is the
    ///          residual after that gate, not a hole in front of it.
    ///        - `live == 0` likewise yields 100%, keeping the division defined.
    ///          Nothing is recoverable either way — `_slashOne` clamps to live
    ///          stake — so the value is inert.
    ///
    ///      Rounds UP. Truncating would shave every approver's rate and the
    ///      residue compounds across a cohort; rounding toward the protocol
    ///      keeps `sum(slashed) >= loss` intact at the wei level.
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

        // Hoisted for the reason `requireApproveQuorum` hoists them (M-4).
        uint256 maxDelegated = swood.maxDelegatedSlashBps();
        uint256 priceX8 = woodPriceX8();

        // Prices against the ALLOCATION, never the reservation. `recordApproval`
        // deliberately over-reserves — each approver books up to the full
        // coverage so there is no leftover to squat — so the reservation is an
        // upper bound on liability, not the liability. Slashing it would take
        // the whole coverage from EVERY approver: two approvers on a $8,000
        // proposal each carry $4,000 but each reserved $5,000.
        //
        // Read once here rather than calling `allocatedUsd` per guardian: that
        // would repeat two external calls (`getProposalView`, then the vault's
        // `asset()`) and a feed read on every iteration.
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        uint256 needUsd = coverageUsd(
            IVaultAssetMinimal(gov.getProposalView(proposalId).vault).asset(), gov.getRequiredCoverage(proposalId)
        );
        // EFFECTIVE basis, matching `allocatedUsd` (review n1). Dividing by the
        // raw pledged total would let a guardian whose bond has gone keep
        // shrinking everyone else's rate — and this is the slash path, so the
        // shortfall would be unrecoverable rather than merely mis-stated. The
        // two must agree about the same guardian.
        uint256 effectiveTotal = _effectiveTotal(key, maxDelegated, priceX8);
        if (effectiveTotal == 0) return (approvers, bps);

        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            approvers[i] = g;
            uint256 reserved = _recorded[key][g].usd;
            if (reserved == 0) continue; // released -> owes nothing
            uint256 liveG = _slashableBondUsd(g, maxDelegated, priceX8);
            uint256 mine = liveG < reserved ? liveG : reserved;
            uint256 owed = _allocate(mine, effectiveTotal, needUsd);
            if (owed == 0) continue; // scaled to dust -> nothing to collect
            uint256 live = liveG;
            if (live == 0 || owed >= live) {
                bps[i] = BPS_DENOMINATOR;
                continue;
            }
            // `owed <= reserved`, itself a uint192, so this cannot overflow.
            bps[i] = (owed * BPS_DENOMINATOR + live - 1) / live;
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev What `guardian` actually carries on this proposal, as opposed to
    ///      what `recordApproval` reserved. Reservations are deliberately
    ///      over-sized (each approver reserves up to the FULL coverage), so the
    ///      real split is this pro-rata scale-back, computed at read time from
    ///      whoever is still an approver right now.
    ///
    ///      Computing it lazily rather than writing it down is what closes the
    ///      squat-then-release veto: there is no stored allocation for an
    ///      attacker to capture early and hand back late. Flipping to Block
    ///      deletes the reservation, `_committedUsd` drops, and every remaining
    ///      approver's allocation scales UP on the next read — so a departing
    ///      approver hands their share to the others instead of voiding the
    ///      proposal.
    ///
    ///      It also means no keeper is required: execution reads the allocation
    ///      directly, so a settlement transaction can never be withheld to
    ///      strand a proposal.
    /// @dev ORACLE ASYMMETRY, AND IT IS DELIBERATE (review n2). `recordApproval`
    ///      books nothing when the price is unreadable; this function REVERTS.
    ///      The two disagree on purpose, because the conservative direction is
    ///      opposite on each path: booking nothing merely declines to extend
    ///      coverage, whereas returning a made-up number here would size a
    ///      SLASH off a price nobody can vouch for. Refusing to price a
    ///      conviction until the feed recovers is the safe failure.
    ///
    ///      Operational consequence, stated precisely (review N10): a conviction
    ///      cannot be computed while the asset feed is stale. That is a delay
    ///      UNLESS the outage outlasts the remaining challenge window. The
    ///      exposure record is untouched, but it is also still counting down —
    ///      bucket expiry is pure wall-clock and does not pause for an outage,
    ///      and `claimUnstakeGuardian` releases the stake the instant it reads
    ///      zero. A long enough outage converts the delay into a loss with no
    ///      attacker involved.
    function allocatedUsd(address governor, uint256 proposalId, address guardian) public view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 reserved = _recorded[key][guardian].usd;
        if (reserved == 0) return 0;
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        address asset = IVaultAssetMinimal(gov.getProposalView(proposalId).vault).asset();
        uint256 needUsd = coverageUsd(asset, gov.getRequiredCoverage(proposalId));
        uint256 bps = swood.maxDelegatedSlashBps();
        uint256 priceX8 = woodPriceX8();
        uint256 live = _slashableBondUsd(guardian, bps, priceX8);
        uint256 mine = live < reserved ? live : reserved;
        if (mine == 0) return 0;
        return _allocate(mine, _effectiveTotal(key, bps, priceX8), needUsd);
    }

    /// @dev Sum of `min(reserved, live bond)` across a proposal's approvers —
    ///      what the cohort can ACTUALLY pay, not what it pledged (review n1).
    ///
    ///      Using raw `_committedUsd` as the denominator lets a guardian who
    ///      unstaked or was devalued after approving keep diluting everyone
    ///      else's share. Their slice is computed against a bond that is no
    ///      longer there, the survivors are assigned correspondingly less, and
    ///      the recoverable total falls short of the loss by far more than
    ///      rounding. `requireApproveQuorum` already discounts by `min(live,
    ///      reserved)`; this is the same discount applied to the split, so the
    ///      two stop disagreeing about the same guardian.
    function _effectiveTotal(bytes32 key, uint256 maxDelegatedSlashBps_, uint256 priceX8)
        internal
        view
        returns (uint256 total)
    {
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 reserved = _recorded[key][listed[i]].usd;
            if (reserved == 0) continue;
            uint256 live = _slashableBondUsd(listed[i], maxDelegatedSlashBps_, priceX8);
            total += live < reserved ? live : reserved;
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev Returns the over-reservation once the approver set is FINAL.
    ///
    ///      `recordApproval` reserves up to the whole coverage from every
    ///      approver, because at vote time any one of them might end up carrying
    ///      it alone. That is what closed C1 — there is no leftover to squat —
    ///      but it means A approvers tie up A x coverage of aggregate cohort
    ///      budget, and until now that lasted the whole bucket lifetime. It is
    ///      why a busy cohort ran out of approve capacity (review N1).
    ///
    ///      Once the review window shuts, nobody can join or leave, so the
    ///      worst case each approver was reserving against can no longer happen.
    ///      This collapses each reservation to its actual pro-rata allocation
    ///      and hands the difference back. The over-reservation now lasts the
    ///      REVIEW WINDOW rather than the coverage window — days instead of
    ///      weeks — which is the part of N1 that actually bites, since the
    ///      bottleneck is budget being unavailable for the NEXT proposal.
    ///
    ///      Deliberately NOT the reviewer's suggested fix (reserve only the
    ///      uncovered remainder, top survivors up on release). That reserves
    ///      everything against the FIRST approver and nothing against later
    ///      ones, which reintroduces first-mover-takes-the-line: under a
    ///      coverage-weighted premium the whole payment goes to whoever is
    ///      fastest, and the allocation stops being a fair split. Keeping equal
    ///      reservations and settling afterwards buys the same budget relief
    ///      without the ordering race, and keeps the loop off the vote path.
    ///
    ///      PERMISSIONLESS and SAFE TO SKIP. If nobody ever calls it the budget
    ///      simply stays over-reserved until the bucket expires, exactly as
    ///      today — conservative, never unsafe. So no keeper is load-bearing.
    function settleCoverage(address governor, uint256 proposalId) external {
        bytes32 key = _reviewKey(governor, proposalId);
        if (_settled[key]) return;

        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        ILedgerGovernorMinimal.ProposalViewLite memory pv = gov.getProposalView(proposalId);
        // The set must be FINAL. Settling mid-review would hand budget back to
        // approvers who could still be left carrying the proposal alone.
        // GATED ON `executeBy`, NOT `reviewEnd` (review N3). Settling is not the
        // neutral act the first version assumed. Before it, each approver holds
        // a full-coverage reservation, so `requireApproveQuorum` sums an A-fold
        // cushion; settling collapses that to EXACTLY `needUsd` priced at settle
        // time, while the quorum re-derives `needUsd` from the live feed at
        // execute. Any rise in between fails the quorum and `_settled` makes it
        // permanent — so any EOA could settle the moment the review shut and let
        // a 1% tick in the vault asset brick a fully-covered proposal, for the
        // cost of gas.
        //
        // Nothing needs the relief before `executeBy`: by then the proposal has
        // executed or expired, so collapsing its reservations can no longer
        // change any quorum. Costs at most `executionWindow` of extra
        // over-reservation against a bucket lifetime of weeks.
        // STRICTLY AFTER `executeBy` (review N12). A proposal is executable
        // while `block.timestamp <= executeBy`, so `>=` left a one-block overlap
        // in which settling and executing were both available to different
        // senders. Not price-exploitable — settling re-derives `needUsd` at the
        // same instant the quorum reads it, so there is no rise in between —
        // but there is no reason to permit settling in the last executable
        // instant, and one character closes it.
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
        // Under-subscribed: every approver already carries its whole
        // reservation, so there is nothing to hand back.
        if (reservedTotal <= needUsd) {
            _settled[key] = true;
            return;
        }

        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        uint256 assigned;
        address firstHolder;
        // Same effective basis as `allocatedUsd` (review n1): a guardian whose
        // bond has gone must not dilute the survivors' shares.
        uint256 maxDelegated = swood.maxDelegatedSlashBps();
        uint256 priceX8 = woodPriceX8();
        uint256 effectiveTotal = _effectiveTotal(key, maxDelegated, priceX8);
        if (effectiveTotal == 0) {
            _settled[key] = true;
            return;
        }

        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            RecordedExposure memory r = _recorded[key][g];
            if (r.usd == 0) continue;
            if (firstHolder == address(0)) firstHolder = g;

            uint256 liveG = _slashableBondUsd(g, maxDelegated, priceX8);
            uint256 mine = liveG < uint256(r.usd) ? liveG : uint256(r.usd);
            uint256 alloc = _allocate(mine, effectiveTotal, needUsd);
            assigned += alloc;
            // `alloc <= mine <= r.usd`, so this cannot underflow.
            uint256 excess = uint256(r.usd) - alloc;
            if (excess != 0) {
                _buckets[g][r.epoch] -= excess;
                // `alloc <= r.usd`, itself a uint192.
                // forge-lint: disable-next-line(unsafe-typecast)
                _recorded[key][g].usd = uint192(alloc);
            }
        }

        // Truncation leaves the total a few wei under `needUsd`. Give the
        // residue to the first holder rather than leaving it short: the quorum
        // compares this same aggregate against `needUsd`, so a rounded-down sum
        // would make a fully-subscribed proposal fail its own coverage check
        // after settling — the mirror of the dust bug the quorum already avoids
        // by summing reservations.
        if (assigned < needUsd && firstHolder != address(0)) {
            uint256 residue = needUsd - assigned;
            RecordedExposure memory rf = _recorded[key][firstHolder];
            _buckets[firstHolder][rf.epoch] += residue;
            // forge-lint: disable-next-line(unsafe-typecast)
            _recorded[key][firstHolder].usd = uint192(uint256(rf.usd) + residue);
            assigned = needUsd;
        }

        _committedUsd[key] = assigned;
        _settled[key] = true;
        emit CoverageSettled(key, reservedTotal, assigned);
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
