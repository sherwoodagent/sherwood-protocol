// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";

/// @dev Minimal sWOOD stub exposing exactly the reads the ledger consumes.
///      Live-basis only (`slashableStakeAt` mirrors live stake) — none of
///      these tests exercise the anchor machinery (issue #35), which is
///      already covered by `test/audit-181/ExposureLedger_anchorAndRetire.t.sol`.
contract MockSwood {
    mapping(address => uint256) public guardianStake;
    uint256 public coolDownPeriod = 45 days;

    function setStake(address g, uint256 own) external {
        guardianStake[g] = own;
    }

    function slashableStakeAt(address g, uint256) external view returns (uint256) {
        return guardianStake[g];
    }
}

/// @dev Ordinary Chainlink-shaped asset feed, flat answer.
contract MockFeed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Answers `decimals()` honestly (so `setWoodFeed`/`setAssetFeed` can be
///      driven with whatever value a test wants to probe the
///      `MAX_FEED_DECIMALS` ceiling with) and nothing else — `latestRoundData`
///      is never meant to be reached by a test using this mock, since the
///      whole point is that the write-time bound refuses to wire it at all.
contract HighDecimalsFeed {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, 1, 1, 1);
    }
}

/// @dev A wired, otherwise-healthy Chainlink aggregator (`decimals()` answers
///      normally, within bound) whose `latestRoundData()` returns too few
///      words to decode — ONE word (32 bytes) where the tuple `(uint80,
///      int256, uint256, uint256, uint80)` needs five (160 bytes). Mirrors
///      the ledger's own defensive read, for the same reason: a typed
///      `try ... returns (...)`
///      does not route a return-data decode failure through `catch` — it is
///      an uncaught, full revert of the transaction (Solidity's own
///      documented limitation) — so a defensive reader must reject the
///      length itself, BEFORE attempting to decode, via a raw staticcall.
contract ShortReturnAggregator {
    uint8 public constant decimals = 8;

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}

contract MockVaultForLedger {
    address internal _asset;
    bool public revertOnAsset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function setRevertOnAsset(bool r) external {
        revertOnAsset = r;
    }

    function asset() external view returns (address) {
        if (revertOnAsset) revert("vault: asset unavailable");
        return _asset;
    }
}

/// @dev Single-proposal-shaped governor stub (state is global, not keyed on
///      `proposalId` — reconfigure immediately before each call, mirroring
///      `test/ExposureLedger.t.sol`'s own `MockGovernorForLedger`).
///      `revertOnRequiredCoverage` is the whole point of this file's finding
///      23 coverage: a governor whose `getRequiredCoverage` reverts is
///      exactly the "arms the moment that getter gains a reverting path"
///      scenario `_tryResolveCoverageInputs`'s natspec describes.
contract MockGovernorForLedger {
    address public vaultAddr;
    uint256 public coverage;
    uint256 public executeBy;
    uint256 public strategyDuration;
    uint256 public executedAt;
    bool public revertOnRequiredCoverage;

    constructor(address vault_) {
        vaultAddr = vault_;
    }

    function set(uint256 coverage_) external {
        coverage = coverage_;
    }

    function setSchedule(uint256 executeBy_, uint256 duration_) external {
        executeBy = executeBy_;
        strategyDuration = duration_;
    }

    function setRevertOnRequiredCoverage(bool r) external {
        revertOnRequiredCoverage = r;
    }

    function getRequiredCoverage(uint256) external view returns (uint256) {
        if (revertOnRequiredCoverage) revert("governor: required coverage unavailable");
        return coverage;
    }

    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
        uint256 executeBy;
        uint256 strategyDuration;
        uint256 executedAt;
    }

    function getProposalView(uint256) external view returns (ProposalViewLite memory v) {
        v.vault = vaultAddr;
        v.executeBy = executeBy;
        v.strategyDuration = strategyDuration;
        v.reviewEnd = executeBy;
        v.executedAt = executedAt;
    }
}

/// @title ExposureLedger_priceAndScope
/// @notice Regression coverage for audit #181 findings 22 and 23.
///
/// @dev    FINDING 22 (`test_setWoodFeed_...`, `test_setAssetFeed_...`,
///         `test_woodPriceX8_fallsThroughToTwap_...`): `_feedPriceX8` used to
///         normalise a Chainlink answer INSIDE a typed `try`'s success block
///         (`(uint256(answer) * 1e8) / (10 ** f.feedDecimals)`), which is
///         ordinary caller-frame code once the call has returned — NOT
///         protected by the sibling `catch`. Two concrete ways that took the
///         whole price path down instead of falling through to the TWAP:
///         (a) `setWoodFeed`/`setAssetFeed` read `feedDecimals` from the feed
///         with no upper bound, so `feedDecimals >= 78` panics `10 **
///         feedDecimals` (0x11); (b) a typed `try` does not catch an
///         ABI-decode failure on the RETURN value either (Solidity's own
///         documented limitation), so malformed/short `latestRoundData()`
///         data reverted uncatchably. Fixed by bounding `feedDecimals` at
///         write time (`MAX_FEED_DECIMALS`, both setters) and by rewriting
///         `_feedPriceX8` to a raw staticcall with an explicit length check
///         before decoding.
///
///         FINDING 23 (`test_recordApproval_...`): `recordApproval` (and the
///         since-deleted `settleCoverage`) used to write the equivalent of `try this.coverageUsd(IVaultAssetMinimal(pv.vault)
///         .asset(), gov.getRequiredCoverage(proposalId)) returns (...) {
///         ... } catch { ... }`. Solidity evaluates a call's ARGUMENTS in the
///         caller's frame, before the call the `try` actually guards, so a
///         revert from either the vault's `asset()` or the governor's
///         `getRequiredCoverage` propagated straight past the `catch` —
///         reverting the whole APPROVE vote instead of locking nothing,
///         exactly the failure mode the function's own natspec says must never
///         happen. Fixed by hoisting both reads into their own try/catch in
///         `_tryResolveCoverageInputs`, called ahead of the `coverageUsd` try
///         the caller still performs. The `settleCoverage` half of the finding
///         went with the function itself (declared coverage locks).
contract ExposureLedgerPriceAndScopeTest is Test {
    ExposureLedger internal ledger;
    MockSwood internal swood;
    MockAggregatorV3 internal woodFeed;
    MockGovernorForLedger internal mgov;
    MockVaultForLedger internal vault;
    address internal usdgAsset;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal registry = makeAddr("registry");

    // $2.00 market, cap 2x above (non-binding).
    uint256 internal constant MARKET_X8 = 2e8;
    uint256 internal constant CAP_X8 = 4e8;

    function setUp() public {
        swood = new MockSwood();
        ledger = new ExposureLedger(owner, address(swood), 28 days);
        woodFeed = new MockAggregatorV3(8, int256(MARKET_X8));

        usdgAsset = makeAddr("usdgAsset");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockFeed assetFeed = new MockFeed(1e8, 8); // $1.00/unit, 8-dec feed
        vault = new MockVaultForLedger(usdgAsset);
        mgov = new MockGovernorForLedger(address(vault));

        vm.startPrank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        // The mock publishes one round at construction and these suites warp far
        // past it; staleness is exercised in test/ExposureLedger.t.sol.
        ledger.setWoodFeed(address(woodFeed), type(uint64).max);
        ledger.setAssetFeed(usdgAsset, address(assetFeed), 365 days);
        ledger.setGuardianRegistry(registry);
        vm.stopPrank();

        assertEq(ledger.woodPriceX8(), MARKET_X8, "fixture must price off the market, not the cap");
    }

    /// @dev USDG (6-dec) amount that prices to exactly `usd18` at the fixture's
    ///      flat $1.00 asset feed.
    function _requiredCoverage6(uint256 usd18) internal pure returns (uint256) {
        return usd18 / 1e12;
    }

    // ══════════════════════════════════════════════════════════════════
    // FINDING 22 — feed-decimals overflow and uncatchable decode failures
    // ══════════════════════════════════════════════════════════════════

    /// @notice `setWoodFeed` must refuse a feed reporting `feedDecimals` above
    ///         the ceiling, rather than storing it and letting `_feedPriceX8`
    ///         panic on every subsequent read.
    ///
    ///         Fails against the pre-fix code (no bound existed, so wiring
    ///         succeeds and `vm.expectRevert` sees no revert), passes against
    ///         the fix.
    function test_setWoodFeed_rejectsFeedDecimalsAboveCeiling() public {
        HighDecimalsFeed bad = new HighDecimalsFeed(19); // one above the 18 ceiling
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodFeed(address(bad), 1 days);
    }

    /// @notice The ceiling itself must still be wireable — this is a bound,
    ///         not an accidental rejection of every legitimate feed.
    function test_setWoodFeed_acceptsFeedDecimalsAtCeiling() public {
        HighDecimalsFeed ok = new HighDecimalsFeed(18);
        vm.prank(owner);
        ledger.setWoodFeed(address(ok), 1 days); // must not revert
    }

    /// @notice The identical overflow reachable through `setAssetFeed` /
    ///         `coverageUsd` (audit #181 finding 22's second half) must be
    ///         refused the same way.
    ///
    ///         Fails against the pre-fix code, passes against the fix.
    function test_setAssetFeed_rejectsFeedDecimalsAboveCeiling() public {
        HighDecimalsFeed bad = new HighDecimalsFeed(19);
        address someAsset = makeAddr("someOtherAsset");
        vm.mockCall(someAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setAssetFeed(someAsset, address(bad), 1 days);
    }

    /// @notice A wired-but-malformed WOOD feed (too little `latestRoundData`
    ///         return data to decode) must resolve to the ledger's own
    ///         `NoWoodPrice`, not to an undecodable revert bubbled out of the
    ///         decoder.
    ///
    ///         The typed `try IAggregatorMinimal(feed).latestRoundData()
    ///         returns (...)` does not catch a return-data ABI-decode failure
    ///         (an uncatchable, full revert per Solidity's own documented
    ///         behaviour), so the read must reject the short return by LENGTH
    ///         before attempting to decode it.
    function test_woodPriceX8_isNoWoodPrice_onShortReturnFeedData() public {
        ShortReturnAggregator badFeed = new ShortReturnAggregator();
        vm.prank(owner);
        ledger.setWoodFeed(address(badFeed), 1 days); // decimals() == 8, within bound: wires cleanly

        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }

    // ══════════════════════════════════════════════════════════════════
    // FINDING 23 — inline try-argument evaluation escapes the guard
    // ══════════════════════════════════════════════════════════════════

    /// @notice A governor whose `getRequiredCoverage` reverts must make
    ///         `recordApproval` book nothing, not revert the whole APPROVE
    ///         vote.
    ///
    ///         Fails against the pre-fix code: `gov.getRequiredCoverage(...)`
    ///         sat as an ARGUMENT to `this.coverageUsd(...)`, evaluated in
    ///         `recordApproval`'s own frame before the guarded call even
    ///         began, so its revert propagated straight out of
    ///         `recordApproval` and this call reverts unexpectedly. Passes
    ///         against the fix, which resolves the read through its own
    ///         try/catch first.
    function test_recordApproval_requiredCoverageReverts_booksNothingInsteadOfReverting() public {
        uint256 proposalId = 1;
        mgov.setRevertOnRequiredCoverage(true);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), proposalId, guardian, type(uint256).max);

        (address[] memory approvers,) = ledger.pledgedOf(address(mgov), proposalId);
        assertEq(approvers.length, 0, "guardian must not be booked when required coverage is unreadable");
    }

    /// @notice The other hoisted read: a vault whose `asset()` reverts must
    ///         likewise make `recordApproval` book nothing rather than revert.
    ///
    ///         Fails against the pre-fix code (`IVaultAssetMinimal(pv.vault)
    ///         .asset()` was called, unguarded, before the try even started),
    ///         passes against the fix.
    function test_recordApproval_vaultAssetReverts_booksNothingInsteadOfReverting() public {
        uint256 proposalId = 2;
        vault.setRevertOnAsset(true);
        mgov.set(_requiredCoverage6(1_000e18));

        vm.prank(registry);
        ledger.recordApproval(address(mgov), proposalId, guardian, type(uint256).max);

        (address[] memory approvers,) = ledger.pledgedOf(address(mgov), proposalId);
        assertEq(approvers.length, 0, "guardian must not be booked when the vault's asset() is unreadable");
    }
}
