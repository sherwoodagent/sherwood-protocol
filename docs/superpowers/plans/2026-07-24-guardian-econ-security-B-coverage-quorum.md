# Guardian Economic Security — Plan B: Coverage, Quorum, and Bonds (v1a completion)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the spec's **v1a** phase (`docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md` §3.3, §3.3a, §3.7, §3.9, §3.6-bond): the dollar-denominated aggregate exposure cap with epoch-bucketed accounting, the explicit approve quorum for coverage-consuming proposals, the risk-scaled proposer bond, the hard WOOD-only covered-TVL cap, and the adapter-submitter bond — consuming the `requiredCoverage` figure Plan A already stores.

**Architecture:** A new standalone `ExposureLedger` (Ownable2Step singleton, like `TierRegistry`) owns all dollar accounting: a governance-set conservative WOOD→USD price (`priceHaircut`, spec §5 — no WOOD Chainlink feed exists, spec §8), per-asset Chainlink feeds for vault assets, `slashableBondUsd(g)` per spec §3.3, and per-guardian **epoch-bucketed** open-exposure tracking (spec §3.4a: "Plan B's exposure ledger must build epoch semantics from day one"). `GuardianRegistry` (UUPS upgrade) calls the ledger on every approve-side review vote — recording exposure, reverting the vote if the guardian's cap is exceeded. `SyndicateGovernor` (beacon upgrade) checks the covered-TVL cap and locks a risk-scaled proposer bond at `propose`, and enforces the approve quorum at `executeProposal` for proposals at/above a governance tier threshold. A new `ProposerBondEscrow` holds WOOD bonds keyed by `(governor, proposalId)` with a single permissionless release path on terminal states. `TierRegistry` gains a submitter bond on `certify` (held while certified, timelocked release after demote). `SyndicateFactory` wires the two new addresses into every new governor and gains **rewire entrypoints for existing governors** (closes the LOW-1 gap, issue #19).

**Tech Stack:** Solidity 0.8.28, Foundry (forge test/fmt), OpenZeppelin Ownable2Step / UUPS. Repo conventions: custom errors, natspec with spec-section tags, tests in `test/*.t.sol`, storage-layout goldens in `test/` (`GovernorLayoutPins.t.sol` + `*.golden.json`).

**Sequencing:** Plan A (merged, PR #13) shipped §3.1–§3.2 (envelopes, metering, tiering, selector guard). This plan completes v1a. **v1b (authorized-slasher entrypoint, compensation escrow §3.8, challenge game §3.4, approver premium §3.10) ships as Plan C** — Plan A's sequencing note folded v1b into "Plan B," but v1b is an independent subsystem (retroactive liability) and per the writing-plans scope rule gets its own plan. v1c (two-layer court §3.5) is Plan D.

**Launch-gate constraints baked into this design (spec §4, both gates):**
1. Every new accounting path carries a one-sentence invariant + fuzz test (Tasks 3, 5, 6).
2. **BLOCKING pre-launch gate:** the approve quorum is fail-closed only for proposals with `envelopeTier >= quorumTierThreshold`. Launch value **2** (tier-2 only): bounded-tier flow keeps optimistic passage, so liveness does not depend on §3.10 premium economics that don't exist yet. Lowering the threshold to 1 or 0 is a governance action gated on the §3.10 ROE validation — do not lower it in this plan.

**Unit conventions (used everywhere below — do not deviate):**
- USD amounts: 18 decimals (`1e18` = $1).
- `woodUsdPriceX8`: 8 decimals (Chainlink convention). `usd = woodWei * priceX8 / 1e8`; `woodWei = usd * 1e8 / priceX8`.
- Asset→USD: `usd18 = amount * feedPrice * 1e18 / (10^assetDecimals * 10^feedDecimals)`; asset decimals cached at feed registration.

**Storage cautions:**
- `StrategyProposal` gains ONE appended field (`proposerBondWood`). Append at the END only.
- `SyndicateGovernor` gains two address slots (`_exposureLedger`, `_bondEscrow`): decrement `__gap` 33 → 31.
- `GuardianRegistry` gains one address slot (`exposureLedger`): decrement `__gap` 50 → 49.
- `SyndicateFactory` gains two address slots (`exposureLedger`, `bondEscrow`).
- After ANY of these changes, regenerate the layout goldens (Task 11) and run `forge test --match-contract GovernorLayoutPins`. If a pin on an EXISTING slot moves, stop and surface — never reorder existing fields.

**Cross-contract invariant (deploy gate, Task 12):** sWOOD `coolDownPeriod >= epochLength + challengeWindow` (spec §5: a guardian cannot unstake before its epoch's approvals can be challenged). At defaults that is `28d + 14d = 42 days`.

---

### Task 1: ExposureLedger — skeleton, WOOD price, `slashableBondUsd`

**Files:**
- Create: `src/ExposureLedger.sol`
- Create: `src/interfaces/IExposureLedger.sol`
- Create: `test/ExposureLedger.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";

/// @dev Minimal sWOOD stub exposing exactly the reads the ledger consumes.
contract MockSwood {
    mapping(address => uint256) public guardianStake;
    mapping(address => uint256) public delegatedInbound;
    uint256 public maxDelegatedSlashBps = 2000;
    uint256 public coolDownPeriod = 45 days;

    function setStake(address g, uint256 own, uint256 inbound) external {
        guardianStake[g] = own;
        delegatedInbound[g] = inbound;
    }

    function setMaxDelegatedSlashBps(uint256 v) external {
        maxDelegatedSlashBps = v;
    }
}

contract ExposureLedgerTest is Test {
    ExposureLedger internal ledger;
    MockSwood internal swood;
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");

    function setUp() public {
        swood = new MockSwood();
        // epochLength 28d immutable; genesis = deploy timestamp.
        ledger = new ExposureLedger(owner, address(swood), 28 days);
        vm.prank(owner);
        ledger.setWoodUsdPrice(0.05e8); // $0.05, conservative haircut price
    }

    function test_slashableBondUsd_ownPlusCappedDelegated() public {
        // own 100k WOOD, inbound 200k WOOD, delegated cap 2000 bps (20%)
        swood.setStake(guardian, 100_000e18, 200_000e18);
        // slashable WOOD = 100k + 200k * 20% = 140k; at $0.05 => $7,000
        assertEq(ledger.slashableBondUsd(guardian), 7_000e18);
    }

    function test_slashableBondUsd_zeroWhenPriceUnset() public {
        ExposureLedger fresh = new ExposureLedger(owner, address(swood), 28 days);
        swood.setStake(guardian, 100_000e18, 0);
        // fail-closed: unset price values every bond at $0 (nothing can be approved)
        assertEq(fresh.slashableBondUsd(guardian), 0);
    }

    function test_setWoodUsdPrice_onlyOwner() public {
        vm.expectRevert();
        ledger.setWoodUsdPrice(1e8);
    }

    function test_currentEpoch_advances() public {
        uint256 e0 = ledger.currentEpoch();
        vm.warp(block.timestamp + 28 days);
        assertEq(ledger.currentEpoch(), e0 + 1);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: compilation failure — `src/ExposureLedger.sol` not found.

- [ ] **Step 3: Write the interface**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IExposureLedger
/// @notice Dollar-denominated aggregate exposure cap + covered-TVL cap +
///         approve-quorum arithmetic (spec 2026-07-22 §3.3, §3.3a, §3.7).
///         Singleton; consumed by GuardianRegistry (exposure recording at
///         approve-vote time) and SyndicateGovernor (covered-TVL check at
///         propose, approve-quorum check at execute).
interface IExposureLedger {
    // ── Errors ──
    error ExposureCapExceeded();
    error CoveredTvlCapExceeded();
    error InsufficientApproveCoverage();
    error NotGuardianRegistry();
    error FeedNotConfigured();
    error StalePrice();
    error InvalidParameter();
    error ZeroAddress();

    // ── Events ──
    event WoodUsdPriceSet(uint256 oldPriceX8, uint256 newPriceX8);
    event AssetFeedSet(address indexed asset, address feed, uint256 maxDelay, uint8 assetDecimals);
    event ExposureRecorded(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ExposureReleased(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);

    // ── Registry-only mutations ──
    function recordApproval(address governor, uint256 proposalId, address guardian) external;
    function releaseApproval(address governor, uint256 proposalId, address guardian) external;

    // ── Governor-consumed checks (view) ──
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view;
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view;

    // ── Views ──
    function slashableBondUsd(address guardian) external view returns (uint256);
    function openExposureUsd(address guardian) external view returns (uint256);
    function coverageUsd(address asset, uint256 amount) external view returns (uint256);
    function proposerBondWood(address asset, uint256 requiredCoverage) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function woodUsdPriceX8() external view returns (uint256);
    function epochLength() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    function kNumerator() external view returns (uint256);
    function coveredTvlCapUsd() external view returns (uint256);
    function quorumTierThreshold() external view returns (uint8);
    function proposerBondBps() external view returns (uint256);

    // ── Owner setters ──
    function setWoodUsdPrice(uint256 newPriceX8) external;
    function setAssetFeed(address asset, address feed, uint256 maxDelay) external;
    function setGuardianRegistry(address registry) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setKNumerator(uint256 newK) external;
    function setCoveredTvlCapUsd(uint256 newCap) external;
    function setQuorumTierThreshold(uint8 newThreshold) external;
    function setProposerBondBps(uint256 newBps) external;
}
```

(`proposerBondWood` / `proposerBondBps` are implemented in Task 8 — the interface carries them from day one so it is written once.)

- [ ] **Step 4: Write the minimal implementation (skeleton + price + bond math)**

```solidity
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

    constructor(address initialOwner, address swood_, uint256 epochLength_) Ownable(initialOwner) {
        if (swood_ == address(0)) revert ZeroAddress();
        if (epochLength_ == 0) revert InvalidParameter();
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
        uint256 own = swood.guardianStake(guardian);
        uint256 inbound = swood.delegatedInbound(guardian);
        uint256 slashableWood = own + (inbound * swood.maxDelegatedSlashBps()) / BPS_DENOMINATOR;
        return (slashableWood * woodUsdPriceX8) / 1e8;
    }

    // ── Owner setters ──

    function setWoodUsdPrice(uint256 newPriceX8) external onlyOwner {
        emit WoodUsdPriceSet(woodUsdPriceX8, newPriceX8);
        woodUsdPriceX8 = newPriceX8;
    }

    function setGuardianRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        guardianRegistry = registry;
    }

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

    // ── Stubs replaced in Tasks 2–4 and 8 (placeholders so each task
    //    compiles and goes green before the next starts — NOT deferred work) ──

    function setAssetFeed(address, address, uint256) external virtual onlyOwner {
        revert InvalidParameter();
    }

    function coverageUsd(address, uint256) public view virtual returns (uint256) {
        revert FeedNotConfigured();
    }

    function proposerBondWood(address, uint256) external view virtual returns (uint256) {
        revert FeedNotConfigured();
    }

    function recordApproval(address, uint256, address) external virtual {
        revert NotGuardianRegistry();
    }

    function releaseApproval(address, uint256, address) external virtual {
        revert NotGuardianRegistry();
    }

    function requireWithinCoveredTvlCap(address, uint256) external view virtual {
        revert CoveredTvlCapExceeded();
    }

    function requireApproveQuorum(address, uint256, address, uint256) external view virtual {
        revert InsufficientApproveCoverage();
    }

    function openExposureUsd(address) public view virtual returns (uint256) {
        return 0;
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ExposureLedger.sol src/interfaces/IExposureLedger.sol test/ExposureLedger.t.sol
git commit -m "feat(ledger): ExposureLedger skeleton — priceHaircut + slashableBondUsd (spec 3.3)"
```

---

### Task 2: ExposureLedger — asset→USD conversion via Chainlink feeds

**Files:**
- Modify: `src/ExposureLedger.sol`
- Test: `test/ExposureLedger.t.sol` (append)

- [ ] **Step 1: Write the failing tests** (append; `MockFeed` at file scope, tests inside `ExposureLedgerTest`)

```solidity
contract MockFeed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

// ── append inside ExposureLedgerTest ──

function test_coverageUsd_6decAsset() public {
    MockFeed feed = new MockFeed(1e8, 8); // $1.00, 8-dec feed
    address usdg = makeAddr("usdg");
    vm.mockCall(usdg, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
    vm.prank(owner);
    ledger.setAssetFeed(usdg, address(feed), 1 days);
    // 2,000,000 USDG (6 dec) at $1 => $2,000,000 in USD-18
    assertEq(ledger.coverageUsd(usdg, 2_000_000e6), 2_000_000e18);
}

function test_coverageUsd_18decAssetNonUnitPrice() public {
    MockFeed feed = new MockFeed(2500e8, 8); // $2,500 (e.g. WETH)
    address weth = makeAddr("weth");
    vm.mockCall(weth, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
    vm.prank(owner);
    ledger.setAssetFeed(weth, address(feed), 1 days);
    assertEq(ledger.coverageUsd(weth, 2e18), 5_000e18);
}

function test_coverageUsd_revertsUnconfigured() public {
    vm.expectRevert(IExposureLedger.FeedNotConfigured.selector);
    ledger.coverageUsd(makeAddr("unknown"), 1e18);
}

function test_coverageUsd_revertsStale() public {
    MockFeed feed = new MockFeed(1e8, 8);
    address usdg = makeAddr("usdg2");
    vm.mockCall(usdg, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
    vm.prank(owner);
    ledger.setAssetFeed(usdg, address(feed), 1 days);
    vm.warp(block.timestamp + 2 days);
    vm.expectRevert(IExposureLedger.StalePrice.selector);
    ledger.coverageUsd(usdg, 1e6);
}
```

Add `import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";` to the test file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: the four new tests FAIL (`setAssetFeed` stub reverts `InvalidParameter`).

- [ ] **Step 3: Implement** — in `src/ExposureLedger.sol`, add file-scope interfaces, storage, and replace the `setAssetFeed` / `coverageUsd` stubs (drop their `virtual`):

```solidity
// ── file scope, next to ISwoodMinimal ──
interface IAggregatorMinimal {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IERC20DecimalsMinimal {
    function decimals() external view returns (uint8);
}

// ── contract storage, after guardianRegistry ──

/// @dev Per-asset USD feed config. `assetDecimals` cached at registration so
///      the hot path makes no external metadata call.
struct AssetFeed {
    address feed;
    uint64 maxDelay;
    uint8 assetDecimals;
    uint8 feedDecimals;
}

mapping(address asset => AssetFeed) internal _assetFeeds;

// ── replace the two stubs ──

/// @notice Register the Chainlink USD feed for a vault asset. Vault assets on
///         Robinhood have live feeds (USDG/USD, USDC/USD, ETH/USD —
///         chains/4663.json); WOOD deliberately does NOT go through this path
///         (governance haircut price instead, spec §8).
function setAssetFeed(address asset, address feed, uint256 maxDelay) external onlyOwner {
    if (asset == address(0) || feed == address(0)) revert ZeroAddress();
    if (maxDelay == 0) revert InvalidParameter();
    uint8 assetDec = IERC20DecimalsMinimal(asset).decimals();
    uint8 feedDec = IAggregatorMinimal(feed).decimals();
    _assetFeeds[asset] =
        AssetFeed({feed: feed, maxDelay: uint64(maxDelay), assetDecimals: assetDec, feedDecimals: feedDec});
    emit AssetFeedSet(asset, feed, maxDelay, assetDec);
}

/// @inheritdoc IExposureLedger
/// @dev USD-18 value of `amount` of `asset`. Fail-closed on unconfigured
///      asset or stale feed — a proposal in an unpriceable asset cannot be
///      coverage-checked and therefore cannot proceed.
function coverageUsd(address asset, uint256 amount) public view returns (uint256) {
    AssetFeed storage f = _assetFeeds[asset];
    if (f.feed == address(0)) revert FeedNotConfigured();
    (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(f.feed).latestRoundData();
    if (answer <= 0) revert StalePrice();
    uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    if (age > f.maxDelay) revert StalePrice();
    return (amount * uint256(answer) * 1e18) / (10 ** f.assetDecimals) / (10 ** f.feedDecimals);
}
```

(No L2-sequencer branch: `ChainlinkReader.readUsd` hard-requires a sequencer-uptime feed, which the Robinhood entries in `chains/4663.json` do not include. Staleness + positive-answer checks are the fail-closed core; if a sequencer feed becomes available, extend `AssetFeed` then.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ExposureLedger.sol test/ExposureLedger.t.sol
git commit -m "feat(ledger): asset-to-USD conversion with fail-closed Chainlink reads"
```

---

### Task 3: ExposureLedger — epoch-bucketed exposure recording + aggregate cap

**Files:**
- Modify: `src/ExposureLedger.sol`
- Test: `test/ExposureLedger.t.sol` (append)

The accounting model, stated once (this is the spec §3.3 + §3.4a core):

- `recordApproval` books `coverageUsd(asset, requiredCoverage)` into `_buckets[guardian][currentEpoch()]` and remembers `(usd, epoch)` per `(reviewKey, guardian)` so a vote-change can release exactly what was recorded.
- `openExposureUsd(g)` sums exactly the buckets whose challenge window has not elapsed: bucket `e` covers `[genesis + e·L, genesis + (e+1)·L)` and stays open until `genesis + (e+1)·L + W` (L = epochLength, W = challengeWindow). Equivalently, the first counted bucket is `from = elapsed > W ? (elapsed - W) / L : 0` with `elapsed = now - genesis`. A bucket drops at exactly `end(e) + W` — the budget recycles every challenge window (spec §3.3), no epoch-granularity slack.
- The cap check is `openExposureUsd(g) + newUsd <= kNumerator * slashableBondUsd(g)`, revert `ExposureCapExceeded`.
- **Invariant (one sentence, spec §4):** at every instant, `openExposureUsd(g)` equals the sum of USD amounts recorded for `g` in unexpired epochs minus amounts released from them, and never exceeded `k * slashableBondUsd(g)` at any record time.

- [ ] **Step 1: Write the failing tests** (append; mocks at file scope)

```solidity
contract MockGovernorForLedger {
    address public vaultAddr;
    uint256 public coverage;

    constructor(address vault_) {
        vaultAddr = vault_;
    }

    function set(uint256 coverage_) external {
        coverage = coverage_;
    }

    function getRequiredCoverage(uint256) external view returns (uint256) {
        return coverage;
    }

    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
    }

    function getProposalView(uint256) external view returns (ProposalViewLite memory v) {
        v.vault = vaultAddr;
    }
}

contract MockVaultForLedger {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

// ── append inside ExposureLedgerTest ──

address internal registry = makeAddr("registry");
MockGovernorForLedger internal mgov;
address internal usdgAsset;

function _wireRecording() internal {
    usdgAsset = makeAddr("usdgAsset");
    vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
    MockFeed feed = new MockFeed(1e8, 8);
    MockVaultForLedger vault = new MockVaultForLedger(usdgAsset);
    mgov = new MockGovernorForLedger(address(vault));
    vm.startPrank(owner);
    ledger.setAssetFeed(usdgAsset, address(feed), 365 days);
    ledger.setGuardianRegistry(registry);
    vm.stopPrank();
    swood.setStake(guardian, 100_000e18, 0); // slashableBondUsd = $5,000 at $0.05
}

function test_recordApproval_registryOnly() public {
    _wireRecording();
    mgov.set(1_000e6);
    vm.expectRevert(IExposureLedger.NotGuardianRegistry.selector);
    ledger.recordApproval(address(mgov), 1, guardian);
}

function test_recordApproval_booksExposure() public {
    _wireRecording();
    mgov.set(1_000e6); // $1,000
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    assertEq(ledger.openExposureUsd(guardian), 1_000e18);
}

function test_recordApproval_capExceededReverts() public {
    _wireRecording();
    mgov.set(6_000e6); // $6,000 > $5,000 bond
    vm.prank(registry);
    vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
    ledger.recordApproval(address(mgov), 1, guardian);
}

function test_recordApproval_netsAcrossSequentialEpochs() public {
    _wireRecording();
    mgov.set(4_000e6);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    // same guardian, next epoch + challenge window fully elapsed: budget recycled
    vm.warp(block.timestamp + 28 days + 14 days + 1);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 2, guardian); // would exceed the cap if netted with #1
    assertEq(ledger.openExposureUsd(guardian), 4_000e18); // only the live epoch counts
}

function test_recordApproval_blocksSimultaneousOverExposure() public {
    _wireRecording();
    mgov.set(3_000e6);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    vm.prank(registry);
    vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
    ledger.recordApproval(address(mgov), 2, guardian); // $3k + $3k > $5k — the batching attack
}

function test_releaseApproval_freesExactRecordedAmount() public {
    _wireRecording();
    mgov.set(3_000e6);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    vm.prank(registry);
    ledger.releaseApproval(address(mgov), 1, guardian);
    assertEq(ledger.openExposureUsd(guardian), 0);
}

function test_releaseApproval_idempotentNoUnderflow() public {
    _wireRecording();
    vm.prank(registry);
    ledger.releaseApproval(address(mgov), 99, guardian); // never recorded: no-op
    assertEq(ledger.openExposureUsd(guardian), 0);
}

/// Fuzz the stated invariant: any record/release interleaving leaves
/// openExposureUsd == sum recorded-minus-released in unexpired buckets.
function testFuzz_exposureAccountingConserved(uint96 c1, uint96 c2, bool releaseFirst) public {
    _wireRecording();
    swood.setStake(guardian, type(uint96).max, 0); // cap never binds in this fuzz
    vm.prank(owner);
    ledger.setWoodUsdPrice(1e8);
    uint256 u1 = uint256(c1) % 1_000_000e6 + 1;
    uint256 u2 = uint256(c2) % 1_000_000e6 + 1;
    mgov.set(u1);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    mgov.set(u2);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 2, guardian);
    if (releaseFirst) {
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), u2 * 1e12); // 6-dec asset at $1 → USD-18
    } else {
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 2, guardian);
        assertEq(ledger.openExposureUsd(guardian), u1 * 1e12);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: new tests FAIL (stubs revert / return 0).

- [ ] **Step 3: Implement** — replace the `recordApproval` / `releaseApproval` / `openExposureUsd` stubs (drop `virtual`):

```solidity
// ── file scope, next to the other minimal interfaces ──
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

// ── contract storage, after _assetFeeds ──

struct RecordedExposure {
    uint192 usd;
    uint64 epoch;
}

mapping(address guardian => mapping(uint256 epoch => uint256 usd)) internal _buckets;
mapping(bytes32 reviewKey => mapping(address guardian => RecordedExposure)) internal _recorded;

// ── modifiers / helpers ──

modifier onlyRegistry() {
    if (msg.sender != guardianRegistry) revert NotGuardianRegistry();
    _;
}

function _reviewKey(address governor, uint256 proposalId) internal pure returns (bytes32) {
    return keccak256(abi.encode(governor, proposalId)); // same derivation as GuardianRegistry
}

// ── replace stubs ──

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

/// @inheritdoc IExposureLedger
/// @dev Called by GuardianRegistry.voteOnProposal on the approve side (spec
///      §3.3: the cap is checked at vote time). Reverting here reverts the
///      guardian's vote — an over-exposed guardian simply cannot approve.
function recordApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
    bytes32 key = _reviewKey(governor, proposalId);
    if (_recorded[key][guardian].usd != 0) return; // idempotent (vote-change round trip)
    ILedgerGovernorMinimal gov = ILedgerGovernorMinimal(governor);
    address asset = IVaultAssetMinimal(gov.getProposalView(proposalId).vault).asset();
    uint256 usd = coverageUsd(asset, gov.getRequiredCoverage(proposalId));
    if (usd == 0) return; // zero-coverage: nothing to book
    uint256 epoch = currentEpoch();
    if (openExposureUsd(guardian) + usd > kNumerator * slashableBondUsd(guardian)) {
        revert ExposureCapExceeded();
    }
    _buckets[guardian][epoch] += usd;
    _recorded[key][guardian] = RecordedExposure({usd: uint192(usd), epoch: uint64(epoch)});
    emit ExposureRecorded(guardian, key, usd, epoch);
}

/// @inheritdoc IExposureLedger
/// @dev Vote-change Approve→Block (or any registry-side unwind). Releases
///      exactly what was recorded, from the bucket it was recorded into.
///      No-op when nothing is recorded — never underflows.
function releaseApproval(address governor, uint256 proposalId, address guardian) external onlyRegistry {
    bytes32 key = _reviewKey(governor, proposalId);
    RecordedExposure memory r = _recorded[key][guardian];
    if (r.usd == 0) return;
    delete _recorded[key][guardian];
    _buckets[guardian][r.epoch] -= r.usd;
    emit ExposureReleased(guardian, key, r.usd, r.epoch);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: all tests PASS (including the fuzz).

- [ ] **Step 5: Commit**

```bash
git add src/ExposureLedger.sol test/ExposureLedger.t.sol
git commit -m "feat(ledger): epoch-bucketed exposure recording + aggregate cap (spec 3.3/3.4a)"
```

---

### Task 4: ExposureLedger — covered-TVL cap check + approve-quorum check

**Files:**
- Modify: `src/ExposureLedger.sol`
- Test: `test/ExposureLedger.t.sol` (append)

- [ ] **Step 1: Write the failing tests**

```solidity
/// @dev Registry stub returning a canned approver set for quorum tests.
contract MockRegistryForLedger {
    address[] internal _approvers;

    function setApprovers(address[] memory a) external {
        _approvers = a;
    }

    function getApproverWeights(address, uint256)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 total)
    {
        approvers = _approvers;
        weights = new uint128[](approvers.length);
        total = 0;
    }
}

// ── append inside ExposureLedgerTest ──

function test_coveredTvlCap_enforced() public {
    _wireRecording();
    vm.prank(owner);
    ledger.setCoveredTvlCapUsd(2_000e18);
    ledger.requireWithinCoveredTvlCap(usdgAsset, 1_500e6); // $1,500 <= $2,000: fine
    vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
    ledger.requireWithinCoveredTvlCap(usdgAsset, 2_500e6);
}

function test_coveredTvlCap_zeroCapFailsClosed() public {
    _wireRecording(); // cap never set => 0
    vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
    ledger.requireWithinCoveredTvlCap(usdgAsset, 1e6);
}

function test_approveQuorum_sumOfApproverBondsCoversCoverage() public {
    _wireRecording();
    MockRegistryForLedger mockReg = new MockRegistryForLedger();
    vm.prank(owner);
    ledger.setGuardianRegistry(address(mockReg));
    address g2 = makeAddr("g2");
    swood.setStake(guardian, 60_000e18, 0); // $3,000
    swood.setStake(g2, 60_000e18, 0); // $3,000
    address[] memory a = new address[](2);
    a[0] = guardian;
    a[1] = g2;
    mockReg.setApprovers(a);
    // $5,000 coverage vs $6,000 combined bonds: passes
    ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 5_000e6);
    // $7,000 coverage: fails
    vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
    ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 7_000e6);
}

function test_approveQuorum_zeroApproversFailsClosed() public {
    _wireRecording();
    MockRegistryForLedger mockReg = new MockRegistryForLedger();
    vm.prank(owner);
    ledger.setGuardianRegistry(address(mockReg));
    // spec §3.3a cold-start: no covering signer => coverage-consuming proposal
    // cannot execute — it expires instead of executing unreviewed.
    vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
    ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1e6);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: new tests FAIL (stubs revert unconditionally — the happy-path calls revert).

- [ ] **Step 3: Implement** — replace the two remaining check stubs (drop `virtual`):

```solidity
// file scope, next to the other minimal interfaces:
interface IRegistryApproversMinimal {
    function getApproverWeights(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 totalApproveWeight);
}

/// @inheritdoc IExposureLedger
/// @dev Spec §3.7: hard per-vault ceiling on coverage-consuming proposals,
///      denominated in dollars. Zero cap fails closed (nothing proposable)
///      until governance seeds it. Called by SyndicateGovernor.propose.
function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view {
    if (coverageUsd(asset, requiredCoverage) > coveredTvlCapUsd) revert CoveredTvlCapExceeded();
}

/// @inheritdoc IExposureLedger
/// @dev Spec §3.3a: execution requires the covering approvers' aggregate
///      slashableBond (LIVE read, dollars) to meet the proposal's coverage.
///      Live rather than at-vote: sWOOD's coolDownPeriod >= epoch + challenge
///      window prevents full escape, and a live read is strictly conservative
///      (a bond that shrank since the vote counts at its shrunken value).
///      Zero approvers ALWAYS reverts, even at zero coverage — R1 requires an
///      identified signer for anything tier-gated into this check.
///      Called by SyndicateGovernor.executeProposal for proposals with
///      envelopeTier >= quorumTierThreshold.
function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
    external
    view
{
    uint256 needUsd = coverageUsd(asset, requiredCoverage);
    (address[] memory approvers,,) =
        IRegistryApproversMinimal(guardianRegistry).getApproverWeights(governor, proposalId);
    if (approvers.length == 0) revert InsufficientApproveCoverage();
    uint256 haveUsd;
    for (uint256 i = 0; i < approvers.length; i++) {
        haveUsd += slashableBondUsd(approvers[i]);
        if (haveUsd >= needUsd) return; // early exit
    }
    if (haveUsd < needUsd) revert InsufficientApproveCoverage();
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ExposureLedger.sol test/ExposureLedger.t.sol
git commit -m "feat(ledger): covered-TVL cap + approve-quorum checks (spec 3.7/3.3a)"
```

---

### Task 5: ProposerBondEscrow

**Files:**
- Create: `src/ProposerBondEscrow.sol`
- Create: `src/interfaces/IProposerBondEscrow.sol`
- Create: `test/ProposerBondEscrow.t.sol`

Design, stated once: WOOD-only escrow keyed by `keccak256(governor, proposalId)`. `lockBond` is governor-only (authorization = `GuardianRegistry.isAuthorizedGovernor(msg.sender)` — the same trust root the registry itself uses; the escrow stores the registry address immutably). `releaseBond` is also governor-only — the GOVERNOR decides when a proposal is terminal (Task 9 wires a permissionless `reclaimProposerBond` on the governor that resolves state first). No forfeit path in v1a: forfeiture routes to the compensation escrow, which is Plan C (v1b); this contract's only exit is release-to-proposer. **Invariant (spec §4): the escrow's WOOD balance always equals the sum of locked, unreleased bonds.**

- [ ] **Step 1: Write the failing tests**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProposerBondEscrow} from "src/ProposerBondEscrow.sol";
import {IProposerBondEscrow} from "src/interfaces/IProposerBondEscrow.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockRegistryAuth {
    mapping(address => bool) public isAuthorizedGovernor;

    function set(address gov, bool ok) external {
        isAuthorizedGovernor[gov] = ok;
    }
}

contract ProposerBondEscrowTest is Test {
    ProposerBondEscrow internal escrow;
    ERC20Mock internal wood;
    MockRegistryAuth internal reg;
    address internal governor = makeAddr("governor");
    address internal proposer = makeAddr("proposer");

    function setUp() public {
        wood = new ERC20Mock();
        reg = new MockRegistryAuth();
        reg.set(governor, true);
        escrow = new ProposerBondEscrow(address(wood), address(reg));
        wood.mint(proposer, 1_000e18);
        vm.prank(proposer);
        wood.approve(address(escrow), type(uint256).max);
    }

    function test_lockBond_pullsWoodAndRecords() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        assertEq(wood.balanceOf(address(escrow)), 100e18);
        (address p, uint256 amt) = escrow.bondOf(governor, 1);
        assertEq(p, proposer);
        assertEq(amt, 100e18);
    }

    function test_lockBond_unauthorizedGovernorReverts() public {
        vm.prank(makeAddr("rogue"));
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedGovernor.selector);
        escrow.lockBond(1, proposer, 100e18);
    }

    function test_lockBond_duplicateReverts() public {
        vm.startPrank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.expectRevert(IProposerBondEscrow.BondAlreadyLocked.selector);
        escrow.lockBond(1, proposer, 100e18);
        vm.stopPrank();
    }

    function test_releaseBond_returnsToProposer() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(proposer), 1_000e18);
        assertEq(wood.balanceOf(address(escrow)), 0);
    }

    function test_releaseBond_governorOnlyAndOnce() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedGovernor.selector);
        escrow.releaseBond(1);
        vm.prank(governor);
        escrow.releaseBond(1);
        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);
    }

    /// Fuzz the conservation invariant: balance == sum of locked-unreleased.
    function testFuzz_balanceMatchesOpenBonds(uint96 a1, uint96 a2, bool release1) public {
        uint256 b1 = uint256(a1) % 500e18 + 1;
        uint256 b2 = uint256(a2) % 500e18 + 1;
        vm.startPrank(governor);
        escrow.lockBond(1, proposer, b1);
        escrow.lockBond(2, proposer, b2);
        if (release1) escrow.releaseBond(1);
        vm.stopPrank();
        uint256 expected = release1 ? b2 : b1 + b2;
        assertEq(wood.balanceOf(address(escrow)), expected);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract ProposerBondEscrowTest -vv`
Expected: compilation failure — contract not found.

- [ ] **Step 3: Write the interface and implementation**

`src/interfaces/IProposerBondEscrow.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IProposerBondEscrow
/// @notice WOOD escrow for the risk-scaled proposer bond (spec 2026-07-22
///         §3.9). Governor-only lock/release; forfeiture (to the compensation
///         escrow, spec §3.8) is Plan C — v1a's only exit is release-to-proposer.
interface IProposerBondEscrow {
    error NotAuthorizedGovernor();
    error BondAlreadyLocked();
    error NoBond();
    error ZeroAddress();

    event BondLocked(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondReleased(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);

    function lockBond(uint256 proposalId, address proposer, uint256 amount) external;
    function releaseBond(uint256 proposalId) external;
    function bondOf(address governor, uint256 proposalId) external view returns (address proposer, uint256 amount);
}
```

`src/ProposerBondEscrow.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProposerBondEscrow} from "./interfaces/IProposerBondEscrow.sol";

interface IRegistryAuthMinimal {
    function isAuthorizedGovernor(address gov) external view returns (bool);
}

/**
 * @title ProposerBondEscrow
 * @notice Holds the risk-scaled proposer bond (spec 2026-07-22 §3.9) for the
 *         lifetime of a proposal. The proposer is the actual attacker in the
 *         threat model, so it posts capital scaled to what the proposal can
 *         extract; in v1a the bond's only exit is release back to the
 *         proposer once the proposal reaches a terminal state (the governor
 *         gates WHEN — see `SyndicateGovernor.reclaimProposerBond`).
 *         Forfeiture to the compensation escrow arrives with the challenge
 *         game (Plan C); this contract deliberately has no owner and no
 *         discretionary exit — the invariant `wood.balanceOf(this) ==
 *         sum of locked-unreleased bonds` holds by construction.
 */
contract ProposerBondEscrow is IProposerBondEscrow {
    using SafeERC20 for IERC20;

    struct Bond {
        address proposer;
        uint96 amount; // WOOD fits: total supply << 2^96
    }

    IERC20 public immutable wood;
    IRegistryAuthMinimal public immutable registry;

    mapping(bytes32 bondKey => Bond) internal _bonds;

    constructor(address wood_, address registry_) {
        if (wood_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        wood = IERC20(wood_);
        registry = IRegistryAuthMinimal(registry_);
    }

    modifier onlyGovernor() {
        if (!registry.isAuthorizedGovernor(msg.sender)) revert NotAuthorizedGovernor();
        _;
    }

    function _key(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    /// @inheritdoc IProposerBondEscrow
    function lockBond(uint256 proposalId, address proposer, uint256 amount) external onlyGovernor {
        if (proposer == address(0)) revert ZeroAddress();
        bytes32 key = _key(msg.sender, proposalId);
        if (_bonds[key].proposer != address(0)) revert BondAlreadyLocked();
        _bonds[key] = Bond({proposer: proposer, amount: uint96(amount)});
        wood.safeTransferFrom(proposer, address(this), amount);
        emit BondLocked(msg.sender, proposalId, proposer, amount);
    }

    /// @inheritdoc IProposerBondEscrow
    /// @dev Governor-only: the governor's `reclaimProposerBond` resolves the
    ///      proposal to a TERMINAL state before calling — the escrow does not
    ///      re-derive lifecycle state.
    function releaseBond(uint256 proposalId) external onlyGovernor {
        bytes32 key = _key(msg.sender, proposalId);
        Bond memory b = _bonds[key];
        if (b.proposer == address(0)) revert NoBond();
        delete _bonds[key];
        wood.safeTransfer(b.proposer, b.amount);
        emit BondReleased(msg.sender, proposalId, b.proposer, b.amount);
    }

    /// @inheritdoc IProposerBondEscrow
    function bondOf(address governor, uint256 proposalId) external view returns (address, uint256) {
        Bond memory b = _bonds[_key(governor, proposalId)];
        return (b.proposer, b.amount);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract ProposerBondEscrowTest -vv`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ProposerBondEscrow.sol src/interfaces/IProposerBondEscrow.sol test/ProposerBondEscrow.t.sol
git commit -m "feat(escrow): ProposerBondEscrow — risk-scaled proposer bond custody (spec 3.9)"
```

---

### Task 6: TierRegistry — adapter-submitter bond

**Files:**
- Modify: `src/TierRegistry.sol`
- Test: `test/TierRegistry.t.sol` (append)

Design, stated once: spec §3.6 / v1a item "adapter-submitter bond escrow." `certify` gains a `submitter` param and pulls `submitterBondWood` WOOD from it (submitter pre-approves). The bond is held while the certification lives; any demotion (owner `demote` or permissionless `poke`) starts a `bondReleaseDelay` timelock, after which the submitter claims via `claimSubmitterBond`. The delay is the hook Plan C's slash path attaches to — a mis-certified bound is backstopped because the bond cannot exit before the challenge machinery has had its window. Re-certifying the same `(target, selector)` while a bond is pending release reverts (one bond per key at a time). `TierRegistry` is not yet on mainnet (Tenderly fork only) so this is an in-place change + redeploy, not an upgrade. **Invariant (spec §4): WOOD held == sum of active-certification bonds + pending-release bonds.**

- [ ] **Step 1: Write the failing tests** (append to `test/TierRegistry.t.sol`; reuse its `reg`/`owner`/`target` fixture — check the file's setUp for exact names)

```solidity
// New import at top of the existing test file:
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// ── append inside the existing TierRegistryTest contract ──

function _bondSetup() internal returns (ERC20Mock wood, address submitter) {
    wood = new ERC20Mock();
    submitter = makeAddr("submitter");
    wood.mint(submitter, 100_000e18);
    vm.startPrank(owner);
    reg.setWood(address(wood));
    reg.setSubmitterBondWood(10_000e18);
    reg.setBondReleaseDelay(14 days);
    vm.stopPrank();
    vm.prank(submitter);
    wood.approve(address(reg), type(uint256).max);
}

function test_certify_pullsSubmitterBond() public {
    (ERC20Mock wood, address submitter) = _bondSetup();
    vm.prank(owner);
    reg.certify(target, bytes4(0x11111111), 1, 500, submitter);
    assertEq(wood.balanceOf(address(reg)), 10_000e18);
    (uint8 tier,) = reg.tierOf(target, bytes4(0x11111111));
    assertEq(tier, 1);
}

function test_certify_zeroBondConfigStillWorks() public {
    // Pre-bond deployments: submitterBondWood == 0 => no pull, certify as before.
    vm.prank(owner);
    reg.certify(target, bytes4(0x22222222), 1, 500, address(0));
    (uint8 tier,) = reg.tierOf(target, bytes4(0x22222222));
    assertEq(tier, 1);
}

function test_demote_startsReleaseTimelock_claimAfterDelay() public {
    (ERC20Mock wood, address submitter) = _bondSetup();
    vm.prank(owner);
    reg.certify(target, bytes4(0x33333333), 1, 500, submitter);
    vm.prank(owner);
    reg.demote(target, bytes4(0x33333333));
    // immediate claim: blocked
    vm.prank(submitter);
    vm.expectRevert(TierRegistry.BondNotReleasable.selector);
    reg.claimSubmitterBond(target, bytes4(0x33333333));
    // after the delay: released
    vm.warp(block.timestamp + 14 days + 1);
    vm.prank(submitter);
    reg.claimSubmitterBond(target, bytes4(0x33333333));
    assertEq(wood.balanceOf(submitter), 100_000e18);
}

function test_recertify_whilePendingReleaseReverts() public {
    (, address submitter) = _bondSetup();
    vm.startPrank(owner);
    reg.certify(target, bytes4(0x44444444), 1, 500, submitter);
    reg.demote(target, bytes4(0x44444444));
    vm.expectRevert(TierRegistry.BondPendingRelease.selector);
    reg.certify(target, bytes4(0x44444444), 1, 500, submitter);
    vm.stopPrank();
}
```

Also update every EXISTING `reg.certify(...)` / `registry.certify(...)` call site in `test/` (and `script/` if any) to append the new final argument `address(0)` (no-bond form). Find them: `grep -rn "\.certify(" test/ script/ src/`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract TierRegistryTest -vv`
Expected: compilation failure — `certify` arity, `setWood`, `claimSubmitterBond` missing.

- [ ] **Step 3: Implement** — modify `src/TierRegistry.sol`:

```solidity
// New imports:
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Inside the contract:

using SafeERC20 for IERC20;

/// @dev Submitter bond per certification (spec §3.6: "tier downgrade = bonded
///      claim"). Held while certified; demotion starts `bondReleaseDelay`,
///      then the submitter claims. The delay is the seam Plan C's
///      guard-bypass slash attaches to (slash-first layering: submitter bond
///      before protocol backstop).
struct SubmitterBond {
    address submitter;
    uint96 amount;
    uint64 releasableAt; // 0 while certified; set on demotion
}

IERC20 public wood;
uint256 public submitterBondWood;
uint256 public bondReleaseDelay = 14 days;
mapping(bytes32 configKey => SubmitterBond) internal _bonds;

// New events / errors:
event SubmitterBondLocked(address indexed target, bytes4 indexed selector, address indexed submitter, uint256 amount);
event SubmitterBondClaimed(address indexed target, bytes4 indexed selector, address indexed submitter, uint256 amount);
event SubmitterBondConfigSet(address wood, uint256 bondWood, uint256 releaseDelay);

error BondNotReleasable();
error BondPendingRelease();
error NotSubmitter();
error BondConfigUnset();
error ZeroAddressSubmitter();

// New setters:
function setWood(address wood_) external onlyOwner {
    wood = IERC20(wood_);
    emit SubmitterBondConfigSet(wood_, submitterBondWood, bondReleaseDelay);
}

function setSubmitterBondWood(uint256 amount) external onlyOwner {
    if (amount != 0 && address(wood) == address(0)) revert BondConfigUnset();
    submitterBondWood = amount;
    emit SubmitterBondConfigSet(address(wood), amount, bondReleaseDelay);
}

function setBondReleaseDelay(uint256 delay) external onlyOwner {
    bondReleaseDelay = delay;
    emit SubmitterBondConfigSet(address(wood), submitterBondWood, delay);
}
```

Change `certify`'s signature and body (keep all existing checks; additions marked NEW):

```solidity
function certify(address target, bytes4 selector, uint8 tier, uint16 extractableBoundBps, address submitter)
    external
    onlyOwner
{
    if (tier >= TIER_ARBITRARY) revert InvalidTier();
    if (extractableBoundBps == 0 || extractableBoundBps >= FULL_NOTIONAL_BPS) revert BoundRequired();
    bytes32 ch = target.codehash;
    if (ch == bytes32(0) || ch == _EMPTY_CODEHASH) revert NotAContract();
    bytes32 k = key(target, selector);
    // NEW: a bond pending release blocks re-certification — one bond per key.
    if (_bonds[k].releasableAt != 0) revert BondPendingRelease();
    // NEW: pull the submitter bond when configured (spec §3.6). Zero-config
    // (bond amount 0) preserves the Plan A no-bond path for the governance-
    // assigned initial adapter set.
    uint256 bondAmount = submitterBondWood;
    if (bondAmount != 0) {
        if (submitter == address(0)) revert ZeroAddressSubmitter();
        _bonds[k] = SubmitterBond({submitter: submitter, amount: uint96(bondAmount), releasableAt: 0});
        wood.safeTransferFrom(submitter, address(this), bondAmount);
        emit SubmitterBondLocked(target, selector, submitter, bondAmount);
    }
    _configs[k] = TierConfig({tier: tier, extractableBoundBps: extractableBoundBps, certifiedCodehash: ch});
    emit TierCertified(target, selector, tier, extractableBoundBps, ch);
}
```

Extend `_demote` and add the claim:

```solidity
function _demote(address target, bytes4 selector) private {
    bytes32 k = key(target, selector);
    delete _configs[k];
    SubmitterBond storage b = _bonds[k];
    if (b.amount != 0 && b.releasableAt == 0) {
        b.releasableAt = uint64(block.timestamp + bondReleaseDelay);
    }
    emit TierDemoted(target, selector);
}

/// @notice Submitter claims its bond back, `bondReleaseDelay` after demotion.
///         The delay is the window Plan C's guard-bypass slash will act in.
function claimSubmitterBond(address target, bytes4 selector) external {
    bytes32 k = key(target, selector);
    SubmitterBond memory b = _bonds[k];
    if (b.submitter != msg.sender) revert NotSubmitter();
    if (b.releasableAt == 0 || block.timestamp < b.releasableAt) revert BondNotReleasable();
    delete _bonds[k];
    wood.safeTransfer(b.submitter, b.amount);
    emit SubmitterBondClaimed(target, selector, b.submitter, b.amount);
}
```

- [ ] **Step 4: Run the affected suites** (this change touches Plan A's suites via the arity change)

Run: `forge test --match-contract "TierRegistry|SelectorGuard|TierResolution|TierEndToEnd" -vv`
Expected: all PASS after the call-site arity updates.

- [ ] **Step 5: Commit**

```bash
git add src/TierRegistry.sol test/ script/ 2>/dev/null || git add src/TierRegistry.sol test/
git commit -m "feat(tiers): adapter-submitter bond with demotion timelock (spec 3.6)"
```

---

### Task 7: GuardianRegistry upgrade — record/release exposure on approve votes

**Files:**
- Modify: `src/GuardianRegistry.sol`
- Modify: `src/interfaces/IGuardianRegistry.sol`
- Create: `test/RegistryExposureHook.t.sol`

Wiring rules, stated once:
- New storage: `IExposureLedger public exposureLedger;` — take ONE slot from `__gap` (50 → 49). Owner-set via `setExposureLedger` (a setter, not init, because the registry proxy is live on the fork).
- `voteOnProposal`, first-vote Approve → `recordApproval`; first-vote Block → nothing.
- Vote-change Approve→Block → `releaseApproval`; Block→Approve → `recordApproval`.
- Ledger unset (`address(0)`) → skip all hooks (pre-wiring compatibility; matches the tierRegistry pattern).
- The ledger call REVERTS the vote when the guardian is over cap — that is the spec §3.3 enforcement point, not an error to swallow.

- [ ] **Step 1: Write the failing tests**

The registry has existing test fixtures — copy the setUp of the newest `test/GuardianRegistry*.t.sol` (real `StakedWood` + registry proxy + governor registered via factory; that harness is canonical). The five test bodies to add, driven through REAL `voteOnProposal` calls against a REAL `ExposureLedger`:

```solidity
contract RegistryExposureHookTest is Test {
    // fixture (from the canonical harness): registry (proxied), swood (real,
    // guardians g1/g2 staked), governor `gov` with proposal PID in its review
    // window, ExposureLedger `ledger` wired both ways:
    //   ledger.setGuardianRegistry(address(registry));
    //   registry.setExposureLedger(address(ledger));
    // plus USDG feed, wood price $0.05, generous caps. A SECOND governor/
    // registry pair `registryNoLedger`/`gov2` is created WITHOUT the ledger.

    function test_approveVote_recordsExposure() public {
        vm.prank(g1);
        registry.voteOnProposal(address(gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
        assertGt(ledger.openExposureUsd(g1), 0);
    }

    function test_blockVote_recordsNothing() public {
        vm.prank(g1);
        registry.voteOnProposal(address(gov), PID, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposureUsd(g1), 0);
    }

    function test_voteChange_approveToBlock_releases() public {
        vm.prank(g1);
        registry.voteOnProposal(address(gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g1);
        registry.voteOnProposal(address(gov), PID, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposureUsd(g1), 0);
    }

    function test_overCapGuardianCannotApprove() public {
        // shrink g1's effective bond to ~$0: crash the governance WOOD price
        vm.prank(ledgerOwner);
        ledger.setWoodUsdPrice(1);
        vm.prank(g1);
        vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
        registry.voteOnProposal(address(gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
    }

    function test_ledgerUnset_votesUnaffected() public {
        vm.prank(g1);
        registryNoLedger.voteOnProposal(address(gov2), PID2, IGuardianRegistry.GuardianVoteType.Approve);
        // no revert, no recording anywhere — Plan A behavior preserved
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract RegistryExposureHookTest -vv`
Expected: compilation failure — `setExposureLedger` missing.

- [ ] **Step 3: Implement**

In `src/interfaces/IGuardianRegistry.sol` add:

```solidity
function setExposureLedger(address ledger) external;
function exposureLedger() external view returns (address);
```

In `src/GuardianRegistry.sol`:

```solidity
// import:
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";

// storage — insert ABOVE the gap, then REPLACE `uint256[50] private __gap;`:
/// @notice Plan B (spec §3.3): exposure ledger consulted on every approve-side
///         review vote. address(0) = not wired = hooks skipped.
IExposureLedger public exposureLedger;

/// @dev Reserved storage for future upgrades (was 50; -1 for exposureLedger).
uint256[49] private __gap;

// setter (next to setReviewPeriod):
/// @notice Wire the exposure ledger (owner-instant; owner is a multisig with
///         external delay).
function setExposureLedger(address ledger) external onlyOwner {
    if (ledger == address(0)) revert ZeroAddress();
    exposureLedger = IExposureLedger(ledger);
}
```

In `voteOnProposal`, FIRST-VOTE branch — after `_votes[key][msg.sender] = support;`, before the `emit GuardianVoteCast(...)`:

```solidity
            if (support == GuardianVoteType.Approve && address(exposureLedger) != address(0)) {
                // Spec §3.3: the aggregate exposure cap is checked HERE, at
                // the approve vote. A revert (ExposureCapExceeded) reverts
                // the vote — an over-exposed guardian cannot approve.
                exposureLedger.recordApproval(governor, proposalId, msg.sender);
            }
```

In the VOTE-CHANGE branch — after `_votes[key][msg.sender] = support;`, before the `emit GuardianVoteChanged(...)`:

```solidity
            if (address(exposureLedger) != address(0)) {
                if (support == GuardianVoteType.Block) {
                    exposureLedger.releaseApproval(governor, proposalId, msg.sender);
                } else {
                    exposureLedger.recordApproval(governor, proposalId, msg.sender);
                }
            }
```

- [ ] **Step 4: Run tests**

Run: `forge test --match-contract "RegistryExposureHook|GuardianRegistry" -vv`
Expected: new suite PASS; every pre-existing GuardianRegistry suite still PASS (ledger unset in their fixtures → hooks skipped).

- [ ] **Step 5: Commit**

```bash
git add src/GuardianRegistry.sol src/interfaces/IGuardianRegistry.sol test/RegistryExposureHook.t.sol
git commit -m "feat(registry): exposure-ledger hooks on approve-side review votes (spec 3.3)"
```

---

### Task 8: Governor — covered-TVL cap + proposer bond at propose

**Files:**
- Modify: `src/SyndicateGovernor.sol`
- Modify: `src/interfaces/ISyndicateGovernor.sol`
- Modify: `src/ExposureLedger.sol` (implement `proposerBondWood`, declared in Task 1's interface)
- Create: `test/GovernorCoverageGates.t.sol`

Wiring rules, stated once:
- Two new governor storage slots after `_tierRegistry`: `address internal _exposureLedger;` and `address internal _bondEscrow;` — decrement `__gap` 33 → 31. Both factory-wired via `setExposureLedger` / `setBondEscrow` (onlyFactory, mirroring `setTierRegistry` at `src/SyndicateGovernor.sol:1315-1319` — copy its exact gate idiom), pushed at `createSyndicate` (Task 10).
- `StrategyProposal` appends ONE field at the very end: `uint256 proposerBondWood;` (with an APPENDED-FIELDS comment matching the Plan A ones).
- In `propose`, the gates run inside `_snapshotTier` (it already runs after coverage is computed, and it is the established stack-budget hoist point): when `_exposureLedger != 0`, call `requireWithinCoveredTvlCap(asset, coverage_)`; then compute and lock the bond.
- Bond formula (spec §3.9 + §5): `bondWood = coverageUsd * proposerBondBps / 10_000 * 1e8 / woodUsdPriceX8`, computed ledger-side by `proposerBondWood(asset, requiredCoverage)` so the governor makes ONE call.
- Ledger or escrow unset → skip the respective gate (pre-wiring compat, tierRegistry pattern).

- [ ] **Step 1: Write the failing tests**

Model the fixture on `test/RiskEnvelope.t.sol` / `test/TierResolution.t.sol` (full factory + vault + governor harness; those setUps are canonical). Key content:

```solidity
contract GovernorCoverageGatesTest is Test {
    // fixture: full syndicate (factory-created governor+vault), ExposureLedger
    // + ProposerBondEscrow deployed, factory.setExposureLedger/setBondEscrow
    // called BEFORE createSyndicate so the governor is wired; USDG feed set;
    // wood price $0.05; coveredTvlCapUsd generous; agent holds WOOD and has
    // approved the escrow. A second, UNWIRED governor is created before the
    // factory setters run.

    function test_propose_revertsOverCoveredTvlCap() public {
        vm.prank(ledgerOwner);
        ledger.setCoveredTvlCapUsd(100e18); // $100 cap
        vm.prank(agent);
        vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
        governor.propose(vault, address(0), "uri", 7 days, envelopeWithCapital(1_000e6), execCalls, settleCalls, none);
    }

    function test_propose_locksRiskScaledBond() public {
        // coverage $1,000 (tier-2 flat: requiredCoverage == maxCapital),
        // bps 100 => $10 => 200 WOOD at $0.05
        vm.prank(agent);
        uint256 pid =
            governor.propose(vault, address(0), "uri", 7 days, envelopeWithCapital(1_000e6), execCalls, settleCalls, none);
        (address p, uint256 amt) = escrow.bondOf(address(governor), pid);
        assertEq(p, agent);
        assertEq(amt, 200e18);
        assertEq(governor.getProposal(pid).proposerBondWood, 200e18);
    }

    function test_propose_insufficientWoodAllowanceReverts() public {
        vm.prank(agent);
        wood.approve(address(escrow), 0);
        vm.prank(agent);
        vm.expectRevert(); // SafeERC20 transferFrom failure inside lockBond
        governor.propose(vault, address(0), "uri", 7 days, envelopeWithCapital(1_000e6), execCalls, settleCalls, none);
    }

    function test_propose_ledgerUnwired_skipsGates() public {
        vm.prank(agent2);
        uint256 pid = unwiredGovernor.propose(
            vault2, address(0), "uri", 7 days, envelopeWithCapital(1_000e6), execCalls2, settleCalls2, none
        );
        assertEq(unwiredGovernor.getProposal(pid).proposerBondWood, 0);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract GovernorCoverageGatesTest -vv`
Expected: compilation failure — wiring functions missing.

- [ ] **Step 3: Implement**

Ledger — replace the `proposerBondWood` stub (drop `virtual`):

```solidity
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
```

Governor (`src/SyndicateGovernor.sol`):

```solidity
// imports:
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IProposerBondEscrow} from "./interfaces/IProposerBondEscrow.sol";

// storage — after `address internal _tierRegistry;`:
address internal _exposureLedger;
address internal _bondEscrow;
// REPLACE `uint256[33] private __gap;` with:
/// @dev (was 33; -2 for _exposureLedger/_bondEscrow — Plan B)
uint256[31] private __gap;

// setters + views. The access gate is COPIED VERBATIM from the existing
// `setTierRegistry` (src/SyndicateGovernor.sol:1315-1319) — open that
// function first and reproduce its exact first-line factory check (whatever
// storage read + revert it uses), then the emit + assign:
function setExposureLedger(address newLedger) external {
    // <exact factory-only check copied from setTierRegistry's first line>
    emit ExposureLedgerSet(_exposureLedger, newLedger);
    _exposureLedger = newLedger;
}

function setBondEscrow(address newEscrow) external {
    // <exact factory-only check copied from setTierRegistry's first line>
    emit BondEscrowSet(_bondEscrow, newEscrow);
    _bondEscrow = newEscrow;
}

function exposureLedger() external view returns (address) {
    return _exposureLedger;
}

function bondEscrow() external view returns (address) {
    return _bondEscrow;
}
```

At the end of `_snapshotTier` (after `p.requiredCoverage = coverage_;`):

```solidity
        // Plan B gates (spec §3.7 + §3.9). Skipped when unwired — the
        // pre-ledger safe default matches the tierRegistry pattern.
        address ledger = _exposureLedger;
        if (ledger != address(0)) {
            address asset = IERC4626(GovernorParameters.vault).asset();
            IExposureLedger(ledger).requireWithinCoveredTvlCap(asset, coverage_);
            address escrow = _bondEscrow;
            if (escrow != address(0)) {
                uint256 bondWood = IExposureLedger(ledger).proposerBondWood(asset, coverage_);
                if (bondWood != 0) {
                    p.proposerBondWood = bondWood;
                    IProposerBondEscrow(escrow).lockBond(p.id, p.proposer, bondWood);
                }
            }
        }
```

Interface (`ISyndicateGovernor.sol`): append `uint256 proposerBondWood;` at the END of `StrategyProposal`; add setters/views/events (`ExposureLedgerSet`, `BondEscrowSet`).

**Stack-budget caution:** `_snapshotTier` was hoisted precisely because `propose` sits at Yul's stack edge. The additions live inside `_snapshotTier`'s own frame — if `forge build` (and `forge coverage`'s no-viaIR pipeline) trips stack-too-deep anyway, hoist the new block into its own `_lockCoverageGates(StrategyProposal storage p, uint256 coverage_)` private function called from `_snapshotTier`, same pattern as the existing hoists.

- [ ] **Step 4: Run tests**

Run: `forge test --match-contract "GovernorCoverageGates|RiskEnvelope|TierResolution" -vv`
Expected: new suite PASS; Plan A suites PASS untouched (their fixtures never wire the ledger).

- [ ] **Step 5: Commit**

```bash
git add src/SyndicateGovernor.sol src/interfaces/ISyndicateGovernor.sol src/ExposureLedger.sol test/GovernorCoverageGates.t.sol
git commit -m "feat(governor): covered-TVL cap + risk-scaled proposer bond at propose (spec 3.7/3.9)"
```

---

### Task 9: Governor — approve quorum at execute + bond reclaim on terminal states

**Files:**
- Modify: `src/SyndicateGovernor.sol`
- Modify: `src/interfaces/ISyndicateGovernor.sol`
- Test: `test/GovernorCoverageGates.t.sol` (append)

Rules, stated once:
- In `executeProposal`, immediately after the `CoverageRegressed` check: when `_exposureLedger != 0` **and** `proposal.envelopeTier >= IExposureLedger(_exposureLedger).quorumTierThreshold()`, call `requireApproveQuorum(address(this), proposalId, asset, proposal.requiredCoverage)`. Tier below threshold → optimistic passage preserved (spec §4 gate 2 — the BLOCKING ROE gate; launch threshold 2).
- New permissionless `reclaimProposerBond(uint256 proposalId)`: resolves state; requires terminal (`Rejected`, `Expired`, `Cancelled`, `Settled`); requires `proposerBondWood != 0`; zeroes the field first (effects-before-interactions + idempotence), then `escrow.releaseBond(proposalId)`. ONE entrypoint instead of hooks in settle/cancel/emergency paths — fewer seams; permissionless is safe because the escrow pays only the recorded proposer.
- Rejection/expiry/cancel RETURN the bond: forfeiture is exclusively a passed-challenge outcome (Plan C). A guardian block is not a conviction.

- [ ] **Step 1: Write the failing tests** (append to `GovernorCoverageGatesTest`; helpers `_passVotingAndReview` / `_warpIntoReview` / `_resolveReview` / `_settle` built from the existing harness patterns)

```solidity
function test_execute_tier2NoApprovers_reverts() public {
    uint256 pid = _proposeDefault(); // tier-2 (unregistered target)
    _passVotingAndReview(pid); // voteEnd passes, openReview, reviewEnd passes, resolveReview (nobody voted)
    vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
    governor.executeProposal(pid);
}

function test_execute_coveredByApprovers_succeeds() public {
    uint256 pid = _proposeDefault();
    _warpIntoReview(pid);
    vm.prank(g1); // g1 staked so slashableBondUsd >= coverage
    registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);
    _resolveReview(pid);
    governor.executeProposal(pid); // no revert
}

function test_execute_tierBelowThreshold_skipsQuorum() public {
    uint256 pid = _proposeTier1(); // exec target certified tier 1 => envelopeTier 1 < threshold 2
    _passVotingAndReview(pid);
    governor.executeProposal(pid); // executes with zero approvers — optimistic lane intact
}

function test_reclaimBond_afterSettle() public {
    uint256 pid = _proposeCoveredAndExecute();
    _settle(pid);
    uint256 balBefore = wood.balanceOf(agent);
    governor.reclaimProposerBond(pid);
    assertEq(wood.balanceOf(agent), balBefore + 200e18);
    vm.expectRevert(ISyndicateGovernor.NoBondToReclaim.selector);
    governor.reclaimProposerBond(pid); // idempotent
}

function test_reclaimBond_activeProposalReverts() public {
    uint256 pid = _proposeDefault();
    vm.expectRevert(ISyndicateGovernor.ProposalNotTerminal.selector);
    governor.reclaimProposerBond(pid);
}

function test_reclaimBond_afterExpiry() public {
    uint256 pid = _proposeDefault();
    _passVotingAndReview(pid);
    vm.warp(governor.getProposal(pid).executeBy + 1); // Approved -> Expired (lazy)
    governor.reclaimProposerBond(pid);
    (, uint256 amt) = escrow.bondOf(address(governor), pid);
    assertEq(amt, 0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract GovernorCoverageGatesTest -vv`
Expected: compilation failure — `reclaimProposerBond` / errors missing.

- [ ] **Step 3: Implement**

In `executeProposal`, right after `if (liveCoverage > proposal.requiredCoverage) revert CoverageRegressed();` (`asset` is already in scope from the balance snapshot):

```solidity
        // Plan B (spec §3.3a): coverage-consuming proposals at/above the tier
        // threshold need a bond-encumbered approve quorum — silence no longer
        // passes them. Below-threshold tiers keep optimistic passage until the
        // §3.10 ROE gate clears (spec §4 gate 2, BLOCKING).
        {
            address ledger = _exposureLedger;
            if (ledger != address(0) && proposal.envelopeTier >= IExposureLedger(ledger).quorumTierThreshold()) {
                IExposureLedger(ledger).requireApproveQuorum(address(this), proposalId, asset, proposal.requiredCoverage);
            }
        }
```

New function (near `cancelProposal`):

```solidity
    /// @notice Permissionless: return the proposer bond once the proposal is
    ///         terminal. Rejection, expiry, and cancellation all RETURN the
    ///         bond — forfeiture is exclusively a passed-challenge outcome
    ///         (Plan C, spec §3.9); a guardian block is not a conviction.
    function reclaimProposerBond(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (proposal.id == 0) revert ProposalNotFound();
        ProposalState s = _resolveState(proposal);
        if (
            s != ProposalState.Rejected && s != ProposalState.Expired && s != ProposalState.Cancelled
                && s != ProposalState.Settled
        ) revert ProposalNotTerminal();
        uint256 bond = proposal.proposerBondWood;
        if (bond == 0) revert NoBondToReclaim();
        proposal.proposerBondWood = 0; // effects before interaction; makes reclaim idempotent
        IProposerBondEscrow(_bondEscrow).releaseBond(proposalId);
    }
```

Interface: add `reclaimProposerBond`, errors `ProposalNotTerminal` / `NoBondToReclaim`.

- [ ] **Step 4: Run tests**

Run: `forge test --match-contract GovernorCoverageGatesTest -vv`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/SyndicateGovernor.sol src/interfaces/ISyndicateGovernor.sol test/GovernorCoverageGates.t.sol
git commit -m "feat(governor): approve quorum at execute + permissionless bond reclaim (spec 3.3a/3.9)"
```

---

### Task 10: Factory — wire ledger + escrow into new AND existing governors

**Files:**
- Modify: `src/SyndicateFactory.sol`
- Modify: `src/interfaces/ISyndicateFactory.sol`
- Create: `test/FactoryCoverageWiring.t.sol`

Rules, stated once:
- Two new factory storage slots + owner setters `setExposureLedger` / `setBondEscrow`, cloning the existing `tierRegistry` slot/setter pattern (`src/SyndicateFactory.sol:175,573`).
- `createSyndicate` pushes both (when set) right after the existing tierRegistry push (`src/SyndicateFactory.sol:333-337`).
- **New rewire path (closes LOW-1 / issue #19):** `pushWiring(address governor)` — owner-only; pushes the factory's CURRENT `tierRegistry`, `exposureLedger`, and `bondEscrow` into an already-created governor. Gate on the factory's own governor bookkeeping (the mapping `createSyndicate` records the proxy in — locate with `grep -n "governorFor\|isGovernor\|_governors" src/SyndicateFactory.sol`; it exists because the factory registers governors on the guardian registry via `addGovernor`).

- [ ] **Step 1: Write the failing tests** (fixture: copy the newest factory test's setUp)

```solidity
contract FactoryCoverageWiringTest is Test {
    function test_createSyndicate_pushesLedgerAndEscrow() public {
        factory.setExposureLedger(address(ledger));
        factory.setBondEscrow(address(escrow));
        (address gov,) = _createSyndicate();
        assertEq(ISyndicateGovernor(gov).exposureLedger(), address(ledger));
        assertEq(ISyndicateGovernor(gov).bondEscrow(), address(escrow));
    }

    function test_createSyndicate_unsetLedgerLeavesGovernorUnwired() public {
        (address gov,) = _createSyndicate();
        assertEq(ISyndicateGovernor(gov).exposureLedger(), address(0));
    }

    function test_pushWiring_rewiresExistingGovernor() public {
        (address gov,) = _createSyndicate(); // created BEFORE wiring existed
        factory.setTierRegistry(address(tierReg));
        factory.setExposureLedger(address(ledger));
        factory.setBondEscrow(address(escrow));
        factory.pushWiring(gov);
        assertEq(ISyndicateGovernor(gov).tierRegistry(), address(tierReg));
        assertEq(ISyndicateGovernor(gov).exposureLedger(), address(ledger));
        assertEq(ISyndicateGovernor(gov).bondEscrow(), address(escrow));
    }

    function test_pushWiring_foreignGovernorReverts() public {
        vm.expectRevert(ISyndicateFactory.NotFactoryGovernor.selector);
        factory.pushWiring(makeAddr("foreign"));
    }

    function test_pushWiring_ownerOnly() public {
        (address gov,) = _createSyndicate();
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        factory.pushWiring(gov);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract FactoryCoverageWiringTest -vv`
Expected: compilation failure.

- [ ] **Step 3: Implement** — clone the `tierRegistry` slot/setter/push idiom exactly:

```solidity
// storage, immediately after `address public tierRegistry;`:
address public exposureLedger;
address public bondEscrow;

// events:
event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
event BondEscrowSet(address indexed oldEscrow, address indexed newEscrow);
event WiringPushed(address indexed governor);

// error:
error NotFactoryGovernor();

// setters (next to setTierRegistry, same onlyOwner gate):
function setExposureLedger(address newLedger) external onlyOwner {
    emit ExposureLedgerSet(exposureLedger, newLedger);
    exposureLedger = newLedger;
}

function setBondEscrow(address newEscrow) external onlyOwner {
    emit BondEscrowSet(bondEscrow, newEscrow);
    bondEscrow = newEscrow;
}

// in createSyndicate, right after the tierRegistry push block:
if (exposureLedger != address(0)) {
    ISyndicateGovernor(govProxy).setExposureLedger(exposureLedger);
}
if (bondEscrow != address(0)) {
    ISyndicateGovernor(govProxy).setBondEscrow(bondEscrow);
}

// rewire path (LOW-1 / issue #19):
/// @notice Push the factory's current tierRegistry / exposureLedger /
///         bondEscrow into an EXISTING governor created by this factory.
///         Closes the "governor predates the registry" gap: without this, a
///         pre-wiring governor runs batches unguarded forever.
function pushWiring(address governor) external onlyOwner {
    // membership check: use the factory's existing governor-tracking mapping
    // (the one createSyndicate writes; located in Step 3's grep). Example if
    // the mapping is `isFactoryGovernor`:
    if (!isFactoryGovernor[governor]) revert NotFactoryGovernor();
    if (tierRegistry != address(0)) ISyndicateGovernor(governor).setTierRegistry(tierRegistry);
    if (exposureLedger != address(0)) ISyndicateGovernor(governor).setExposureLedger(exposureLedger);
    if (bondEscrow != address(0)) ISyndicateGovernor(governor).setBondEscrow(bondEscrow);
    emit WiringPushed(governor);
}
```

(The membership mapping name is the ONE lookup this plan can't pin from here — resolve it with the Step 3 grep; if none exists, add `mapping(address => bool) public isFactoryGovernor;` written in `createSyndicate`, which is itself a storage APPEND — note it for Task 11's goldens.)

Interface: add the setters, `pushWiring`, `NotFactoryGovernor`, and the views to `ISyndicateFactory.sol`.

- [ ] **Step 4: Run tests**

Run: `forge test --match-contract "FactoryCoverageWiring|SyndicateFactory" -vv`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/SyndicateFactory.sol src/interfaces/ISyndicateFactory.sol test/FactoryCoverageWiring.t.sol
git commit -m "feat(factory): wire exposure ledger + bond escrow; pushWiring rewire path (closes LOW-1)"
```

---

### Task 11: Storage-layout goldens + full-suite regression

**Files:**
- Modify: the golden JSONs + pins (`test/GovernorLayoutPins.t.sol`, `syndicate-governor-layout.golden.json`, `syndicate-factory-layout.golden.json` — locate exact paths with `grep -rn "golden" test/ -l`)

- [ ] **Step 1: Run the layout pins and read the diff**

Run: `forge test --match-contract GovernorLayoutPins -vv`
Expected: FAIL — the goldens don't know `_exposureLedger`, `_bondEscrow`, the shrunken gaps, `StrategyProposal.proposerBondWood`, or the factory's new slots.

- [ ] **Step 2: Verify the diff is APPEND-ONLY, then regenerate**

Manually inspect: every pre-existing slot number/offset/type in the failure diff must be UNCHANGED; only new entries and gap-size changes may appear. If any existing slot moved: STOP, surface to the user, do not regenerate.

Regenerate per the harness's own documented command (the golden test file's header documents it — Plan A wrote it; typically `forge inspect SyndicateGovernor storage-layout` piped into the golden, plus the factory equivalent).

- [ ] **Step 3: Run the full suite**

Run: `forge test`
Expected: zero NEW failures. (The same pre-existing fork/RPC failures PR #13 documented — no `--fork-url` in env — are expected.)

- [ ] **Step 4: Commit**

```bash
git add test/
git commit -m "test: regenerate storage-layout goldens for Plan B appends (verified append-only)"
```

---

### Task 12: Deploy script + parameter seeding

**Files:**
- Create: `script/DeployPlanB.s.sol` (standalone: deploy + wire onto an EXISTING Plan A deployment)

- [ ] **Step 1: Write `script/DeployPlanB.s.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {ProposerBondEscrow} from "src/ProposerBondEscrow.sol";
import {ISyndicateFactory} from "src/interfaces/ISyndicateFactory.sol";
import {IGuardianRegistry} from "src/interfaces/IGuardianRegistry.sol";

interface ISwoodCooldown {
    function coolDownPeriod() external view returns (uint256);
}

/// @notice Plan B deployment against an existing Plan A deployment. Address
///         book via env vars (from chains/<chainid>.json). Order:
///           1. deploy ExposureLedger (epochLength 28d) + ProposerBondEscrow
///           2. seed ledger params (WOOD haircut price, USDG feed, caps, registry link)
///           3. registry.setExposureLedger   (owner op — REQUIRES the UUPS-upgraded impl)
///           4. factory.setExposureLedger / setBondEscrow (new syndicates)
///         MANUAL follow-ups printed at the end (beacon/UUPS upgrades,
///         pushWiring per governor, TierRegistry redeploy + recertify).
/// @dev PRE-FLIGHT (cross-contract invariant, spec §5): swood.coolDownPeriod()
///      must be >= 28d + challengeWindow BEFORE wiring — asserted below.
contract DeployPlanB is Script {
    function run() external {
        address swood = vm.envAddress("STAKED_WOOD");
        address factory = vm.envAddress("SYNDICATE_FACTORY");
        address registry = vm.envAddress("GUARDIAN_REGISTRY");
        address wood = vm.envAddress("WOOD_TOKEN");
        address usdg = vm.envAddress("USDG");
        address usdgFeed = vm.envAddress("CHAINLINK_USDG_USD_FEED");
        uint256 woodPriceX8 = vm.envUint("WOOD_PRICE_HAIRCUT_X8"); // conservative, <= 30-day low
        uint256 coveredTvlCapUsd = vm.envUint("COVERED_TVL_CAP_USD18");

        vm.startBroadcast();

        ExposureLedger ledger = new ExposureLedger(msg.sender, swood, 28 days);
        require(
            ISwoodCooldown(swood).coolDownPeriod() >= 28 days + ledger.challengeWindow(),
            "coolDownPeriod < epoch + challengeWindow (raise sWOOD cooldown first)"
        );
        ProposerBondEscrow escrow = new ProposerBondEscrow(wood, registry);

        ledger.setWoodUsdPrice(woodPriceX8);
        ledger.setAssetFeed(usdg, usdgFeed, 1 days);
        ledger.setGuardianRegistry(registry);
        ledger.setCoveredTvlCapUsd(coveredTvlCapUsd);
        // quorumTierThreshold stays at the default 2 (tier-2 only) — lowering
        // it is gated on the §3.10 ROE validation (BLOCKING, spec §4 gate 2).

        IGuardianRegistry(registry).setExposureLedger(address(ledger));
        ISyndicateFactory(factory).setExposureLedger(address(ledger));
        ISyndicateFactory(factory).setBondEscrow(address(escrow));

        vm.stopBroadcast();

        console.log("ExposureLedger:     %s", address(ledger));
        console.log("ProposerBondEscrow: %s", address(escrow));
        console.log("MANUAL NEXT: governor beacon upgrade, registry UUPS upgrade,");
        console.log("factory.pushWiring(<each existing governor>), TierRegistry redeploy + recertify.");
    }
}
```

- [ ] **Step 2: Dry-run against the Tenderly fork**

Run (env from `chains/9994663.json` + fork RPC): `forge script script/DeployPlanB.s.sol --rpc-url robinhood_fork -vvvv` (no `--broadcast` — simulation only).
Expected: simulation succeeds end-to-end, or fails ONLY on the coolDownPeriod pre-flight — in which case the runbook step "raise sWOOD coolDownPeriod to >= 42d" precedes deployment. That is a live-parameter governance action: SURFACE it to the user, do not change cooldown in this plan.

- [ ] **Step 3: Commit**

```bash
git add script/DeployPlanB.s.sol
git commit -m "chore(deploy): Plan B deploy script with cooldown pre-flight + param seeding"
```

---

### Task 13: End-to-end lifecycle + adversarial tests

**Files:**
- Create: `test/CoverageEndToEnd.t.sol`

- [ ] **Step 1: Write the tests** (full-harness fixture as in Task 8; every helper exists from Tasks 8–9. Five behaviors, each a complete concrete test — no body may be empty when this task finishes):

1. `test_fullLifecycle_coverageAccountingRoundTrips` — propose (bond locked, TVL cap passed) → guardian approves (exposure recorded, cap checked) → execute (quorum covered) → settle → `reclaimProposerBond` returns the bond → warp past epoch + challenge window → `openExposureUsd` back to zero (budget recycled).
2. `test_batchingAttack_secondApproveReverts` — two vaults, two governors, same guardian: approving drain #2 while drain #1's coverage is open reverts `ExposureCapExceeded` (spec §3.3's netting cap blocks *simultaneous* over-exposure).
3. `test_thinCohortCannotForceExecution` — tier-2 proposal, cohort below `MIN_COHORT_STAKE_AT_OPEN` ⇒ review auto-resolves not-blocked with ZERO approvers ⇒ `executeProposal` reverts `InsufficientApproveCoverage` ⇒ warp past `executeBy` ⇒ state Expired ⇒ bond reclaimable. Suppressing the cohort BLOCKS execution rather than forcing it (spec §3.3a cold-start).
4. `test_woodPriceCrashBetweenApproveAndExecute_blocksExecute` — approve with ample bond, then `setWoodUsdPrice` to 1/10th, execute reverts: quorum re-reads bonds LIVE, so coverage holds in dollars at execute-time (F2 approximation for v1a).
5. `test_boundedTierFlowUnaffected` — tier-1-certified target, zero approvers, executes fine: the optimistic lane the ROE gate depends on is genuinely preserved.

- [ ] **Step 2: Run**

Run: `forge test --match-contract CoverageEndToEnd -vv`
Expected: 5 PASS.

- [ ] **Step 3: Commit**

```bash
git add test/CoverageEndToEnd.t.sol
git commit -m "test: end-to-end coverage lifecycle + batching/cold-start/price-crash adversarial paths"
```

---

### Task 14: Format, full suite, docs, PR

- [ ] **Step 1: Format with the CI-matching forge** (guardrail: fmt rules differ across forge versions; check `.github/workflows/*.yml` for a pinned version FIRST — if CI pins a nightly, fmt with that nightly, not local 1.7.1)

Run: `forge fmt && forge fmt --check`

- [ ] **Step 2: Full suite**

Run: `forge test`
Expected: zero non-fork failures (same pre-existing fork/RPC skips as PR #13).

- [ ] **Step 3: Update the spec's status header** — one sentence in `docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md`: v1a implementation complete (Plans A+B), v1b next (Plan C). Mirror the Plan A precedent.

- [ ] **Step 4: Commit + push + PR**

```bash
git add -A && git commit -m "docs: mark v1a complete in economic-security spec"
git push -u origin feat/guardian-econ-security-b
```

PR body must state: what's in (ledger / quorum / proposer + submitter bonds / covered-TVL cap / factory rewire path), what's deliberately NOT in (compensation escrow, challenge game, bond forfeiture — Plan C; multi-collateral — v2; renewal/wind-down machinery of §3.4a — Plan C), the two launch gates (quorumTierThreshold=2 until the §3.10 ROE validation; sWOOD coolDownPeriod >= 42d before wiring), and the invariant + fuzz table (Tasks 3, 5, 6).

---

## Self-review checklist (run after implementation, before PR)

1. **Spec coverage:** §3.3 exposure cap → Tasks 1, 3, 7. §3.3a quorum + cold-start → Tasks 4, 9, 13. §3.7 covered-TVL cap → Tasks 4, 8. §3.9 proposer bond → Tasks 5, 8, 9. §3.6 submitter bond → Task 6. §3.4a epoch semantics → Task 3. §4 invariant+fuzz rule → Tasks 3, 5, 6. §4 gate 2 (BLOCKING ROE) → threshold default 2, never lowered here. §5 unstake-delay invariant → Task 1 (setter) + Task 12 (pre-flight). LOW-1 / issue #19 → Task 10.
2. **Known deliberate gaps (state them in the PR, never silently ship):**
   - Exposure is released by TIME (epoch + challenge window), not by settle — a settled-early proposal's coverage stays booked until its bucket ages out. Conservative and spec-consistent (that epoch's challenge window is still open).
   - `requiredCoverage` still over-counts multi-call batches (Plan A finding-5 note): the cap is conservative; per-call notional threading is future work.
   - Renewal / renew-before-reveal / forced wind-down (§3.4a) belong with the challenge game — Plan C.
   - The quorum reads approver bonds live at execute, not at slash-time — true slash-time dollar coverage arrives with the challenge game (Plan C); the covered-TVL cap bounds the gap meanwhile.
   - §3.9's last clause ("emergency-settle owner bond scales the same way") is satisfied only approximately: sWOOD's `requiredOwnerBond` is already TVL-scaled (`max(floor, TVL * ownerStakeTvlBps / 10_000)`), which upper-bounds any proposal's coverage but is not coverage-exact. Re-scaling it off `requiredCoverage` touches the live sWOOD bond path and is deferred to Plan C alongside forfeiture; state this in the PR.
3. **Type consistency spot-checks:** `requiredCoverage` is vault-asset units everywhere until it crosses `coverageUsd()`; USD is always 18-dec; `woodUsdPriceX8` 8-dec; `quorumTierThreshold` (uint8) compares against `envelopeTier` (uint8); reviewKey derivation (`keccak256(abi.encode(governor, proposalId))`) is byte-identical in GuardianRegistry, ExposureLedger, and ProposerBondEscrow.
