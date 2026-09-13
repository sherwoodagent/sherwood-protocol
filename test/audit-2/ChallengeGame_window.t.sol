// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockChallengeLedger, MockChallengeTierRegistry, MockChallengeStakedWood} from "../ChallengeGame.t.sol";

/// @dev Governor stub identical in shape to `ChallengeGame.t.sol`'s
///      `MockChallengeGovernor`, EXTENDED with a settable `strategyDuration` —
///      the field second-audit finding A's fix reads and the original mock
///      has no way to drive. Kept local to this file rather than editing the
///      shared mock, which is owned by a sibling agent's worktree right now.
contract MockGovernorWithDuration {
    mapping(uint256 proposalId => ISyndicateGovernor.StrategyProposal) internal _proposals;

    address public defaultTarget;
    bytes4 public defaultSelector;

    function setDefaultCall(address target, bytes4 selector) external {
        defaultTarget = target;
        defaultSelector = selector;
    }

    function setExecuted(uint256 proposalId, address vault_, uint256 executedAt, uint256 strategyDuration_) external {
        _proposals[proposalId].vault = vault_;
        _proposals[proposalId].executedAt = executedAt;
        _proposals[proposalId].strategyDuration = strategyDuration_;
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
    }

    function getExecuteCalls(uint256) external view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory one = new BatchExecutorLib.Call[](1);
        one[0] = BatchExecutorLib.Call({target: defaultTarget, data: abi.encodePacked(defaultSelector), value: 0});
        return one;
    }

    /// @dev Empty: this stub's only adapter sits on the execute leg. Implemented
    ///      so a filing naming anything else reaches `AdapterNotInProposal`
    ///      rather than reverting on a selector the stub does not carry.
    function getSettlementCalls(uint256) external pure returns (BatchExecutorLib.Call[] memory) {
        return new BatchExecutorLib.Call[](0);
    }
}

/// @dev `MockChallengeLedger` plus the one view `honestFilingNetPayoffBps`
///      needs (`proposerBondBps`) that the shared mock does not implement —
///      no existing test calls `honestFilingBreaksEven`/
///      `honestFilingNetPayoffBps` against it, so it was never added there.
///      Inherits everything else unchanged.
contract MockChallengeLedgerWithBondBps is MockChallengeLedger {
    uint256 public proposerBondBps;

    constructor(uint256 priceX8) MockChallengeLedger(priceX8) {}

    function setProposerBondBps(uint256 bps) external {
        proposerBondBps = bps;
    }
}

/// @title ChallengeGame_window
/// @notice Second-audit-181 regression suite for `ChallengeGame`/
///         `IChallengeGame`, findings A and D. Each test exercises the FAILURE
///         MODE the original finding described, not the happy path: a filing
///         landing in the gap the old deadline formula left open (A), and a
///         break-even boolean that cannot show magnitude (D).
contract ChallengeGame_window is Test {
    ChallengeGame internal game;
    ERC20Mock internal wood;
    MockGovernorWithDuration internal gov;
    MockChallengeLedgerWithBondBps internal ledger;
    MockChallengeTierRegistry internal tiers;
    MockChallengeStakedWood internal swood;

    address internal owner = makeAddr("owner2");
    address internal challenger = makeAddr("challenger2");
    address internal challengerB = makeAddr("challengerB2");
    address internal defender = makeAddr("defender2");
    address internal guardianA = makeAddr("guardianA2");
    address internal guardianB = makeAddr("guardianB2");
    address internal vault = makeAddr("vault2");

    uint256 internal constant PROPOSAL = 1;
    string internal constant EVIDENCE = "ipfs://bafyEvidence2";
    address internal constant ADAPTER = address(0xADA9);
    bytes4 internal constant SELECTOR = bytes4(0xfeedface);

    function setUp() public {
        vm.warp(365 days);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        gov = new MockGovernorWithDuration();
        gov.setDefaultCall(ADAPTER, SELECTOR);
        ledger = new MockChallengeLedgerWithBondBps(0.05e8);
        ledger.setProposerBondBps(100); // mirrors the real ledger's default 1%
        tiers = new MockChallengeTierRegistry();
        swood = new MockChallengeStakedWood();
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tiers));

        ledger.setCoverageFreezer(address(game));
        swood.setAuthorizedSlasher(address(game));
        vm.prank(owner);
        game.setStakedWood(address(swood));

        address[3] memory funders = [challenger, challengerB, defender];
        for (uint256 i = 0; i < funders.length; i++) {
            wood.mint(funders[i], 10_000_000e18);
            vm.prank(funders[i]);
            wood.approve(address(game), type(uint256).max);
        }
        for (uint256 i = 0; i < 2; i++) {
            address g = i == 0 ? guardianA : guardianB;
            wood.mint(g, 10_000_000e18);
            vm.prank(g);
            wood.approve(address(game), type(uint256).max);
        }
    }

    // ── Helpers ──

    function _setCoverage(uint256 proposalId, uint256 usdA, uint256 usdB) internal {
        address[] memory guardians = new address[](2);
        uint256[] memory usd = new uint256[](2);
        guardians[0] = guardianA;
        guardians[1] = guardianB;
        usd[0] = usdA;
        usd[1] = usdB;
        ledger.setApprovers(address(gov), proposalId, guardians, usd);
    }

    function _reviewKey(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    function _fileAs(address who, uint256 proposalId) internal returns (uint256 id) {
        vm.prank(who);
        id = game.file(
            address(gov), proposalId, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
    }

    // ── FINDING A — the challenge window must outlive settlement, not just execution ──

    /// @notice The exact failure mode: a filing landing AFTER the old
    ///         `executedAt + challengeWindow` deadline but BEFORE the
    ///         settlement calls the ledger required guardians to underwrite
    ///         have even run. Pre-fix this reverted `WindowClosed`, closing
    ///         the only door onto a drain that had not yet happened.
    function test_file_survivesPastOldChallengeWindow_whenSettlementIsStillPending() public {
        uint256 strategyDuration = 20 days;
        uint256 executedAt = vm.getBlockTimestamp();
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        gov.setExecuted(PROPOSAL, vault, executedAt, strategyDuration);

        // Past the OLD deadline (executedAt + 14d challengeWindow) but
        // strictly before settlement runs (executedAt + 20d strategyDuration).
        // A pre-fix `file` reverts `WindowClosed` right here.
        vm.warp(executedAt + game.challengeWindow() + 1 days);

        uint256 id = _fileAs(challenger, PROPOSAL);
        assertEq(id, 1, "filing must succeed while settlement risk is still live");
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Filed));
    }

    /// @notice The precise boundary, not merely "some later deadline": the
    ///         true deadline is `executedAt + strategyDuration +
    ///         challengeWindow` to the second. One challenger files exactly
    ///         AT it (succeeds); a second, independent challenger — a
    ///         different slot, so the first filing cannot block it — files
    ///         one second later against the SAME proposal and is refused.
    function test_file_boundaryIsExactlyExecutedAtPlusStrategyDurationPlusChallengeWindow() public {
        uint256 strategyDuration = 20 days;
        uint256 executedAt = vm.getBlockTimestamp();
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        gov.setExecuted(PROPOSAL, vault, executedAt, strategyDuration);

        uint256 trueDeadline = executedAt + strategyDuration + game.challengeWindow();

        vm.warp(trueDeadline);
        uint256 id = _fileAs(challenger, PROPOSAL);
        assertEq(
            uint8(game.challengeOf(id).status),
            uint8(IChallengeGame.Status.Filed),
            "exactly-at-deadline must still succeed"
        );

        vm.warp(trueDeadline + 1);
        vm.prank(challengerB);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);
    }

    // ── FINDING D — the boolean alone cannot show magnitude ──

    /// @notice `honestFilingBreaksEven()` reads `true` both when the
    ///         configuration is comfortably profitable AND when it is
    ///         trivially "free" (`settleBurnBps == 0`, cost side zeroed).
    ///         `honestFilingNetPayoffBps` must show the two apart by
    ///         magnitude even though the boolean cannot.
    function test_honestFilingNetPayoffBps_showsMagnitudeTheBooleanHides() public view {
        assertTrue(game.honestFilingBreaksEven());
        int256 payoffBefore = game.honestFilingNetPayoffBps();
        uint256 expectedReward = ledger.proposerBondBps() * game.prosecutorFeeBps();
        uint256 expectedCost = game.challengerBondBps() * game.settleBurnBps();
        assertEq(
            payoffBefore,
            int256(expectedReward) - int256(expectedCost),
            "must equal the reward-minus-cost formula the natspec commits to"
        );
    }

    /// @notice THE POINT OF HALVING `settleBurnBps` — prosecutor economics,
    ///         third-audit owner decision on audit #181 finding 18a's
    ///         residual.
    ///
    ///         Finding 18a halved the rate 2,000 -> 1,000 and left prosecution
    ///         still barely worth doing: `100*2,000 - 150*1,000 = +50,000`
    ///         bps^2, about $500 on a $1m proposal against $15,000 of bond
    ///         tied up for weeks. Halving again to 500 gives
    ///         `100*2,000 - 150*500 = +125,000` — 2.5x.
    ///
    ///         THE COST TERM WAS THE ONLY LEVER. `prosecutorFeeBps` was
    ///         already at `MAX_PROSECUTOR_FEE_BPS`, which `ProposerBondEscrow`
    ///         enforces independently, so the reward side could not be raised
    ///         without changing two contracts' ceilings. Asserted below so
    ///         that fact stays visible.
    ///
    ///         AND IT DOES NOT SUBSIDISE LYING. This rate burns part of a
    ///         WINNING challenger's bond. A false accuser never reaches it —
    ///         they lose on the merits and forfeit the WHOLE bond to the
    ///         accused, a different and untouched path. The honest payoff
    ///         rises; the deterrent against fabrication does not move.
    function test_prosecutorEconomics_halvedSettleBurnRaisesTheHonestPayoff() public view {
        assertEq(game.settleBurnBps(), 500, "the halved rate is the live default");
        assertEq(
            game.prosecutorFeeBps(),
            game.MAX_PROSECUTOR_FEE_BPS(),
            "the reward side is pinned at its ceiling -- which is why the cost side had to move"
        );
        assertTrue(game.honestFilingBreaksEven(), "an honest filing must at least break even");

        uint256 reward = ledger.proposerBondBps() * game.prosecutorFeeBps();
        int256 payoffNow = game.honestFilingNetPayoffBps();
        assertEq(
            payoffNow,
            int256(reward) - int256(game.challengerBondBps() * game.settleBurnBps()),
            "the view agrees with the two products it documents"
        );
        assertEq(payoffNow, int256(125_000), "+125,000 bps^2, ~$1,250 on a $1m proposal");

        // Fixture-independent statement of the improvement: recompute what the
        // same configuration would pay at the old 1,000 rate.
        int256 payoffAtOldRate = int256(reward) - int256(game.challengerBondBps() * 1_000);
        assertEq(payoffAtOldRate, int256(50_000), "the old rate's +50,000, for comparison");
        assertGt(payoffNow, payoffAtOldRate, "halving the burn strictly raised the honest filer's payoff");
    }

    /// @notice The degenerate case the finding names: zeroing the cost side
    ///         leaves the boolean unchanged (still `true`) while the signed
    ///         payoff moves — proving it carries information the boolean
    ///         discards.
    function test_honestFilingNetPayoffBps_movesWhileBooleanStaysTrueAtZeroCost() public {
        int256 payoffBefore = game.honestFilingNetPayoffBps();

        vm.prank(owner);
        game.setSettleBurnBps(0);

        assertTrue(game.honestFilingBreaksEven());
        int256 payoffAfter = game.honestFilingNetPayoffBps();
        assertGt(
            payoffAfter,
            payoffBefore,
            "zeroing the cost side must show up as a larger net payoff, not just the same 'true'"
        );
        uint256 expectedReward = ledger.proposerBondBps() * game.prosecutorFeeBps();
        assertEq(payoffAfter, int256(expectedReward), "at zero cost the net payoff is exactly the reward side");
    }
}
