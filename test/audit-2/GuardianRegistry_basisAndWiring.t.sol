// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";

/// @notice Regression tests for the SECOND audit-181 pass on `GuardianRegistry`
///         (findings A, B, C + the `initialize` blockQuorumBps gap).
///
///         FINDING A (the worst defect the FIRST remediation produced): it
///         added `_lookbackMinTotalVotes` to the block-quorum DENOMINATOR
///         (`Review.totalStakeAtOpen` / `EmergencyReview.totalStakeAtOpen`)
///         but left the voter's own NUMERATOR weight (`voteOnProposal`'s
///         first-vote branch, `voteBlockEmergencySettle`) reading raw
///         `getPastVotes` with no matching clamp. An attacker's fresh stake
///         was therefore discounted OUT of the denominator but counted IN
///         FULL on the numerator — turning a mathematically impossible block
///         (own stake symmetric on both sides can never flip the inequality)
///         into a cheap one. The fix mirrors `TokenCourt.vote`'s
///         growth-gated min (issue #82) via `_growthGatedVoteWeight`.
///
///         FINDING B: `cohortTooSmall` was computed from the 30-day
///         lookback-min instead of the LIVE electorate, making it a free,
///         on-demand off-switch for the entire guardian veto
///         (`resolveReview`) and the emergency owner-bond slash
///         (`_resolveEmergency`) during ordinary early growth. Fixed to read
///         `sw.getPastTotalVotes(ts1)` directly in both `openReview` and
///         `openEmergency`.
///
///         FINDING C: `setExposureLedger`'s body wrapped both external reads
///         in `code.length` + swallowing `try/catch`, directly contradicting
///         its own dev-comment block ("STRICT, not tolerant, on purpose ... both
///         external reads below are plain, unguarded calls"). A codeless /
///         CREATE2-counterfactual ledger was silently admitted. Fixed to
///         plain, unguarded calls that revert the wiring transaction.
///
///         PLUS: `initialize` validated `reviewPeriod_` but wrote
///         `blockQuorumBps` with no bound, while `setBlockQuorumBps` enforces
///         `[1000, 10000]`. A zero `blockQuorumBps` seats a state where every
///         non-cohort-too-small review resolves Blocked unconditionally.
contract GuardianRegistry_basisAndWiringTest is RegistryTestHarness {
    uint256 internal constant REVIEW_PERIOD = 24 hours;
    uint256 internal constant BLOCK_QUORUM_BPS = 2000; // 20%

    address internal honestBlocker = address(0xB10C4E5);
    address internal honestSilent = address(0x51E17);
    address internal attacker = address(0xA77AC4E5);
    address internal guardian1 = address(0x60A1);
    address internal guardian2 = address(0x60A2);
    address internal guardian3 = address(0x60A3);
    address internal guardian4 = address(0x60A4);
    address internal guardian5 = address(0x60A5);

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, BLOCK_QUORUM_BPS);
    }

    // ══════════════════════════ FINDING A ══════════════════════════

    /// @notice The exact "mathematically impossible attack turned cheap"
    ///         scenario. Honest cohort E = 1_000_000e18, matured >30 days.
    ///         Attacker parks 1.2E (1_200_000e18) in the SAME block as
    ///         `openReview` and tries to cast the sole Block vote.
    ///
    ///         Pre-fix (numerator raw, denominator lookback-min-of-E): the
    ///         attacker's vote alone would land at full 1_200_000e18 weight
    ///         against a lookback-min denominator of ~1_000_000e18 —
    ///         `1_200_000e18 * 10_000 >= 2000 * 1_000_000e18` is TRUE, so a
    ///         lone attacker with fresh capital blocks a proposal the honest
    ///         cohort never voted on at all.
    ///
    ///         Fixed: the attacker's raw stake GREW across `FLOOR_LOOKBACK`
    ///         (0 -> 1_200_000e18) while the global total at the lookback
    ///         instant is nonzero (the honest cohort), so
    ///         `_growthGatedVoteWeight` clamps their weight to
    ///         `getPastVotes(attacker, ts1 - FLOOR_LOOKBACK) == 0` (they held
    ///         nothing back then). `voteOnProposal` then reverts
    ///         `NotActiveGuardian` on the zero-weight guard — the attacker
    ///         cannot cast a vote that counts for anything, and the review
    ///         resolves NOT blocked with zero block-side weight.
    function test_voteOnProposal_freshStakeAttackerCannotContributeToBlockNumerator() public {
        _stakeGuardian(honestSilent, 1_000_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _stakeGuardian(attacker, 1_200_000e18, 2);

        uint256 voteEnd = vm.getBlockTimestamp();
        _registerReview(1, voteEnd, voteEnd + REVIEW_PERIOD);
        vm.warp(vm.getBlockTimestamp() + 1); // ToB C-1 pattern: see sibling suite

        registry.openReview(address(governor), 1);

        vm.prank(attacker);
        vm.expectRevert(IGuardianRegistry.NotActiveGuardian.selector);
        registry.voteOnProposal(address(governor), 1, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(voteEnd + REVIEW_PERIOD);
        bool blocked = registry.resolveReview(address(governor), 1);
        assertFalse(blocked, "a lone attacker's fresh stake must not be able to block a proposal by itself");
    }

    /// @notice Sanity companion to the test above: a genuinely MATURE
    ///         guardian (staked long before `FLOOR_LOOKBACK`, no top-up) must
    ///         NOT be clamped — the fix must not degrade ordinary voting.
    ///         `getPastStake` at `openedAt` and at `openedAt - FLOOR_LOOKBACK`
    ///         are identical (no growth), so `_growthGatedVoteWeight` returns
    ///         the raw, un-clamped `getPastVotes` reading.
    function test_voteOnProposal_matureGuardianWeightIsNotClamped() public {
        _stakeGuardian(honestBlocker, 1_000_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        uint256 voteEnd = vm.getBlockTimestamp();
        _registerReview(2, voteEnd, voteEnd + REVIEW_PERIOD);
        vm.warp(vm.getBlockTimestamp() + 1);

        registry.openReview(address(governor), 2);

        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.GuardianVoteCast(
            2, honestBlocker, IGuardianRegistry.GuardianVoteType.Block, 1_000_000e18
        );
        vm.prank(honestBlocker);
        registry.voteOnProposal(address(governor), 2, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(voteEnd + REVIEW_PERIOD);
        bool blocked = registry.resolveReview(address(governor), 2);
        assertTrue(blocked, "a mature guardian's full, un-clamped weight must still be able to block");
    }

    /// @notice Mirror of the numerator-clamp test on the emergency path
    ///         (`voteBlockEmergencySettle`) — finding A names BOTH functions
    ///         explicitly, and they must not diverge (Failure Mode 1: fixing
    ///         the named path while leaving its sibling raw).
    function test_voteBlockEmergencySettle_freshStakeAttackerCannotContributeToBlockNumerator() public {
        _stakeGuardian(honestSilent, 1_000_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _stakeGuardian(attacker, 1_200_000e18, 2);
        vm.warp(vm.getBlockTimestamp() + 1);

        BatchExecutorLib.Call[] memory emptyCalls = new BatchExecutorLib.Call[](0);
        bytes32 emptyHash = keccak256(abi.encode(emptyCalls));
        vm.prank(address(governor));
        registry.openEmergency(3, emptyHash, emptyCalls);

        vm.prank(attacker);
        vm.expectRevert(IGuardianRegistry.NotActiveGuardian.selector);
        registry.voteBlockEmergencySettle(address(governor), 3);
    }

    // ══════════════════════════ FINDING B ══════════════════════════

    /// @notice `cohortTooSmall` must be decided off the LIVE electorate, not
    ///         the 30-day lookback-min. Setup: `guardian1` stakes only
    ///         10_000e18 (below `MIN_COHORT_STAKE_AT_OPEN` = 50_000e18) and
    ///         matures untouched for 31 days -- this is what the lookback
    ///         read (`ts1 - FLOOR_LOOKBACK`) sees. THEN, at `ts1`, four more
    ///         guardians stake 20_000e18 each, pushing the LIVE total to
    ///         90_000e18 -- well above the floor.
    ///
    ///         Against the (broken) lookback-min basis, `cohortTooSmall`
    ///         would read `10_000e18 < 50_000e18 -> true`, disabling the
    ///         guardian veto outright: `resolveReview` would return `false`
    ///         regardless of any block vote cast. Against the fix,
    ///         `cohortTooSmall` reads the live 90_000e18 total (`false`), and
    ///         `guardian1`'s own vote -- which by itself equals the ENTIRE
    ///         lookback-min denominator used for the block-quorum test --
    ///         clears the quorum and the review resolves Blocked.
    function test_openReview_cohortTooSmallUsesLiveElectorateNotLookbackMin() public {
        _stakeGuardian(guardian1, 10_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _stakeGuardian(guardian2, 20_000e18, 2);
        _stakeGuardian(guardian3, 20_000e18, 3);
        _stakeGuardian(guardian4, 20_000e18, 4);
        _stakeGuardian(guardian5, 20_000e18, 5);

        uint256 voteEnd = vm.getBlockTimestamp();
        _registerReview(4, voteEnd, voteEnd + REVIEW_PERIOD);
        vm.warp(vm.getBlockTimestamp() + 1);

        registry.openReview(address(governor), 4);

        (,, bool blockedYet, bool cohortTooSmall) = registry.getReviewState(address(governor), 4);
        assertFalse(blockedYet, "not yet resolved");
        assertFalse(
            cohortTooSmall,
            "live electorate (90_000e18) clears MIN_COHORT_STAKE_AT_OPEN even though the 30-day-old checkpoint (10_000e18) does not"
        );

        // guardian1's own vote equals the WHOLE lookback-min denominator
        // (10_000e18), so it alone clears any legal block-quorum bps.
        vm.prank(guardian1);
        registry.voteOnProposal(address(governor), 4, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(voteEnd + REVIEW_PERIOD);
        bool blocked = registry.resolveReview(address(governor), 4);
        assertTrue(blocked, "the veto pipeline must actually run -- cohortTooSmall must not have short-circuited it");
    }

    /// @notice Mirror of the above for `openEmergency` / `_resolveEmergency`
    ///         -- the emergency owner-bond slash path shares the identical
    ///         `cohortTooSmall` off-switch hazard (Failure Mode 1).
    function test_openEmergency_cohortTooSmallUsesLiveElectorateNotLookbackMin() public {
        _stakeGuardian(guardian1, 10_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _stakeGuardian(guardian2, 20_000e18, 2);
        _stakeGuardian(guardian3, 20_000e18, 3);
        _stakeGuardian(guardian4, 20_000e18, 4);
        _stakeGuardian(guardian5, 20_000e18, 5);
        vm.warp(vm.getBlockTimestamp() + 1);

        BatchExecutorLib.Call[] memory emptyCalls = new BatchExecutorLib.Call[](0);
        bytes32 emptyHash = keccak256(abi.encode(emptyCalls));
        vm.prank(address(governor));
        registry.openEmergency(5, emptyHash, emptyCalls);

        vm.prank(guardian1);
        registry.voteBlockEmergencySettle(address(governor), 5);

        // `resolveEmergencyReview` is the permissionless keeper path; its
        // commit is entirely internal (`_resolveEmergency`), so the only
        // window into `cohortTooSmall` is the resolved outcome itself.
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.EmergencyReviewResolved(5, true, 0);
        registry.resolveEmergencyReview(address(governor), 5);
    }

    // ══════════════════════════ FINDING C ══════════════════════════

    /// @notice `setExposureLedger` must be STRICT: a codeless address (an
    ///         EOA, or a CREATE2 counterfactual not yet deployed) must revert
    ///         the wiring transaction, not be silently admitted with a
    ///         no-op floor check. `makeAddr` produces exactly this shape --
    ///         a valid address with zero deployed bytecode.
    function test_setExposureLedger_codelessLedgerRevertsWiringTx() public {
        address counterfactualLedger = makeAddr("counterfactualLedger");
        assertEq(counterfactualLedger.code.length, 0, "precondition: target must be genuinely codeless");

        vm.prank(regOwner);
        vm.expectRevert(); // Solidity's own extcodesize-guard revert, not a custom error
        registry.setExposureLedger(counterfactualLedger);

        assertEq(
            address(registry.exposureLedger()),
            address(0),
            "a codeless ledger must never get wired in -- the FAILURE-MODE CHECK: this reverts the WIRING tx, not some later unrelated call"
        );
    }

    /// @notice Sanity: the strict rewrite must not break the ordinary,
    ///         legitimate first-time-wiring order -- a real, freshly deployed
    ///         `ExposureLedger` with a conforming `challengeWindow` and an
    ///         unset (`address(0)`) reciprocal `guardianRegistry()` still
    ///         wires in cleanly. This is the reciprocal-tolerance the
    ///         FAILURE-MODE CHECK requires: strictness applies to CODE
    ///         PRESENCE, not to the legitimate zero value of a live read.
    function test_setExposureLedger_wellFormedLedgerStillWiresCleanly() public {
        ExposureLedger ledger = new ExposureLedger(makeAddr("ledgerOwner"), address(swood), 28 days);
        // Default challengeWindow (14 days) clears REVIEW_PERIOD (24h) + 7d.
        // ledger.guardianRegistry() is still address(0) -- untouched.

        vm.prank(regOwner);
        registry.setExposureLedger(address(ledger));

        assertEq(address(registry.exposureLedger()), address(ledger), "a well-formed ledger must still wire in");
    }

    // ══════════════════════ initialize blockQuorumBps ══════════════════════

    /// @notice `initialize` must mirror `setBlockQuorumBps`'s `[1000, 10000]`
    ///         bounds. A zero `blockQuorumBps` makes `_isBlocked`
    ///         (`blockStakeWeight * 10_000 >= blockQuorumBps * totalStakeAtOpen`)
    ///         true unconditionally, slashing every approver on every review
    ///         that isn't cohort-too-small.
    function test_initialize_rejectsZeroBlockQuorumBps() public {
        GuardianRegistry impl = new GuardianRegistry(6 hours);
        bytes memory badInit =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(swood), 3 days, 0));
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), badInit);
    }

    /// @notice Upper-bound companion: `blockQuorumBps_ > 10_000` (>100%)
    ///         would make the block quorum permanently unreachable and must
    ///         also be rejected, mirroring `setBlockQuorumBps`'s ceiling.
    function test_initialize_rejectsBlockQuorumBpsAboveTenThousand() public {
        GuardianRegistry impl = new GuardianRegistry(6 hours);
        bytes memory badInit =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(swood), 3 days, 10_001));
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), badInit);
    }

    /// @notice Sanity: an in-range value still deploys cleanly.
    function test_initialize_acceptsInRangeBlockQuorumBps() public {
        GuardianRegistry impl = new GuardianRegistry(6 hours);
        bytes memory okInit =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(swood), 3 days, 5_000));
        GuardianRegistry freshReg = GuardianRegistry(address(new ERC1967Proxy(address(impl), okInit)));
        assertEq(freshReg.blockQuorumBps(), 5_000);
    }
}
