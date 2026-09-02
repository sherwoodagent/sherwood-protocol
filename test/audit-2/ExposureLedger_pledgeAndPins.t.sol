// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {MockWoodTwapOracle} from "test/mocks/MockWoodTwapOracle.sol";
import {MockCoverageFreezer} from "test/mocks/MockCoverageFreezer.sol";

/// @dev Minimal sWOOD stub. Every proposal in this file stays UNEXECUTED
///      (`executedAt` never set away from its 0 default), so every
///      `_slashableBondUsd` call in the paths under test resolves through the
///      `anchor == 0` branch, which reads `guardianStake` directly rather than
///      `slashableStakeAt` — the checkpoint precision `MockSwoodAnchored`
///      (test/audit-181) exists for is therefore not needed here.
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

contract MockAssetFeed {
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

contract MockVaultForLedger {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

/// @dev Single-proposal-shaped governor stub (state is global, not keyed by
///      `proposalId` — reconfigure before each `recordApproval` call when
///      booking more than one proposal on the same instance).
contract MockGovernorForLedger {
    address public vaultAddr;
    uint256 public coverage;
    uint256 public executeBy;
    uint256 public strategyDuration;
    uint256 public executedAt;

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

    function getRequiredCoverage(uint256) external view returns (uint256) {
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
        v.executedAt = executedAt;
    }
}

/// @dev Stands in for `ChallengeGame`'s own `challengeWindow` state variable —
///      `coverageFreezer` IS the game address, and finding D's mirrored check
///      in `ExposureLedger.setChallengeWindow` reads exactly this selector.
contract MockChallengeGameWindow {
    uint256 public challengeWindow;

    constructor(uint256 window_) {
        challengeWindow = window_;
    }
}

/// @title ExposureLedger_pledgeAndPins
/// @notice Regression coverage for audit-181-critical-high findings A-D plus
///         the standalone `_feedPriceX8` zero-truncation finding, all on
///         functions the PRIOR remediation pass touched (freezeCoverage,
///         pinCoverageUntil, retireApproval, hasFrozenCoverage,
///         setChallengeWindow, _feedPriceX8).
///
/// @dev    FINDING A (`test_freezeAndPin_reachAGuardianWhoseStakeCollapsed`):
///         `freezeCoverage` and `pinCoverageUntil` gated on the LIVE BOOKING,
///         which the permissionless, deliberately-not-freeze-gated
///         `settleCoverage` could rewrite to zero while the PLEDGE and the
///         `_approversOf` listing survived. A guardian whose booking transited
///         through zero was therefore never counted into
///         `_frozenCommitments`, so `hasFrozenCoverage` — the gate
///         `StakedWood.claimUnstakeGuardian` reads — came back clean while
///         the accusation naming them was still live. Fixed by gating both
///         loops on the pledge. Declared coverage locks then collapsed booking
///         and pledge into ONE lock and deleted `settleCoverage`, so the
///         divergence can no longer be produced at all; what survives here is
///         the property the fix was defending — a guardian whose STAKE has
///         collapsed to nothing, with its lock still live, is still frozen,
///         pinned and named by `slashBpsFor`, because every one of those reads
///         the lock and none reads the stake.
///
///         FINDING B (`test_pinCoverageUntil_boundaryIsInclusiveOfDeadline`):
///         `ChallengeGame.file` refuses a filing only STRICTLY past its
///         deadline (`if (block.timestamp > deadline) revert`) — inclusive of
///         the deadline second. `retireApproval` and `hasFrozenCoverage` read
///         the pin EXCLUSIVE of it (`> block.timestamp`), so both opened one
///         second before filing actually closed. Fixed with `>=` on both
///         reads.
///
///         FINDING C (`test_retireApproval_notBlockedByAPinOnAnUnrelatedProposal`):
///         `_pinnedCoverageUntil` is a per-GUARDIAN max, correct for
///         `hasFrozenCoverage`'s binary unstake question but wrong as
///         `retireApproval`'s per-proposal gate: one grindable non-verdict on
///         ANY single stale proposal blocked retirement of a guardian's
///         ENTIRE book. Fixed by adding a per-(reviewKey, guardian) pin
///         (`_pinnedUntil`) that `retireApproval` reads instead, written by
///         `pinCoverageUntil` alongside the existing per-guardian max.
///
///         FINDING D (`test_setChallengeWindow_cannotShrinkBelowTheWiredGameWindow`):
///         `ChallengeGame` enforces `game.challengeWindow <=
///         ledger.challengeWindow()` in three places, none of which re-fire
///         when the LEDGER's window shrinks afterward. Fixed by mirroring the
///         check back in `setChallengeWindow` against `coverageFreezer`
///         (which IS the game address).
///
///         CAUTION RESOLUTION (`test_setChallengeWindow_toleratesACodelessGuardianRegistry`):
///         `setGuardianRegistry` admits a registry TOLERANTLY (codeless or
///         reverting `reviewPeriod()` is let through); `setChallengeWindow`
///         used to read that same pointer STRICTLY, so a registry the
///         tolerant setter admitted permanently bricked this setter. Both
///         sides now use the identical tolerant `code.length` + try/catch
///         shape.
///
///         ALSO (`test_feedPriceX8_truncatingToZeroFallsThroughToTwap`):
///         `_feedPriceX8` could return `(0, true)` — a positive answer
///         truncating to zero at 18 decimals — reporting the feed HEALTHY at
///         a price of zero, skipping the TWAP fallback, and silently
///         resolving `woodPriceX8()` to 0 rather than reverting or falling
///         through. Fixed to report `ok = priceX8 != 0`.
contract ExposureLedgerPledgeAndPinsTest is Test {
    ExposureLedger internal ledger;
    MockSwood internal swood;
    MockWoodTwapOracle internal twap;
    MockGovernorForLedger internal mgov;
    address internal usdgAsset;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal registry = makeAddr("registry"); // deliberately codeless
    // SHE-214: a freezer must answer `challengeWindow()` to wire; a low window so
    // no test that lowers the ledger's window trips the game-side floor.
    address internal freezer = address(new MockCoverageFreezer(1 days));

    uint256 internal constant MARKET_X8 = 2e8; // $2.00/WOOD
    uint256 internal constant CAP_X8 = 4e8; // 2x above market, non-binding

    function setUp() public {
        swood = new MockSwood();
        ledger = new ExposureLedger(owner, address(swood), 28 days);
        twap = new MockWoodTwapOracle(MARKET_X8);

        usdgAsset = makeAddr("usdgAsset");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockAssetFeed assetFeed = new MockAssetFeed(1e8, 8); // $1.00/unit, 8-dec feed
        MockVaultForLedger vault = new MockVaultForLedger(usdgAsset);
        mgov = new MockGovernorForLedger(address(vault));

        vm.startPrank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        ledger.setWoodTwapOracle(address(twap));
        ledger.setAssetFeed(usdgAsset, address(assetFeed), 365 days);
        ledger.setGuardianRegistry(registry);
        ledger.setCoverageFreezer(freezer);
        vm.stopPrank();

        assertEq(ledger.woodPriceX8(), MARKET_X8, "fixture must price off the market, not the cap");
    }

    /// @dev USDG (6-dec) amount that prices to exactly `usd18` at the
    ///      fixture's flat $1.00 asset feed.
    function _requiredCoverage6(uint256 usd18) internal pure returns (uint256) {
        return usd18 / 1e12;
    }

    // ══════════════════════════════════════════════════════════════════
    // FINDING A — freezeCoverage/pinCoverageUntil must count a guardian
    // whose live booking transited through zero
    // ══════════════════════════════════════════════════════════════════

    /// @notice A guardian whose bond evaporates entirely — unstaked, or
    ///         slashed on an unrelated conviction — while its lock is still
    ///         live must still be counted by `freezeCoverage`, raised by
    ///         `pinCoverageUntil` and named by `slashBpsFor` (at the saturated
    ///         rate: the lock exceeds a zero basis). All three read the LOCK,
    ///         and nothing about the stake can move a lock.
    ///
    ///         The original finding-A fixture reached the same end state
    ///         through `settleCoverage` writing the booking to zero; that path
    ///         no longer exists, and this is the surviving one.
    function test_freezeAndPin_reachAGuardianWhoseStakeCollapsed() public {
        address g2 = makeAddr("g2");
        // 5,000e18 WOOD @ $2.00 = $10,000 slashable each — exactly the full
        // $10,000 requirement, so each locks its whole free budget.
        swood.setStake(guardian, 5_000e18);
        swood.setStake(g2, 5_000e18);
        mgov.set(_requiredCoverage6(10_000e18));
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian, type(uint256).max);
        ledger.recordApproval(address(mgov), 1, g2, type(uint256).max);
        vm.stopPrank();

        (, uint256[] memory lockedBefore) = ledger.pledgedOf(address(mgov), 1);
        assertEq(lockedBefore[0], 5_000e18, "guardian must lock its whole stake");

        skip(31 days); // review shut; nothing about the lock changes

        // The guardian's bond evaporates entirely while g2 stays solvent.
        swood.setStake(guardian, 0);

        // The lock is untouched — there is no permissionless pass left that
        // could write it down, and `coverageUsdOf` is what now reads zero.
        (address[] memory approvers, uint256[] memory locked) = ledger.approversOf(address(mgov), 1);
        assertEq(approvers[0], guardian, "guardian must still be listed first");
        assertEq(locked[0], 5_000e18, "the lock survives the stake collapse");
        assertEq(ledger.lockOf(address(mgov), 1, guardian), 5_000e18);
        assertEq(ledger.coverageUsdOf(address(mgov), 1, guardian), 0, "what a conviction could recover is zero");

        // slashBpsFor still NAMES the guardian, at the ceiling: pashov #13's
        // concern (a permissionless write dropping a pledged guardian out of
        // the slash set) has nothing left to write.
        (address[] memory accused, uint256[] memory bps) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(accused[0], guardian, "the guardian is still in the slash set");
        assertEq(bps[0], 10_000, "a lock over a zero basis saturates; it does not vanish");

        vm.prank(freezer);
        ledger.freezeCoverage(address(mgov), 1);
        assertTrue(ledger.hasFrozenCoverage(guardian), "guardian must be frozen despite a zero stake");
        assertEq(ledger.frozenCoverageCount(), 1);

        // And the pin sibling: raised, not skipped.
        vm.prank(freezer);
        ledger.unfreezeCoverage(address(mgov), 1);
        assertFalse(ledger.hasFrozenCoverage(guardian), "control: unfrozen and unpinned reads clean");
        vm.prank(freezer);
        ledger.pinCoverageUntil(address(mgov), 1, block.timestamp + 1_000);
        assertTrue(ledger.hasFrozenCoverage(guardian), "pin must have raised despite a zero stake");
    }

    // ══════════════════════════════════════════════════════════════════
    // FINDING B — the pin boundary is inclusive of `deadline`, matching
    // ChallengeGame.file's own inclusive filing-deadline check
    // ══════════════════════════════════════════════════════════════════

    /// @notice At `block.timestamp == deadline` the guardian must still read
    ///         pinned on BOTH `hasFrozenCoverage` and `retireApproval`; one
    ///         second later, both must have decayed.
    ///
    ///         Fails against the pre-fix code (`>` instead of `>=`): AT the
    ///         deadline instant `hasFrozenCoverage` would already read
    ///         `false` and `retireApproval` would already succeed, one second
    ///         before `ChallengeGame.file`'s own inclusive deadline check
    ///         actually closes.
    function test_pinCoverageUntil_boundaryIsInclusiveOfDeadline() public {
        uint256 p1 = 1;
        swood.setStake(guardian, 5_000e18);
        mgov.set(_requiredCoverage6(1_000e18));
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), p1, guardian, type(uint256).max);

        // Advance past the guardian's own bucket challenge-window expiry, so
        // the ONLY thing left gating `retireApproval` below is the pin.
        uint256 expiry = ledger.epochGenesis() + ledger.epochLength() + ledger.challengeWindow();
        vm.warp(expiry + 1);

        uint256 deadline = block.timestamp + 100;
        vm.prank(freezer);
        ledger.pinCoverageUntil(address(mgov), p1, deadline);

        // AT the deadline instant: still pinned on both reads.
        vm.warp(deadline);
        assertTrue(ledger.hasFrozenCoverage(guardian), "must still read frozen AT the deadline instant");
        vm.expectRevert(IExposureLedger.CoveragePinnedActive.selector);
        ledger.retireApproval(address(mgov), p1, guardian);

        // One instant past the deadline: the pin has decayed on both reads.
        vm.warp(deadline + 1);
        assertFalse(ledger.hasFrozenCoverage(guardian), "must read unfrozen the instant after the deadline");
        ledger.retireApproval(address(mgov), p1, guardian); // must now succeed

        (address[] memory approvers,) = ledger.pledgedOf(address(mgov), p1);
        assertEq(approvers.length, 0, "the sweep must actually have gone through");
    }

    // ══════════════════════════════════════════════════════════════════
    // FINDING C — a pin on one proposal must not block retiring an
    // unrelated proposal for the same guardian
    // ══════════════════════════════════════════════════════════════════

    /// @notice `retireApproval` must read the PER-KEY pin, not the
    ///         per-guardian max: a pin issued against one stale proposal (say,
    ///         a grindable Inconclusive verdict, no attacker required) must
    ///         not block sweeping the guardian's other, unrelated
    ///         commitments. `hasFrozenCoverage` — a genuinely guardian-scoped
    ///         question — correctly stays conservative throughout.
    ///
    ///         Fails against the pre-fix code (`retireApproval` reads the
    ///         per-guardian max, so P1's pin alone blocks P2's sweep too),
    ///         passes against the fix.
    function test_retireApproval_notBlockedByAPinOnAnUnrelatedProposal() public {
        uint256 p1 = 1;
        uint256 p2 = 2;
        swood.setStake(guardian, 10_000e18); // enough to fully back both proposals

        mgov.set(_requiredCoverage6(1_000e18));
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), p1, guardian, type(uint256).max);

        mgov.set(_requiredCoverage6(1_000e18));
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), p2, guardian, type(uint256).max);

        uint256 expiry = ledger.epochGenesis() + ledger.epochLength() + ledger.challengeWindow();
        vm.warp(expiry + 1); // both P1 and P2's buckets are now provably dead

        // A grindable non-verdict lands on P1 only.
        vm.prank(freezer);
        ledger.pinCoverageUntil(address(mgov), p1, block.timestamp + 1_000);

        // Guardian-scoped read stays conservative: reachable by SOME live
        // accusation.
        assertTrue(ledger.hasFrozenCoverage(guardian), "P1's pin must still make the guardian's stake reachable");

        // P1 itself is correctly still blocked -- it is the pinned proposal.
        vm.expectRevert(IExposureLedger.CoveragePinnedActive.selector);
        ledger.retireApproval(address(mgov), p1, guardian);

        // P2 is unrelated and unpinned -- must sweep cleanly despite P1's
        // live pin on the same guardian.
        ledger.retireApproval(address(mgov), p2, guardian);

        (address[] memory p2Approvers,) = ledger.pledgedOf(address(mgov), p2);
        assertEq(p2Approvers.length, 0, "P2 must be fully retired despite P1's live pin");

        // hasFrozenCoverage must STILL read true -- P1's pin is untouched.
        assertTrue(ledger.hasFrozenCoverage(guardian), "P1's pin must remain in effect after P2's sweep");
    }

    // ══════════════════════════════════════════════════════════════════
    // FINDING D — the ledger's challengeWindow may not shrink below the
    // wired ChallengeGame's own window
    // ══════════════════════════════════════════════════════════════════

    /// @notice `setChallengeWindow` must refuse to shrink the ledger's window
    ///         below the wired game's own `challengeWindow` — otherwise
    ///         `retireApproval`'s gate could open before `ChallengeGame.file`'s
    ///         filing deadline closes, letting a sweep empty `_approversOf`
    ///         while the proposal is still, legally, filable.
    ///
    ///         Fails against the pre-fix code (no such check exists, so the
    ///         shrink below succeeds), passes against the fix.
    function test_setChallengeWindow_cannotShrinkBelowTheWiredGameWindow() public {
        MockChallengeGameWindow game = new MockChallengeGameWindow(20 days);

        // Bump the ledger's window above the game's first, isolating the
        // SHRINK direction finding D is about. Before wiring: since SHE-214
        // `setCoverageFreezer` refuses a game whose window exceeds the ledger's.
        vm.prank(owner);
        ledger.setChallengeWindow(25 days);
        assertEq(ledger.challengeWindow(), 25 days);
        vm.prank(owner);
        ledger.setCoverageFreezer(address(game));

        // Shrinking below the game's own 20d window must revert.
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(19 days);
        assertEq(ledger.challengeWindow(), 25 days, "the rejected shrink must not have taken effect");

        // Shrinking to EXACTLY the game's window is legal -- the invariant is
        // `game.challengeWindow <= ledger.challengeWindow()`.
        vm.prank(owner);
        ledger.setChallengeWindow(20 days);
        assertEq(ledger.challengeWindow(), 20 days);
    }

    /// @notice CAUTION RESOLUTION: `setGuardianRegistry` admits a registry
    ///         TOLERANTLY (any nonzero address, even codeless). This fixture's
    ///         `registry` is exactly that — a plain `makeAddr`, no code — so
    ///         `setChallengeWindow` must NOT revert when it reads that
    ///         pointer: a registry the tolerant setter admitted must not
    ///         permanently brick this setter.
    ///
    ///         Fails against the pre-fix code (a raw, non-tolerant call to
    ///         `IRegistryApproversMinimal(reg).reviewPeriod()` against a
    ///         codeless address reverts in this frame, unconditionally, on
    ///         every call), passes against the fix.
    function test_setChallengeWindow_toleratesACodelessGuardianRegistry() public {
        assertEq(registry.code.length, 0, "precondition: fixture registry must be codeless");

        vm.prank(owner);
        ledger.setChallengeWindow(15 days); // must not revert
        assertEq(ledger.challengeWindow(), 15 days);
    }

    // ══════════════════════════════════════════════════════════════════
    // ALSO — _feedPriceX8 must report a truncated-to-zero answer as
    // UNAVAILABLE, not as a healthy zero price
    // ══════════════════════════════════════════════════════════════════

    /// @notice A Chainlink WOOD feed with a small positive answer at 18
    ///         decimals normalises to exactly zero wei-X8
    ///         (`(1 * 1e8) / 1e18 == 0`). The ledger must fall through to the
    ///         TWAP rather than silently resolving `woodPriceX8()` to zero.
    ///
    ///         Fails against the pre-fix code (`_feedPriceX8` returns
    ///         `(0, true)`, `fromFeed` reads `true`, the TWAP fallback is
    ///         skipped entirely, and `woodPriceX8()` resolves to 0), passes
    ///         against the fix.
    function test_feedPriceX8_truncatingToZeroFallsThroughToTwap() public {
        MockAssetFeed woodFeed = new MockAssetFeed(1, 18); // answer=1, 18-dec feed
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 365 days);

        (uint256 price, bool fromFeed, bool capBinding) = ledger.woodPriceDetail();
        assertFalse(fromFeed, "a source that truncates to zero must not count as a healthy feed answer");
        assertFalse(capBinding, "the cap (2x market) must not be binding");
        assertEq(price, MARKET_X8, "price must fall through to the healthy TWAP, not resolve to zero");
        assertGt(ledger.woodPriceX8(), 0, "woodPriceX8 must not silently resolve to zero");
    }
}
