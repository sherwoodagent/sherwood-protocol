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
 * @dev    WOOD is priced by `woodPriceX8()`: a Chainlink read times
 *         `woodHaircutBps` when a feed is wired and fresh, falling back to the
 *         governance-set `woodUsdPriceX8` otherwise. A stale or unset feed
 *         falls back rather than reverting, because failing closed here would
 *         value every bond at $0 and halt approvals protocol-wide on a
 *         Chainlink hiccup — so the fallback must stay maintained.
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

    /// @dev Minimum spacing between price updates. Without it the 2x ceiling
    ///      bounds a single call and nothing bounds the number of calls.
    uint256 internal constant MIN_PRICE_UPDATE_INTERVAL = 1 days;

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

    /// @dev How many proposals are frozen right now, across every guardian.
    ///      Lets `setCoverageFreezer` refuse a rotation that would orphan a
    ///      live freeze.
    uint256 internal _frozenKeyCount;

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
        return _slashableBondUsd(guardian, woodPriceX8());
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

    /// @dev EVERY failure mode of the aggregator falls back, including a bare
    ///      revert from `latestRoundData` — a reverting feed would otherwise
    ///      take approve votes and `requireApproveQuorum` down with it,
    ///      bricking coverage protocol-wide with no governance path back.
    ///
    ///      `code.length` is checked FIRST because Solidity's extcodesize guard
    ///      on a high-level call to a codeless address reverts in THIS frame,
    ///      which `try` cannot catch — the same reason `setGuardianRegistry`
    ///      guards its tolerant read that way.
    function _woodPrice() internal view returns (uint256 price, bool usingFallback) {
        AssetFeed storage f = _woodFeed;
        // `code.length` FIRST: `try` cannot catch the extcodesize revert a
        // high-level call to a codeless address raises in THIS frame, so a
        // zeroed proxy would still propagate past the wrap below.
        address feed = f.feed;
        if (feed == address(0) || feed.code.length == 0) return (_haircut(woodUsdPriceX8), true);
        try IAggregatorMinimal(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return (_haircut(woodUsdPriceX8), true);
            uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
            if (age > f.maxDelay) return (_haircut(woodUsdPriceX8), true);
            // Normalise to 8 decimals. `answer > 0` checked above.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 priceX8 = (uint256(answer) * 1e8) / (10 ** f.feedDecimals);
            return (_haircut(priceX8), false);
        } catch {
            return (_haircut(woodUsdPriceX8), true);
        }
    }

    /// @dev THE HAIRCUT APPLIES TO BOTH PATHS. Applying it only to the feed
    ///      would make the fallback LESS conservative than the primary
    ///      whenever governance sets a haircut below 100%: the degraded path
    ///      would return `woodUsdPriceX8` raw while the healthy path discounts
    ///      it, over-valuing bonds precisely when more margin is wanted.
    ///      `setWoodUsdPrice` bounds only upward moves, so the manual number may
    ///      sit at spot — haircutting both is what keeps it a conservative floor.
    function _haircut(uint256 priceX8) internal view returns (uint256) {
        return (priceX8 * woodHaircutBps) / BPS_DENOMINATOR;
    }

    /// @dev `slashableBondUsd` with the loop-invariant price passed in, so a
    ///      multi-approver quorum reads it once instead of once per approver.
    function _slashableBondUsd(address guardian, uint256 priceX8) internal view returns (uint256) {
        return (swood.guardianStake(guardian) * priceX8) / 1e8;
    }

    // ── Owner setters ──

    /// @dev BOUNDED AT 2x PER UPWARD CHANGE ONLY. This is the single scalar
    ///      behind every guardian's coverage: set high, every quorum is
    ///      trivially satisfied and the coverage check becomes theatre.
    ///
    ///      ZERO IS STILL ALLOWED. Rejecting it would not prevent disabling
    ///      coverage — 1 wei-X8 does the same — and would strand the price with
    ///      no way back up once at zero. The fail-closed direction is
    ///      intentional (spec §3.7); the mitigation is owner custody, not a
    ///      value check. The FIRST price is exempt since there is nothing to
    ///      bound it against.
    ///
    ///      ONLY THE UPWARD MOVE IS BOUNDED, because the two directions are not
    ///      symmetric: upward over-values bonds and makes quorums easier to
    ///      clear (the dangerous direction), while downward only tightens
    ///      quorums. Rate-limiting downward would be harmful — this price
    ///      exists to absorb a WOOD crash, and capping the recovery at 2x per
    ///      transaction would leave bonds over-valued for as long as it took to
    ///      walk the price down, exactly when coverage matters most.
    function setWoodUsdPrice(uint256 newPriceX8) external onlyOwner {
        uint256 current = woodUsdPriceX8;
        uint256 last = lastPriceUpdateAt;

        // THE INTERVAL IS WHAT MAKES THIS A RATE LIMIT. A 2x ceiling with no
        // time component is not one: N calls in a single multisig batch move
        // the price 2^N. Only the first-ever price is exempt, since there is
        // nothing to compare it against.
        if (last != 0 && block.timestamp < last + MIN_PRICE_UPDATE_INTERVAL) revert InvalidParameter();

        // The ceiling binds every upward move except a recovery from zero.
        // Zero stays SETTABLE as the emergency stop; any non-zero value
        // exceeds `0 * 2` so a stuck-at-zero price could never recover
        // otherwise. The interval above closes the `set(0)` then
        // `set(anything)` round trip, at a day's cost instead of two calls.
        if (current != 0 && newPriceX8 > current * 2) revert InvalidParameter();

        lastPriceUpdateAt = uint64(block.timestamp);
        emit WoodUsdPriceSet(current, newPriceX8);
        woodUsdPriceX8 = newPriceX8;
    }

    /// @notice Wire (or UNWIRE) the Chainlink WOOD/USD feed.
    ///
    /// @dev    ZERO IS THE UNWIRE SWITCH and it is load-bearing: it is the
    ///         governance path back from a bad aggregator, since every coverage
    ///         path prices bonds through `_woodPrice`.
    ///
    ///         Unwiring is SAFE: it falls back to `woodUsdPriceX8`, haircut on
    ///         the same terms as the feed and maintained as a conservative
    ///         floor. It is a degraded mode, not a resting state — the manual
    ///         number lags a crash.
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

    /// @dev Bounded like every other bps setter here. A zero haircut would
    ///      value bonds at $0 and brick approvals; above 100% would value them
    ///      ABOVE market, overstating coverage.
    /// @dev Rate-limited and floored like `setWoodUsdPrice`: an unbounded
    ///      multiplier on the same quantity would let the owner move every
    ///      bond's valuation 10,000x in a single transaction. A haircut below
    ///      `MIN_WOOD_HAIRCUT_BPS` is a mis-set parameter rather than a policy.
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
        // Free budget = k * bond - open exposure. Zero free budget is the
        // batching attack's boundary: this guardian's bond is already fully
        // spoken for by its other open approvals, so it cannot back another drain.
        uint256 capUsd = kNumerator * slashableBondUsd(guardian);
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
        return _frozenCommitments[guardian] != 0;
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
    /// @dev KNOWN GAP — THIS GATE DOES NOT PRICE IN `maxSlashBps`. The sum
    ///      checked here is `Σ min(live_i, reserved_i) >= needUsd`. What the
    ///      slash can actually TAKE is `Σ min(live_i · maxSlashBps/10_000,
    ///      allocated_i)`, because `slashToEscrow` clamps every rate to the
    ///      severity ceiling — so an allocation run to the top of a bond is
    ///      short by `1 - maxSlashBps/10_000` of itself (deploy scripts ship
    ///      `maxSlashBps = 10_000`, where the clamp never binds; spec §3.8).
    ///
    ///      This is an UNENFORCED RUNTIME INVARIANT: nothing here or in the
    ///      deploy pre-flight keeps `maxSlashBps` at a value where the clamp
    ///      never binds, so the gap opens the moment governance lowers the
    ///      ceiling. Closing it means changing the coverage gate to
    ///      `Σ min(live_i · maxSlashBps/10_000, reserved_i) >= needUsd`.
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
    ///      path can actually take — though NOT an exact one: this reads the
    ///      LIVE bond while `_slashOne` slashes `min(checkpointAt(openedAt),
    ///      live)`, so a top-up made after review-open inflates the booked
    ///      coverage with capital a verdict anchored at `openedAt` cannot reach.
    ///
    ///      `slashToEscrow` speaks in bps of stake; the ledger books liability
    ///      in USD. The conversion reads TWO prices, both operands:
    ///        - the numerator (the allocation) traces back to `coverageUsd`,
    ///          which reads a Chainlink feed behind a `StalePrice` gate — a
    ///          stale asset feed makes a conviction UNPRICEABLE and this view
    ///          reverts. Feed outages correlate with the market stress a drain
    ///          happens in, so this is a real liveness hole in the slash path;
    ///        - the denominator (`live`, via `_slashableBondUsd`) is priced by
    ///          `woodPriceX8()` — the SAME read `requireApproveQuorum`,
    ///          `allocatedUsd` and `settleCoverage` use. In the fallback
    ///          regime governance still resizes every conviction with one
    ///          scalar.
    ///
    ///      Approvers come from the ledger's OWN `_approversOf`, exactly as
    ///      `requireApproveQuorum` does. A guardian holding a zero commitment —
    ///      released by a vote change, or an approval that landed after
    ///      coverage was already met — yields 0 bps and is slashed nothing:
    ///      liability follows the commitment.
    ///
    ///      Two saturating cases, both deliberate:
    ///        - `committed >= live` — the bond shrank since the vote (unstake,
    ///          or a WOOD price crash) — pins the rate at 100%. This
    ///          under-recovers by the shortfall, which is unavoidable: the
    ///          guardian does not have it. `requireApproveQuorum` already
    ///          re-checks coverage in LIVE dollars at execution, so this is the
    ///          residual after that gate, not a hole in front of it.
    ///        - `live == 0` likewise yields 100%, keeping the division defined;
    ///          `_slashOne` clamps to live stake, so the value is inert.
    ///
    ///      Rounds UP: truncating would shave every approver's rate and the
    ///      residue compounds across a cohort, while rounding toward the
    ///      protocol keeps `sum(slashed) >= loss` intact at the wei level.
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

        // Hoisted for the reason `requireApproveQuorum` hoists it.
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
        // EFFECTIVE basis, matching `allocatedUsd`. Dividing by the raw pledged
        // total would let a guardian whose bond has gone keep shrinking
        // everyone else's rate — and this is the slash path, so the shortfall
        // would be unrecoverable rather than merely mis-stated.
        uint256 effectiveTotal = _effectiveTotal(key, priceX8);
        if (effectiveTotal == 0) return (approvers, bps);

        for (uint256 i = 0; i < n; i++) {
            address g = listed[i];
            approvers[i] = g;
            uint256 reserved = _recorded[key][g].usd;
            if (reserved == 0) continue; // released -> owes nothing
            uint256 liveG = _slashableBondUsd(g, priceX8);
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
        address asset = IVaultAssetMinimal(gov.getProposalView(proposalId).vault).asset();
        uint256 needUsd = coverageUsd(asset, gov.getRequiredCoverage(proposalId));
        uint256 priceX8 = woodPriceX8();
        uint256 live = _slashableBondUsd(guardian, priceX8);
        uint256 mine = live < reserved ? live : reserved;
        if (mine == 0) return 0;
        return _allocate(mine, _effectiveTotal(key, priceX8), needUsd);
    }

    /// @inheritdoc IExposureLedger
    /// @dev Mirrors `slashBpsFor`'s own basis exactly — the same `needUsd`, the
    ///      same `_effectiveTotal` — so the figure a challenger is charged
    ///      against and the figure a conviction takes cannot drift apart.
    ///      `ChallengeGame.file()` must not sum the RESERVATION while slashing
    ///      prices the ALLOCATION.
    ///
    ///      Reverts rather than returning a stale figure when the asset feed is
    ///      down, inheriting `coverageUsd`'s `StalePrice` gate. A caller that
    ///      must stay live through a feed outage has to say so explicitly — see
    ///      `ChallengeGame.file()`, which catches and falls back.
    function liabilityUsd(address governor, uint256 proposalId) external view returns (uint256) {
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 effectiveTotal = _effectiveTotal(key, woodPriceX8());
        if (effectiveTotal == 0) return 0;

        ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
        uint256 needUsd = coverageUsd(
            IVaultAssetMinimal(gov.getProposalView(proposalId).vault).asset(), gov.getRequiredCoverage(proposalId)
        );
        return needUsd < effectiveTotal ? needUsd : effectiveTotal;
    }

    /// @dev Sum of `min(reserved, live bond)` across a proposal's approvers —
    ///      what the cohort can ACTUALLY pay, not what it pledged.
    ///
    ///      Using raw `_committedUsd` as the denominator would let a guardian
    ///      who unstaked or was devalued after approving keep diluting
    ///      everyone else's share, so the recoverable total would fall short
    ///      of the loss by more than rounding. `requireApproveQuorum` already
    ///      discounts by `min(live, reserved)`; this applies the same discount
    ///      to the split, so the two agree about the same guardian.
    function _effectiveTotal(bytes32 key, uint256 priceX8) internal view returns (uint256 total) {
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 reserved = _recorded[key][listed[i]].usd;
            if (reserved == 0) continue;
            uint256 live = _slashableBondUsd(listed[i], priceX8);
            total += live < reserved ? live : reserved;
        }
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
        uint256 priceX8 = woodPriceX8();
        uint256 effectiveTotal = _effectiveReservedTotal(key, priceX8);
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

            uint256 liveG = _slashableBondUsd(g, priceX8);
            uint256 mine = liveG < reserved ? liveG : reserved;
            uint256 alloc = _allocate(mine, effectiveTotal, needUsd);
            assigned += alloc;
            headroom[i] = mine - alloc; // `_allocate` never scales up: alloc <= mine
            _rebook(key, g, alloc);
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
        // `min(live bond, pledge)`, the most a conviction could ever take from
        // it — crediting past that would consume budget that buys no recovery.
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
                _rebook(key, g, uint256(_recorded[key][g].usd) + take);
                residue -= take;
                assigned += take;
            }
        }

        _settled[key] = true;
        emit CoverageSettled(key, reservedTotal, assigned);
    }

    /// @dev Move a guardian's live booking to `target`, keeping its epoch bucket
    ///      in step. Both directions: settlement is re-runnable, so a booking
    ///      that was written down at a bad price has to be able to walk back up.
    ///      `target` is always `<= _reservedUsd[key][g]`, which `recordApproval`
    ///      bounded to `uint192`, so neither the cast nor the bucket arithmetic
    ///      can misbehave — the bucket was incremented by the pledge and every
    ///      subsequent booking is a fraction of it.
    function _rebook(bytes32 key, address g, uint256 target) internal {
        RecordedExposure memory r = _recorded[key][g];
        uint256 current = uint256(r.usd);
        if (target == current) return;
        if (target < current) {
            _buckets[g][r.epoch] -= (current - target);
        } else {
            _buckets[g][r.epoch] += (target - current);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _recorded[key][g].usd = uint192(target);
    }

    /// @dev `_effectiveTotal` over the PLEDGES rather than the live bookings.
    ///      The two coincide until `settleCoverage` first runs and diverge
    ///      afterwards; settlement needs this one, because it is rewriting the
    ///      very numbers `_effectiveTotal` reads and must divide by an input its
    ///      own previous passes did not move.
    function _effectiveReservedTotal(bytes32 key, uint256 priceX8) internal view returns (uint256 total) {
        address[] storage listed = _approversOf[key];
        uint256 n = listed.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 reserved = _reservedUsd[key][listed[i]];
            if (reserved == 0) continue;
            uint256 live = _slashableBondUsd(listed[i], priceX8);
            total += live < reserved ? live : reserved;
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
