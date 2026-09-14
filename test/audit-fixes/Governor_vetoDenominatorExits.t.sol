// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title Governor_vetoDenominatorExits
/// @notice SHE-205 / SHE-258 / SHE-287: the veto electorate is recorded at the Draft -> Pending
///         stamp, and from there to settle no share is burned, so the bar is measured against a
///         set nothing can shrink. The only exit past Draft is a queued redeem, cancellable
///         until its proposal is stamped at settle. A Draft locks nothing.
contract GovernorVetoDenominatorExitsTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    ERC20Mock usdc;
    MockAgentRegistry reg;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address attacker = makeAddr("attacker");

    function setUp() public {
        ProtocolConfig cfg = new ProtocolConfig(owner);
        vm.prank(owner);
        cfg.setProtocolFeeRecipient(owner);
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        reg = new MockAgentRegistry();
        uint256 nft = reg.mint(agent);
        ISyndicateVault.InitParams memory ip = ISyndicateVault.InitParams(
            address(usdc), "Sherwood Vault", "swUSDC", owner, address(new BatchExecutorLib()), true, address(reg), 0
        );
        bytes memory vInit = abi.encodeCall(SyndicateVault.initialize, (ip));
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(new SyndicateVault()), vInit))));
        vm.prank(owner);
        vault.registerAgent(nft, agent);
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        ISyndicateGovernor.GovernorParams memory gp =
            ISyndicateGovernor.GovernorParams(1 days, 1 days, 4000, 1500, 1 days, 48 hours, 5, 1 hours, 30 days);
        address tiers = address(deployTierRegistry(address(this)));
        bytes memory gInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (address(vault), address(new MockRegistryMinimal()), address(cfg), address(this), tiers, gp)
        );
        governor =
            SyndicateGovernor(address(new ERC1967Proxy(address(new SyndicateGovernor(24 hours, 1 hours)), gInit)));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));
    }

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1); // snapshot is `timestamp - 1`
    }

    function _calls(uint256 allowance) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call(address(usdc), abi.encodeCall(usdc.approve, (address(1), allowance)), 0);
    }

    function _propose() internal returns (uint256 pid) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        ISyndicateGovernor.CoProposer[] memory none;
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(0),
            "she258",
            7 days,
            env,
            _calls(1),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _calls(0),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            none
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev A collaborative Draft: same batch as `_propose`, one co-proposer who has not
    ///      approved yet. Returns the pid and the co-proposer that can take it to Pending.
    function _proposeDraft() internal returns (uint256 pid, address coAgent) {
        coAgent = makeAddr("coAgent");
        uint256 nft = reg.mint(coAgent);
        vm.prank(owner);
        vault.registerAgent(nft, coAgent);
        ISyndicateGovernor.CoProposer[] memory co = new ISyndicateGovernor.CoProposer[](1);
        co[0] = ISyndicateGovernor.CoProposer({agent: coAgent, splitBps: 2000});
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(0),
            "she287",
            7 days,
            env,
            _calls(1),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _calls(0),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            co
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _endVote() internal {
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
    }

    function _settle(uint256 pid) internal {
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
    }

    function _instantExitReverts(address who) internal {
        assertEq(vault.maxRedeem(who), 0);
        assertEq(vault.maxWithdraw(who), 0);
        vm.prank(who);
        vm.expectPartialRevert(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector);
        vault.redeem(1, who, who);
    }

    /// @notice Instant redeem/withdraw revert from Pending until settle; ERC20 transfer still works.
    function test_sharesCannotLeaveTheVaultWhileAProposalIsPastDraft() public {
        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);
        uint256 supply = vault.totalSupply();
        uint256 pid = _propose();
        assertTrue(vault.redemptionsLocked(), "locked at Pending");
        _instantExitReverts(lp1);
        _endVote();
        _instantExitReverts(lp1); // Approved, not yet executed
        governor.executeProposal(pid);
        _instantExitReverts(lp1);
        uint256 half = vault.balanceOf(lp1) / 2;
        uint256 lp2Before = vault.balanceOf(lp2);
        vm.prank(lp1);
        vault.transfer(lp2, half);
        assertEq(vault.balanceOf(lp2), lp2Before + half, "shares still move between holders");
        assertEq(vault.totalSupply(), supply, "supply unchanged from propose to settle");
        _settle(pid);
        assertFalse(vault.redemptionsLocked(), "unlocked at settle");
        vm.prank(lp1);
        vault.redeem(half, lp1, lp1);
        assertLt(vault.totalSupply(), supply, "instant exit reopened after settle");
    }

    /// @notice A queued redeem is the only exit while a proposal is open; it can be cancelled until stamped.
    function test_queuedRedeemIsTheOnlyExitDuringAProposalAndIsCancellableUntilStamped() public {
        _deposit(lp1, 60_000e6);
        uint256 shares = vault.balanceOf(lp1);
        vm.prank(lp1);
        vm.expectRevert(ISyndicateVault.RedemptionsNotLocked.selector);
        vault.requestRedeem(shares, lp1); // no proposal open: instant path only
        uint256 pid = _propose();
        vm.startPrank(lp1);
        uint256 first = vault.requestRedeem(shares / 2, lp1);
        uint256 second = vault.requestRedeem(shares / 2, lp1);
        assertEq(queue.getRequest(first).pid, pid, "tagged with the open (not yet executing) proposal");
        assertEq(vault.totalSupply(), shares, "queued shares stay in supply");
        queue.cancel(first);
        assertEq(vault.balanceOf(lp1), shares / 2, "cancel returns the escrowed shares before the stamp");
        vm.stopPrank();
        _endVote();
        governor.executeProposal(pid);
        _settle(pid);
        vm.prank(lp1);
        vm.expectRevert(IVaultWithdrawalQueue.AlreadySettled.selector);
        queue.cancel(second);
        vm.prank(lp1);
        queue.claim(second);
        assertEq(vault.totalSupply(), shares / 2, "the claim burns the queued shares at the settle price");
    }

    /// @notice The veto denominator at resolve is the supply snapshot at propose; nothing the attacker
    ///         does between propose and settle moves it. 80k Against on a 200k snapshot sits exactly on
    ///         the 40% bar; one unit fewer clears it.
    function test_vetoBarEqualsTheSnapshotSupplyBecauseNoShareCanLeave() public {
        assertEq(uint256(_resolveWithAgainst(80_000e6)), uint256(ISyndicateGovernor.ProposalState.Rejected));
        setUp(); // fresh instance for the other side of the bar
        assertEq(uint256(_resolveWithAgainst(80_000e6 - 1)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    /// @notice A redeem ordered ahead of propose in its block is in the snapshot but gone from
    ///         the supply recorded as the electorate, so 100% of that electorate Against rejects.
    function test_sameBlockPreProposeRedeemCannotInflateTheVetoBar() public {
        _deposit(lp1, 100_000e6);
        _deposit(attacker, 200_000e6); // block N-1; the fixture then warps to block N
        uint256 lp1Shares = vault.balanceOf(lp1);
        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, attacker); // block N, ahead of propose
        uint256 pid = _propose();
        uint256 snapshot = vault.getPastTotalSupply(governor.getProposal(pid).snapshotTimestamp);
        assertEq(snapshot, lp1Shares + attackerShares, "attacker's shares are in the snapshot");
        assertEq(vault.totalSupply(), lp1Shares, "and gone from the live supply");
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    /// @notice Control: with nothing leaving in the propose block the recorded electorate equals
    ///         the snapshot supply, and 39% Against does not reach the 40% bar.
    function test_vetoBarIsTheSnapshotSupplyWhenNothingLeftInTheProposeBlock() public {
        _deposit(lp1, 39_000e6);
        _deposit(lp2, 61_000e6);
        uint256 pid = _propose();
        assertEq(vault.totalSupply(), vault.getPastTotalSupply(governor.getProposal(pid).snapshotTimestamp));
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    /// @notice A holder who queues a redeem AFTER propose still votes with snapshot weight, and
    ///         the electorate was already recorded, so the bar must not shrink by his shares.
    ///         250k supply, bar 100k; 90k queued and voted Against is short of the bar.
    function test_queuedRedeemAfterTheSnapshotDoesNotShrinkTheVetoBar() public {
        _deposit(lp1, 160_000e6);
        _deposit(attacker, 90_000e6);
        uint256 pid = _propose();
        vm.startPrank(attacker);
        vault.requestRedeem(vault.balanceOf(attacker), attacker);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        vm.stopPrank();
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    /// @notice Queue a full redeem under pid0, settle it, and claim (burn) in the block of the next
    ///         propose. The burned shares are gone from live supply AND still the queue's snapshot
    ///         votes, so they must be removed once, not twice.
    function _queueClaimThenPropose(address who) internal returns (uint256 pid1, uint256 burned) {
        uint256 pid0 = _propose();
        burned = vault.balanceOf(who);
        vm.prank(who);
        uint256 req = vault.requestRedeem(burned, who);
        _endVote();
        governor.executeProposal(pid0);
        _settle(pid0);
        vm.warp(governor.getCooldownEnd()); // propose honours the settle cooldown
        vm.prank(who);
        queue.claim(req); // same block as propose(pid1)
        pid1 = _propose();
        uint256 snap = governor.getProposal(pid1).snapshotTimestamp;
        assertEq(vault.getPastTotalSupply(snap), vault.totalSupply() + burned, "snapshot still holds the burned shares");
        assertEq(vault.getPastVotes(address(queue), snap), burned, "and the queue term counts them");
    }

    /// @notice 100k live vs 200k claimed: the earlier min-before-subtract gave 0 and skipped the
    ///         veto entirely; the recorded votable set is 100k, so 100% Against must reject.
    function test_queuedSharesClaimedInTheProposeBlockAreNotSubtractedTwice_zeroBar() public {
        _deposit(lp1, 100_000e6);
        _deposit(attacker, 200_000e6);
        (uint256 pid1,) = _queueClaimThenPropose(attacker);
        vm.prank(lp1);
        governor.vote(pid1, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid1)), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    /// @notice 75k/25k live vs 50k claimed: the earlier min-before-subtract halved the bar
    ///         (40k -> 20k) and a 25% Against rejected; the true bar is 40k, so it must approve.
    function test_queuedSharesClaimedInTheProposeBlockAreNotSubtractedTwice_halvedBar() public {
        _deposit(lp1, 75_000e6);
        _deposit(lp2, 25_000e6);
        _deposit(attacker, 50_000e6);
        (uint256 pid1,) = _queueClaimThenPropose(attacker);
        vm.prank(lp2);
        governor.vote(pid1, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid1)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    /// @notice THE SHE-282 REPRO. 100k parked in the queue, 200k redeemed ahead of propose in
    ///         the same block: `min(snapshot - queueVotes, totalSupply())` read 200k and set the
    ///         bar at 80k, while the electorate that could actually vote was 100k. 45k Against —
    ///         45% of the real electorate — cleared the true 40k bar and missed the inflated one,
    ///         so the veto failed. The recorded votable set is 100k, so it now rejects.
    function test_parkedQueueAndSameBlockRedeemCannotInflateTheVetoBar() public {
        address lp3 = makeAddr("lp3");
        _deposit(lp1, 45_000e6);
        _deposit(lp3, 55_000e6);
        _deposit(lp2, 100_000e6);
        _deposit(attacker, 200_000e6);

        // lp2 parks its whole balance in the queue under a proposal that is then cancelled, so
        // nothing ever stamps or claims it — the shape the old denominator overcounted.
        uint256 parkPid = _propose();
        // Hoisted: `balanceOf` in argument position would eat the one-shot prank.
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.requestRedeem(lp2Shares, lp2);
        vm.prank(agent);
        governor.cancelProposal(parkPid);
        vm.warp(governor.getCooldownEnd());

        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, attacker); // ahead of propose, same block
        uint256 pid = _propose();

        uint256 electorate = vault.balanceOf(lp1) + vault.balanceOf(lp3);
        assertEq(governor.getProposal(pid).votableSupply, electorate, "electorate is the two live LPs");
        assertEq(vault.totalSupply(), electorate + lp2Shares, "the parked shares still exist");

        // 45% of the electorate Against: over the true 40% bar, under the old inflated one.
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    /// @notice Queued shares are outside the electorate: 200k of supply with 100k parked gives a
    ///         100k votable set, not 200k. Deliberately does NOT distinguish the live-at-propose
    ///         read from a snapshot read — on the direct path nothing can move shares into the
    ///         queue between the two instants (`requestRedeem` needs an open proposal, `propose`
    ///         needs none), so both reads agree here. See `design.md` Decision 1.
    function test_queuedSharesAreOutsideTheVetoElectorate() public {
        _deposit(lp1, 100_000e6);
        _deposit(lp2, 100_000e6);

        uint256 parkPid = _propose();
        // Hoisted: `balanceOf` in argument position would eat the one-shot prank.
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.requestRedeem(lp2Shares, lp2);
        vm.prank(agent);
        governor.cancelProposal(parkPid);
        vm.warp(governor.getCooldownEnd());

        uint256 pid = _propose();
        assertEq(
            governor.getProposal(pid).votableSupply, vault.balanceOf(lp1), "queued shares are not in the electorate"
        );
        assertEq(vault.totalSupply(), vault.balanceOf(lp1) + lp2Shares, "but they still exist");
    }

    // ── SHE-287: a Draft locks nothing; redeem locks at Pending, deposit at execute ──

    /// @notice A Draft binds the vault but locks no LP flow: instant redeem is open, and a
    ///         holder who leaves during the Draft is out of the supply at the snapshot instant,
    ///         so the recorded electorate excludes them.
    function test_draft_instantRedeemIsOpenAndLeavesTheElectorate() public {
        _deposit(lp1, 100_000e6);
        _deposit(lp2, 100_000e6);
        (uint256 pid, address coAgent) = _proposeDraft();

        assertFalse(vault.redemptionsLocked(), "a Draft must not lock redemption");
        assertFalse(vault.depositsLocked(), "a Draft must not lock deposits");
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.redeem(lp2Shares, lp2, lp2);
        vm.warp(vm.getBlockTimestamp() + 1); // the exit is in the past at the stamp

        vm.prank(coAgent);
        governor.approveCollaboration(pid);
        assertTrue(vault.redemptionsLocked(), "Pending locks redemption");
        assertEq(governor.getProposal(pid).votableSupply, vault.balanceOf(lp1), "electorate is lp1 alone");
        assertEq(governor.getVoteWeight(pid, lp2), 0, "and lp2 has no weight");
    }

    /// @notice THE COLLABORATIVE SAME-BLOCK EXIT (#320 review). The final approve's readiness is
    ///         public and instant redeem is open until it lands, so a holder bundles
    ///         `{redeem, approveCollaboration}`: gone from the live supply, still in the `t - 1`
    ///         weight. The electorate is read at the snapshot, so the bar is the one the weight
    ///         was measured against: 30k Against of a 100k electorate misses the 40% bar. A live
    ///         read would make it 30k of 70k — a free veto.
    function test_collab_sameBlockRedeemBeforeTheFinalApproveCannotShrinkTheVetoBar() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        (uint256 pid, address coAgent) = _proposeDraft();
        uint256 lp1Shares = vault.balanceOf(lp1);
        uint256 lp2Shares = vault.balanceOf(lp2);

        vm.prank(lp2);
        vault.redeem(lp2Shares, lp2, lp2); // same block as the final approve
        vm.prank(coAgent);
        governor.approveCollaboration(pid);

        assertEq(governor.getProposal(pid).votableSupply, lp1Shares + lp2Shares, "electorate read at the snapshot");
        assertEq(vault.totalSupply(), lp1Shares, "lp2 is gone from the live supply");
        assertEq(governor.getVoteWeight(pid, lp2), lp2Shares, "but keeps snapshot weight (Decision 2 class)");
        assertEq(usdc.balanceOf(lp2), 30_000e6, "with nothing at risk");

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    /// @notice The collaborative stamp's queue term: shares parked in the queue under an
    ///         earlier, cancelled proposal cannot vote and are outside the recorded electorate,
    ///         read at the snapshot through the queue's own checkpointed custody.
    function test_collab_parkedQueueSharesAreOutsideTheElectorate() public {
        _deposit(lp1, 100_000e6);
        _deposit(lp2, 100_000e6);

        uint256 parkPid = _propose();
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.requestRedeem(lp2Shares, lp2);
        vm.prank(agent);
        governor.cancelProposal(parkPid);
        vm.warp(governor.getCooldownEnd());

        (uint256 pid, address coAgent) = _proposeDraft();
        vm.prank(coAgent);
        governor.approveCollaboration(pid);
        assertEq(
            governor.getProposal(pid).votableSupply, vault.balanceOf(lp1), "queued shares are not in the electorate"
        );
        assertEq(vault.totalSupply(), vault.balanceOf(lp1) + lp2Shares, "but they still exist");
    }

    /// @notice THE COLLABORATIVE WINDOW IS UNREACHABLE (SHE-282 design.md Decision 3). The
    ///         attack front-ran the final `approveCollaboration` with `requestRedeem`, parking
    ///         shares in the queue so they left the electorate while the holder kept snapshot
    ///         weight. The queue only opens with the redeem lock, and a Draft does not hold it.
    function test_draft_queueIsClosed_soTheCollaborativeWindowIsUnreachable() public {
        _deposit(lp1, 100_000e6);
        _deposit(lp2, 100_000e6);
        (uint256 pid, address coAgent) = _proposeDraft();

        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        vm.expectRevert(ISyndicateVault.RedemptionsNotLocked.selector);
        vault.requestRedeem(lp2Shares, lp2); // the front-run, in the Draft window

        vm.prank(coAgent);
        governor.approveCollaboration(pid); // Pending: now the queue opens
        vm.prank(lp2);
        uint256 req = vault.requestRedeem(lp2Shares, lp2);
        assertGt(req, 0, "queue opens once redemption is locked");
        assertEq(
            governor.getProposal(pid).votableSupply, lp2Shares + vault.balanceOf(lp1), "stamped before the queue move"
        );
    }

    /// @notice Pending keeps instant deposit open, and a deposit after the stamp buys no vote:
    ///         weight is read at `snapshot`, and the electorate was already recorded.
    function test_pending_depositIsOpenButBuysNoVoteWeight() public {
        _deposit(lp1, 100_000e6);
        uint256 pid = _propose();
        uint256 electorate = governor.getProposal(pid).votableSupply;

        assertFalse(vault.depositsLocked(), "deposit lock waits for execute");
        _deposit(lp2, 100_000e6); // lands during Pending
        assertGt(vault.balanceOf(lp2), 0, "instant deposit open while Pending");
        assertEq(governor.getVoteWeight(pid, lp2), 0, "a post-stamp deposit has no weight");
        assertEq(governor.getProposal(pid).votableSupply, electorate, "the recorded electorate did not move");
        vm.prank(lp2);
        vm.expectRevert(ISyndicateGovernor.NoVotingPower.selector);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
    }

    /// @notice Execute is where the deposit lock lands: instant deposit closes, the async
    ///         lane opens tagged to the active pid, and settle reopens instant deposit.
    function test_executed_depositLocksAndTheLaneOpens() public {
        _deposit(lp1, 100_000e6);
        uint256 pid = _propose();
        _endVote();
        governor.executeProposal(pid);
        assertTrue(vault.depositsLocked(), "execute locks deposits");

        usdc.mint(lp2, 1_000e6);
        vm.startPrank(lp2);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, lp2);
        uint256 req = vault.requestDeposit(1_000e6, lp2);
        vm.stopPrank();
        assertEq(queue.getRequest(req).pid, pid, "lane request tagged to the executing proposal");

        _settle(pid);
        assertFalse(vault.depositsLocked(), "settle reopens deposits");
        assertFalse(vault.redemptionsLocked(), "settle reopens redemption");
    }

    function _resolveWithAgainst(uint256 againstAssets) internal returns (ISyndicateGovernor.ProposalState) {
        _deposit(lp1, againstAssets);
        _deposit(lp2, 120_000e6 - againstAssets);
        _deposit(attacker, 80_000e6);
        uint256 pid = _propose();
        uint256 snapshot = vault.getPastTotalSupply(governor.getProposal(pid).snapshotTimestamp);
        _instantExitReverts(attacker);
        vm.startPrank(attacker);
        vault.requestRedeem(vault.balanceOf(attacker) / 2, attacker);
        vault.transfer(lp2, vault.balanceOf(attacker));
        vm.stopPrank();
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(vault.totalSupply(), snapshot, "denominator at resolve == snapshot at propose");
        return governor.getProposalState(pid);
    }
}
