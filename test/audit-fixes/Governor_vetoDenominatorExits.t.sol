// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title Governor_vetoDenominatorExits
/// @notice SHE-205 — the LP veto bar is priced against a supply SNAPSHOT, while
///         shares may leave freely for the whole of the vote. Deposits shut the
///         moment a proposal exists (`openProposalCount() != 0`) but redemptions
///         only once one EXECUTES (`getActiveProposal() != 0`), so a depositor
///         who arrives one block before `propose` is counted in the denominator
///         and can be gone before the vote settles — raising the veto bar
///         without ever casting a vote.
///
/// @dev    THE FIX UNDER TEST (option A): shares that exit during the voting
///         window are netted out of the veto denominator, AND a holder who
///         exits forfeits the vote they cast. Both halves are load-bearing and
///         each has its own test below:
///
///         - Net out exits WITHOUT rescinding votes and you have merely traded
///           one attack for its mirror: a voter casts a ballot, withdraws to
///           shrink the denominator their own ballot is measured against, and
///           forces a veto with less support than the bar nominally demands.
///           `test_she205_exitAfterVoting_cannotForceAVeto` is that guard.
///         - Rescind votes WITHOUT netting out exits and the original attack is
///           untouched, since the attacker never votes at all.
///           `test_she205_exitedDepositorDoesNotRaiseTheVetoBar` is that guard.
///
///         Numbers are chosen so the two cases sit on opposite sides of the
///         bar; see each test for the arithmetic.
contract GovernorVetoDenominatorExitsTest is Test {
    SyndicateGovernor public governor;
    ProtocolConfig public protocolConfig;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public targetToken;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public attacker = makeAddr("attacker");
    address public helper = makeAddr("helper");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000; // 40%
    uint256 constant COOLDOWN_PERIOD = 1 days;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        uint256 agentNftId = agentRegistry.mint(agent);

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    // Zero management fee: these tests assert on share
                    // arithmetic, and a fee accrual between propose and settle
                    // would move `totalAssets()` for reasons unrelated to the
                    // behaviour under test.
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(protocolConfig),
                address(this),
                address(deployTierRegistry(address(this))),
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
        // Checkpoints are timestamp-keyed; a proposal's snapshot is
        // `block.timestamp - 1`, so a deposit must land in an EARLIER second to
        // be counted. Advancing here is what makes these deposits eligible.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _executeCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 1)), value: 0
        });
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
    }

    function _propose() internal returns (uint256 proposalId) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://she205",
            7 days,
            env,
            _executeCalls(),
            GovEnvelope.defaultCaps(env.maxCapital, _executeCalls().length),
            _settleCalls(),
            GovEnvelope.defaultCaps(env.maxCapital, _settleCalls().length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _stateAfterVoting(uint256 pid) internal returns (ISyndicateGovernor.ProposalState) {
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        return governor.getProposalState(pid);
    }

    /// @dev Full instant exit for `who`.
    ///      The balance read is HOISTED deliberately: a call in ARGUMENT
    ///      position is evaluated before the call it is an argument to, so
    ///      `vault.redeem(vault.balanceOf(who), ...)` under a one-shot
    ///      `vm.prank` would consume the prank on `balanceOf` and run `redeem`
    ///      unpranked — surfacing as `ERC20InsufficientAllowance`, not as the
    ///      behaviour under test.
    function _exitAll(address who) internal {
        uint256 shares = vault.balanceOf(who);
        vm.prank(who);
        vault.redeem(shares, who, who);
    }

    /// @dev Partial exit sized in ASSETS. `redeem` takes SHARES, and this
    ///      vault carries a decimals offset, so the conversion is hoisted for
    ///      the same one-shot-cheatcode reason as `_exitAll`.
    function _exitAssets(address who, uint256 assets) internal {
        uint256 shares = vault.convertToShares(assets);
        vm.prank(who);
        vault.redeem(shares, who, who);
    }

    // ── 1. THE ATTACK ─────────────────────────────────────────────────────

    /// @notice A depositor who arrives before the proposal, never votes, and
    ///         leaves during the vote must not raise the bar for those who stay.
    ///
    /// @dev    Honest book is 100k (lp1 60k + lp2 40k); the bar is 40% = 40k, and
    ///         lp2's 40k Against meets it exactly, so the honest outcome is
    ///         Rejected. The attacker adds 100k one second before `propose`,
    ///         which freezes the snapshot at 200k and lifts the bar to 80k, then
    ///         exits during the vote. Their capital is gone before settlement,
    ///         but pre-fix the denominator still counts it and 40k < 80k flips
    ///         the outcome to Approved.
    function test_she205_exitedDepositorDoesNotRaiseTheVetoBar() public {
        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);
        _deposit(attacker, 100_000e6);

        uint256 pid = _propose();

        // The attacker never votes — that is the whole point. They simply leave.
        _exitAll(attacker);
        assertEq(vault.balanceOf(attacker), 0, "attacker has fully exited during the vote");

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Rejected),
            "40k Against against a real 100k book must veto: departed capital cannot hold up the bar"
        );
    }

    /// @notice Control for the above: with the attacker's capital STAYING, the
    ///         bar really is 80k and lp2's 40k genuinely falls short.
    /// @dev    Without this, the test above would still pass if the fix simply
    ///         ignored the denominator altogether. It pins that the bar tracks
    ///         capital that is actually present.
    function test_she205_capitalThatStaysDoesRaiseTheVetoBar() public {
        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);
        _deposit(attacker, 100_000e6);

        uint256 pid = _propose();

        // Same book as the attack case, except nobody leaves.
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "40k Against against a real 200k book is below the 80k bar"
        );
    }

    // ── 2. THE MIRROR ATTACK THE FIX MUST NOT OPEN ────────────────────────

    /// @notice A holder who votes Against and then withdraws must not thereby
    ///         force a veto. Their ballot leaves with their capital.
    ///
    /// @dev    THIS IS THE GUARD ON THE NAIVE FIX. Book is 100k, bar 40k. lp2
    ///         votes Against with 30k — short of the bar, so the honest outcome
    ///         is Approved. lp2 then withdraws all 30k.
    ///
    ///         Netting exits out of the denominator WITHOUT rescinding the vote
    ///         gives: supply 70k, bar 28k, votesAgainst still 30k → 30k >= 28k →
    ///         Rejected. A 30% holder would have beaten a 40% bar, which is
    ///         strictly worse than the bug being fixed.
    ///
    ///         With the vote rescinded on exit: supply 70k, bar 28k,
    ///         votesAgainst 0 → Approved, as it should be.
    function test_she205_exitAfterVoting_cannotForceAVeto() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);

        uint256 pid = _propose();

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        _exitAll(lp2);
        assertEq(vault.balanceOf(lp2), 0, "the voter has fully exited");

        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "a departing voter must not shrink the denominator their own ballot is measured against"
        );
    }

    /// @notice A voter who STAYS keeps full weight — the rescission must key on
    ///         exiting, not on having voted.
    /// @dev    Non-vacuity control for the test above: same 30k Against, but
    ///         lp2 holds. 30k < 40k bar, so Approved either way — the assertion
    ///         that carries the weight is `votesAgainst`, which must survive
    ///         intact rather than being zeroed by an over-broad rescission.
    function test_she205_voterWhoStaysKeepsFullWeight() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);

        uint256 pid = _propose();

        uint256 weight = vault.balanceOf(lp2);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        assertEq(governor.getProposal(pid).votesAgainst, weight, "a holder who stays keeps every vote they cast");
    }

    // ── 3. PARTIAL EXIT ───────────────────────────────────────────────────

    /// @notice A partial exit forfeits only the departed portion of the vote.
    /// @dev    Book 100k, bar 40k. lp2 votes Against with 50k — over the bar, so
    ///         Rejected if they stay. They then withdraw 20k, leaving 30k.
    ///         Netting: supply 80k, bar 32k; rescinding proportionally:
    ///         votesAgainst 30k. 30k < 32k → Approved. The holder cannot keep
    ///         the full 50k ballot while removing 20k from the denominator.
    function test_she205_partialExitForfeitsOnlyTheDepartedPortion() public {
        _deposit(lp1, 50_000e6);
        _deposit(lp2, 50_000e6);

        uint256 pid = _propose();

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        _exitAssets(lp2, 20_000e6);

        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "a partial exit must shrink the ballot in step with the denominator"
        );
    }

    // ── 4. DETERMINISM ────────────────────────────────────────────────────

    /// @notice The verdict must not move after `voteEnd`, whoever resolves it
    ///         and whenever.
    /// @dev    This is the property that ruled out pricing the bar against LIVE
    ///         supply. `resolveProposalState` is permissionless and
    ///         `_computeState` is a true view, so a denominator that kept
    ///         tracking supply would make the outcome an MEV race: withdraw,
    ///         resolve, redeposit. Exits are therefore counted only while
    ///         `block.timestamp <= voteEnd`, freezing the verdict there.
    function test_she205_verdictIsStableAfterVoteEnd() public {
        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);

        uint256 pid = _propose();

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        uint256 before = uint256(governor.getProposalState(pid));
        assertEq(before, uint256(ISyndicateGovernor.ProposalState.Rejected), "40k of 100k meets the 40% bar");

        // A large exit AFTER voting closed must not retroactively move the bar.
        _exitAll(lp1);

        assertEq(uint256(governor.getProposalState(pid)), before, "post-voteEnd flow must not change a settled verdict");
    }

    // ── 4. REVIEW OF #286 — the netting must not become its own weapon ────
    //
    // All four cases below FAIL against the first version of this fix, which
    // reported every outbound transfer and accumulated them gross.

    /// @notice A dust holder cannot move the denominator by bouncing shares.
    ///
    /// @dev    Plain `transfer` is not gated during a proposal. When the vault
    ///         reported every outbound move and the governor accumulated them,
    ///         ~1% of the book could be ping-ponged between two attacker-owned
    ///         addresses until the netted denominator hit zero — at which point
    ///         the veto check is skipped and a unanimous Against book is
    ///         ignored. 101 transfers sufficed. Only a BURN is reported now, so
    ///         the round trip is invisible and the bar is untouched.
    function test_she205_transferPingPongCannotDisableTheVeto() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        _deposit(attacker, 1_000e6);
        uint256 supply = vault.totalSupply();
        uint256 pid = _propose();

        _pingPong(supply);

        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Rejected),
            "a unanimous Against book must still veto"
        );
    }

    /// @notice A proposal nobody voted on is never Rejected, however small the
    ///         electorate has become.
    ///
    /// @dev    `vetoThreshold = liveSupply * 4000 / 10000` is integer division:
    ///         once `liveSupply` is small enough the bar is `0`, and
    ///         `votesAgainst >= 0` holds with an empty tally. Two share-units
    ///         left standing is the smallest honest way to reach it. The
    ///         threshold now floors at one vote.
    function test_she205_tinyElectorateStillNeedsOneVoteAgainst() public {
        _deposit(lp1, 100_000e6);
        uint256 pid = _propose();

        uint256 bal = vault.balanceOf(lp1);
        vm.prank(lp1);
        vault.redeem(bal - 2, lp1, lp1); // liveSupply == 2 -> bar rounds to 0

        // Nobody votes.
        assertTrue(
            _stateAfterVoting(pid) != ISyndicateGovernor.ProposalState.Rejected, "zero votes against must never reject"
        );
    }

    /// @notice Exiting BEFORE voting does not buy a cheaper veto.
    ///
    /// @dev    The mirror of `test_she205_exitAfterVoting_cannotForceAVeto`,
    ///         with the two statements swapped. `notifyShareExit` can only
    ///         rescind a ballot that already exists, so in this order it shrank
    ///         the denominator and left nothing to withdraw — 30% of the book
    ///         then cleared a bar set at 40% of the remaining 70%, with the
    ///         capital already gone. `vote` now caps weight at what the voter
    ///         still carries.
    function test_she205_exitBeforeVoting_cannotForceAVeto() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        uint256 pid = _propose();

        _exitAll(lp2);

        vm.prank(lp2);
        vm.expectRevert(ISyndicateGovernor.NoVotingPower.selector);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        assertTrue(
            _stateAfterVoting(pid) != ISyndicateGovernor.ProposalState.Rejected,
            "a fully exited holder must not carry a veto"
        );
    }

    /// @notice A share round trip leaves the ballot exactly where it was.
    ///
    /// @dev    The cut was keyed on gross shares moved, so an honest voter who
    ///         sent shares out and took them back lost their tally for good
    ///         (`_hasVoted` blocks re-voting). Worse, `transferFrom` reports
    ///         `from = the owner`, so any spender holding an allowance could
    ///         delete a voter's Against ballot without the holder acting at all.
    ///         Neither path fires now.
    function test_she205_shareRoundTripLeavesTheBallotIntact() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        uint256 pid = _propose();

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        uint256 againstBefore = governor.getProposal(pid).votesAgainst;
        assertGt(againstBefore, 0, "control: the ballot was actually cast");

        uint256 bal = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.transfer(helper, bal);
        vm.prank(helper);
        vault.transfer(lp2, bal);

        assertEq(vault.balanceOf(lp2), bal, "control: balance is back where it started");
        assertEq(governor.getProposal(pid).votesAgainst, againstBefore, "the ballot must survive a round trip");
    }

    /// @notice A delegatee votes the weight delegated to it, holding no shares.
    ///
    /// @dev    NON-VACUITY GUARD for the cap added to `vote`. The cap must read
    ///         `getVotes`, not `balanceOf`: this vault auto-delegates on receipt
    ///         but leaves an explicit delegation alone, so a delegatee carries
    ///         weight with a zero balance. A balance-based cap would silently
    ///         disenfranchise every delegation — and this test is what fails if
    ///         someone later "simplifies" it to one.
    function test_she205_delegateeVotesFullWeightHoldingNoShares() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);

        uint256 delegated = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.delegate(helper);
        vm.warp(vm.getBlockTimestamp() + 1); // let the checkpoint land before the snapshot

        uint256 pid = _propose();
        assertEq(vault.balanceOf(helper), 0, "control: the delegatee holds nothing");

        vm.prank(helper);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        assertEq(governor.getProposal(pid).votesAgainst, delegated, "delegated weight must survive the live-votes cap");
    }

    /// @dev Bounce the same shares between two attacker-controlled addresses
    ///      until `target` share-units have moved. Returns the transfer count so
    ///      a regression that makes this expensive is visible rather than silent.
    function _pingPong(uint256 target) internal returns (uint256 transfers) {
        address a = attacker;
        address b = helper;
        uint256 done;
        while (done < target) {
            uint256 amt = vault.balanceOf(a);
            if (amt == 0) break;
            if (done + amt > target) amt = target - done;
            vm.prank(a);
            vault.transfer(b, amt);
            done += amt;
            transfers++;
            (a, b) = (b, a);
        }
    }
}
