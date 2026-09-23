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
/// @notice SHE-205 / SHE-258: while a proposal is open no share is minted or burned, so the
///         veto bar is measured against a supply nothing can shrink. The only exit is a
///         queued redeem, cancellable until its proposal is stamped at settle.
contract GovernorVetoDenominatorExitsTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    ERC20Mock usdc;
    MockAgentRegistry agentReg;
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
        agentReg = new MockAgentRegistry();
        uint256 nft = agentReg.mint(agent);
        ISyndicateVault.InitParams memory ip = ISyndicateVault.InitParams(
            address(usdc),
            "Sherwood Vault",
            "swUSDC",
            owner,
            address(new BatchExecutorLib()),
            true,
            address(agentReg),
            0
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

    function _depositNoWarp(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal {
        _depositNoWarp(who, amount);
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

    /// @dev The collaborative path: a Draft that stamps its electorate at the co-agent's approval.
    function _proposeCollab(address coAgent) internal returns (uint256 pid) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](1);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: coAgent, splitBps: 2000});
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(0),
            "she282-collab",
            7 days,
            env,
            _calls(1),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _calls(0),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            coProps
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _registerCoAgent(address who) internal {
        // startPrank, not prank: `agentReg.mint` sits in argument position and is evaluated
        // first, so a one-shot prank would be consumed by the mint.
        vm.startPrank(owner);
        vault.registerAgent(agentReg.mint(who), who);
        vm.stopPrank();
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

    /// @notice Instant redeem/withdraw revert from propose until settle; ERC20 transfer still works.
    function test_sharesCannotLeaveTheVaultWhileAProposalIsOpen() public {
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
    ///         the vault, so the electorate drops to the live supply and 100% of it Against rejects.
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
        assertEq(governor.getProposal(pid).votableSupply, lp1Shares, "the electorate is clamped at the live supply");
        assertLe(_vetoBar(pid), vault.totalSupply(), "the bar is reachable by the shares that still exist");
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

    /// @notice 400k of supply with 100k parked in the queue and 200k redeemed ahead of propose in
    ///         the same block: the parked shares are out and the exit leaves the electorate, so the
    ///         electorate is the two live LPs' 100k and lp1's 45k Against is 45% — over the 40% bar.
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

        uint256 s = governor.getProposal(pid).snapshotTimestamp;
        uint256 electorate = governor.getProposal(pid).votableSupply;
        assertEq(vault.getPastVotes(lp2, s), 0, "the parked shares carry no castable weight");
        assertEq(electorate, vault.balanceOf(lp1) + vault.balanceOf(lp3), "electorate is the two live LPs");
        assertEq(vault.getPastTotalSupply(s) - lp2Shares, electorate + attackerShares, "snapshot still holds the exit");
        assertEq(vault.totalSupply(), vault.balanceOf(lp1) + vault.balanceOf(lp3) + lp2Shares, "attacker really exited");
        assertLe(_vetoBar(pid), vault.totalSupply() - lp2Shares, "the bar is reachable by the unparked live shares");

        // 45% of the electorate Against: over the 40% bar.
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    /// @notice Queued shares are outside the electorate: 200k of supply with 100k parked gives a
    ///         100k votable set, not 200k.
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

    /// @notice The collaborative Draft already holds the redeem lock, so the queue is open right
    ///         up to the approval that stamps the electorate. Read live there, lp2's escrowed 30k
    ///         would leave the bar at 70k while his snapshot weight still voted — 42.9%, a veto.
    ///         Read at the snapshot instant both terms predate the escrow, the bar is the full
    ///         100k, and 30% falls short of the 40% threshold.
    function test_collab_queuedRedeemInTheApproveBlockCannotShrinkTheVetoBar() public {
        address coAgent = makeAddr("coAgent");
        _registerCoAgent(coAgent);

        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        uint256 supply = vault.totalSupply();

        uint256 pid = _proposeCollab(coAgent);

        assertEq(
            uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Draft), "still a Draft"
        );
        assertTrue(vault.redemptionsLocked(), "the Draft holds the lock, so the queue is the only exit");

        // Hoisted: `balanceOf` in argument position would eat the one-shot prank.
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.requestRedeem(lp2Shares, lp2);

        // SAME BLOCK, ahead of the approval that transitions Draft -> Pending and stamps.
        vm.prank(coAgent);
        governor.approveCollaboration(pid);

        assertEq(vault.balanceOf(address(queue)), lp2Shares, "the shares really are escrowed in the queue");
        assertEq(governor.getProposal(pid).votableSupply, supply, "the recorded electorate is the full supply");

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    /// @notice Both delegation entrypoints are refused whatever the target, and `delegateBySig`
    ///         reverts before it ever looks at the signature (zeros get the same revert).
    function test_delegate_isRefused() public {
        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);
        vm.startPrank(lp1);
        vm.expectRevert(ISyndicateVault.DelegationDisabled.selector);
        vault.delegate(address(0));
        vm.expectRevert(ISyndicateVault.DelegationDisabled.selector);
        vault.delegate(lp2);
        vm.expectRevert(ISyndicateVault.DelegationDisabled.selector);
        vault.delegate(lp1);
        vm.expectRevert(ISyndicateVault.DelegationDisabled.selector);
        vault.delegateBySig(lp2, 0, type(uint256).max, 0, bytes32(0), bytes32(0));
        vm.expectRevert(ISyndicateVault.DelegationDisabled.selector);
        vault.delegateBySig(address(0), 0, 0, 0, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(vault.delegates(lp1), lp1, "the receipt self-delegated and nothing could move it");
        assertEq(vault.getVotes(lp1), vault.balanceOf(lp1), "votes equal balance");
    }

    /// @notice THE ATTACK SHAPE. The attacker holds X == 2G, twice the honest float, and tries to
    ///         walk its votes out of the electorate one block before the approval stamps it:
    ///         `getPastTotalSupply` would still count the shares while `getPastVotes` no longer
    ///         did, so the bar would be b*(G+X) over an electorate of only G — unreachable. The
    ///         vault refuses, so the recorded electorate is exactly the weight that can be cast.
    function test_undelegationCannotInflateTheVetoBar() public {
        address coAgent = makeAddr("coAgent");
        _registerCoAgent(coAgent);

        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);
        uint256 honest = vault.totalSupply(); // G
        _deposit(attacker, 200_000e6);
        uint256 attackerShares = vault.balanceOf(attacker); // X
        assertEq(attackerShares, 2 * honest, "the attacker holds twice the honest float");

        uint256 pid = _proposeCollab(coAgent);

        // The Draft already holds the redeem lock, so the queue is the only exit. lp2 takes it
        // before the stamp, putting real weight on the excluded side of the electorate.
        // Hoisted: `balanceOf` in argument position would eat the one-shot prank.
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.requestRedeem(lp2Shares, lp2);
        vm.warp(vm.getBlockTimestamp() + 1);

        // At the snapshot instant itself, the tightest the exit could be timed.
        vm.prank(attacker);
        vm.expectRevert(ISyndicateVault.DelegationDisabled.selector);
        vault.delegate(address(0));
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(coAgent);
        governor.approveCollaboration(pid);

        uint256 s = governor.getProposal(pid).snapshotTimestamp;
        uint256 queued = vault.getPastVotes(address(queue), s);
        assertEq(queued, lp2Shares, "lp2's escrowed shares are the queue's snapshot votes");
        assertEq(
            governor.getProposal(pid).votableSupply, honest + attackerShares - queued, "electorate is G + X - queued"
        );
        assertEq(governor.getVoteWeight(pid, attacker), attackerShares, "capital at risk still buys a vote");
        // Every share's votes are somewhere -- no holder walked out of the snapshot...
        assertEq(
            vault.getPastVotes(lp1, s) + vault.getPastVotes(lp2, s) + vault.getPastVotes(attacker, s) + queued,
            vault.getPastTotalSupply(s),
            "sum over every holder equals the snapshot supply"
        );
        // ...and the electorate is that sum less the queue's, which cannot vote.
        assertEq(
            governor.getProposal(pid).votableSupply,
            vault.getPastVotes(lp1, s) + vault.getPastVotes(lp2, s) + vault.getPastVotes(attacker, s),
            "the electorate is exactly the castable weight outside the queue"
        );
    }

    /// @notice The same invariant on the direct path: `delegate(queue)` would walk weight out of
    ///         the electorate's second term, and it is refused alongside `delegate(0)`.
    function test_directPath_votableSupplyEqualsTheCastableWeight() public {
        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);
        _deposit(attacker, 200_000e6);

        vm.startPrank(attacker);
        vm.expectRevert(ISyndicateVault.DelegationDisabled.selector);
        vault.delegate(address(0));
        vm.expectRevert(ISyndicateVault.DelegationDisabled.selector);
        vault.delegate(address(queue));
        vm.stopPrank();

        uint256 pid = _propose();
        uint256 s = governor.getProposal(pid).snapshotTimestamp;
        assertEq(vault.balanceOf(address(queue)), 0, "nothing is parked, so the electorate is the whole supply");
        assertEq(governor.getProposal(pid).votableSupply, vault.totalSupply(), "300k of shares, 300k of electorate");
        assertEq(
            governor.getProposal(pid).votableSupply,
            vault.getPastVotes(lp1, s) + vault.getPastVotes(lp2, s) + vault.getPastVotes(attacker, s),
            "the electorate is exactly the castable weight"
        );
    }

    /// @notice SHE-292: a deposit ordered ahead of `propose` in the same block carries no snapshot
    ///         weight, so it must stay outside the recorded electorate too.
    function test_sameBlockDepositIsOutsideTheVetoElectorate() public {
        _deposit(lp1, 100_000e6);
        _depositNoWarp(attacker, 200_000e6); // same block as propose, ordered first

        uint256 pid = _propose();
        uint256 s = governor.getProposal(pid).snapshotTimestamp;

        assertEq(vault.getPastVotes(attacker, s), 0, "funded after the snapshot, so no castable weight");
        assertEq(
            governor.getProposal(pid).votableSupply,
            vault.getPastVotes(lp1, s) + vault.getPastVotes(attacker, s),
            "electorate is exactly the castable weight"
        );
    }

    /// @notice An exit ordered ahead of `propose` in the same block keeps its snapshot vote
    ///         weight, but the electorate counts only weight still backed by shares in the vault.
    function test_directPathElectorateIsTheCastableWeightStillBackedByShares() public {
        _deposit(lp1, 100_000e6);
        _deposit(attacker, 200_000e6);

        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, attacker); // same block as propose, ordered first

        uint256 pid = _propose();
        uint256 s = governor.getProposal(pid).snapshotTimestamp;

        assertEq(governor.getVoteWeight(pid, attacker), attackerShares, "the exit keeps its snapshot weight");
        assertEq(
            governor.getProposal(pid).votableSupply,
            vault.getPastVotes(lp1, s),
            "but the electorate is only the weight whose shares are still in the vault"
        );
        assertEq(governor.getProposal(pid).votableSupply, vault.totalSupply(), "which is the live supply");
    }

    /// @notice F1 (NM 6.4-F2): a collaborative Draft created AND finally approved in the block
    ///         behind an instant redeem stamps at `t-1` too, so the same clamp must hold there.
    function test_collab_sameBlockDraftAndApproveBehindARedeemCannotInflateTheVetoBar() public {
        address coAgent = makeAddr("coAgent");
        _registerCoAgent(coAgent);
        _deposit(lp1, 100_000e6);
        _deposit(attacker, 200_000e6);

        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, attacker); // block N, ahead of the Draft

        uint256 pid = _proposeCollabNoWarp(coAgent); // Draft, same block
        vm.prank(coAgent);
        governor.approveCollaboration(pid); // stamps, same block

        assertEq(governor.getProposal(pid).votableSupply, vault.totalSupply(), "electorate clamped at live supply");
        assertLe(_vetoBar(pid), vault.totalSupply(), "the bar is reachable by the shares that still exist");

        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against); // 100% of the live supply
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    /// @dev A Draft that does not warp, so its final approval stamps in the creation block.
    function _proposeCollabNoWarp(address coAgent) internal returns (uint256 pid) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](1);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: coAgent, splitBps: 2000});
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(0),
            "f1-collab",
            7 days,
            env,
            _calls(1),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _calls(0),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            coProps
        );
    }

    /// @notice A request escrowed before the snapshot and cancelled in the approve block: lp2 has no
    ///         snapshot weight, so the electorate is min(S - Q, L - min(Q, lq)) = 100k, not 300k.
    function test_collab_preSnapshotRequestCancelledInTheApproveBlockStaysOutOfTheElectorate() public {
        address coAgent = makeAddr("coAgent");
        _registerCoAgent(coAgent);
        _deposit(lp1, 100_000e6);
        _deposit(lp2, 200_000e6);
        uint256 pid = _proposeCollab(coAgent);
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        uint256 req = vault.requestRedeem(lp2Shares, lp2); // at the coming snapshot instant
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp2);
        queue.cancel(req); // same block as the approval that stamps
        vm.prank(coAgent);
        governor.approveCollaboration(pid);
        uint256 s = governor.getProposal(pid).snapshotTimestamp;
        assertEq(vault.getPastVotes(address(queue), s), lp2Shares, "Q: escrowed at the snapshot");
        assertEq(vault.balanceOf(address(queue)), 0, "lq: cancelled since");
        assertEq(vault.getPastVotes(lp2, s), 0, "lp2 has no snapshot weight");
        assertEq(governor.getProposal(pid).votableSupply, vault.balanceOf(lp1), "electorate is lp1 alone");
    }

    /// @notice Queue `shares` under a proposal that settles (stamping the request), never claim it,
    ///         and stop at the block of the next propose.
    function _parkStamped(address who, uint256 shares) internal {
        uint256 pid0 = _propose();
        vm.prank(who);
        vault.requestRedeem(shares, who);
        _endVote();
        governor.executeProposal(pid0);
        _settle(pid0);
        vm.warp(governor.getCooldownEnd());
    }

    /// @notice 200k parked (stamped, unclaimed) and an exit of R <= P ahead of propose in its block:
    ///         the live supply still counts the parked 200k, so only dropping them from the live side
    ///         too leaves lp1's 100k as the electorate and 100% of it Against rejects (NM 6.4 residual).
    function test_stampedParkedSharesCannotHideASameBlockPreProposeRedeem() public {
        _deposit(lp1, 100_000e6);
        _deposit(attacker, 400_000e6);
        uint256 parked = vault.balanceOf(attacker) / 2;
        _parkStamped(attacker, parked);
        uint256 redeemed = vault.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(redeemed, attacker, attacker); // same block, ahead of propose
        uint256 pid = _propose();
        uint256 snap = governor.getProposal(pid).snapshotTimestamp;
        assertEq(vault.getPastVotes(address(queue), snap), parked, "the parked shares are the queue's snapshot term");
        assertEq(vault.getPastTotalSupply(snap) - parked, vault.balanceOf(lp1) + redeemed, "snapshot holds the exit");
        assertEq(vault.totalSupply(), vault.balanceOf(lp1) + parked, "live supply holds the parked shares");
        assertEq(governor.getProposal(pid).votableSupply, vault.balanceOf(lp1), "electorate is lp1 alone");
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    function _vetoBar(uint256 pid) internal view returns (uint256) {
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(pid);
        return (p.votableSupply * p.vetoThresholdBps) / 10_000;
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
