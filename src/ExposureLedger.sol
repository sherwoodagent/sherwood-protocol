// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";

/// @dev Narrow sWOOD read surface (own stake, cooldown). Mirrors the
///      IGovernorMinimal pattern in GuardianRegistry — the ledger does not
///      import the full IStakedWood ABI.
interface ISwoodMinimal {
    function guardianStake(address guardian) external view returns (uint256);
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
}

/**
 * @title ExposureLedger
 * @notice Dollar-denominated coverage accounting for the guardian
 *         economic-security model (spec 2026-07-22 §3.3, §3.3a, §3.7).
 *
 *         `slashableBond(g)` (spec §3.3, precision definition):
 *             ownStake(g) * priceHaircut
 *         (The delegated-inbound term was removed with the DPoS-delegation
 *         postponement — the guardian's own bond is the only slashable
 *         capital.)
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
    mapping(bytes32 reviewKey => mapping(address guardian => bool)) internal _listed;

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
        if (challengeWindow > epochLength_) revert InvalidParameter();
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
        return _slashableBondUsd(guardian, woodUsdPriceX8);
    }

    /// @dev `slashableBondUsd` with the loop-invariant price passed in, so a
    ///      multi-approver quorum reads it once instead of once per approver
    ///      (review finding M-4).
    function _slashableBondUsd(address guardian, uint256 priceX8) internal view returns (uint256) {
        return (swood.guardianStake(guardian) * priceX8) / 1e8;
    }

    // ── Owner setters ──

    function setWoodUsdPrice(uint256 newPriceX8) external onlyOwner {
        emit WoodUsdPriceSet(woodUsdPriceX8, newPriceX8);
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
        // Bounded (0, epochLength]: zero would free coverage instantly;
        // beyond one epoch the lookback in openExposureUsd grows unbounded.
        if (newWindow == 0 || newWindow > epochLength) revert InvalidParameter();
        // Cross-contract invariant (spec §5): unstake delay must cover
        // epoch + challenge window, or an approver can unstake before its
        // epoch's approvals can be challenged.
        if (epochLength + newWindow > swood.coolDownPeriod()) revert InvalidParameter();
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
        address asset = IVaultAssetMinimal(gov.getProposalView(proposalId).vault).asset();
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
        uint256 epoch = currentEpoch();
        _buckets[guardian][epoch] += share;
        // share bounded to uint192 above; epoch = elapsed / epochLength cannot
        // approach 2^64 on any realistic timescale.
        // forge-lint: disable-next-line(unsafe-typecast)
        _recorded[key][guardian] = RecordedExposure({usd: uint192(share), epoch: uint64(epoch)});
        _committedUsd[key] += share;
        // The ledger keeps its OWN approver list: the quorum reads this, never
        // the registry, so the ledger's registry pointer and the governor's can
        // never disagree about who covered a proposal (review finding I-1).
        if (!_listed[key][guardian]) {
            _listed[key][guardian] = true;
            _approversOf[key].push(guardian);
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

        // Hoisted: loop-invariant — `slashableBondUsd` would otherwise
        // re-read it once per approver (review finding M-4).
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
            uint256 live = _slashableBondUsd(g, priceX8);
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
    ///      other cancels the unit, so this conversion needs no price read of
    ///      its own — which matters, because an oracle in the slash path would
    ///      let a stale or compromised feed resize a conviction.
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

        // Hoisted for the reason `requireApproveQuorum` hoists it (M-4).
        uint256 priceX8 = woodUsdPriceX8;

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
        uint256 reservedTotal = _committedUsd[key];

        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            approvers[i] = g;
            uint256 reserved = _recorded[key][g].usd;
            if (reserved == 0) continue; // released -> owes nothing
            uint256 owed = _allocate(reserved, reservedTotal, needUsd);
            if (owed == 0) continue; // scaled to dust -> nothing to collect
            uint256 live = _slashableBondUsd(g, priceX8);
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
        for (uint256 e = from; e <= cur; e++) {
            total += _buckets[guardian][e];
        }
    }
}
