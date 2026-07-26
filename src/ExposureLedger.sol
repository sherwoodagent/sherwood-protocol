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
 * @dev    v1 is WOOD-only (spec §3.7): `woodUsdPriceX8` is a GOVERNANCE-SET
 *         conservative price (<= 30-day low), not an oracle read — no WOOD
 *         Chainlink feed exists on Robinhood Chain (spec §8). Fail-closed: an
 *         unset price values every bond at $0.
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

    /// @dev Total USD committed by all approvers of a proposal. Lets
    ///      `recordApproval` size the next approver's share against what is
    ///      still uncovered, so the aggregate stops growing once the proposal
    ///      is fully backed.
    mapping(bytes32 reviewKey => uint256 usd) internal _committedUsd;

    /// @dev The ledger's own approver list per proposal, plus a membership flag
    ///      so a release/re-approve round trip cannot double-push. Read by
    ///      `requireApproveQuorum` INSTEAD of the guardian registry: the ledger
    ///      books commitments itself, so it needs no external opinion about who
    ///      approved, and the ledger's and governor's registry pointers can
    ///      therefore never disagree (review finding I-1).
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
        if (epochLength_ + challengeWindow > ISwoodMinimal(swood_).coolDownPeriod()) revert InvalidParameter();
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
        return _slashableBondUsd(guardian, swood.maxDelegatedSlashBps(), woodUsdPriceX8);
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
    ///          `ExposureCapExceeded` — a global kill switch.
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
        if (current != 0 && newPriceX8 > current * 2) revert InvalidParameter();
        emit WoodUsdPriceSet(current, newPriceX8);
        woodUsdPriceX8 = newPriceX8;
    }

    /// @dev Re-pointing the registry ORPHANS exposures booked under the old
    ///      registry: releaseApproval is registry-gated, so entries recorded
    ///      by the old registry become unreleasable and only self-heal when
    ///      their buckets expire (end of epoch + challenge window). Re-point
    ///      only at low open exposure.
    function setGuardianRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
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
        if (epochLength + newWindow > swood.coolDownPeriod()) revert InvalidParameter();
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
        if (woodUsdPriceX8 == 0) revert InvalidParameter();
        return (usd * 1e8) / woodUsdPriceX8;
    }

    /// @inheritdoc IExposureLedger
    /// @dev Called by GuardianRegistry.voteOnProposal on the approve side.
    ///
    ///      An approver commits a SHARE of its free bond — `min(free bond,
    ///      coverage still uncovered)` — not the proposal's full coverage.
    ///      This is what lets §3.3a's *aggregate* quorum actually aggregate:
    ///      two guardians holding $600k each can jointly cover a $1M proposal,
    ///      because a conviction slashes EVERY approver of that proposal
    ///      (`GuardianRegistry.resolveReview` hands the whole approver array to
    ///      `slashGuardians` at 100%), so recovery is the SUM of their bonds —
    ///      exactly what §2's inequality states ("coalition loss >= Σ dollar
    ///      value of slashable approver stake").
    ///
    ///      Booking the FULL coverage against EACH approver (the earlier
    ///      behaviour) conflated two different rules: §3.3's cap exists to stop
    ///      ONE guardian backing MANY proposals ("approve N drains in one
    ///      window, lose one bond once") — not to force one guardian to
    ///      single-handedly cover ONE proposal. Committing shares enforces the
    ///      former without imposing the latter.
    ///
    ///      Consequence: an under-bonded guardian is no longer rejected at vote
    ///      time — it commits what it can, and the proposal simply fails the
    ///      execute-time quorum unless other approvers make up the rest. A
    ///      guardian with NO free budget still reverts (`ExposureCapExceeded`),
    ///      which is what closes the batching attack.
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
        if (_assetFeeds[asset].feed == address(0)) return;
        uint256 needUsd = coverageUsd(asset, gov.getRequiredCoverage(proposalId));
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
        if (open >= capUsd) revert ExposureCapExceeded();
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
        uint256 epoch = _coverageEpoch(pv);
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
    ///      No-op when nothing is recorded — never underflows. The address stays
    ///      in `_approversOf` with a zeroed commitment; the quorum skips it.
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
        uint256 priceX8 = woodUsdPriceX8;

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
    function allocatedUsd(address governor, uint256 proposalId, address guardian) public view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 reserved = _recorded[key][guardian].usd;
        if (reserved == 0) return 0;
        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        address asset = IVaultAssetMinimal(gov.getProposalView(proposalId).vault).asset();
        uint256 needUsd = coverageUsd(asset, gov.getRequiredCoverage(proposalId));
        return _allocate(reserved, _committedUsd[key], needUsd);
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
        uint256 cur = currentEpoch();
        uint256 elapsed = block.timestamp - epochGenesis;
        uint256 from = elapsed > challengeWindow ? (elapsed - challengeWindow) / epochLength : 0;
        // Scans FORWARD as well as back. Approvals are booked into the bucket
        // covering settlement, which is in the future at vote time, so a
        // backward-only sum would miss every live commitment and report a
        // guardian's budget as free while it is fully pledged — the batching cap
        // would then wave through exactly what it exists to stop.
        // `MAX_FORWARD_EPOCHS` bounds the span, and `_coverageEpoch` refuses to
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
    ///      `MAX_FORWARD_EPOCHS`. Clamping would silently under-cover the tail
    ///      of a long strategy, which is the very bug this replaced; refusing
    ///      the approval instead surfaces a mis-set duration ceiling as a failed
    ///      vote rather than as a hole nobody sees. At the shipped 28d epoch
    ///      this permits ~84 days of horizon, comfortably above the 30d duration
    ///      cap plus a 7d execution window.
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
