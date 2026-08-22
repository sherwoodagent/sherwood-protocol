// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioStrategy, ChainlinkReport} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";

/// @notice Minimal Data Streams verifier, echoing the report it is handed.
/// @dev    Added because the anchor requirement at `_execute` (audit finding #6)
///         means a DS-mode fixture must be able to actually VERIFY a report to
///         reach execute at all. `makeAddr("verifier")` is a bare EOA and
///         reverts on `verify`, which was fine only while DS-mode execute
///         silently ran with no anchor — the very thing the requirement removes.
contract MockDsVerifier {
    /// @dev Two arguments, matching the deployed `VerifierProxy 2.0.0`. The
    ///      single-argument 1.x shape this mock used to expose is not on the
    ///      real proxy at all -- calling it there reverts with empty returndata,
    ///      so a one-argument mock would have gone on passing against a
    ///      contract that could never work on chain. `parameterPayload` names
    ///      the fee token when a `FeeManager` is wired; none is, so it is
    ///      ignored here exactly as the live proxy ignores it.
    function verify(bytes calldata signedReport, bytes calldata) external payable returns (bytes memory) {
        (bytes32 feedId, int192 price) = abi.decode(signedReport, (bytes32, int192));
        return abi.encode(
            ChainlinkReport({
                feedId: feedId,
                validFromTimestamp: uint32(block.timestamp),
                observationsTimestamp: uint32(block.timestamp),
                nativeFee: 0,
                linkFee: 0,
                expiresAt: uint32(block.timestamp + 300),
                price: price,
                bid: price,
                ask: price
            })
        );
    }
}

/// @notice Minimal vault stand-in exposing `governor()` — the one hop
///         `_requireAllowedAdapter`/`_requireAllowedPriceSource(s)` and
///         `BaseStrategy.execute()`'s active-proposal check both read off
///         `vault()`. Mirrors `test/audit-181/PortfolioStrategy_oracleBinding.t.sol`'s
///         fixture shape — declared locally rather than imported, since this
///         suite must not depend on a file another agent may be editing.
contract MockVaultWithGovernor {
    /// @dev `BaseStrategy.onlyProposer` re-checks the vault's live agent set on
    ///      every proposer-gated call, so a vault stand-in must answer this or
    ///      `rebalance` / `rebalanceDelta` / `updateParams` all fail closed.
    ///      Stored inverted so the zero default is "still an agent".
    mapping(address => bool) internal _revoked;

    function isAgent(address a) external view returns (bool) {
        return !_revoked[a];
    }

    function setAgent(address a, bool allowed) external {
        _revoked[a] = !allowed;
    }

    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }
}

/// @notice Minimal governor stand-in exposing `tierRegistry()` plus a
///         DELIBERATELY PERMISSIVE `IProposalStatus` pair so `execute()`'s
///         active-proposal binding check (issue #150) passes without
///         per-test proposal wiring — this suite is about the sell/buy
///         floors and the live oracle re-check (Findings A/B/C), not the
///         binding property itself.
contract MockGovernorWithRegistry {
    address public tierRegistry;

    constructor(address registry_) {
        tierRegistry = registry_;
    }

    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function strategyOf(uint256) external view returns (address) {
        return msg.sender;
    }
}

/// @notice Owner-settable per-address allowlist, standing in for TierRegistry.
contract MockTierRegistry {
    mapping(address => bool) public allowed;

    function setAllowed(address a, bool value) external {
        allowed[a] = value;
    }

    function isAdapterAllowed(address a) external view returns (bool) {
        return allowed[a];
    }

    /// @dev The CALLEE axis (`_guardBatchCalls` PART 2a), split out of
    ///      `isAdapterAllowed` per pashov finding #14. Mirrors the adapter axis:
    ///      the demotion asymmetry is exercised against the real registry in
    ///      `test/pashov-final/Registry_demoteKeepsCalleeStanding.t.sol`, so
    ///      mirroring keeps every floors/oracle case here unchanged. Present at
    ///      all because the vault's PART 2a call is TYPED — a stand-in missing
    ///      this selector reverts in the CALLER's frame with empty returndata.
    function isCallableTarget(address a) external view returns (bool) {
        return allowed[a];
    }

    /// @dev Token↔price-source attestation, permissive by default so the
    ///      floors/oracle cases keep testing what they were written for.
    mapping(address => mapping(bytes32 => bool)) public deniedPair;

    function setPriceSourceForToken(address token, bytes32 src, bool allow) external {
        deniedPair[token][src] = !allow;
    }

    function isPriceSourceForToken(address token, bytes32 src) external view returns (bool) {
        return !deniedPair[token][src];
    }
}

/// @notice Configurable AggregatorV3-shaped push feed: settable answer,
///         updatedAt, and decimals (to simulate a post-init proxy upgrade
///         to a different scale — one of the `_tryPushFeedPrice` failure
///         modes Finding A must degrade on rather than revert).
contract MockAggregator {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

/// @title PortfolioStrategy_floorsAndOracle
/// @notice Regression suite for the second-pass audit-181 findings on
///         `PortfolioStrategy`:
///
///   Finding A — `_sellFloor`'s push-mode oracle read must DEGRADE to the
///     quote-anchored floor on a stale/mismatched-decimals/codeless feed,
///     not revert. `settle()` is the only non-emergency exit; a routine
///     equity-feed holiday gap must not strand vault capital behind a
///     revert.
///
///   Finding B — the buy legs (`_execute`, `rebalance`'s re-buy) must be
///     oracle-anchored in push mode via the new `_buyFloor`, not purely
///     quote-anchored — `executeProposal` is permissionless, so a bare
///     `_quoteMinOut` floor let anyone move the pool immediately before
///     triggering execution and unwind the vault's allocation.
///
///   Finding C — the oracle/price-source allowlist binding must be
///     re-checked LIVE on every `rebalance()` / `rebalanceDelta()` call,
///     mirroring the adapter re-check (issue #147), and must NOT be
///     re-checked on `_execute`/`_settle` (same capital-hostage exemption).
///
///   Every test here exercises the failure mode itself (a guard tripping,
///   a stale feed, a revoked registry entry, a manipulated pool at the
///   exact moment of a permissionless call) rather than the happy path.
contract PortfolioStrategy_floorsAndOracleTest is Test {
    PortfolioStrategy public template;

    ERC20Mock public weth;
    ERC20Mock public tsla;

    address public proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18;
    uint256 constant SLIPPAGE_100 = 100; // 1%, comfortably inside [50, 1000]
    uint256 constant START = 10_000_000;
    // Matches `MAX_PUSH_PRICE_AGE` (26 hours) — kept as a local literal so
    // this suite doesn't need visibility into the contract's constant to
    // read; boundary tests below step just past it.
    uint256 constant DEFAULT_MAX_AGE = 26 hours;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        template = new PortfolioStrategy();
        vm.warp(START);
    }

    // ── Helpers ──

    function _clone() internal returns (PortfolioStrategy) {
        return PortfolioStrategy(Clones.clone(address(template)));
    }

    /// @dev Single-token, 100%-weight push-mode basket at a 1:1 (1e18)
    ///      oracle scale — `_tokensToValue`/`_valueToTokens` reduce to the
    ///      identity, so expected minOuts in the tests below are exact,
    ///      literal numbers rather than scaled approximations.
    function _pushModeInitData(address adapter, address feed) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        extra[0] = "";
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 18;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(uint160(feed)));

        return abi.encode(
            address(weth),
            adapter,
            address(0), // push mode
            tokens,
            weights,
            TOTAL_AMOUNT,
            SLIPPAGE_100,
            extra,
            priceDecs,
            feedIds
        );
    }

    /// @dev Same single-token shape in Data Streams mode. `feedIds[0]` is an
    ///      arbitrary non-zero id — the price-source binding check
    ///      (Finding C) runs before any report is ever consumed, so no
    ///      working verifier is needed to exercise it.
    function _dataStreamsInitData(address adapter, address verifier) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        extra[0] = "";
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 18;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(0xBEEF));

        return abi.encode(
            address(weth), adapter, verifier, tokens, weights, TOTAL_AMOUNT, SLIPPAGE_100, extra, priceDecs, feedIds
        );
    }

    /// @dev A real, working `MockSwapAdapter` pre-funded both directions at
    ///      the fair 1:1 rate matching the oracle price used throughout this
    ///      suite (1e18) — individual tests then perturb one direction's
    ///      rate to simulate a moved pool.
    function _deployFundedAdapter() internal returns (MockSwapAdapter adapter) {
        adapter = new MockSwapAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);
        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
    }

    struct Rig {
        PortfolioStrategy strategy;
        MockVaultWithGovernor vault;
        MockTierRegistry registry;
        MockSwapAdapter adapter;
        MockAggregator feed;
    }

    /// @dev Deploys the registry/governor/vault trio, clones, initializes,
    ///      and executes a push-mode strategy against a live, allowlisted,
    ///      fresh feed at the fair 1:1 rate — the common starting point for
    ///      every test below, each of which then perturbs exactly one
    ///      variable (feed staleness, feed decimals, feed code, a swap
    ///      rate, or a registry entry) to hit its target failure mode.
    function _rig() internal returns (Rig memory r) {
        r.adapter = _deployFundedAdapter();
        r.feed = new MockAggregator(18, int256(1e18), START);
        r.registry = new MockTierRegistry();
        r.registry.setAllowed(address(r.adapter), true);
        r.registry.setAllowed(address(r.feed), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(r.registry));
        r.vault = new MockVaultWithGovernor(address(governor));

        r.strategy = _clone();
        weth.mint(address(r.vault), TOTAL_AMOUNT);
        vm.prank(address(r.vault));
        weth.approve(address(r.strategy), type(uint256).max);

        r.strategy.initialize(address(r.vault), proposer, _pushModeInitData(address(r.adapter), address(r.feed)));

        _seedAnchor(r.strategy);
        vm.prank(address(r.vault));
        r.strategy.execute();
    }

    /// @dev Seed the Data Streams price anchor so `_execute` will deploy.
    ///      Permissionless, so no prank. Before the anchor requirement existed
    ///      these fixtures executed with `_lastGoodPrice[0] == 0` and the buy
    ///      floor fell through to `_quoteMinOut` — a quote from the very pool the
    ///      swap was about to hit, which is audit finding #6. One test's comment
    ///      recorded that fallback as expected behaviour; it was the bug.
    ///
    ///      `1e18` is this fixture's fair rate, matching the oracle price the
    ///      suite uses throughout, so the floor binds where the swap lands, and
    ///      the feed id is read off the clone rather than restated here.
    ///
    ///      NO-OP IN PUSH MODE, where `submitPriceReports` correctly refuses: a
    ///      push-mode clone reads its own aggregator and consumes no report.
    ///      Deliberately called from push-mode fixtures too, so a fixture can be
    ///      flipped between modes without its call sites having to follow.
    function _seedAnchor(PortfolioStrategy s_) internal {
        if (s_.chainlinkVerifier() == address(0)) return;
        bytes[] memory reports = new bytes[](1);
        reports[0] = abi.encode(s_.feedIdOf(0), int192(int256(1e18)));
        s_.submitPriceReports(reports);
    }

    // ════════════════════════════════════════════════════════════════════
    // pashov review finding #9 — bounded rebalancing, live proposer standing
    // ════════════════════════════════════════════════════════════════════

    /// @dev FINDING #9a. `maxSlippageBps` bounded ONE swap, but nothing bounded
    ///      how many full-notional round trips the proposer could take, so the
    ///      per-call allowance composed multiplicatively (`1-(1-s)^2N`) over an
    ///      unlimited call count for the whole `strategyDuration`. None of this
    ///      traffic passes `SyndicateVault.executeGovernorBatch`, so neither
    ///      `BatchExecutorLib`'s per-call caps nor the vault's `maxNetOutflow`
    ///      meter ever saw it — the capital is already inside the clone.
    ///      `cumulativeDecayBps` charges the worst case (`2 * maxSlippageBps`
    ///      per full rebalance) and refuses once `MAX_CUMULATIVE_DECAY_BPS` is
    ///      spent. Pre-fix this loop never terminated.
    function test_finding9_rebalanceDecayBudgetIsFinite() public {
        Rig memory r = _rig();

        uint256 perCall = 2 * SLIPPAGE_100;
        uint256 allowed = r.strategy.MAX_CUMULATIVE_DECAY_BPS() / perCall;

        for (uint256 i; i < allowed; ++i) {
            vm.prank(proposer);
            r.strategy.rebalance();
        }
        assertEq(r.strategy.cumulativeDecayBps(), allowed * perCall, "budget accounted exactly");

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.DecayBudgetExhausted.selector);
        r.strategy.rebalance();
    }

    /// @dev FINDING #9b. `_proposer` is written once at `initialize` and was
    ///      never re-validated, while `SyndicateVault.removeAgent` — the
    ///      owner's revocation lever — only deletes `_agents[a]` and reaches no
    ///      already-deployed clone. A de-registered agent therefore kept
    ///      unbounded `rebalance` / `rebalanceDelta` / `updateParams` authority
    ///      over deployed capital for the rest of `strategyDuration`, and the
    ///      owner's only alternatives were demoting the shared swap adapter or
    ///      price feed (blast radius: every strategy on the protocol) or
    ///      waiting for a permissionless settle. `rebalance` already re-checked
    ///      the ADAPTER and the PRICE SOURCES live; the CALLER was the one
    ///      input still trusted from init.
    function test_finding9_removedAgentLosesProposerRightsOnLiveClone() public {
        Rig memory r = _rig();

        vm.prank(proposer);
        r.strategy.rebalance(); // still an agent: ordinary path works

        // The vault owner revokes the agent. That call touches the vault only —
        // the live clone is untouched, which is exactly the gap.
        r.vault.setAgent(proposer, false);

        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.ProposerNoLongerAgent.selector);
        r.strategy.rebalance();
    }

    // ════════════════════════════════════════════════════════════════════
    // Finding A — _sellFloor must degrade, not revert, on a broken push feed
    // ════════════════════════════════════════════════════════════════════

    /// @dev THE core Finding A regression: a routine holiday-weekend feed
    ///      gap (feed age past `MAX_PUSH_PRICE_AGE`) at settle time must NOT
    ///      strand vault capital behind `StalePrice`. Pre-fix, `_sellFloor`
    ///      called the hard-reverting `_pushFeedPrice` and `settle()` would
    ///      revert here, with no non-emergency recovery path. Post-fix, the
    ///      non-reverting `_tryPushFeedPrice` reports `ok == false` and
    ///      `_sellFloor` falls back to the quote-anchored floor, so the swap
    ///      still clears and the vault gets its asset back.
    function test_settle_survivesStalePushFeed_capitalNotStranded() public {
        Rig memory r = _rig();
        assertEq(tsla.balanceOf(address(r.strategy)), TOTAL_AMOUNT, "execute should have filled 1:1");

        // Feed goes stale: last update far older than the default 26h max age.
        r.feed.setUpdatedAt(START - DEFAULT_MAX_AGE - 1 hours);
        vm.warp(START + 1); // keep block.timestamp fixed at a sane value

        uint256 vaultWethBefore = weth.balanceOf(address(r.vault));

        vm.prank(address(r.vault));
        r.strategy.settle(); // must NOT revert StalePrice

        assertEq(tsla.balanceOf(address(r.strategy)), 0, "settle should have sold the whole position");
        assertEq(weth.balanceOf(address(r.vault)), vaultWethBefore + TOTAL_AMOUNT, "capital must return to the vault");
        assertEq(uint256(r.strategy.state()), uint256(BaseStrategy.State.Settled));
    }

    /// @dev Sibling path (FAILURE MODE 1 in the audit brief): `rebalance()`'s
    ///      sell leg calls the SAME `_sellFloor` as `_settle`. Fixing
    ///      `_sellFloor` in one place must fix both call sites — this proves
    ///      it does, independent of the settle-specific test above.
    function test_rebalance_sellLeg_survivesStalePushFeed() public {
        Rig memory r = _rig();

        r.feed.setUpdatedAt(START - DEFAULT_MAX_AGE - 1 hours);
        vm.warp(START + 1);

        vm.prank(proposer);
        r.strategy.rebalance(); // must NOT revert StalePrice

        assertEq(uint256(r.strategy.state()), uint256(BaseStrategy.State.Executed));
    }

    /// @dev Boundary case named explicitly in Finding A: a codeless feed
    ///      (e.g. a proxy that was later destroyed / never redeployed at
    ///      that address). Solidity's high-level call to an interface with
    ///      declared return values reverts on a codeless target, which
    ///      `_tryPushFeedPrice`'s try/catch must convert into `ok == false`,
    ///      not propagate.
    function test_settle_survivesCodelessFeed_capitalNotStranded() public {
        Rig memory r = _rig();

        vm.etch(address(r.feed), ""); // feed contract "disappears"

        uint256 vaultWethBefore = weth.balanceOf(address(r.vault));
        vm.prank(address(r.vault));
        r.strategy.settle(); // must NOT revert
        assertEq(weth.balanceOf(address(r.vault)), vaultWethBefore + TOTAL_AMOUNT);
    }

    /// @dev Second boundary named in Finding A: a feed mid-proxy-upgrade
    ///      reporting different decimals than declared at init. Same
    ///      requirement — degrade, don't revert, at settle.
    function test_settle_survivesDecimalsMismatch_capitalNotStranded() public {
        Rig memory r = _rig();

        r.feed.setDecimals(8); // was 18 at init; simulates a live proxy upgrade

        uint256 vaultWethBefore = weth.balanceOf(address(r.vault));
        vm.prank(address(r.vault));
        r.strategy.settle(); // must NOT revert InvalidPriceDecimals
        assertEq(weth.balanceOf(address(r.vault)), vaultWethBefore + TOTAL_AMOUNT);
    }

    /// @dev THE BOUNDARY SECOND, made observable — REWRITTEN for pashov review
    ///      finding #4. This test used to assert that one tick past
    ///      `MAX_PUSH_PRICE_AGE` the SAME manipulated pool was ALLOWED
    ///      through, via the quote-anchored fallback. That allowance WAS the
    ///      finding: the fallback derives `minOut` from a quote taken in the
    ///      same transaction against the very pool the swap is about to hit,
    ///      so `maxSlippageBps` bounded drift from a price the attacker had
    ///      just set. `_sellFloor` now falls back to the last price this
    ///      contract itself observed from the allowlisted feed —
    ///      attacker-independent however stale — so BOTH sides of the boundary
    ///      reject the manipulation.
    ///
    ///      `test_sellFloor_staleAnchor_stillClearsUnmanipulated` below pins
    ///      the other half, which is why this is not simply a fail-closed
    ///      change: a stale feed must still let an HONEST settle through, or
    ///      capital is stranded for the length of the outage.
    function test_sellFloor_boundary_freshAndStaleBothRejectManipulation() public {
        // ── Fresh side: oracle floor rejects a pool moved to half price ──
        Rig memory rFresh = _rig();
        rFresh.adapter.setRate(address(tsla), address(weth), 0.5e18); // pool moved 2x against the vault
        // Oracle price still 1e18 → minOut ≈ 9.9e18; manipulated output ≈ 5e18.
        vm.prank(address(rFresh.vault));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        rFresh.strategy.settle();

        // ── Stale side: same manipulation, one tick past the max age ──
        Rig memory rStale = _rig();
        rStale.adapter.setRate(address(tsla), address(weth), 0.5e18);
        rStale.feed.setUpdatedAt(START - DEFAULT_MAX_AGE - 1);
        vm.warp(START + 1);
        // Post-finding-#4: the stale branch no longer quotes the pool it is
        // about to trade. It anchors to the last price observed from the feed
        // during execute, which the manipulation cannot move, so the same 2x
        // pool move is rejected here exactly as on the fresh side above.
        vm.prank(address(rStale.vault));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        rStale.strategy.settle();
    }

    /// @dev The liveness half of finding #4, and the reason the fix is a
    ///      stale-price ANCHOR rather than a fail-closed revert. With the feed
    ///      one tick past its max age and the pool NOT manipulated, settle must
    ///      still clear — otherwise a routine equity-feed gap (this contract's
    ///      own `MAX_PUSH_PRICE_AGE` notes 77h over holiday weekends) would
    ///      strand the vault's capital for the length of the outage.
    function test_sellFloor_staleAnchor_stillClearsUnmanipulated() public {
        Rig memory r = _rig();
        r.feed.setUpdatedAt(START - DEFAULT_MAX_AGE - 1);
        vm.warp(START + 1);

        uint256 vaultWethBefore = weth.balanceOf(address(r.vault));
        vm.prank(address(r.vault));
        r.strategy.settle();
        assertGt(weth.balanceOf(address(r.vault)), vaultWethBefore, "honest settle must still clear once stale");
    }

    /// @notice PR #195 re-review: the stale band must widen with the ANCHOR'S
    ///         AGE, or a long outage plus an honest gap move strands capital.
    /// @dev    `test_sellFloor_staleAnchor_stillClearsUnmanipulated` above only
    ///         exercises an UNMOVED pool, so it cannot see this. A fixed
    ///         `STALE_PRICE_SLIPPAGE_BPS` of 1,000 cannot tell a manipulation
    ///         from a real move, and `_sellFloor` sits on `_settle()` — the only
    ///         exit. An equity feed dark for a week (this contract's own
    ///         `MAX_PUSH_PRICE_AGE` documents 77h holiday gaps) plus an
    ///         earnings gap past 10% made every swap revert on its floor, with
    ///         no lever to widen it: `STALE_PRICE_SLIPPAGE_BPS` is a constant,
    ///         and finding #9's live `isAgent` re-check can strip the proposer
    ///         of `updateParams` too. That is fail-closed on the exit path,
    ///         which is the outcome finding #4's fix set out to avoid.
    ///
    ///         Both halves are asserted together because the widening is only
    ///         correct if the ceiling stays binding: an attacker who simply
    ///         waits out the whole ramp must still be rejected.
    function test_reviewItem2_staleBandWidensWithAnchorAge_gapSettlesManipulationDoesNot() public {
        // BOTH RIGS BUILT BEFORE THE WARP, and this ordering is load-bearing.
        // `_rig()` hardcodes its feed's `updatedAt` to `START`, so a rig
        // constructed after the warp executes against an already-stale feed,
        // records NO anchor, and falls through to `_quoteMinOut` — the
        // never-priced path, not the stale-anchor path this test is about.
        // Each rig owns its own adapter and feed, so they do not interfere.
        // (Built forward-only: `vm.warp` backwards is a no-op on forge 1.7.1.)
        Rig memory rGap = _rig();
        Rig memory rAttack = _rig();

        // Both anchors were taken at `START` by `execute`. Age them past the
        // full ramp, with the feeds left dark throughout.
        vm.warp(START + 7 days + 1);

        // ── Liveness: a genuine 20% gap clears once the anchor is fully aged ──
        // The market really moved — the pool now pays 0.8 WETH per TSLA. At the
        // fully-ramped 3,000 bps band the floor is 0.70x and this clears; at the
        // old fixed 1,000 bps band the floor is 0.90x and `settle()` reverts,
        // stranding the position for the length of the outage.
        rGap.adapter.setRate(address(tsla), address(weth), 0.8e18);

        uint256 vaultWethBefore = weth.balanceOf(address(rGap.vault));
        vm.prank(address(rGap.vault));
        rGap.strategy.settle();
        assertEq(tsla.balanceOf(address(rGap.strategy)), 0, "an honest gap move must not strand the position");
        assertGt(weth.balanceOf(address(rGap.vault)), vaultWethBefore, "capital must return to the vault");

        // ── Security: waiting out the ramp does NOT buy an unbounded take ──
        // Same fully-aged anchor, but the pool is pushed 2x against the vault.
        // 0.50x is past even the `MAX_STALE_SLIPPAGE_BPS` floor of 0.70x, so the
        // anchor still binds — the band widens, it never stops applying.
        rAttack.adapter.setRate(address(tsla), address(weth), 0.5e18);

        vm.prank(address(rAttack.vault));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        rAttack.strategy.settle();
    }

    // ════════════════════════════════════════════════════════════════════
    // Finding B — buy legs must be oracle-anchored in push mode
    // ════════════════════════════════════════════════════════════════════

    /// @dev THE core Finding B regression, traced exactly as in the audit
    ///      brief: `executeProposal` is permissionless, so an attacker can
    ///      move the pool immediately before anyone triggers `execute()`
    ///      and unwind the vault's whole allocation against their own
    ///      quote. Pre-fix, `_execute` derived `minOut` purely from
    ///      `_quoteMinOut`, which reads the SAME manipulated rate as the
    ///      swap — so the attack sailed through undetected. Post-fix,
    ///      `_buyFloor` anchors to the oracle price instead, and the
    ///      manipulated swap must revert.
    function test_execute_buyLeg_revertsOnPoolManipulatedBeforeExecute() public {
        MockSwapAdapter adapter = _deployFundedAdapter();
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        registry.setAllowed(address(feed), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();
        weth.mint(address(vault), TOTAL_AMOUNT);
        vm.prank(address(vault));
        weth.approve(address(strategy), type(uint256).max);
        strategy.initialize(address(vault), proposer, _pushModeInitData(address(adapter), address(feed)));

        // Attacker moves the pool 100x against the vault immediately before
        // execute() is triggered (permissionless in production).
        adapter.setRate(address(weth), address(tsla), 0.01e18);

        _seedAnchor(strategy);
        vm.prank(address(vault));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        strategy.execute();
    }

    /// @dev Sibling path (FAILURE MODE 1): `rebalance()`'s re-buy leg must
    ///      get the SAME protection as `_execute`'s buy leg — it's a
    ///      distinct call site that used bare `_quoteMinOut` before this
    ///      fix. Sell leg runs at the (unperturbed) fair rate so it clears
    ///      normally; only the re-buy leg's rate is manipulated, isolating
    ///      exactly the code path Finding B targets.
    function test_rebalance_reBuyLeg_revertsOnPoolManipulated() public {
        Rig memory r = _rig(); // fair rates both directions, holds TOTAL_AMOUNT tsla

        // Manipulate only the buy-side rate; sell-side stays fair so the
        // sell leg (already covered by Finding A's tests) clears normally.
        r.adapter.setRate(address(weth), address(tsla), 0.01e18);

        vm.prank(proposer);
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        r.strategy.rebalance();
    }

    // ════════════════════════════════════════════════════════════════════
    // Finding C — price source must be re-validated live on every rebalance
    // ════════════════════════════════════════════════════════════════════

    /// @dev THE core Finding C regression: a feed that was allowlisted at
    ///      init and later demoted/revoked in the `TierRegistry` must block
    ///      further `rebalance()` calls, exactly like a demoted swap
    ///      adapter already does (issue #147). Pre-fix,
    ///      `_requireAllowedPriceSource` was called only from `_initialize`
    ///      — the revoked feed would have kept anchoring every subsequent
    ///      rebalance for the strategy's lifetime.
    function test_rebalance_revertsWhenPriceSourceRevokedPostExecute() public {
        Rig memory r = _rig();
        r.registry.setAllowed(address(r.feed), false); // governance revokes the feed

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.PriceSourceNotAllowed.selector, address(r.feed), address(r.registry)
            )
        );
        r.strategy.rebalance();
    }

    /// @dev Sibling path: `rebalanceDelta` gets the identical live re-check.
    function test_rebalanceDelta_revertsWhenPriceSourceRevokedPostExecute() public {
        Rig memory r = _rig();
        r.registry.setAllowed(address(r.feed), false);

        bytes[] memory reports = new bytes[](1);
        reports[0] = "";
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.PriceSourceNotAllowed.selector, address(r.feed), address(r.registry)
            )
        );
        r.strategy.rebalanceDelta(reports);
    }

    /// @dev Data Streams mode: `_requireAllowedPriceSources`'s OTHER branch
    ///      (single `chainlinkVerifier` check instead of a per-slot loop)
    ///      must be exercised too — a revoked verifier must block
    ///      `rebalanceDelta` the same way a revoked push feed does above.
    function test_rebalanceDelta_revertsWhenVerifierRevoked_dataStreamsMode() public {
        MockSwapAdapter adapter = _deployFundedAdapter();
        address verifier = address(new MockDsVerifier());
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        registry.setAllowed(verifier, true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();
        weth.mint(address(vault), TOTAL_AMOUNT);
        vm.prank(address(vault));
        weth.approve(address(strategy), type(uint256).max);
        strategy.initialize(address(vault), proposer, _dataStreamsInitData(address(adapter), verifier));

        // The buy leg is now ORACLE-anchored, not pool-quoted. This line used to
        // read "Data Streams buy leg falls back to _quoteMinOut; fair rate fills
        // fine" — which was audit finding #6 recorded as expected behaviour: with
        // no anchor the floor came from a quote against the very pool the swap
        // was about to hit, and it only "filled fine" because this fixture's
        // adapter quotes honestly.
        _seedAnchor(strategy);
        vm.prank(address(vault));
        strategy.execute();

        registry.setAllowed(verifier, false); // governance revokes the verifier post-execute

        bytes[] memory reports = new bytes[](1);
        reports[0] = abi.encode(bytes32(uint256(0xBEEF)), int192(1e18)); // never reached — check trips first
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.PriceSourceNotAllowed.selector, verifier, address(registry))
        );
        strategy.rebalanceDelta(reports);
    }

    /// @dev The exemption half of Finding C, proven directly rather than
    ///      merely asserted: with the SAME feed revoked as in the
    ///      `rebalance()` test above, `settle()` must remain the untouched
    ///      exit path — capital must still come back. This is exactly the
    ///      invariant `_requireAllowedAdapter`'s natspec claims ("blocking a
    ///      rebalance strands nothing — settle() remains the untouched exit
    ///      path either way") and Finding C explicitly extends to the
    ///      oracle binding.
    function test_settle_untouchedByPriceSourceRevocation() public {
        Rig memory r = _rig();
        r.registry.setAllowed(address(r.feed), false); // same revocation as the blocked-rebalance test

        uint256 vaultWethBefore = weth.balanceOf(address(r.vault));
        vm.prank(address(r.vault));
        r.strategy.settle(); // must NOT revert PriceSourceNotAllowed
        assertEq(weth.balanceOf(address(r.vault)), vaultWethBefore + TOTAL_AMOUNT);
    }
}
