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
    mapping(address guardian => uint256) internal _slashableBondUsd;

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

    /// @dev Per-approver slash rates, mirroring the real ledger's arithmetic:
    ///      `ceil(committed * 10_000 / slashableBondUsd)`, saturating at 100%
    ///      when the bond is gone or has fallen below what was committed.
    ///
    ///      An UNSET bond means zero slashable capital, which the real ledger
    ///      also prices at 10_000 — so a suite that never calls
    ///      `setSlashableBondUsd` sees the full-severity behaviour it did before
    ///      per-approver rates existed. That is a faithful mirror of the
    ///      `live == 0` branch, not a convenience default.
    function slashBpsFor(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory guardians, uint256[] memory bps)
    {
        bytes32 k = _key(governor, proposalId);
        guardians = _approvers[k];
        bps = new uint256[](guardians.length);
        for (uint256 i = 0; i < guardians.length; i++) {
            uint256 committed = _committed[k][guardians[i]];
            if (committed == 0) continue; // released -> owes nothing
            uint256 live = _slashableBondUsd[guardians[i]];
            if (live == 0 || committed >= live) {
                bps[i] = 10_000;
                continue;
            }
            bps[i] = (committed * 10_000 + live - 1) / live;
        }
    }

    function setSlashableBondUsd(address guardian, uint256 usd) external {
        _slashableBondUsd[guardian] = usd;
    }

    /// @dev Mirrors the real ledger's freeze check, so a test can prove the
    ///      guardian genuinely regains the ability to recycle its budget once a
    ///      challenge reaches a terminal state — not merely that a flag flipped.
    error CoverageFrozen();

    function releaseApproval(address governor, uint256 proposalId, address guardian) external {
        bytes32 k = _key(governor, proposalId);
        if (_frozen[k]) revert CoverageFrozen();
        _committed[k][guardian] = 0;
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

/// @dev Tier-registry stub recording the passed-challenge demotion.
contract MockChallengeTierRegistry {
    address public lastTarget;
    bytes4 public lastSelector;
    uint256 public demoteCount;

    function demoteByChallenge(address target, bytes4 selector) external {
        lastTarget = target;
        lastSelector = selector;
        demoteCount++;
    }
}

/// @dev sWOOD stub recording every argument of the verdict slash, so the tests
///      assert the SIX-parameter call the game actually makes — in particular
///      that the compensation case is pinned to `executedAt - 1` (D6) and the
///      verdict anchored at `filedAt`, which are the two easiest to get wrong.
contract MockChallengeStakedWood {
    uint256 public maxSlashBps = 10_000;
    uint256 public callCount;
    bytes32 public lastCaseKey;
    uint256 public lastOpenedAt;
    address[] internal _lastApprovers;
    uint256[] internal _lastSlashBpsPer;

    function lastSlashBpsPer() external view returns (uint256[] memory) {
        return _lastSlashBpsPer;
    }
    address public lastVault;
    uint256 public lastSnapshotTimestamp;

    uint256 internal _nextTotal = 1_000e18;
    uint256 internal _nextCaseId = 1;

    function setMaxSlashBps(uint256 v) external {
        maxSlashBps = v;
    }

    function setNextResult(uint256 total, uint256 caseId) external {
        _nextTotal = total;
        _nextCaseId = caseId;
    }

    function lastApprovers() external view returns (address[] memory) {
        return _lastApprovers;
    }

    function slashToEscrow(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer,
        address vault,
        uint256 snapshotTimestamp
    ) external returns (uint256, uint256) {
        callCount++;
        lastCaseKey = caseKey;
        lastOpenedAt = openedAt;
        _lastApprovers = approvers;
        _lastSlashBpsPer = slashBpsPer;
        lastVault = vault;
        lastSnapshotTimestamp = snapshotTimestamp;
        return (_nextTotal, _nextCaseId);
    }
}

contract ChallengeGameTest is Test {
    ChallengeGame internal game;
    ERC20Mock internal wood;
    MockChallengeGovernor internal gov;
    MockChallengeLedger internal ledger;
    MockChallengeTierRegistry internal tiers;
    MockChallengeStakedWood internal swood;

    address internal owner = makeAddr("owner");
    address internal challenger = makeAddr("challenger");
    address internal guardianA = makeAddr("guardianA");
    address internal guardianB = makeAddr("guardianB");
    address internal vault = makeAddr("vault");

    uint256 internal constant PROPOSAL = 1;
    string internal constant EVIDENCE = "ipfs://bafyEvidence";
    /// @dev The adapter the challenger accuses, and which a passed challenge
    ///      demotes. Named by the filer (§3.4), not derived on-chain.
    address internal constant ADAPTER = address(0xADA9);
    bytes4 internal constant SELECTOR = bytes4(0xfeedface);

    function setUp() public {
        vm.warp(365 days); // keep executedAt well away from the genesis timestamp
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        gov = new MockChallengeGovernor();
        ledger = new MockChallengeLedger(0.05e8); // $0.05, the governance haircut price
        tiers = new MockChallengeTierRegistry();
        swood = new MockChallengeStakedWood();
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tiers));
        vm.prank(owner);
        game.setStakedWood(address(swood));

        wood.mint(challenger, 10_000_000e18);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);
        // The accused need WOOD to match the challenger's bond when disputing.
        for (uint256 i = 0; i < 2; i++) {
            address g = i == 0 ? guardianA : guardianB;
            wood.mint(g, 10_000_000e18);
            vm.prank(g);
            wood.approve(address(game), type(uint256).max);
        }
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

    /// @dev `vm.getBlockTimestamp()` rather than `block.timestamp` throughout
    ///      this suite: with the optimizer on, solc common-subexpression-
    ///      eliminates repeated `TIMESTAMP` reads across external calls — sound
    ///      inside a real transaction, wrong either side of a `vm.warp`, and it
    ///      fails by silently yielding a stale "now" rather than by reverting.
    function _execute(uint256 proposalId) internal {
        gov.setExecuted(proposalId, vault, vm.getBlockTimestamp());
    }

    function _executedAt(uint256 proposalId) internal view returns (uint256) {
        return gov.getProposal(proposalId).executedAt;
    }

    function _filedAt(uint256 challengeId) internal view returns (uint256) {
        return game.challengeOf(challengeId).filedAt;
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
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );

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
        assertEq(c.filedAt, vm.getBlockTimestamp());
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
        uint256 small =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);

        _setCoverage(2, 12_000e18, 8_000e18); // $20,000 — double
        _execute(2);
        vm.prank(challenger);
        uint256 big = game.file(address(gov), 2, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);

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
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);
    }

    /// @notice §3.4: filing closes `challengeWindow` after execution. The final
    ///         second is still inside the window — the boundary is inclusive.
    function test_file_revertsAfterWindowCloses() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _setCoverage(2, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        _execute(2);
        uint256 executedAt = vm.getBlockTimestamp();

        // The last second of the window is still inside it.
        vm.warp(executedAt + game.challengeWindow());
        vm.prank(challenger);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OraclePriceDeviation, ADAPTER, SELECTOR, EVIDENCE);
        assertEq(game.challengeCount(), 1, "filed on the closing second");

        // One second later it is shut, for a proposal executed at the same time.
        vm.warp(executedAt + game.challengeWindow() + 1);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.file(address(gov), 2, IChallengeGame.Predicate.OraclePriceDeviation, ADAPTER, SELECTOR, EVIDENCE);
    }

    /// @notice One live challenge per proposal: a second filing would double the
    ///         freeze and the accounting on the same coverage.
    function test_file_revertsWhenAlreadyChallenged() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);

        address other = makeAddr("otherChallenger");
        wood.mint(other, 1_000_000e18);
        vm.startPrank(other);
        wood.approve(address(game), type(uint256).max);
        vm.expectRevert(IChallengeGame.AlreadyChallenged.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.ProposerLinkedOutflow, ADAPTER, SELECTOR, EVIDENCE);
        vm.stopPrank();
    }

    /// @notice Nothing to accuse: a proposal no guardian covered (or whose
    ///         approvers all released before execution) has no coverage to
    ///         freeze and therefore no bond to size against.
    function test_file_revertsWhenNothingToFreeze() public {
        _execute(PROPOSAL);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.NothingToFreeze.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);

        // An approver list whose committed shares are all zero is equally empty:
        // the ledger reports a released commitment as zero rather than dropping it.
        _setCoverage(PROPOSAL, 0, 0);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.NothingToFreeze.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);
    }

    /// @notice Every predicate takes the identical path (D1) — the enum is a
    ///         label carried in the event, not a branch.
    function test_file_everyPredicateTakesTheSamePath() public {
        for (uint256 i = 0; i <= uint256(type(IChallengeGame.Predicate).max); i++) {
            uint256 proposalId = 100 + i;
            _setCoverage(proposalId, 6_000e18, 4_000e18);
            _execute(proposalId);
            vm.prank(challenger);
            uint256 id = game.file(address(gov), proposalId, IChallengeGame.Predicate(i), ADAPTER, SELECTOR, EVIDENCE);
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
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);
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
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
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

    // ─────────────────────────────────────────────────────────────────────────
    // Task 4 — dispute, timeout, resolve, slash, demote
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A standard $10,000-covered, executed, challenged proposal. Execution
    ///      is deliberately 3 days BEFORE the filing so `executedAt - 1` and
    ///      `filedAt` are distinguishable in the slash assertions.
    function _fileStandard(uint256 proposalId) internal returns (uint256 id) {
        _setCoverage(proposalId, 6_000e18, 4_000e18);
        _execute(proposalId);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(challenger);
        id = game.file(
            address(gov), proposalId, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
    }

    /// @dev The §4 invariant, asserted point-by-point: the game custodies
    ///      exactly the bonds of the challenges still live.
    function _assertLiveBondsBacked() internal view {
        uint256 live;
        for (uint256 i = 1; i <= game.challengeCount(); i++) {
            IChallengeGame.Challenge memory c = game.challengeOf(i);
            if (c.status == IChallengeGame.Status.Filed || c.status == IChallengeGame.Status.Disputed) {
                live += c.bondWood + c.counterBondWood;
            }
        }
        assertEq(game.bondedWood(), live, "accounted bonds != live bonds");
        assertEq(wood.balanceOf(address(game)), live, "custody != live bonds");
    }

    // ── Undisputed: silence is the verdict ──

    /// @notice §3.4 + D1: nobody contested within `autoSlashDelay`, so the
    ///         silence IS the adjudication. The accused are slashed into the
    ///         compensation escrow as a case pinned to the block before the
    ///         challenged proposal executed (D6), the named adapter is demoted,
    ///         and the challenger gets its bond back.
    function test_resolve_undisputedSlashesDemotesAndReturnsBond() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 executedAt = _executedAt(PROPOSAL);
        uint256 filedAt = _filedAt(id);
        assertEq(filedAt, executedAt + 3 days, "the filing trails execution, so the two are distinguishable");
        uint256 challengerBefore = wood.balanceOf(challenger);

        swood.setNextResult(9_999e18, 42);
        vm.warp(filedAt + game.autoSlashDelay());

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeSettled(id, 9_999e18, 42);
        game.resolve(id); // permissionless — this test contract is nobody

        // The verdict slash, argument by argument.
        assertEq(swood.callCount(), 1, "slashed exactly once");
        assertEq(swood.lastCaseKey(), keccak256(abi.encode(address(gov), PROPOSAL)), "case key is the review key");
        assertEq(swood.lastOpenedAt(), filedAt, "verdict anchored at the filing");
        // Severity is now PER APPROVER, sourced from the ledger rather than
        // from one protocol-wide ceiling. The game must pass through exactly
        // what `slashBpsFor` derived — anything else would let the challenge
        // path invent a liability the ledger never booked.
        (, uint256[] memory expectedBps) = ledger.slashBpsFor(address(gov), PROPOSAL);
        uint256[] memory sentBps = swood.lastSlashBpsPer();
        assertEq(sentBps.length, expectedBps.length, "one rate per approver");
        for (uint256 i = 0; i < expectedBps.length; i++) {
            assertEq(sentBps[i], expectedBps[i], "rate passed through unmodified");
        }
        assertEq(swood.lastVault(), vault, "vault re-read from the proposal");
        assertEq(swood.lastSnapshotTimestamp(), executedAt - 1, "case pinned to the pre-drain block (D6)");
        address[] memory slashed = swood.lastApprovers();
        assertEq(slashed.length, 2);
        assertEq(slashed[0], guardianA);
        assertEq(slashed[1], guardianB);

        // The adapter the challenger named is demoted (§3.4, D7).
        assertEq(tiers.demoteCount(), 1);
        assertEq(tiers.lastTarget(), ADAPTER);
        assertEq(tiers.lastSelector(), SELECTOR);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Settled));
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage released on settlement");
        assertEq(game.liveChallengeOf(address(gov), PROPOSAL), 0, "no longer live");

        assertEq(wood.balanceOf(challenger) - challengerBefore, 10_000e18, "bond returned in full");
        _assertLiveBondsBacked();
    }

    /// @notice The snapshot is pinned to the pre-drain block, so a slash whose
    ///         proposal executed long before the filing still compensates the
    ///         holders of record at the drain — never the post-drain buyers.
    function test_resolve_pinsTheCaseToTheBlockBeforeExecution() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        uint256 executedAt = _executedAt(PROPOSAL);
        vm.warp(executedAt + 10 days);
        vm.prank(challenger);
        uint256 id =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);

        vm.warp(_filedAt(id) + game.autoSlashDelay());
        game.resolve(id);
        assertEq(swood.lastSnapshotTimestamp(), executedAt - 1);
        assertLt(swood.lastSnapshotTimestamp(), swood.lastOpenedAt(), "snapshot precedes the verdict");
    }

    /// @notice Only the guardians STILL covering the proposal are slashed. One
    ///         that released before the filing committed nothing to this
    ///         proposal and answers for nothing (D2).
    function test_resolve_slashesOnlyStillCommittedApprovers() public {
        _setCoverage(PROPOSAL, 10_000e18, 0); // guardianB released before the filing
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);

        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay());
        game.resolve(id);

        address[] memory slashed = swood.lastApprovers();
        assertEq(slashed.length, 1, "the released approver is not accused");
        assertEq(slashed[0], guardianA);
    }

    /// @notice A filing that names no adapter (predicates 2/3/5 often indict a
    ///         price or an envelope, not a certification) still slashes — it
    ///         just demotes nothing.
    function test_resolve_withoutAnAdapterDemotesNothing() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OraclePriceDeviation, address(0), bytes4(0), EVIDENCE
        );
        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay());
        game.resolve(id);

        assertEq(swood.callCount(), 1, "still slashed");
        assertEq(tiers.demoteCount(), 0, "nothing was accused, so nothing is demoted");
    }

    /// @notice The delay is the guardians' entire window to notice and contest
    ///         (D1) — it cannot be short-circuited by an impatient challenger.
    function test_resolve_revertsBeforeTheAutoSlashDelay() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay() - 1);
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(id);
        assertEq(swood.callCount(), 0);
    }

    function test_resolve_revertsOnATerminalOrUnknownChallenge() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay());
        game.resolve(id);

        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(id); // no double-slash
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(999); // never existed
    }

    /// @notice The slash path has no sink without sWOOD wired, and must fail
    ///         closed rather than silently settling without slashing anyone.
    function test_resolve_revertsWhenStakedWoodUnset() public {
        ChallengeGame bare = new ChallengeGame(owner, address(wood), address(ledger), address(tiers));
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.startPrank(challenger);
        wood.approve(address(bare), type(uint256).max);
        uint256 id = bare.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + bare.autoSlashDelay());
        vm.expectRevert(IChallengeGame.ZeroAddress.selector);
        bare.resolve(id);
    }

    // ── Dispute ──

    /// @notice §3.4: an accused approver posts a matching counter-bond, which
    ///         stops the auto-slash clock and escalates to the court.
    function test_dispute_stopsTheAutoSlashClock() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 filedAt = vm.getBlockTimestamp();
        uint256 guardianBefore = wood.balanceOf(guardianA);

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeDisputed(id, guardianA, 10_000e18);
        vm.prank(guardianA);
        game.dispute(id);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Disputed));
        assertEq(c.counterBondWood, c.bondWood, "the counter-bond matches the challenger's");
        assertEq(c.disputer, guardianA);
        assertEq(guardianBefore - wood.balanceOf(guardianA), 10_000e18, "counter-bond pulled");
        _assertLiveBondsBacked();

        // The clock is stopped: the auto-slash deadline passes with no effect.
        vm.warp(filedAt + game.autoSlashDelay());
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(id);

        // And it stays stopped right up to the dispute timeout.
        vm.warp(filedAt + game.disputeTimeout() - 1);
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(id);
        assertEq(swood.callCount(), 0, "a disputed challenge never reaches the slash");
        assertTrue(ledger.isCoverageFrozen(address(gov), PROPOSAL), "still frozen while contested");
    }

    /// @notice Only the ACCUSED may buy the escalation. Anyone else posting a
    ///         counter-bond would be paying to stop a clock they are not under.
    function test_dispute_revertsForANonApprover() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.NotAccusedApprover.selector);
        game.dispute(id);

        address stranger = makeAddr("stranger");
        wood.mint(stranger, 1_000_000e18);
        vm.startPrank(stranger);
        wood.approve(address(game), type(uint256).max);
        vm.expectRevert(IChallengeGame.NotAccusedApprover.selector);
        game.dispute(id);
        vm.stopPrank();
    }

    /// @notice A guardian that released its commitment before the filing is not
    ///         among the accused, so it has nothing to defend here either.
    function test_dispute_revertsForAReleasedApprover() public {
        _setCoverage(PROPOSAL, 10_000e18, 0);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);

        vm.prank(guardianB);
        vm.expectRevert(IChallengeGame.NotAccusedApprover.selector);
        game.dispute(id);
    }

    /// @notice The dispute window closes exactly where the auto-slash opens —
    ///         the boundary second belongs to the slash, so `dispute` and
    ///         `resolve` can never both be live on the same challenge.
    function test_dispute_revertsOnceTheAutoSlashDelayElapsed() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 filedAt = vm.getBlockTimestamp();

        vm.warp(filedAt + game.autoSlashDelay());
        vm.prank(guardianA);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.dispute(id);
    }

    function test_dispute_revertsWhenNotFiled() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        game.dispute(id);

        vm.prank(guardianB);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.dispute(id); // already disputed — one counter-bond settles it
    }

    // ── Disputed → timeout → fail (D5) ──

    /// @notice D5: no court exists to rule, so a contested challenge fails SAFE
    ///         after `disputeTimeout`. The challenger's bond forfeits to the
    ///         accused pro-rata to what each committed, and the counter-bond
    ///         goes back to whoever posted it.
    function test_resolve_disputedPastTimeoutFailsToTheAccused() public {
        uint256 challengerBefore = wood.balanceOf(challenger); // before the bond is pulled
        uint256 id = _fileStandard(PROPOSAL); // $6,000 / $4,000 → 60/40
        uint256 filedAt = _filedAt(id);
        uint256 aBefore = wood.balanceOf(guardianA);
        uint256 bBefore = wood.balanceOf(guardianB);

        vm.prank(guardianA);
        game.dispute(id);

        vm.warp(filedAt + game.disputeTimeout());
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeFailed(id, 10_000e18);
        game.resolve(id);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Failed));
        assertEq(swood.callCount(), 0, "a failed challenge slashes nobody");
        assertEq(tiers.demoteCount(), 0, "adapters demote only on a PASSED challenge");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage released on failure");

        // The challenger paid for the freeze it bought.
        assertEq(challengerBefore - wood.balanceOf(challenger), 10_000e18, "bond forfeited in full");
        // guardianA: counter-bond back (net 0) plus 60% of the forfeit.
        assertEq(wood.balanceOf(guardianA) - aBefore, 6_000e18, "60% of the forfeit, counter-bond returned");
        assertEq(wood.balanceOf(guardianB) - bBefore, 4_000e18, "40% of the forfeit");
        _assertLiveBondsBacked();
    }

    /// @notice The forfeit is pro-rata to committed shares, not per-capita: a
    ///         guardian that backed more of the proposal is compensated more for
    ///         having been accused of it.
    function test_resolve_forfeitIsProRataAndLeavesNoDust() public {
        _setCoverage(PROPOSAL, 7_777e18, 2_223e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.ProposerLinkedOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 aBefore = wood.balanceOf(guardianA);
        uint256 bBefore = wood.balanceOf(guardianB);

        vm.prank(guardianB);
        game.dispute(id);
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(id);

        uint256 aGain = wood.balanceOf(guardianA) - aBefore;
        uint256 bGain = wood.balanceOf(guardianB) - bBefore;
        assertEq(aGain, (bond * 7_777e18) / 10_000e18, "pro-rata to the committed share");
        assertEq(aGain + bGain, bond, "every wei of the forfeit reaches the accused");
        assertEq(wood.balanceOf(address(game)), 0, "no dust stranded in the game");
    }

    // ── Coverage is released on BOTH terminal paths ──

    /// @notice The freeze exists only while the challenge is live. On either
    ///         terminal path the guardian can genuinely recycle its budget
    ///         again — asserted through a real `releaseApproval`, not a flag.
    function test_resolve_unfreezesOnBothPathsAndReleaseWorksAgain() public {
        // Path 1: settled.
        uint256 settled = _fileStandard(PROPOSAL);
        vm.expectRevert(MockChallengeLedger.CoverageFrozen.selector);
        ledger.releaseApproval(address(gov), PROPOSAL, guardianA);
        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay());
        game.resolve(settled);
        ledger.releaseApproval(address(gov), PROPOSAL, guardianA);

        // Path 2: failed on timeout.
        uint256 failed = _fileStandard(2);
        vm.expectRevert(MockChallengeLedger.CoverageFrozen.selector);
        ledger.releaseApproval(address(gov), 2, guardianA);
        vm.prank(guardianA);
        game.dispute(failed);
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(failed);
        ledger.releaseApproval(address(gov), 2, guardianA);
    }

    /// @notice A resolved challenge unblocks a later, legitimate filing against
    ///         the same proposal — the liveness check reads status, not history.
    function test_resolve_allowsALaterFilingOnTheSameProposal() public {
        vm.prank(owner);
        game.setChallengeWindow(90 days); // outlive the dispute timeout
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        game.dispute(id);
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(id);

        vm.prank(challenger);
        uint256 second =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);
        assertEq(game.liveChallengeOf(address(gov), PROPOSAL), second);
    }

    // ── The detector incentive is off-chain ──

    /// @notice A WINNING challenger is paid its bond back and NOTHING else. The
    ///         first-detector bounty is a protocol bug-bounty program keyed off
    ///         `ChallengeFiled`/`ChallengeSettled`, not an on-chain payout —
    ///         forensic cost runs from minutes to days, and no constant in the
    ///         contract could be "sized to cover" it. So the on-chain payoff of
    ///         a successful filing is exactly break-even, and this pins it.
    function test_resolve_returnsBondAndPaysNoBounty() public {
        // WOOD sitting on the game beyond its live bonds is NOT a bounty pot:
        // no path spends it, so it is still here, untouched, afterwards.
        wood.mint(address(game), 5_000e18);

        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;
        assertEq(bond, 10_000e18);

        uint256 before = wood.balanceOf(challenger);
        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay());
        game.resolve(id);

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled), "silence was the verdict");
        assertEq(wood.balanceOf(challenger) - before, bond, "the bond back, to the wei, and nothing more");
        assertEq(game.bondedWood(), 0, "no challenge is live");
        assertEq(wood.balanceOf(address(game)), 5_000e18, "stray WOOD is never spent on a settlement");
    }

    /// @notice And with nothing donated, the game's custody returns to exactly
    ///         `bondedWood` — zero once the only challenge is terminal.
    function test_resolve_leavesTheGameHoldingExactlyItsLiveBonds() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay());
        game.resolve(id);
        _assertLiveBondsBacked();
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded, nothing withheld");
    }

    /// @notice A FAILED challenge pays the challenger nothing at all — the bond
    ///         forfeits to the accused. With the settle path above, that is the
    ///         whole on-chain payoff of filing: break-even at best.
    function test_resolve_failedChallengePaysChallengerNothing() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 before = wood.balanceOf(challenger);
        vm.prank(guardianA);
        game.dispute(id);
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(id);

        assertEq(wood.balanceOf(challenger), before, "the challenger loses the bond outright");
        _assertLiveBondsBacked();
    }

    // ── Parameters ──

    function test_task4Setters_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setAutoSlashDelay(3 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setDisputeTimeout(60 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setStakedWood(makeAddr("rogue"));
    }

    /// @notice The delay is the guardians' whole window to notice an unproven
    ///         assertion (D1), so it has a hard floor; and because both clocks
    ///         run from `filedAt`, it must stay strictly below the dispute
    ///         timeout or a contested challenge could fail before the slash it
    ///         was raised against was ever due.
    function test_setAutoSlashDelay_bounded() public {
        // Read the bounds BEFORE arming `expectRevert` — it latches onto the
        // very next call, and a getter is a call.
        uint256 floor = game.MIN_AUTO_SLASH_DELAY();
        uint256 timeout = game.disputeTimeout();
        assertEq(floor, 2 days);

        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setAutoSlashDelay(floor - 1);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setAutoSlashDelay(timeout); // must stay strictly under
        game.setAutoSlashDelay(floor);
        vm.stopPrank();
        assertEq(game.autoSlashDelay(), floor);
    }

    function test_setDisputeTimeout_bounded() public {
        uint256 delay = game.autoSlashDelay();

        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setDisputeTimeout(delay); // never at or below the slash clock
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setDisputeTimeout(181 days);
        game.setDisputeTimeout(60 days);
        vm.stopPrank();
        assertEq(game.disputeTimeout(), 60 days);
    }

    function test_setStakedWood_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.ZeroAddress.selector);
        game.setStakedWood(address(0));
    }

    /// @notice The defaults ship with a dispute window generous relative to the
    ///         auto-slash delay — the balance D1's shift in vigilance demands.
    function test_defaultTimings() public view {
        assertEq(game.autoSlashDelay(), 7 days);
        assertEq(game.disputeTimeout(), 30 days);
        assertGt(game.disputeTimeout(), game.autoSlashDelay());
    }

    // ── The §4 invariant ──

    /// @notice Spec §4 requires an invariant + fuzz per new accounting path. The
    ///         game's WOOD custody must equal the bonds of the challenges still
    ///         live, at EVERY point — across fuzzed bond sizes, an arbitrary
    ///         subset disputed, and an arbitrary resolution order.
    function testFuzz_woodBalanceEqualsLiveBonds(uint96[3] memory coverage, uint8 disputeMask, uint8 orderSeed) public {
        uint256[3] memory ids;
        for (uint256 i = 0; i < 3; i++) {
            uint256 usd = bound(uint256(coverage[i]), 1e18, 1_000_000e18);
            uint256 proposalId = 500 + i;
            _setCoverage(proposalId, usd - usd / 3, usd / 3);
            _execute(proposalId);
            vm.prank(challenger);
            ids[i] = game.file(
                address(gov), proposalId, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE
            );
            _assertLiveBondsBacked();
        }

        for (uint256 i = 0; i < 3; i++) {
            if ((disputeMask >> i) & 1 == 1) {
                vm.prank(guardianA);
                game.dispute(ids[i]);
                _assertLiveBondsBacked();
            }
        }

        // Past BOTH deadlines, so every challenge is resolvable whichever state
        // it is in and the order is genuinely free.
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());

        // All six orderings of {0,1,2}.
        uint256 seed = orderSeed % 6;
        uint256 first = seed % 3;
        uint256 second = (first + 1 + (seed / 3)) % 3;
        uint256 third = 3 - first - second;
        uint256[3] memory order = [first, second, third];

        for (uint256 i = 0; i < 3; i++) {
            game.resolve(ids[order[i]]);
            _assertLiveBondsBacked();
        }
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded once every challenge is terminal");
    }
}
