// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {MockWoodTwapOracle} from "test/mocks/MockWoodTwapOracle.sol";

/// @dev Minimal sWOOD stub, but UNLIKE `test/ExposureLedger.t.sol`'s
///      `MockSwood`, this one mirrors `StakedWood.slashableStakeAt`'s ACTUAL
///      offset-by-one basis (`StakedWood.sol:1632-1634`:
///      `_slashableAt(guardian, anchor == 0 ? 0 : anchor - 1)`), because that
///      offset is exactly what audit #181 finding 4 is about: a checkpoint
///      pushed AT the anchor instant must be EXCLUDED by
///      `swood.slashableStakeAt(g, anchor)`, matching
///      `StakedWood.slashVerdict`'s own `lookupAnchor = openedAt - 1` basis. A
///      mock that used plain `upperLookupRecent`-style inclusion (ts <=
///      anchor, no offset) would make this test pass for the wrong reason —
///      it would not distinguish the fixed `requireApproveQuorum` from the
///      broken one, because both anchor bases would include a same-instant
///      checkpoint identically.
contract MockSwoodAnchored {
    mapping(address => uint256) public guardianStake;
    uint256 public coolDownPeriod = 45 days;

    struct Checkpoint {
        uint256 ts;
        uint256 amount;
    }

    mapping(address => Checkpoint[]) internal _checkpoints;

    function setStake(address g, uint256 own) external {
        guardianStake[g] = own;
        _checkpoints[g].push(Checkpoint({ts: block.timestamp, amount: own}));
    }

    /// @dev Mirrors `StakedWood.slashableStakeAt` exactly: subtracts one from
    ///      the anchor BEFORE the checkpoint lookup, so `anchor ==
    ///      block.timestamp` resolves to the checkpoint state as of
    ///      `block.timestamp - 1` — a checkpoint pushed in the SAME instant as
    ///      `anchor` is excluded.
    function slashableStakeAt(address g, uint256 anchor) external view returns (uint256) {
        return _slashableAt(g, anchor == 0 ? 0 : anchor - 1);
    }

    function _slashableAt(address g, uint256 anchor) internal view returns (uint256) {
        Checkpoint[] storage cps = _checkpoints[g];
        uint256 snap;
        for (uint256 i = 0; i < cps.length; i++) {
            if (cps[i].ts > anchor) break;
            snap = cps[i].amount;
        }
        return snap;
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

/// @dev Single-proposal-shaped governor stub (mirrors
///      `test/ExposureLedger.t.sol`'s own `MockGovernorForLedger`): state is
///      global rather than per-`proposalId`, so a test that books more than
///      one proposal on the same governor mock re-configures the mock
///      immediately before each `recordApproval` call. `requireApproveQuorum`
///      never reads this mock at all — its `requiredCoverage` comes straight
///      from the caller — so this shape only matters for `recordApproval`.
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

/// @title ExposureLedger_anchorAndRetire
/// @notice Regression coverage for audit #181 findings 4 and 11.
///
/// @dev    FINDING 4 (`test_requireApproveQuorum_...`): `requireApproveQuorum`
///         used to value every approver at LIVE stake (`anchor = 0`) while the
///         matching conviction (`ChallengeGame` -> `StakedWood.slashVerdict`)
///         values the SAME guardian at `swood.slashableStakeAt(g,
///         c.executedAt)`. A stake checkpoint pushed in the same block as
///         execution was therefore COUNTED by the gate and EXCLUDED by the
///         verdict, letting a same-block top-up certify coverage no
///         conviction could ever collect. Fixed by anchoring the gate at
///         `block.timestamp`, matching the verdict's basis for a proposal
///         executing this same block.
///
///         FINDING 11 (`test_retireApproval_...`): a lock is cleared ONLY by
///         `releaseApproval`, whose one caller (`GuardianRegistry
///         .voteOnProposal`'s Approve->Block branch) is gated on the review
///         still being open. A commitment that survives its own review has NO
///         release path, so its record and its approver listing — which the
///         freeze/pin walks and every accused-set derivation read — outlive
///         the window in which it could still be collected on. Fixed by
///         `retireApproval`, a permissionless sweep gated on the booked
///         epoch's challenge window having elapsed, the key being unfrozen,
///         and the guardian holding no active `pinCoverageUntil`. (Under the
///         original booking/pledge model the stale record ALSO diluted every
///         other proposal the guardian backed through a shared-stake
///         denominator; declared coverage locks removed that denominator, so
///         the sweep now bounds list length rather than repairing coverage.)
contract ExposureLedgerAnchorAndRetireTest is Test {
    ExposureLedger internal ledger;
    MockSwoodAnchored internal swood;
    MockWoodTwapOracle internal twap;
    MockGovernorForLedger internal mgov;
    address internal usdgAsset;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal registry = makeAddr("registry");
    address internal freezer = makeAddr("freezer");

    // $2.00 market, cap 2x above (non-binding) — matches finding 4's own
    // worked example (guardian at $2.00/WOOD, price falls to $1.00).
    uint256 internal constant MARKET_X8 = 2e8;
    uint256 internal constant CAP_X8 = 4e8;

    function setUp() public {
        swood = new MockSwoodAnchored();
        ledger = new ExposureLedger(owner, address(swood), 28 days);
        twap = new MockWoodTwapOracle(MARKET_X8);

        usdgAsset = makeAddr("usdgAsset");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockAssetFeed feed = new MockAssetFeed(1e8, 8); // $1.00/unit, 8-dec feed
        MockVaultForLedger vault = new MockVaultForLedger(usdgAsset);
        mgov = new MockGovernorForLedger(address(vault));

        vm.startPrank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        ledger.setWoodTwapOracle(address(twap));
        ledger.setAssetFeed(usdgAsset, address(feed), 365 days);
        ledger.setGuardianRegistry(registry);
        ledger.setCoverageFreezer(freezer);
        vm.stopPrank();

        assertEq(ledger.woodPriceX8(), MARKET_X8, "fixture must price off the market, not the cap");
    }

    /// @dev USDG (6-dec) amount that prices to exactly `usd18` at the fixture's
    ///      flat $1.00 asset feed.
    function _requiredCoverage6(uint256 usd18) internal pure returns (uint256) {
        return usd18 / 1e12;
    }

    // ══════════════════════════════════════════════════════════════════
    // FINDING 4 — requireApproveQuorum must not certify a same-block top-up
    // ══════════════════════════════════════════════════════════════════

    /// @notice Reproduces finding 4's worked example verbatim: guardian holds
    ///         500,000e18 WOOD at $2.00 (slashable $1,000,000), reserves the
    ///         full $1,000,000 requirement. WOOD falls to $1.00. In the SAME
    ///         block, the guardian tops up to 1,000,000e18 WOOD (worth
    ///         $1,000,000 live, but the anchored basis a verdict can reach is
    ///         still only the pre-top-up 500,000e18 = $500,000).
    ///
    ///         Before the fix, `requireApproveQuorum` read live stake
    ///         (`anchor = 0`) and would have seen $1,000,000 — passing a gate
    ///         a conviction could only ever collect $500,000 against. This
    ///         test asserts the FIXED behaviour: the gate must revert, because
    ///         `min(max(500_000e18, 500_000e18), 1_000_000e18) = 500,000e18`
    ///         is short of the $1,000,000 requirement.
    ///
    ///         Fails against the pre-fix code (which returns normally here —
    ///         `vm.expectRevert` would see no revert), passes against the fix.
    function test_requireApproveQuorum_sameBlockTopUp_doesNotCertifyPhantomCoverage() public {
        uint256 proposalId = 1;
        uint256 needUsd = 1_000_000e18;
        uint256 requiredCoverage6 = _requiredCoverage6(needUsd);

        // 500,000e18 WOOD @ $2.00 = $1,000,000 slashable — exactly enough to
        // reserve the whole requirement.
        swood.setStake(guardian, 500_000e18);
        mgov.set(requiredCoverage6);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), proposalId, guardian, type(uint256).max);

        // Sanity: the lock is the guardian's whole 500,000e18 stake (worth the
        // full requirement at $2.00), so any shortfall below is attributable
        // to the anchor basis, not to under-locking.
        (, uint256[] memory locked) = ledger.pledgedOf(address(mgov), proposalId);
        assertEq(locked.length, 1, "guardian must have locked into the approver list");
        assertEq(locked[0], 500_000e18, "lock must be the whole stake");
        assertEq(ledger.coverageUsdOf(address(mgov), proposalId, guardian), needUsd, "worth the full requirement");

        // WOOD crashes to $1.00 ...
        twap.setPrice(1e8);
        // ... and in the SAME block, the guardian tops up its stake. No time
        // passes between the crash, the top-up, and the gate check below —
        // this is the exact same-block sequence the finding describes.
        swood.setStake(guardian, 1_000_000e18);

        // The gate must now revert: the anchored basis excludes the top-up,
        // so the covering approver can only be shown to back $500,000 of the
        // $1,000,000 requirement.
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), proposalId, usdgAsset, requiredCoverage6);
    }

    /// @notice The other half of the same property: the gate DOES pass when
    ///         sized to what the anchored basis can actually show —
    ///         confirming the fix does not simply revert unconditionally, and
    ///         that $500,000 (the pre-top-up, anchored value) is exactly the
    ///         boundary.
    function test_requireApproveQuorum_passesAtTheAnchoredAmount() public {
        uint256 proposalId = 2;
        uint256 fullNeedUsd = 1_000_000e18;
        uint256 anchoredNeedUsd = 500_000e18;

        swood.setStake(guardian, 500_000e18);
        mgov.set(_requiredCoverage6(fullNeedUsd));
        vm.prank(registry);
        ledger.recordApproval(address(mgov), proposalId, guardian, type(uint256).max);

        // Advance one second so the ORIGINAL 500,000e18 checkpoint lands
        // strictly BEFORE the "current" block the crash + top-up below
        // occurs in. Without this, both `setStake` calls land at the same
        // `block.timestamp` (this test's `setUp` never warps), so the
        // anchored lookup at `block.timestamp - 1` would see NEITHER
        // checkpoint and read 0 — masking the very distinction this test
        // exists to prove (that the PRE-top-up amount, not 0 and not the
        // top-up, is what the anchored gate shows). This mirrors the
        // sibling `..._doesNotCertifyPhantomCoverage` test's own worked
        // example, which frames the initial stake as already held "before"
        // the same-block crash-and-top-up sequence.
        vm.warp(vm.getBlockTimestamp() + 1);

        twap.setPrice(1e8);
        swood.setStake(guardian, 1_000_000e18);

        // Sized to the anchored, pre-top-up value: must pass.
        ledger.requireApproveQuorum(address(mgov), proposalId, usdgAsset, _requiredCoverage6(anchoredNeedUsd));
    }

    // ══════════════════════════════════════════════════════════════════
    // FINDING 11 — retireApproval must free a dead commitment's share of the
    // shared-stake denominator
    // ══════════════════════════════════════════════════════════════════

    /// @notice A guardian's stale, long-expired approval on one proposal keeps
    ///         its lock record and its approver listing alive with no release
    ///         path; `retireApproval` is what clears them. Declared coverage
    ///         locks removed the shared-stake denominator the original finding
    ///         was about, so a fresh proposal the same guardian later backs is
    ///         whole BEFORE the sweep as well as after — pinned here so the
    ///         sweep is understood as list hygiene, not coverage repair.
    ///
    ///         Fails against a ledger with no `retireApproval` (the listing can
    ///         never be cleared), passes against the fix.
    function test_retireApproval_sweepsADeadLockAndLeavesTheFreshProposalWhole() public {
        uint256 p1 = 10;
        uint256 p2 = 20;

        // 500,000e18 WOOD @ $2.00 = $1,000,000 slashable, held flat through
        // the whole test — no top-up, no crash. Only wall-clock and the sweep
        // move anything.
        swood.setStake(guardian, 500_000e18);

        // P1 locks half the guardian's stake and is never touched again.
        mgov.set(_requiredCoverage6(500_000e18));
        vm.prank(registry);
        ledger.recordApproval(address(mgov), p1, guardian, 250_000e18);
        (, uint256[] memory p1Locked) = ledger.pledgedOf(address(mgov), p1);
        assertEq(p1Locked[0], 250_000e18, "P1 must lock 250,000 WOOD");

        // Advance past P1's bucket's challenge-window expiry
        // (genesis + (epoch + 1) * epochLength + challengeWindow; P1 booked
        // into epoch 0, since it was recorded at genesis with a zero
        // executeBy/strategyDuration schedule).
        uint256 expiry = ledger.epochGenesis() + ledger.epochLength() + ledger.challengeWindow();
        vm.warp(expiry + 1);

        // P1 is now provably dead: its bucket has aged out of the batching-cap
        // scan, and no `ChallengeGame.file` could reach it any more. Its LOCK
        // RECORD, however, is still there.
        assertEq(ledger.openExposure(guardian), 0, "P1's bucket must have aged out of the batching cap");
        assertEq(ledger.lockOf(address(mgov), p1, guardian), 250_000e18, "...but its lock record persists");

        // P2 locks the guardian's WHOLE stake — the budget recycled with the
        // bucket, so the full 500,000e18 is free again.
        mgov.set(_requiredCoverage6(1_000_000e18));
        vm.prank(registry);
        ledger.recordApproval(address(mgov), p2, guardian, type(uint256).max);
        (, uint256[] memory p2Locked) = ledger.pledgedOf(address(mgov), p2);
        assertEq(p2Locked[0], 500_000e18, "P2 must lock the whole stake");

        // BEFORE the sweep: P2 is already whole. There is no shared-stake
        // denominator for P1's dead record to dilute — the quorum reads
        // `min(lock, stake) x price` for P2 alone.
        (uint256 raisedBeforeUsd, uint256 requiredUsd) =
            ledger.requireApproveQuorum(address(mgov), p2, usdgAsset, _requiredCoverage6(1_000_000e18));
        assertEq(requiredUsd, 1_000_000e18, "requirement must be P2's own full $1,000,000");
        assertEq(raisedBeforeUsd, requiredUsd, "a dead lock elsewhere does not dilute a fresh proposal");

        // Sweep P1 — anyone may call this, no registry/freezer role needed.
        ledger.retireApproval(address(mgov), p1, guardian);

        // P1 must be fully gone: no longer listed, no longer locked.
        (address[] memory p1Approvers,) = ledger.pledgedOf(address(mgov), p1);
        assertEq(p1Approvers.length, 0, "retireApproval must remove the guardian from P1's approver list");
        assertEq(ledger.lockOf(address(mgov), p1, guardian), 0, "and clear the lock record");

        // AFTER the sweep: P2 is exactly as whole as before — the sweep touched
        // P1's record only.
        (uint256 raisedAfterUsd,) =
            ledger.requireApproveQuorum(address(mgov), p2, usdgAsset, _requiredCoverage6(1_000_000e18));
        assertEq(raisedAfterUsd, requiredUsd, "P2 unchanged by retiring P1");
        assertEq(ledger.lockOf(address(mgov), p2, guardian), 500_000e18, "P2's lock untouched");
    }

    /// @notice `retireApproval` must revert while the key is still frozen by a
    ///         live challenge, exactly like `releaseApproval` — a guardian may
    ///         not have its pinned coverage swept out from under a live
    ///         accusation just because the underlying epoch bucket happens to
    ///         have aged out.
    function test_retireApproval_revertsWhileFrozen() public {
        uint256 p1 = 30;
        swood.setStake(guardian, 500_000e18);
        mgov.set(_requiredCoverage6(500_000e18));
        vm.prank(registry);
        ledger.recordApproval(address(mgov), p1, guardian, type(uint256).max);

        vm.prank(freezer);
        ledger.freezeCoverage(address(mgov), p1);

        uint256 expiry = ledger.epochGenesis() + ledger.epochLength() + ledger.challengeWindow();
        vm.warp(expiry + 1);

        vm.expectRevert(IExposureLedger.CoverageFrozen.selector);
        ledger.retireApproval(address(mgov), p1, guardian);

        // Unfreezing clears the block; the sweep then succeeds.
        vm.prank(freezer);
        ledger.unfreezeCoverage(address(mgov), p1);
        ledger.retireApproval(address(mgov), p1, guardian);
    }

    /// @notice `retireApproval` must revert while the guardian's booked epoch
    ///         has not yet reached its own challenge-window expiry — sweeping
    ///         early would release capital a conviction could still reach.
    function test_retireApproval_revertsBeforeChallengeWindowElapses() public {
        uint256 p1 = 40;
        swood.setStake(guardian, 500_000e18);
        mgov.set(_requiredCoverage6(500_000e18));
        vm.prank(registry);
        ledger.recordApproval(address(mgov), p1, guardian, type(uint256).max);

        uint256 expiry = ledger.epochGenesis() + ledger.epochLength() + ledger.challengeWindow();
        vm.warp(expiry); // exactly at expiry, not yet past it

        vm.expectRevert(IExposureLedger.ChallengeWindowOpen.selector);
        ledger.retireApproval(address(mgov), p1, guardian);

        vm.warp(expiry + 1);
        ledger.retireApproval(address(mgov), p1, guardian); // now succeeds
    }

    /// @notice No-op when nothing is recorded, mirroring `releaseApproval`'s
    ///         own no-op — never reverts, never underflows.
    function test_retireApproval_noopWhenNothingRecorded() public {
        ledger.retireApproval(address(mgov), 999, guardian);
    }
}
