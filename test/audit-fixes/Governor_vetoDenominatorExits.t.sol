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

    // ── 5. RE-REVIEW OF #286 — the ballot follows the VOTER's weight ──────
    //
    // Keying the rescission on the BURNING address left the ballot attached
    // to an account and the capital free to leave through another: vote, move
    // the shares, redeem them elsewhere. The denominator fell by the full
    // amount, the ballot stayed, and 29% forced a veto against a 40% bar with
    // every cent returned. A ballot is a claim on voting weight, so it now
    // tracks the weight of the address that cast it — recomputed against live
    // `getVotes` whenever that weight moves, by transfer, burn or delegation.

    /// @notice Vote, transfer the shares to a second address, redeem there.
    /// @dev    The burner never voted, so a burner-keyed lookup found nothing to
    ///         rescind. The transfer itself now empties the ballot: lp2's live
    ///         weight is zero the moment the shares leave, whoever burns them.
    function test_she205_voteThenLaunderThenBurn_cannotForceAVeto() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        uint256 pid = _propose();

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        uint256 bal = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.transfer(helper, bal);
        _exitAll(helper);

        assertEq(usdc.balanceOf(helper), 30_000e6, "control: the capital came back in full");
        assertEq(governor.getProposal(pid).votesAgainst, 0, "the ballot must leave with the weight");
        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "30% must not veto a 40% bar by burning from a second address"
        );
    }

    /// @notice The delegatee votes; the underlying holder redeems.
    /// @dev    The ballot lives under the delegatee, the burn is reported for
    ///         the holder. Resolving the voter through the delegation graph is
    ///         what connects the two.
    function test_she205_delegateeVotes_holderExits_cannotForceAVeto() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        vm.prank(lp2);
        vault.delegate(helper);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 pid = _propose();

        vm.prank(helper);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _exitAll(lp2);

        assertEq(governor.getProposal(pid).votesAgainst, 0, "a delegatee's ballot must fall with the holder's exit");
        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "30% must not veto a 40% bar through a delegatee"
        );
    }

    /// @notice The delegatee votes; the holder re-delegates to itself, then redeems.
    /// @dev    Resolving `delegates(from)` at burn time is not enough on its own:
    ///         after the re-delegation the holder's delegate is the holder, and
    ///         the delegatee's ballot would survive the burn. Delegation moves
    ///         weight too, so it is reported like a transfer.
    function test_she205_delegateeVotes_holderRedelegatesThenExits_cannotForceAVeto() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        vm.prank(lp2);
        vault.delegate(helper);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 pid = _propose();

        vm.prank(helper);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        vm.prank(lp2);
        vault.delegate(lp2);
        assertEq(governor.getProposal(pid).votesAgainst, 0, "re-delegation moves the weight out from under the ballot");

        _exitAll(lp2);
        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "30% must not veto a 40% bar by re-delegating before the exit"
        );
    }

    /// @notice The ballot is recomputed, not decremented: weight that returns
    ///         restores it.
    /// @dev    Keeps finding 3 of the first review closed under the new rule.
    ///         An honest voter who sends shares out and takes them back ends
    ///         where they started; a spender pulling on an allowance can only
    ///         suspend the ballot, not delete it.
    function test_she205_ballotFollowsTheWeightOutAndBack() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        uint256 pid = _propose();

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        uint256 cast = governor.getProposal(pid).votesAgainst;
        assertGt(cast, 0, "control: the ballot was cast");

        uint256 bal = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.transfer(helper, bal);
        assertEq(governor.getProposal(pid).votesAgainst, 0, "weight out, ballot out");

        vm.prank(helper);
        vault.transfer(lp2, bal);
        assertEq(governor.getProposal(pid).votesAgainst, cast, "weight back, ballot back");
    }

    /// @notice DOCUMENTED TRADEOFF. Shares transferred away BEFORE voting are
    ///         weight nobody can cast: the sender's cap has fallen, the
    ///         recipient has no snapshot weight, and the bar does not move.
    /// @dev    Deliberate. Letting the recipient vote would need a live-weight
    ///         electorate, which is the MEV race `_voteExitShares` exists to
    ///         avoid; letting the sender keep the weight is exactly the ballot
    ///         without capital behind it that this fix removes. A holder who
    ///         sells mid-vote has chosen not to vote with what they sold. This
    ///         test pins that choice so a change to it is a decision, not drift.
    function test_she205_transferBeforeVoting_destroysWeightNotTheBar() public {
        _deposit(lp1, 50_000e6);
        _deposit(lp2, 50_000e6);
        uint256 pid = _propose();
        uint256 supplyBefore = vault.totalSupply();

        uint256 moved = vault.convertToShares(30_000e6);
        vm.prank(lp2);
        vault.transfer(helper, moved);

        vm.prank(helper);
        vm.expectRevert(ISyndicateGovernor.NoVotingPower.selector);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        assertEq(governor.getProposal(pid).votesAgainst, vault.balanceOf(lp2), "the sender votes only what they kept");
        assertEq(vault.totalSupply(), supplyBefore, "a transfer does not move the bar");
        assertEq(
            uint256(_stateAfterVoting(pid)),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "20% cannot veto: the 30% that moved is cast by nobody"
        );
    }

    // ── 6. THE PINNED PROPERTY: the veto floor is 40% under every strategy ─

    uint8 constant STRAT_STAY = 0;
    uint8 constant STRAT_VOTE_THEN_EXIT = 1;
    uint8 constant STRAT_EXIT_THEN_VOTE = 2;
    uint8 constant STRAT_VOTE_LAUNDER_BURN = 3;
    uint8 constant STRAT_DELEGATEE_VOTES_HOLDER_EXITS = 4;
    uint8 constant STRAT_VOTE_THEN_HALF_EXIT = 5;
    uint8 constant STRAT_DELEGATEE_VOTES_REDELEGATE_EXIT = 6;
    uint8 constant STRAT_COUNT = 7;

    /// @notice Sweep the attacker's share of the book from 20% to 45% across
    ///         every exit strategy the two reviews found. No strategy vetoes
    ///         below 40%, and staying put vetoes at 40% and above.
    /// @dev    This is the assertion the individual cases approximate: the
    ///         effective bar is 40% of the book whatever the attacker does with
    ///         their shares during the window. Each case runs from a state
    ///         snapshot so the cases are independent.
    function test_she205_vetoFloorIsFortyPercentUnderEveryExitStrategy() public {
        uint256 floor = type(uint256).max;
        for (uint256 pct = 20; pct <= 45; pct++) {
            for (uint8 s = 0; s < STRAT_COUNT; s++) {
                uint256 snap = vm.snapshotState();
                bool vetoed = _runStrategy(pct, s);
                vm.revertToState(snap);

                if (vetoed) {
                    assertGe(pct, 40, string.concat("strategy ", vm.toString(s), " vetoed below the 40% bar"));
                    if (pct < floor) floor = pct;
                }
                if (s == STRAT_STAY && pct >= 40) {
                    assertTrue(vetoed, "an honest 40% must still veto");
                }
            }
        }
        assertEq(floor, 40, "the effective veto floor must be exactly the configured 40%");
    }

    /// @dev Book is 100k: `pct`% to the attacker, the rest to lp1, who never
    ///      votes. Returns whether the proposal ends Rejected.
    function _runStrategy(uint256 pct, uint8 s) internal returns (bool) {
        _deposit(lp1, (100 - pct) * 1_000e6);
        _deposit(attacker, pct * 1_000e6);
        bool viaDelegatee = s == STRAT_DELEGATEE_VOTES_HOLDER_EXITS || s == STRAT_DELEGATEE_VOTES_REDELEGATE_EXIT;
        if (viaDelegatee) {
            vm.prank(attacker);
            vault.delegate(helper);
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        uint256 pid = _propose();
        address voter = viaDelegatee ? helper : attacker;

        if (s == STRAT_EXIT_THEN_VOTE) {
            _exitAll(attacker);
            vm.prank(attacker);
            try governor.vote(pid, ISyndicateGovernor.VoteType.Against) {} catch {}
        } else {
            vm.prank(voter);
            governor.vote(pid, ISyndicateGovernor.VoteType.Against);
            if (s == STRAT_VOTE_THEN_EXIT || s == STRAT_DELEGATEE_VOTES_HOLDER_EXITS) {
                _exitAll(attacker);
            } else if (s == STRAT_VOTE_LAUNDER_BURN) {
                uint256 bal = vault.balanceOf(attacker);
                vm.prank(attacker);
                vault.transfer(helper, bal);
                _exitAll(helper);
            } else if (s == STRAT_VOTE_THEN_HALF_EXIT) {
                _exitAssets(attacker, pct * 500e6);
            } else if (s == STRAT_DELEGATEE_VOTES_REDELEGATE_EXIT) {
                vm.prank(attacker);
                vault.delegate(attacker);
                _exitAll(attacker);
            }
        }
        return _stateAfterVoting(pid) == ISyndicateGovernor.ProposalState.Rejected;
    }

    // ── 7. ROUND-3 REVIEW — the reports cannot be starved ─────────────────
    //
    // Both reports were best-effort raw calls with no gas floor. Under
    // EIP-150 a caller keeps 1/64 of its gas and forwards the rest, so a
    // call site with almost no trailing work -- `delegate()` -- could be run
    // at a gas cap where the vault finished and the governor starved. The
    // move landed, the report did not, and the round-2 exploit came back:
    // vote, `delegate(address(0))` at ~40k gas, transfer to a mule, redeem.
    // The vault now requires enough gas to fund a fixed grant to the
    // governor and reverts otherwise, so a starved report is a reverted
    // transaction rather than a silent skip. The sweeps below pin that on
    // every call site a report hangs off.

    uint256 constant SWEEP_LO = 21_000;
    uint256 constant SWEEP_HI = 400_000;
    uint256 constant SWEEP_STEP = 250;

    /// @notice `delegate(address(0))` at any gas cap either reverts or cuts
    ///         the ballot. There is no cap at which the delegation lands and
    ///         the ballot stands.
    function test_she205_delegateCannotStarveTheBallotReport() public {
        _deposit(lp1, 71_000e6);
        _deposit(attacker, 29_000e6);
        uint256 pid = _propose();
        vm.prank(attacker);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        uint256 cast = governor.getProposal(pid).votesAgainst;
        assertGt(cast, 0, "control: ballot cast");

        uint256 landed;
        for (uint256 cap = SWEEP_LO; cap <= SWEEP_HI; cap += SWEEP_STEP) {
            uint256 snap = vm.snapshotState();
            vm.prank(attacker);
            (bool ok,) = address(vault).call{gas: cap}(abi.encodeCall(vault.delegate, (address(0))));
            if (ok) {
                landed++;
                assertEq(vault.getVotes(attacker), 0, "control: the delegation landed");
                assertEq(governor.getProposal(pid).votesAgainst, 0, "a landed delegation must have cut the ballot");
            }
            vm.revertToState(snap);
        }
        assertGt(landed, 0, "control: some cap let the delegation through");
    }

    /// @notice A gas-capped transfer that returns a voter's shares either
    ///         reverts or restores the ballot. An allowance holder cannot pull
    ///         and push back at a cap that leaves the LP with shares and no vote.
    function test_she205_returnTransferCannotStarveTheRestore() public {
        _deposit(lp1, 55_000e6);
        _deposit(lp2, 45_000e6);
        uint256 pid = _propose();
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        uint256 cast = governor.getProposal(pid).votesAgainst;

        uint256 bal = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.approve(helper, bal);
        vm.prank(helper);
        vault.transferFrom(lp2, helper, bal);
        assertEq(governor.getProposal(pid).votesAgainst, 0, "control: the pull cut the ballot");

        uint256 landed;
        for (uint256 cap = SWEEP_LO; cap <= SWEEP_HI; cap += SWEEP_STEP) {
            uint256 snap = vm.snapshotState();
            vm.prank(helper);
            (bool ok,) = address(vault).call{gas: cap}(abi.encodeCall(vault.transfer, (lp2, bal)));
            if (ok) {
                landed++;
                assertEq(vault.balanceOf(lp2), bal, "control: the shares came back");
                assertEq(governor.getProposal(pid).votesAgainst, cast, "a landed return must have restored the ballot");
            }
            vm.revertToState(snap);
        }
        assertGt(landed, 0, "control: some cap let the return through");
    }

    /// @notice A gas-capped `redeem` either reverts or nets the denominator.
    ///         The burn report is held to the same floor as the ballot report,
    ///         so the audited path cannot be re-opened by starving it.
    function test_she205_redeemCannotStarveTheExitReport() public {
        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);
        _deposit(attacker, 100_000e6);
        uint256 pid = _propose();
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        uint256 shares = vault.balanceOf(attacker);

        uint256 landed;
        for (uint256 cap = SWEEP_LO; cap <= SWEEP_HI; cap += SWEEP_STEP) {
            uint256 snap = vm.snapshotState();
            vm.prank(attacker);
            (bool ok,) = address(vault).call{gas: cap}(abi.encodeCall(vault.redeem, (shares, attacker, attacker)));
            if (ok) {
                landed++;
                assertEq(vault.balanceOf(attacker), 0, "control: the redeem landed");
                assertEq(
                    uint256(_stateAfterVoting(pid)),
                    uint256(ISyndicateGovernor.ProposalState.Rejected),
                    "a landed redeem must have netted the denominator"
                );
            }
            vm.revertToState(snap);
        }
        assertGt(landed, 0, "control: some cap let the redeem through");
    }

    /// @notice The grant the vault hands each report is a hard ceiling, so
    ///         the governor's work per report must sit well inside it or a
    ///         fully funded call is starved by construction. Measured cold,
    ///         on the most expensive shape (a ballot that changes).
    function test_she205_reportGasGrantCoversAColdRecompute() public {
        _deposit(lp1, 70_000e6);
        _deposit(lp2, 30_000e6);
        uint256 pid = _propose();
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        uint256 bal = vault.balanceOf(lp2);

        // Make lp2's live votes fall WITHOUT the report landing, so the
        // measured call actually has a cut to record. The governor's hook is
        // mocked to a no-op for the duration of the transfer.
        vm.mockCall(address(governor), abi.encodeWithSelector(governor.notifyVotingWeightMoved.selector), "");
        vm.prank(lp2);
        vault.transfer(helper, bal);
        vm.clearMockedCalls();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));
        assertEq(governor.getProposal(pid).votesAgainst, bal, "control: the ballot is stale");

        vm.cool(address(governor));
        vm.cool(address(vault));
        vm.prank(address(vault));
        uint256 g0 = gasleft();
        governor.notifyVotingWeightMoved(lp2);
        uint256 used = g0 - gasleft();
        emit log_named_uint("cold notifyVotingWeightMoved gas", used);
        assertEq(governor.getProposal(pid).votesAgainst, 0, "control: the recompute ran");
        assertLt(
            used * 2, vault.GOVERNANCE_REPORT_GAS(), "the grant must leave at least 2x headroom over a cold recompute"
        );

        vm.cool(address(governor));
        vm.cool(address(vault));
        vm.prank(address(vault));
        g0 = gasleft();
        governor.notifyShareExit(1);
        used = g0 - gasleft();
        emit log_named_uint("cold notifyShareExit gas", used);
        assertLt(
            used * 2, vault.GOVERNANCE_REPORT_GAS(), "the grant must leave at least 2x headroom over a cold exit report"
        );
    }

    /// @notice DOCUMENTED BOUNDARY. A ballot suspended inside the window and
    ///         whose weight returns only after `voteEnd` is not restored.
    /// @dev    Deliberate, and the same reason the denominator freezes there:
    ///         a tally that moved after the window would make the verdict a
    ///         race between `resolveProposalState` callers. The attacker
    ///         version of this -- vote, exit, re-acquire weight after `voteEnd`
    ///         against the already-shrunk denominator -- is exactly what the
    ///         freeze forecloses. Cost falls on a holder whose shares are moved
    ///         out by an allowance holder across the boundary; that holder can
    ///         already be redeemed out by the same allowance.
    function test_she205_suspensionAtVoteEndIsNotRestored() public {
        _deposit(lp1, 55_000e6);
        _deposit(lp2, 45_000e6);
        uint256 pid = _propose();
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        uint256 bal = vault.balanceOf(lp2);
        vm.prank(lp2);
        vault.approve(helper, bal);
        vm.prank(helper);
        vault.transferFrom(lp2, helper, bal);
        assertEq(governor.getProposal(pid).votesAgainst, 0, "control: suspended inside the window");

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        vm.prank(helper);
        vault.transfer(lp2, bal);
        assertEq(vault.balanceOf(lp2), bal, "control: the shares came back");
        assertEq(governor.getProposal(pid).votesAgainst, 0, "a return after voteEnd does not reopen the tally");
        assertTrue(
            governor.getProposalState(pid) != ISyndicateGovernor.ProposalState.Rejected,
            "the verdict is a pure function of the window"
        );
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
