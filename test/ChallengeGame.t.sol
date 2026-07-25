// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChallengeGame} from "src/ChallengeGame.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @dev Governor stub. The game reads exactly two fields off `getProposal`:
///      `executedAt` (a challenge only exists against an EXECUTED proposal) and
///      `vault` (consumed by the slash path in the next task).
contract MockChallengeGovernor {
    mapping(uint256 proposalId => ISyndicateGovernor.StrategyProposal) internal _proposals;

    function setExecuted(uint256 proposalId, address vault, uint256 executedAt) external {
        _proposals[proposalId].vault = vault;
        _proposals[proposalId].executedAt = executedAt;
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
    }
}

/// @dev Exposure-ledger stub: the covering approver set with each one's
///      committed USD, the governance WOOD price, and a REAL per-proposal
///      freeze flag so the tests can assert the freeze actually landed rather
///      than merely that a call was made.
contract MockChallengeLedger {
    uint256 public woodUsdPriceX8;

    mapping(bytes32 reviewKey => address[]) internal _approvers;
    mapping(bytes32 reviewKey => mapping(address guardian => uint256)) internal _committed;
    mapping(bytes32 reviewKey => bool) internal _frozen;

    constructor(uint256 priceX8) {
        woodUsdPriceX8 = priceX8;
    }

    function setWoodUsdPrice(uint256 priceX8) external {
        woodUsdPriceX8 = priceX8;
    }

    function setApprovers(address governor, uint256 proposalId, address[] memory guardians, uint256[] memory usd)
        external
    {
        bytes32 k = _key(governor, proposalId);
        delete _approvers[k];
        for (uint256 i = 0; i < guardians.length; i++) {
            _approvers[k].push(guardians[i]);
            _committed[k][guardians[i]] = usd[i];
        }
    }

    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory guardians, uint256[] memory committedUsd)
    {
        bytes32 k = _key(governor, proposalId);
        guardians = _approvers[k];
        committedUsd = new uint256[](guardians.length);
        for (uint256 i = 0; i < guardians.length; i++) {
            committedUsd[i] = _committed[k][guardians[i]];
        }
    }

    function freezeCoverage(address governor, uint256 proposalId) external {
        _frozen[_key(governor, proposalId)] = true;
    }

    function unfreezeCoverage(address governor, uint256 proposalId) external {
        _frozen[_key(governor, proposalId)] = false;
    }

    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool) {
        return _frozen[_key(governor, proposalId)];
    }

    function _key(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }
}

/// @dev Tier-registry stub. Wired at construction; the demotion itself belongs
///      to the passed-challenge path (next task), so nothing here is called yet.
contract MockChallengeTierRegistry {
    address public lastTarget;
    bytes4 public lastSelector;

    function demoteByChallenge(address target, bytes4 selector) external {
        lastTarget = target;
        lastSelector = selector;
    }
}

contract ChallengeGameTest is Test {
    ChallengeGame internal game;
    ERC20Mock internal wood;
    MockChallengeGovernor internal gov;
    MockChallengeLedger internal ledger;
    MockChallengeTierRegistry internal tiers;

    address internal owner = makeAddr("owner");
    address internal challenger = makeAddr("challenger");
    address internal guardianA = makeAddr("guardianA");
    address internal guardianB = makeAddr("guardianB");
    address internal vault = makeAddr("vault");

    uint256 internal constant PROPOSAL = 1;
    string internal constant EVIDENCE = "ipfs://bafyEvidence";

    function setUp() public {
        vm.warp(365 days); // keep executedAt well away from the genesis timestamp
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        gov = new MockChallengeGovernor();
        ledger = new MockChallengeLedger(0.05e8); // $0.05, the governance haircut price
        tiers = new MockChallengeTierRegistry();
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tiers));

        wood.mint(challenger, 10_000_000e18);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);
    }

    // ── Helpers ──

    /// @dev Two covering approvers with the given committed USD-18 shares.
    function _setCoverage(uint256 proposalId, uint256 usdA, uint256 usdB) internal {
        address[] memory guardians = new address[](2);
        uint256[] memory usd = new uint256[](2);
        guardians[0] = guardianA;
        guardians[1] = guardianB;
        usd[0] = usdA;
        usd[1] = usdB;
        ledger.setApprovers(address(gov), proposalId, guardians, usd);
    }

    function _execute(uint256 proposalId) internal {
        gov.setExecuted(proposalId, vault, block.timestamp);
    }

    // ── Filing ──

    /// @notice §3.4: filing pulls the bond, pins the accused coverage, and lands
    ///         the challenge in `Filed` awaiting silence or a counter-bond.
    function test_file_pullsBondFreezesCoverageAndRecords() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // $10,000 committed
        _execute(PROPOSAL);

        uint256 challengerBefore = wood.balanceOf(challenger);

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeFiled(
            1, address(gov), PROPOSAL, challenger, IChallengeGame.Predicate.OutOfAdapterOutflow, 10_000e18, EVIDENCE
        );
        vm.prank(challenger);
        uint256 id = game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, EVIDENCE);

        assertEq(id, 1, "first challenge id");
        assertEq(game.challengeCount(), 1);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(c.governor, address(gov));
        assertEq(c.proposalId, PROPOSAL);
        assertEq(c.challenger, challenger);
        assertEq(c.bondWood, 10_000e18);
        assertEq(c.counterBondWood, 0, "nobody has disputed yet");
        assertEq(uint8(c.predicate), uint8(IChallengeGame.Predicate.OutOfAdapterOutflow));
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Filed));
        assertEq(c.filedAt, block.timestamp);
        assertEq(c.frozenCoverageUsd, 10_000e18);

        assertTrue(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage pinned by the live challenge");
        assertEq(game.liveChallengeOf(address(gov), PROPOSAL), id);

        assertEq(wood.balanceOf(address(game)), 10_000e18, "bond custodied by the game");
        assertEq(challengerBefore - wood.balanceOf(challenger), 10_000e18, "bond pulled from the challenger");
    }

    /// @notice D4: with no proof required, the bond is the ONLY thing deterring
    ///         a frivolous filing, so it must scale with the exposure it freezes.
    ///         $10,000 x 500 bps = $500, at $0.05/WOOD = 10,000 WOOD.
    function test_file_bondScalesWithFrozenExposure() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // $10,000
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 small = game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, EVIDENCE);

        _setCoverage(2, 12_000e18, 8_000e18); // $20,000 — double
        _execute(2);
        vm.prank(challenger);
        uint256 big = game.file(address(gov), 2, IChallengeGame.Predicate.RogueAllowance, EVIDENCE);

        uint256 smallBond = game.challengeOf(small).bondWood;
        uint256 bigBond = game.challengeOf(big).bondWood;

        // The arithmetic itself, not just the ordering: usd * bps / 10_000 * 1e8 / priceX8.
        assertEq(smallBond, ((10_000e18 * 500) / 10_000) * 1e8 / 0.05e8, "500 USD at 0.05 USD/WOOD");
        assertEq(smallBond, 10_000e18);
        assertEq(bigBond, 20_000e18);
        assertEq(bigBond, 2 * smallBond, "twice the frozen exposure, twice the bond");
        assertEq(wood.balanceOf(address(game)), 30_000e18, "both bonds custodied");
    }

    /// @notice A challenge accuses an EXECUTED proposal — there is no drain to
    ///         allege before execution.
    function test_file_revertsWhenNotExecuted() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        // deliberately no _execute()
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.NotExecuted.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, EVIDENCE);
    }

    /// @notice §3.4: filing closes `challengeWindow` after execution. The final
    ///         second is still inside the window — the boundary is inclusive.
    function test_file_revertsAfterWindowCloses() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _setCoverage(2, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        _execute(2);
        uint256 executedAt = block.timestamp;

        // The last second of the window is still inside it.
        vm.warp(executedAt + game.challengeWindow());
        vm.prank(challenger);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OraclePriceDeviation, EVIDENCE);
        assertEq(game.challengeCount(), 1, "filed on the closing second");

        // One second later it is shut, for a proposal executed at the same time.
        vm.warp(executedAt + game.challengeWindow() + 1);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.file(address(gov), 2, IChallengeGame.Predicate.OraclePriceDeviation, EVIDENCE);
    }

    /// @notice One live challenge per proposal: a second filing would double the
    ///         freeze and the accounting on the same coverage.
    function test_file_revertsWhenAlreadyChallenged() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, EVIDENCE);

        address other = makeAddr("otherChallenger");
        wood.mint(other, 1_000_000e18);
        vm.startPrank(other);
        wood.approve(address(game), type(uint256).max);
        vm.expectRevert(IChallengeGame.AlreadyChallenged.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.ProposerLinkedOutflow, EVIDENCE);
        vm.stopPrank();
    }

    /// @notice Nothing to accuse: a proposal no guardian covered (or whose
    ///         approvers all released before execution) has no coverage to
    ///         freeze and therefore no bond to size against.
    function test_file_revertsWhenNothingToFreeze() public {
        _execute(PROPOSAL);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.NothingToFreeze.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, EVIDENCE);

        // An approver list whose committed shares are all zero is equally empty:
        // the ledger reports a released commitment as zero rather than dropping it.
        _setCoverage(PROPOSAL, 0, 0);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.NothingToFreeze.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, EVIDENCE);
    }

    /// @notice Every predicate takes the identical path (D1) — the enum is a
    ///         label carried in the event, not a branch.
    function test_file_everyPredicateTakesTheSamePath() public {
        for (uint256 i = 0; i <= uint256(type(IChallengeGame.Predicate).max); i++) {
            uint256 proposalId = 100 + i;
            _setCoverage(proposalId, 6_000e18, 4_000e18);
            _execute(proposalId);
            vm.prank(challenger);
            uint256 id = game.file(address(gov), proposalId, IChallengeGame.Predicate(i), EVIDENCE);
            IChallengeGame.Challenge memory c = game.challengeOf(id);
            assertEq(uint8(c.predicate), uint8(i));
            assertEq(c.bondWood, 10_000e18, "identical bond regardless of predicate");
            assertEq(uint8(c.status), uint8(IChallengeGame.Status.Filed));
        }
    }

    /// @notice Fail-closed on an unset WOOD price: an unpriceable bond is no
    ///         bond, and no bond is a free freeze.
    function test_file_revertsWhenWoodPriceUnset() public {
        ledger.setWoodUsdPrice(0);
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, EVIDENCE);
    }

    // ── Parameters ──

    function test_setters_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setChallengeWindow(7 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setChallengerBondBps(100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setExposureLedger(makeAddr("rogue"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setTierRegistry(makeAddr("rogue"));
    }

    function test_setChallengerBondBps_bounded() public {
        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setChallengerBondBps(0); // a free challenge is a free freeze
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setChallengerBondBps(10_001);
        game.setChallengerBondBps(1_000);
        vm.stopPrank();
        assertEq(game.challengerBondBps(), 1_000);

        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id = game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, EVIDENCE);
        assertEq(game.challengeOf(id).bondWood, 20_000e18, "10% of $10,000 at $0.05");
    }

    function test_setChallengeWindow_bounded() public {
        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setChallengeWindow(0);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setChallengeWindow(91 days);
        game.setChallengeWindow(7 days);
        vm.stopPrank();
        assertEq(game.challengeWindow(), 7 days);
    }
}
