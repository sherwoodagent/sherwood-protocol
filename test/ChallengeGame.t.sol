// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BatchExecutorLib} from "src/BatchExecutorLib.sol";
import {ChallengeGame} from "src/ChallengeGame.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @dev Governor stub. The game reads exactly two fields off `getProposal`:
///      `executedAt` (a challenge only exists against an EXECUTED proposal) and
///      `vault` (consumed by the slash path in the next task).
contract MockChallengeGovernor {
    mapping(uint256 proposalId => ISyndicateGovernor.StrategyProposal) internal _proposals;
    mapping(uint256 proposalId => BatchExecutorLib.Call[]) internal _calls;

    /// @dev Stands in for "the proposal did touch the adapter the filing
    ///      names", which is the usual case; `setExecuteCall` overrides it per
    ///      proposal for the mismatch tests (review 🟠F4).
    address public defaultTarget;
    bytes4 public defaultSelector;

    function setExecuted(uint256 proposalId, address vault, uint256 executedAt) external {
        _proposals[proposalId].vault = vault;
        _proposals[proposalId].executedAt = executedAt;
    }

    function setDefaultCall(address target, bytes4 selector) external {
        defaultTarget = target;
        defaultSelector = selector;
    }

    function setExecuteCall(uint256 proposalId, address target, bytes4 selector) external {
        delete _calls[proposalId];
        _calls[proposalId].push(BatchExecutorLib.Call({target: target, data: abi.encodePacked(selector), value: 0}));
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
    }

    function getExecuteCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] storage stored = _calls[proposalId];
        if (stored.length != 0) return stored;
        BatchExecutorLib.Call[] memory one = new BatchExecutorLib.Call[](1);
        one[0] = BatchExecutorLib.Call({target: defaultTarget, data: abi.encodePacked(defaultSelector), value: 0});
        return one;
    }
}

/// @dev Exposure-ledger stub: the covering approver set with each one's
///      committed USD, the governance WOOD price, and a REAL per-proposal
///      freeze flag so the tests can assert the freeze actually landed rather
///      than merely that a call was made.
contract MockChallengeLedger {
    uint256 public woodUsdPriceX8;

    /// @dev Mirrors the real `ExposureLedger.challengeWindow` default (Part C,
    ///      review 2026-07-29 lock-time reduction) — `ChallengeGame` now reads
    ///      this live from `setChallengeWindow` and `setExposureLedger`, so a
    ///      mock without it would revert every call into either setter.
    uint256 public challengeWindow = 14 days;

    mapping(bytes32 reviewKey => address[]) internal _approvers;
    mapping(bytes32 reviewKey => mapping(address guardian => uint256)) internal _committed;
    /// @dev The PLEDGE — the real ledger's `_reservedUsd`. `recordApproval`
    ///      writes it equal to the live booking and only `releaseApproval`
    ///      clears it; `settleCoverage` never touches it. Kept separate here so
    ///      a test can drive the BOOKING to zero under a live challenge (the
    ///      #83 chain) without pretending the guardian released.
    mapping(bytes32 reviewKey => mapping(address guardian => uint256)) internal _pledged;
    mapping(bytes32 reviewKey => bool) internal _frozen;
    mapping(address guardian => uint256) internal _slashableBondUsd;

    constructor(uint256 priceX8) {
        woodUsdPriceX8 = priceX8;
    }

    function setWoodUsdPrice(uint256 priceX8) external {
        woodUsdPriceX8 = priceX8;
    }

    function setChallengeWindow(uint256 newWindow) external {
        challengeWindow = newWindow;
    }

    /// @dev THE COMPOSED PRICE, which is what every rail in the real ledger
    ///      divides by: Chainlink first, `woodHaircutBps` applied, the owner-set
    ///      scalar only as the degraded fallback — and the haircut applies to
    ///      the fallback too, so these two diverge without any feed at all.
    ///      DEFAULTS to the raw scalar so a suite that never sets it sees the
    ///      pre-fix behaviour; `setWoodPriceX8` is what opens the gap. The old
    ///      mock had no `woodPriceX8()` whatsoever, which is precisely why no
    ///      challenge-path test could express this divergence (review 🟠F16).
    uint256 internal _woodPriceX8;
    bool internal _woodPriceSet;

    function setWoodPriceX8(uint256 priceX8) external {
        _woodPriceX8 = priceX8;
        _woodPriceSet = true;
    }

    function woodPriceX8() external view returns (uint256) {
        return _woodPriceSet ? _woodPriceX8 : woodUsdPriceX8;
    }

    function setApprovers(address governor, uint256 proposalId, address[] memory guardians, uint256[] memory usd)
        external
    {
        bytes32 k = _key(governor, proposalId);
        delete _approvers[k];
        for (uint256 i = 0; i < guardians.length; i++) {
            _approvers[k].push(guardians[i]);
            // `recordApproval` writes the same number into both: the pledge and
            // the live booking only diverge once settlement runs.
            _committed[k][guardians[i]] = usd[i];
            _pledged[k][guardians[i]] = usd[i];
        }
    }

    /// @dev A settlement pass on ONE approver: rewrites the LIVE BOOKING and
    ///      leaves the pledge alone, exactly as `ExposureLedger._rebook` does.
    ///      Driving it to zero is what a `settleCoverage` call does to a
    ///      guardian whose own slashable bond was emptied by a concurrent
    ///      conviction.
    function setCommittedOnly(address governor, uint256 proposalId, address guardian, uint256 usd) external {
        _committed[_key(governor, proposalId)][guardian] = usd;
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

    function pledgedOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory guardians, uint256[] memory pledgedUsd)
    {
        bytes32 k = _key(governor, proposalId);
        guardians = _approvers[k];
        pledgedUsd = new uint256[](guardians.length);
        for (uint256 i = 0; i < guardians.length; i++) {
            pledgedUsd[i] = _pledged[k][guardians[i]];
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

    /// @dev The ledger's HALF of the two-sided freeze grant (review PR #56 M2).
    ///      `ChallengeGame.setExposureLedger` now refuses a ledger that has not
    ///      named it, so a mock without this field could never be re-pointed to.
    ///      Deliberately NOT enforced on `freezeCoverage`/`unfreezeCoverage`
    ///      below: those stay open so the pre-existing suite keeps exercising
    ///      the game's own logic rather than the mock's access control, and the
    ///      test that cares about the revoked-role failure asserts the SETTER
    ///      refuses rather than trying to reach the failure through the mock.
    address public coverageFreezer;

    function setCoverageFreezer(address freezer) external {
        coverageFreezer = freezer;
    }

    function freezeCoverage(address governor, uint256 proposalId) external {
        _frozen[_key(governor, proposalId)] = true;
    }

    function unfreezeCoverage(address governor, uint256 proposalId) external {
        _frozen[_key(governor, proposalId)] = false;
    }

    /// @dev Issue #95: `_refundAll` calls this through the typed
    ///      `IExposureLedger` interface, so every existing `Inconclusive` test
    ///      in this suite needs the mock to implement it or the call reverts.
    ///      Recorded, not merely accepted, so a test can pin exactly what
    ///      `_refundAll` passed — `pinCoverageUntil`'s whole job is carrying
    ///      the JUST-EXTENDED `challengeableUntil[rk]`, not some other value.
    mapping(bytes32 reviewKey => uint256) internal _pinnedUntil;
    uint256 public pinCoverageUntilCallCount;

    function pinCoverageUntil(address governor, uint256 proposalId, uint256 deadline) external {
        pinCoverageUntilCallCount++;
        bytes32 k = _key(governor, proposalId);
        if (deadline > _pinnedUntil[k]) _pinnedUntil[k] = deadline;
    }

    function pinnedUntil(address governor, uint256 proposalId) external view returns (uint256) {
        return _pinnedUntil[_key(governor, proposalId)];
    }

    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool) {
        return _frozen[_key(governor, proposalId)];
    }

    /// @dev What a conviction could actually take. DEFAULTS to the sum of
    ///      reservations — the pre-🟡F13 figure — so every suite that never sets
    ///      it sees exactly the bond sizing it saw before. Setting it is what
    ///      opens a gap between reservation and liability, which is the whole
    ///      point of the real ledger's distinction.
    mapping(bytes32 reviewKey => uint256) internal _liabilityUsd;
    mapping(bytes32 reviewKey => bool) internal _liabilitySet;

    function setLiabilityUsd(address governor, uint256 proposalId, uint256 usd) external {
        bytes32 k = _key(governor, proposalId);
        _liabilityUsd[k] = usd;
        _liabilitySet[k] = true;
    }

    function liabilityUsd(address governor, uint256 proposalId) external view returns (uint256) {
        bytes32 k = _key(governor, proposalId);
        if (_liabilitySet[k]) return _liabilityUsd[k];
        address[] storage list = _approvers[k];
        uint256 total;
        for (uint256 i = 0; i < list.length; i++) {
            total += _committed[k][list[i]];
        }
        return total;
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

    /// @dev Stands in for a REVOKED demoter role: the real `TierRegistry` reverts
    ///      `NotAuthorizedDemoter` once `setAuthorizedDemoter` has pointed
    ///      elsewhere, and the game must survive that rather than strand the
    ///      verdict behind it.
    bool public reverting;

    error NotAuthorizedDemoter();

    function setReverting(bool v) external {
        reverting = v;
    }

    function demoteByChallenge(address target, bytes4 selector) external {
        if (reverting) revert NotAuthorizedDemoter();
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
    bool[] internal _lastContestors;

    function lastSlashBpsPer() external view returns (uint256[] memory) {
        return _lastSlashBpsPer;
    }

    uint256 internal _nextTotal = 1_000e18;

    function setMaxSlashBps(uint256 v) external {
        maxSlashBps = v;
    }

    function setNextResult(uint256 total) external {
        _nextTotal = total;
    }

    function lastApprovers() external view returns (address[] memory) {
        return _lastApprovers;
    }

    /// @dev THE HALF OF THE VERDICT DEDUP THAT OUTLIVES A GAME DEPLOYMENT
    ///      (review PR #56 B1). The real sWOOD keys this on
    ///      `keccak256(governor, proposalId)` — the SAME key a redeployed
    ///      `ChallengeGame` derives — and `slashVerdict` reverts
    ///      `ApproverAlreadySlashed` the moment it is handed an approver already
    ///      marked under it. Modelling both halves faithfully is what lets the
    ///      redeploy regression below prove a real wedge rather than a mock's
    ///      convenience: without the revert, the old code would have "settled"
    ///      the second conviction and the test would have proved nothing.
    mapping(bytes32 caseKey => mapping(address approver => bool)) internal _verdictSlashed;

    error ApproverAlreadySlashed();

    /// @dev Seeds the state a PREVIOUS deployment of the game would have left
    ///      behind — the whole point of the redeploy fixture, since the fresh
    ///      game's own `_convicted` mapping starts empty either way.
    function setVerdictSlashed(bytes32 caseKey, address approver, bool v) external {
        _verdictSlashed[caseKey][approver] = v;
    }

    function verdictSlashed(bytes32 caseKey, address approver) external view returns (bool) {
        return _verdictSlashed[caseKey][approver];
    }

    /// @dev sWOOD's half of the two-sided slasher grant (review PR #56 M2).
    ///      `ChallengeGame.setStakedWood` now refuses a sWOOD that has not named
    ///      it, which is the order `DeployPlanD` already wires in.
    address public authorizedSlasher;

    function setAuthorizedSlasher(address slasher) external {
        authorizedSlasher = slasher;
    }

    function slashVerdict(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer
    ) external returns (uint256) {
        for (uint256 i = 0; i < approvers.length; i++) {
            if (_verdictSlashed[caseKey][approvers[i]]) revert ApproverAlreadySlashed();
            _verdictSlashed[caseKey][approvers[i]] = true;
        }
        callCount++;
        lastCaseKey = caseKey;
        lastOpenedAt = openedAt;
        _lastApprovers = approvers;
        _lastSlashBpsPer = slashBpsPer;
        return _nextTotal;
    }

    function lastContestors() external view returns (bool[] memory) {
        return _lastContestors;
    }
}

/// @dev Stands in for `TokenCourt.refer` on the RECORDING path — Task 8's
///      auto-referral happy case. Records the challenge id it was called
///      with so the test can assert `dispute`'s pool-completing branch
///      actually invoked it.
contract MockRecordingCourt {
    uint256 public lastReferred;

    /// @dev Mirrors the real `TokenCourt`'s defaults (5-day `voteWindow`,
    ///      1-day `FINALIZE_BUFFER`) — `ChallengeGame._requireWindowFits` (B3,
    ///      review 2026-07-29 lock-time reduction) now reads both live off
    ///      whatever `court` is wired, so a mock without them would revert
    ///      every `setAutoSlashDelay`/`setDisputeTimeout` call once this court
    ///      is set in `setUp`.
    uint256 public voteWindow = 5 days;
    uint256 public constant FINALIZE_BUFFER = 1 days;

    function setVoteWindow(uint256 w) external {
        voteWindow = w;
    }

    function refer(uint256 challengeId) external returns (uint256) {
        lastReferred = challengeId;
        return 1;
    }
}

/// @dev Stands in for a court whose `refer` always reverts — the case
///      `AutoReferFailed` exists for. `dispute`'s try/catch must swallow this
///      and let the completing dispute land regardless.
contract MockRevertingCourt {
    /// @dev Mirrors `MockRecordingCourt`'s defaults — `ChallengeGame.setCourt`
    ///      (B3 re-wire guard, review 2026-07-29 audit item 1) now reads these
    ///      live off ANY court it is pointed at, including this one.
    uint256 public voteWindow = 5 days;
    uint256 public constant FINALIZE_BUFFER = 1 days;

    function refer(uint256) external pure returns (uint256) {
        revert("nope");
    }
}

/// @dev Stands in for a court whose `refer` needs at least `floor` gas to
///      complete. Set the floor beyond any reachable budget and every referral
///      reverts — which is exactly the scenario `dispute` must survive without
///      denying the accused its defence.
contract MockGasHungryCourt {
    uint256 public lastReferred;
    uint256 public floor;
    /// @dev Same reason as `MockRevertingCourt`'s identical fields.
    uint256 public voteWindow = 5 days;
    uint256 public constant FINALIZE_BUFFER = 1 days;

    constructor(uint256 f) {
        floor = f;
    }

    function refer(uint256 challengeId) external returns (uint256) {
        if (gasleft() < floor) revert("starved");
        lastReferred = challengeId;
        return 1;
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
    /// @dev Stands in for the §3.5 court (Plan E). `rule` reads it as a
    ///      caller identity via `vm.prank`, which works whether or not the
    ///      address has code — but since Task 8, a POOL-COMPLETING `dispute`
    ///      also CALLS INTO it (`ITokenCourt(court).refer`), so this can no
    ///      longer be a bare `makeAddr` EOA: an external call into an address
    ///      with no code is a distinct failure mode from a reverting one, and
    ///      it is not what any pre-Task-8 dispute test means to exercise. A
    ///      `MockRecordingCourt` is deployed in `setUp` instead — it always
    ///      succeeds and touches no state these tests assert on, so every
    ///      Plan D/E path this fixture already covers stays byte-identical;
    ///      only the auto-referral tests below swap in a different mock to
    ///      exercise the revert/gas-floor cases deliberately.
    address internal court;

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
        // Every proposal touches the adapter these tests accuse, so the 🟠F4
        // membership test passes by default; the mismatch cases override it.
        gov.setDefaultCall(ADAPTER, SELECTOR);
        ledger = new MockChallengeLedger(0.05e8); // $0.05, the governance haircut price
        tiers = new MockChallengeTierRegistry();
        swood = new MockChallengeStakedWood();
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tiers));
        court = address(new MockRecordingCourt()); // see the field's own doc for why not a bare EOA
        // BOTH HALVES OF BOTH GRANTS, IN THE ORDER `DeployPlanD` uses (review PR
        // #56 M2): the target contract names the game FIRST, then the game is
        // pointed at it. `setStakedWood` below now enforces that order.
        ledger.setCoverageFreezer(address(game));
        swood.setAuthorizedSlasher(address(game));
        vm.startPrank(owner);
        game.setStakedWood(address(swood));
        game.setCourt(court);
        vm.stopPrank();

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
    /// @notice The slot is PER CHALLENGER (review 🔴F3). One filer cannot file
    ///         twice — that would double-charge the freeze for nothing — but a
    ///         second, independent challenger always gets its own slot. The old
    ///         one-slot-per-proposal rule let the accused cohort self-file,
    ///         self-dispute, and lock the only slot for the whole window at
    ///         zero net cost, since `_fail` returned both bonds to them.
    function test_file_oneSlotPerChallengerNotPerProposal() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 first = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );

        // The same challenger cannot occupy two slots on one proposal.
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.AlreadyChallenged.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);

        // An independent challenger does.
        address other = makeAddr("otherChallenger");
        wood.mint(other, 1_000_000e18);
        vm.startPrank(other);
        wood.approve(address(game), type(uint256).max);
        uint256 second = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.ProposerLinkedOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        vm.stopPrank();

        assertTrue(second != first, "the honest filer is not denied by an existing challenge");
        assertEq(game.liveChallengeCountOf(address(gov), PROPOSAL), 2, "both are live");
        assertEq(game.liveChallengeOfBy(address(gov), PROPOSAL, challenger), first, "each slot is its own");
        assertEq(game.liveChallengeOfBy(address(gov), PROPOSAL, other), second);
        assertTrue(ledger.isCoverageFrozen(address(gov), PROPOSAL), "one freeze covers both");
    }

    /// @notice 🔴F3, the squat itself: the accused cohort files and disputes to
    ///         block the slot, and it no longer blocks anything. The freeze is
    ///         refcounted, so the squatter's own resolution does not release
    ///         coverage the honest challenge is still pinning.
    function test_file_aSquattedSlotNoLongerDeniesTheHonestChallenge() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);

        // The cohort's sybil files, and an accused approver disputes it: under
        // the old rule this pinned the only slot for `disputeTimeout` (30d),
        // outliving the 14d challenge window entirely.
        address sybil = makeAddr("sybil");
        wood.mint(sybil, 1_000_000e18);
        vm.startPrank(sybil);
        wood.approve(address(game), type(uint256).max);
        uint256 squat =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);
        vm.stopPrank();
        vm.prank(guardianA);
        game.dispute(squat, type(uint256).max);

        // Deep into the window, the honest challenger still files.
        vm.warp(vm.getBlockTimestamp() + 13 days);
        vm.prank(challenger);
        uint256 honest = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        assertEq(game.liveChallengeCountOf(address(gov), PROPOSAL), 2);

        // The squat times out to the accused, as designed — and takes nothing
        // with it: coverage stays frozen for the honest filing behind it.
        vm.warp(_filedAt(squat) + game.disputeTimeout());
        game.resolve(squat);
        assertEq(uint8(game.challengeOf(squat).status), uint8(IChallengeGame.Status.Failed));
        assertTrue(ledger.isCoverageFrozen(address(gov), PROPOSAL), "the honest challenge still pins the coverage");
        assertEq(game.liveChallengeCountOf(address(gov), PROPOSAL), 1);

        // And the honest challenge still convicts.
        vm.warp(_filedAt(honest) + game.autoSlashDelay());
        game.resolve(honest);
        assertEq(swood.callCount(), 1, "the squat delayed the verdict; it did not prevent it");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "last one out unfreezes");
    }

    /// @notice 🔴F3 corollary: two concurrent challenges must not slash the same
    ///         approvers twice. The liability is one liability, and sWOOD's own
    ///         per-verdict dedup would revert the second settle — wedging an
    ///         otherwise-correct challenge with no terminal path — so the game
    ///         records the conviction as already collected instead.
    function test_resolve_concurrentSettlesConvictOnlyOnce() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);

        vm.prank(challenger);
        uint256 a = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        address other = makeAddr("otherChallenger");
        wood.mint(other, 1_000_000e18);
        vm.startPrank(other);
        wood.approve(address(game), type(uint256).max);
        uint256 b =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);
        vm.stopPrank();

        vm.warp(_filedAt(b) + game.autoSlashDelay());
        game.resolve(a);
        assertEq(swood.callCount(), 1, "the first settle collects the liability");

        uint256 otherBefore = wood.balanceOf(other);
        game.resolve(b);
        assertEq(swood.callCount(), 1, "the second does NOT slash again");
        assertEq(uint8(game.challengeOf(b).status), uint8(IChallengeGame.Status.Settled), "but it still terminates");
        assertGt(wood.balanceOf(other) - otherBefore, 0, "and its challenger is still refunded");
        assertEq(game.bondedWood(), 0, "no bond is stranded");
    }

    /// @notice Nothing to accuse: a proposal no guardian covered (or whose
    ///         approvers all released before execution) has no coverage to
    ///         freeze and therefore no bond to size against.
    /// @notice THE BOND IS PRICED ON WHAT A CONVICTION CAN TAKE, NOT ON WHAT THE
    ///         APPROVERS RESERVED (review 🟡F13).
    ///
    ///         `recordApproval` deliberately over-reserves: every approver books
    ///         up to the FULL coverage, because at vote time any one of them
    ///         might end up carrying it alone. So reservations sum ABOVE the
    ///         proposal's need, and by a factor that grows with the approver
    ///         count. `slashBpsFor` prices the slash against the ALLOCATION for
    ///         exactly that reason — but `file` summed `approversOf`, the
    ///         reservation, and charged the challenger against it.
    ///
    ///         The effect was perverse: the MORE guardians backed a proposal,
    ///         the more expensive it became to challenge, while the recoverable
    ///         total stayed flat. A well-covered proposal bought itself
    ///         protection from scrutiny out of the fact that it was well
    ///         covered. Here the cohort reserved $10,000 against $8,000 of real
    ///         liability, and the bond must follow the $8,000.
    function test_file_bondDividesByTheComposedPriceNotTheRawScalar() public {
        // Raw scalar $0.05; composed $0.04 after a 20% haircut. No feed needed —
        // the haircut applies to the fallback branches too, which is why these
        // two diverge on a deployment that never wires Chainlink at all.
        ledger.setWoodPriceX8(0.04e8);

        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // $10,000 of liability
        _execute(PROPOSAL);

        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );

        // 5% of $10,000 = $500. At the composed $0.04 that is 12,500 WOOD; at
        // the raw $0.05 it would be 10,000 — a 20% under-charge. The bond
        // DIVIDES by the price, so a stale-high scalar always under-charges.
        assertEq(game.challengeOf(id).bondWood, 12_500e18, "bond divides by the composed price, not the raw scalar");
    }

    function test_file_bondIsSizedOnLiabilityNotReservations() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // reservations sum to $10,000
        ledger.setLiabilityUsd(address(gov), PROPOSAL, 8_000e18); // but only $8,000 is takeable
        _execute(PROPOSAL);

        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );

        // 5% of $8,000 at $0.05/WOOD = 8,000 WOOD. Against the reservations it
        // would have been 10,000 — a 25% over-charge on this cohort alone.
        assertEq(game.challengeOf(id).bondWood, 8_000e18, "the bond follows the liability, not the reservations");
        assertEq(game.challengeOf(id).frozenCoverageUsd, 8_000e18, "and the recorded coverage is the liability too");
    }

    /// @notice The cap only ever REDUCES. An under-covered cohort — whose
    ///         reservations fall short of the proposal's need — is still priced
    ///         on what it actually pledged, because that is all a conviction
    ///         could take from it.
    function test_file_bondUsesReservationsWhenTheyAreTheSmallerFigure() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // reservations sum to $10,000
        ledger.setLiabilityUsd(address(gov), PROPOSAL, 25_000e18); // a larger need
        _execute(PROPOSAL);

        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );

        assertEq(game.challengeOf(id).bondWood, 10_000e18, "capped by the cohort, never inflated by the need");
    }

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
    /// @notice 🔵F14: the two fail-closed branches in `file` shared ONE opaque
    ///         error, so "the protocol has no WOOD price" and "your bond rounded
    ///         away" were indistinguishable from outside. They need completely
    ///         different responses — wait for governance to set a price, versus
    ///         this proposal can never be challenged by anyone.
    function test_file_revertsWhenWoodPriceUnset() public {
        ledger.setWoodUsdPrice(0);
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.WoodPriceUnset.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);
    }

    /// @notice The other branch, named separately. Reaching it takes dust
    ///         coverage against an absurd WOOD price — the bond is 18-decimal
    ///         USD scaled by an 8-decimal price, so truncation needs the product
    ///         to floor below one wei — but the FAILURE MODE is the point: the
    ///         proposal becomes permanently unchallengeable, and the old shared
    ///         error gave a reader no way to tell that from a missing price.
    function test_file_revertsWhenTheBondTruncatesToZero() public {
        _setCoverage(PROPOSAL, 1, 0); // one wei of USD coverage
        ledger.setWoodUsdPrice(type(uint128).max); // against an absurd WOOD price
        _execute(PROPOSAL);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.BondTooSmall.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);
    }

    /// @notice 🔵F15: THE BURN RATES ARE PINNED AT FILING, like both clocks.
    ///
    ///         `autoSlashDelayAtFiling` and `disputeTimeoutAtFiling` exist
    ///         because reading a live parameter let the owner change the deal
    ///         after the money was committed. The burn rates were left live on
    ///         the argument that they "price the refund rather than bound a
    ///         window the accused is relying on" — but the challenger relied on
    ///         `settleBurnBps` when it decided to file, and it cannot withdraw.
    ///         Raising 0 -> 5,000 mid-window takes half the refund of a filing
    ///         that turned out to be correct.
    function test_resolve_settleBurnIsPinnedAtFiling() public {
        vm.startPrank(owner);
        // `setSettleBurnBps` now refuses to drop below the live
        // `inconclusiveBurnBps` (review round 2, 2026-07-30) — zero it first,
        // or the default 500 `inconclusiveBurnBps` would refuse this call.
        game.setInconclusiveBurnBps(0);
        game.setSettleBurnBps(0); // filed under a full-refund regime
        vm.stopPrank();
        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 before = wood.balanceOf(challenger);

        vm.prank(owner);
        game.setSettleBurnBps(5_000); // governance changes its mind mid-window

        vm.warp(_filedAt(id) + game.autoSlashDelay());
        game.resolve(id);

        assertEq(wood.balanceOf(challenger) - before, bond, "refunded at the rate it filed under, not the new one");
    }

    /// @notice The same on the FAIL side, where the victims are the accused who
    ///         funded the counter-bond. They committed WOOD to a pool whose
    ///         payout `forfeitBurnBps` scales, so a raise after they paid in
    ///         shrinks what they collect for a defence that WON.
    function test_resolve_forfeitBurnIsPinnedAtFiling() public {
        vm.prank(owner);
        game.setForfeitBurnBps(0);
        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;

        vm.prank(guardianA);
        game.dispute(id, type(uint256).max); // guardianA funds the whole defence
        uint256 before = wood.balanceOf(guardianA);

        vm.prank(owner);
        game.setForfeitBurnBps(5_000);

        vm.warp(_filedAt(id) + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        // Its stake back plus the WHOLE forfeited bond: zero burn, as filed.
        assertEq(wood.balanceOf(guardianA) - before, bond + bond, "forfeit paid at the rate in force when it was filed");
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

    /// @notice Part C: the ceiling is the LEDGER's own live window, not a
    ///         restated literal — a window above it would let a filing freeze
    ///         exposure the ledger has already aged out of its epoch buckets,
    ///         which is exactly what the old `90 days` literal (6x the
    ///         ledger's 14-day default) let happen.
    function test_setChallengeWindow_boundedByLedgersLiveWindow() public {
        uint256 ledgerWindow = ledger.challengeWindow();
        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setChallengeWindow(ledgerWindow + 1);
        game.setChallengeWindow(ledgerWindow); // exactly the ledger's window succeeds
        vm.stopPrank();
        assertEq(game.challengeWindow(), ledgerWindow);
    }

    /// @notice Part C mirror guard, same class as `setStakedWood`'s re-point
    ///         check: re-pointing to a ledger whose OWN window is smaller than
    ///         this game's current `challengeWindow` would silently reopen the
    ///         gap `setChallengeWindow` closes, with no setter call left to
    ///         catch it. Chosen to REVERT rather than clamp — the same choice
    ///         `setStakedWood` makes for its own re-point hazard.
    function test_setExposureLedger_revertsWhenNewLedgersWindowIsSmallerThanCurrent() public {
        assertEq(game.challengeWindow(), 14 days, "fixture: default game window");
        MockChallengeLedger smaller = new MockChallengeLedger(0.05e8);
        smaller.setChallengeWindow(7 days); // below the game's current 14-day window
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setExposureLedger(address(smaller));
    }

    /// @notice The other side of the same guard: a new ledger whose window
    ///         covers (or exceeds) the game's current one re-points cleanly.
    function test_setExposureLedger_succeedsWhenNewLedgersWindowCoversCurrent() public {
        MockChallengeLedger bigger = new MockChallengeLedger(0.05e8);
        bigger.setChallengeWindow(30 days); // >= the game's current 14-day window
        // The new ledger's own half of the freeze grant (review PR #56 M2) —
        // without it the re-point is refused, which is the sibling test below.
        bigger.setCoverageFreezer(address(game));
        vm.prank(owner);
        game.setExposureLedger(address(bigger));
        assertEq(address(game.exposureLedger()), address(bigger));
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

    /// @dev The §4 invariant, asserted point-by-point. `bondedWood` still means
    ///      exactly the bonds of the LIVE challenges — that is why the
    ///      pull-payment change put entitlements in a separate counter rather
    ///      than folding them in. Custody widened to cover both, because a
    ///      terminal challenge's funders are paid lazily and their WOOD sits
    ///      here until claimed.
    ///
    ///      `>=` rather than `==` on custody: lazy pro-rata shares floor-divide
    ///      independently, so wei-scale dust from a failed challenge stays
    ///      accounted in `unclaimedWood` and is never claimable.
    function _assertLiveBondsBacked() internal view {
        uint256 live;
        for (uint256 i = 1; i <= game.challengeCount(); i++) {
            IChallengeGame.Challenge memory c = game.challengeOf(i);
            if (c.status == IChallengeGame.Status.Filed || c.status == IChallengeGame.Status.Disputed) {
                live += c.bondWood + c.counterBondWood;
            }
        }
        assertEq(game.bondedWood(), live, "accounted bonds != live bonds");
        assertGe(
            wood.balanceOf(address(game)), game.bondedWood() + game.unclaimedWood(), "custody < accounted obligations"
        );
    }

    /// @dev Collect what a terminal challenge owes `who`, if anything.
    ///
    ///      Resolution used to transfer to every funder in a loop; it now
    ///      records entitlements and each funder collects for itself, which is
    ///      what removed the unbounded-loop hazard and let contribution standing
    ///      open up. Tests that assert end-to-end balances therefore have to
    ///      settle up first — the economics are unchanged, the timing is not.
    function _claim(uint256 id, address who) internal {
        if (game.claimableContribution(id, who) == 0) return;
        vm.prank(who);
        game.claimContribution(id);
    }

    /// @dev Settle up for the fixture's standard funders. A no-op for anyone who
    ///      contributed nothing, so it is safe to call after any resolution.
    ///      Tests with bespoke funders call `_claim` for those directly.
    function _claimAll(uint256 id) internal {
        _claim(id, guardianA);
        _claim(id, guardianB);
        _claim(id, challenger);
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

        swood.setNextResult(9_999e18);
        vm.warp(filedAt + game.autoSlashDelay());

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeSettled(id, 9_999e18);
        game.resolve(id); // permissionless — this test contract is nobody

        // The verdict slash, argument by argument.
        assertEq(swood.callCount(), 1, "slashed exactly once");
        assertEq(swood.lastCaseKey(), keccak256(abi.encode(address(gov), PROPOSAL)), "case key is the review key");
        // 🔴F1: anchored at EXECUTION, never at the filing. `filedAt` is a
        // timestamp the accused controls the state of — one `requestUnstakeGuardian`
        // between the drain and the accusation pushes a zero stake checkpoint,
        // zeroing the slash basis, and `cancelUnstakeGuardian` puts it back.
        assertEq(swood.lastOpenedAt(), executedAt, "verdict anchored at execution, before the accused could react");
        assertTrue(swood.lastOpenedAt() < filedAt, "and strictly before the filing, which is the whole point");
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
        address[] memory slashed = swood.lastApprovers();
        assertEq(slashed.length, 2);
        assertEq(slashed[0], guardianA);
        assertEq(slashed[1], guardianB);
        // The slash names no payee on ANY path — `slashVerdict` has no
        // recipient argument to pass one through, so the property is now
        // enforced by the signature rather than by a runtime check. Pinned
        // structurally in `test_slash_carriesNoPayoutRecipient`; the
        // prosecutor's fee arrives from the proposer's forfeited bond, which
        // this mock never touches.

        // The adapter the challenger named is demoted (§3.4, D7).
        assertEq(tiers.demoteCount(), 1);
        assertEq(tiers.lastTarget(), ADAPTER);
        assertEq(tiers.lastSelector(), SELECTOR);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Settled));
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage released on settlement");
        assertEq(game.liveChallengeOf(address(gov), PROPOSAL), 0, "no longer live");

        // Less the F4 settle burn: a correct filing is cheap, not free.
        assertEq(wood.balanceOf(challenger) - challengerBefore, 8_000e18, "bond returned less the 20% burn");
        _assertLiveBondsBacked();
    }

    /// @notice A REVOKED DEMOTER ROLE MUST NOT STRAND A VERDICT (PR #25 review
    ///         🟠F11). `demoteByChallenge` is role-gated on the registry's side,
    ///         and `TierRegistry.setAuthorizedDemoter(0)` is documented as an
    ///         unwire switch that "fails CLOSED". Used while a challenge is live
    ///         it did the opposite of closing: `_settle` reverted inside the
    ///         demotion, so `resolve()` could never complete — the challenge sat
    ///         in `Filed` forever, both bonds stranded with no withdrawal path,
    ///         the coverage stayed frozen, and every accused approver stayed
    ///         barred from `claimUnstakeGuardian`. One governance transaction,
    ///         permanent.
    ///
    ///         Losing a certification revocation is a far smaller harm than
    ///         losing the slash, the bond refund and the freeze release — and
    ///         the registry owner can always demote by hand afterwards, since
    ///         `demote` is theirs. So the demotion is BEST-EFFORT and its
    ///         failure is surfaced as an event rather than swallowed.
    function test_resolve_settlesEvenWhenTheDemoterRoleWasRevoked() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 challengerBefore = wood.balanceOf(challenger);

        // Governance rotates the demoter role out from under the live challenge.
        tiers.setReverting(true);

        swood.setNextResult(9_999e18);
        vm.warp(_filedAt(id) + game.autoSlashDelay());

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.AdapterDemotionFailed(id, ADAPTER, SELECTOR);
        game.resolve(id);

        // Everything that actually holds value still happened.
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Settled), "the verdict still lands");
        assertEq(swood.callCount(), 1, "the slash still executed");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "the coverage is still released");
        assertEq(wood.balanceOf(challenger) - challengerBefore, 8_000e18, "the bond still comes back");
        assertEq(tiers.demoteCount(), 0, "and the demotion is the only thing lost");
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
        // The pre-drain snapshot this used to pin died with the compensation
        // escrow — nothing is apportioned, so there is no instant to choose.
        // The surviving anchor is the one that sizes the slash.
        assertEq(swood.lastOpenedAt(), executedAt, "verdict anchored at execution");
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

    /// @notice `resolve` is permissionless, so the caller chooses the gas. The
    ///         game pins a floor: too little is refused before any state moves,
    ///         and the retry costs nothing but the gas. Originally N-4 (PR #24
    ///         round 4), where a starved `openCase` child inside
    ///         `slashToEscrow` burned the victims' compensation instead of
    ///         bubbling; the burn removed that child, and what the floor now
    ///         protects is the best-effort `demoteByChallenge` that runs AFTER
    ///         the slash — structurally, via `DEMOTION_GAS`, since issue #51
    ///         (openspec settle-demotion-gas-floor).
    function test_resolve_enforcesTheSlashGasFloor() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(_filedAt(id) + game.autoSlashDelay());

        // Two approvers, adapter named (`_fileStandard`) -> floor =
        // 2 * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE + DEMOTION_GAS. Starve
        // the call to just under it: ample for all the pre-floor work, never
        // enough for the floor itself. Derived from the LIVE constants rather
        // than hardcoded, so re-sizing the floor (PR #56 H2 did, from 300k/1M
        // to 180k/2M; issue #51 added the DEMOTION_GAS term) cannot quietly
        // turn this into an out-of-gas test that passes for the wrong reason.
        uint256 starved = 2 * game.SLASH_GAS_PER_APPROVER() + game.SLASH_GAS_BASE() + game.DEMOTION_GAS() - 100_000;
        bytes memory callData = abi.encodeWithSelector(game.resolve.selector, id);
        (bool ok, bytes memory ret) = address(game).call{gas: starved}(callData);
        assertFalse(ok, "a gas-starved resolve must not settle");
        assertEq(bytes4(ret), IChallengeGame.InsufficientSlashGas.selector, "refused at the floor, not an OOG");
        assertEq(swood.callCount(), 0, "the slasher was never reached");

        // Same challenge, honest gas: settles clean.
        swood.setNextResult(9_999e18);
        game.resolve(id);
        assertEq(swood.callCount(), 1, "the retry lost nothing");
    }

    /// @notice Issue #51's reproduction, in its honest form (openspec
    ///         settle-demotion-gas-floor — the literal "silent miss converts
    ///         to a clean revert" scenario cannot be built because the silent
    ///         miss was never reachable, see design.md). What CAN be shown: a
    ///         gas budget that would have cleared the pre-#51 floor (slash
    ///         terms alone) — the exact budget the issue argued a caller could
    ///         dial to land the conviction while starving the demotion — is
    ///         now refused outright, before the slash ever runs. Only a budget
    ///         that also affords the demotion is accepted, and that budget
    ///         both slashes and demotes.
    function test_resolve_refusesABudgetThatClearsOnlyTheOldFloor() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(_filedAt(id) + game.autoSlashDelay());

        uint256 oldFloor = 2 * game.SLASH_GAS_PER_APPROVER() + game.SLASH_GAS_BASE();
        uint256 newFloor = oldFloor + game.DEMOTION_GAS();
        uint256 budget = oldFloor + 50_000;
        assertLt(budget, newFloor, "the probed budget must sit strictly below the extended floor");

        bytes memory callData = abi.encodeWithSelector(game.resolve.selector, id);
        (bool ok, bytes memory ret) = address(game).call{gas: budget}(callData);
        assertFalse(ok, "a budget that only clears the pre-#51 floor must not settle");
        assertEq(bytes4(ret), IChallengeGame.InsufficientSlashGas.selector, "refused at the extended floor, not an OOG");
        assertEq(swood.callCount(), 0, "no state moved on the refused attempt");

        // Retry with honest gas: the conviction lands AND the demotion
        // succeeds. `demoteCount() == 1` is exclusive with
        // `AdapterDemotionFailed` (the try/catch takes exactly one branch),
        // so it alone proves the demotion was not silently dropped.
        swood.setNextResult(9_999e18);
        game.resolve(id);
        assertEq(swood.callCount(), 1, "the retry slashes");
        assertEq(tiers.demoteCount(), 1, "and the retry demotes - no silent miss");
    }

    /// @notice The `DEMOTION_GAS` term is owed only where a demotion is owed.
    ///         A zero-adapter filing demotes nothing, so a gas budget between
    ///         the slash-only floor and what would be the adapter-naming
    ///         floor still settles cleanly — the term is not charged where
    ///         nothing is at risk of starving.
    function test_resolve_noAdapterFloorDoesNotChargeDemotionGas() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OraclePriceDeviation, address(0), bytes4(0), EVIDENCE
        );
        vm.warp(_filedAt(id) + game.autoSlashDelay());

        uint256 slashOnlyFloor = 2 * game.SLASH_GAS_PER_APPROVER() + game.SLASH_GAS_BASE();
        // Comfortably above the slash-only floor but well below what the
        // extended (adapter-naming) floor would have required — if the
        // no-adapter branch were mistakenly charged DEMOTION_GAS, this budget
        // would be refused.
        uint256 budget = slashOnlyFloor + game.DEMOTION_GAS() / 2;
        swood.setNextResult(9_999e18);

        bytes memory callData = abi.encodeWithSelector(game.resolve.selector, id);
        (bool ok,) = address(game).call{gas: budget}(callData);
        assertTrue(ok, "a no-adapter settle must not be charged the demotion term");
        assertEq(swood.callCount(), 1, "still slashed");
        assertEq(tiers.demoteCount(), 0, "nothing named, nothing demoted");
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
        emit IChallengeGame.CounterBondContributed(id, guardianA, 10_000e18, 10_000e18);
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeDisputed(id, 10_000e18);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Disputed));
        assertEq(c.counterBondWood, c.bondWood, "the pool matches the challenger's bond");
        assertEq(game.counterBondContributionOf(id, guardianA), 10_000e18, "and guardianA funded all of it");
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

    /// @notice 🟠F18: ANY ADDRESS MAY FUND THE DEFENCE.
    ///
    ///         This asserted the opposite until the payout became pull-based.
    ///         The accused-only rule answered "who may BUY the escalation" —
    ///         right — but with a POOL the same check also decided "who may help
    ///         FILL it", and a cohort short by a sliver could not be topped up
    ///         by anyone. The rule's other job was bounding the contributor
    ///         list, which `claimContribution` retired.
    ///
    ///         Skin in the game is now economic rather than by identity: a
    ///         guilty ruling forfeits the whole pool to the challenger, so a
    ///         stranger funding a defence risks real capital. Pinned here so a
    ///         future re-tightening has to argue with a test.
    function test_dispute_anyAddressMayFundTheDefence() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 target = game.challengeOf(id).bondWood;

        address stranger = makeAddr("stranger");
        wood.mint(stranger, 1_000_000e18);
        vm.startPrank(stranger);
        wood.approve(address(game), type(uint256).max);
        game.dispute(id, target / 2);
        vm.stopPrank();

        assertEq(game.counterBondContributionOf(id, stranger), target / 2, "a non-approver's stake is recorded");
        assertEq(game.challengeOf(id).counterBondWood, target / 2, "and it counts toward the pool");
        assertEq(
            uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Filed), "half a pool buys no escalation"
        );
    }

    /// @notice A guardian that released its commitment before the filing may
    ///         fund too. It is not itself at risk, but its WOOD is: the forfeit
    ///         rule does not care who posted it, which is exactly why the
    ///         identity check was redundant.
    function test_dispute_aReleasedApproverMayFundTheDefence() public {
        _setCoverage(PROPOSAL, 10_000e18, 0);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);

        vm.prank(guardianB);
        game.dispute(id, type(uint256).max);

        assertEq(
            uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed), "a full pool buys the dispute"
        );
        assertEq(game.counterBondContributionOf(id, guardianB), game.challengeOf(id).bondWood, "funded in full");
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
        game.dispute(id, type(uint256).max);
    }

    function test_dispute_revertsWhenNotFiled() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);

        vm.prank(guardianB);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.dispute(id, type(uint256).max); // already disputed — one counter-bond settles it
    }

    // ── Dispute: best-effort auto-referral (Task 8) ──

    /// @notice The happy path: the pool-completing `dispute` call refers the
    ///         challenge to the wired court itself, in the same transaction
    ///         that bought the escalation.
    function test_dispute_autoRefersOnCompletion() public {
        MockRecordingCourt recording = new MockRecordingCourt();
        vm.prank(owner);
        game.setCourt(address(recording));

        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max); // completes the pool

        assertEq(recording.lastReferred(), id, "the completing dispute referred itself");
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed));
    }

    /// @notice A contribution that does not complete the pool buys no
    ///         escalation (existing behaviour) and therefore must not attempt a
    ///         referral either — there is nothing yet to refer.
    function test_dispute_partialContributionDoesNotRefer() public {
        MockRecordingCourt recording = new MockRecordingCourt();
        vm.prank(owner);
        game.setCourt(address(recording));

        uint256 id = _fileStandard(PROPOSAL);
        uint256 target = game.challengeOf(id).bondWood;
        vm.prank(guardianA);
        game.dispute(id, target / 2); // short of the pool target

        assertEq(recording.lastReferred(), 0, "half a pool buys no referral attempt either");
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Filed));
    }

    /// @notice A court that reverts on `refer` must not brick the dispute: the
    ///         accused's defence purchase always lands, and the miss is
    ///         surfaced as `AutoReferFailed`.
    /// @dev    Recovery — that the miss is actually recoverable via a real,
    ///         still-wired `TokenCourt` — is proven separately and for real in
    ///         `test/AutoReferRecovery.t.sol` (I-1), against the genuine
    ///         `InsufficientClock` failure mode rather than a mock revert. A
    ///         fresh, disconnected court told to `refer` here would prove
    ///         nothing about THIS court's state, so that assertion no longer
    ///         lives in this test.
    function test_dispute_courtRevertDoesNotBrickDispute() public {
        MockRevertingCourt reverting = new MockRevertingCourt();
        vm.prank(owner);
        game.setCourt(address(reverting));

        uint256 id = _fileStandard(PROPOSAL);

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.AutoReferFailed(id);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max); // must not revert despite the court reverting

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed), "the dispute still landed");
        _assertLiveBondsBacked();
    }

    /// @notice No court wired (the zero address, Plan D's off-switch) skips the
    ///         auto-referral attempt entirely rather than reverting or emitting
    ///         a failure — there is nothing to refer to.
    function test_dispute_noCourtSkipsAutoRefer() public {
        vm.prank(owner);
        game.setCourt(address(0));

        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max); // must not revert with no court wired

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed));
    }

    /// @notice THE DEFENCE IS NEVER HOSTAGE TO THE COURT'S GAS APPETITE. A
    ///         court whose `refer` cannot complete within the gas `dispute`
    ///         happens to forward it must not be able to stop the accused
    ///         from buying its escalation — because a reverting `dispute`
    ///         leaves the counter-bond incomplete, the auto-slash clock
    ///         running, and the accused slashed by the silence verdict without
    ///         ever reaching adjudication. That failure is unrecoverable;
    ///         a SKIPPED referral is not (proven for real, against a genuine
    ///         `TokenCourt`, in `test/AutoReferRecovery.t.sol`'s I-1 test).
    ///
    ///         This is the mirror image of `finalize`'s under-gassed
    ///         regression, and deliberately so. There, swallowing a failure
    ///         destroyed a verdict with no retry, so the catch had to narrow.
    ///         Here, bubbling a failure would destroy a defence with no retry,
    ///         so the catch stays broad and unguarded. Same shape, opposite
    ///         answer, because the retry path sits on opposite sides.
    /// @dev    THE OUTER GAS CAP IS MEASURED, NOT GUESSED. With
    ///         `MockGasHungryCourt`'s floor set to a realistic 400_000 (a
    ///         number `refer`'s real `_recordAccused` loop could plausibly
    ///         need for a handful of approvers), a scratch binary search over
    ///         `dispute{gas: N}(...)` on this exact fixture found the
    ///         referral-lands/referral-skips crossover between N = 502_000
    ///         (skipped) and N = 504_000 (landed) — i.e. `dispute` itself
    ///         never runs short of gas anywhere in that range, only the
    ///         forwarded sub-call does. 300_000 sits comfortably inside the
    ///         skip side of that crossover: ~200k below it, and ~150k above
    ///         the lowest gas this suite observed `dispute` still completing
    ///         at (150_000) — wide enough on both sides that the test is not
    ///         chasing an exact boundary, so it will not flake under minor
    ///         gas-cost drift in either function.
    function test_dispute_underGassedCallSkipsReferralButLandsTheDefence() public {
        // A realistic floor, not an unconditionally-reverting one: exactly
        // what makes the skip genuinely GAS-caused rather than merely
        // "any revert is swallowed the same way" (that case is already
        // covered by `test_dispute_courtRevertDoesNotBrickDispute`).
        MockGasHungryCourt hungry = new MockGasHungryCourt(400_000);
        vm.prank(owner);
        game.setCourt(address(hungry));

        uint256 id = _fileStandard(PROPOSAL);

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.AutoReferFailed(id);
        vm.prank(guardianA);
        // Measured in-band: skips the referral (< ~503k crossover) but still
        // lets `dispute` itself complete (needs far less than 300k alone).
        game.dispute{gas: 300_000}(id, type(uint256).max);

        // (a) The defence landed in full despite the under-gassed referral.
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Disputed), "the accused bought its escalation");
        assertEq(c.counterBondWood, c.bondWood, "pool completed");
        assertEq(game.counterBondContributionOf(id, guardianA), c.counterBondWood, "contributor accounting intact");
        // (b) `AutoReferFailed` emitted — asserted above via `vm.expectEmit`.
        // (c) The court recorded nothing: the skip never reached the court's
        //     own bookkeeping.
        assertEq(hungry.lastReferred(), 0, "the court never recorded a referral");
    }

    // ── Disputed → timeout → fail (D5) ──

    /// @notice D5: no court exists to rule, so a contested challenge fails SAFE
    ///         after `disputeTimeout`. The challenger's bond forfeits to the
    ///         guardians that FUNDED THE DEFENCE, and their contributions come
    ///         back.
    /// @dev    CHANGED WITH THE POOLED COUNTER-BOND. This used to assert a 60/40
    ///         split by committed coverage, paying guardianB 40% of the forfeit
    ///         despite guardianB never putting up a wei. That is exactly the
    ///         free-ride the split is now keyed to contribution to kill: here
    ///         guardianA funds the whole pool alone, so it takes the whole
    ///         forfeit and guardianB — an accused approver that sat the defence
    ///         out — is paid nothing at all.
    /// @dev    CHANGED AGAIN BY THE FORFEIT BURN. guardianA still takes the
    ///         entire DISTRIBUTED forfeit, but that is now 80% of the bond: the
    ///         other 20% is destroyed, because a forfeit paid perfectly back to
    ///         its funder is free money whenever the funder and the challenger
    ///         are the same operator. The challenger's side of the ledger is
    ///         unchanged — it still loses the whole bond.
    function test_resolve_disputedPastTimeoutFailsToTheAccused() public {
        uint256 challengerBefore = wood.balanceOf(challenger); // before the bond is pulled
        uint256 id = _fileStandard(PROPOSAL); // $6,000 / $4,000 → 60/40 by COVERAGE
        uint256 filedAt = _filedAt(id);
        uint256 aBefore = wood.balanceOf(guardianA);
        uint256 bBefore = wood.balanceOf(guardianB);

        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);

        vm.warp(filedAt + game.disputeTimeout());
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeFailed(id, 10_000e18, 2_000e18);
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Failed));
        assertEq(swood.callCount(), 0, "a failed challenge slashes nobody");
        assertEq(tiers.demoteCount(), 0, "adapters demote only on a PASSED challenge");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage released on failure");

        // The challenger paid for the freeze it bought — the whole bond, exactly
        // as before the burn existed. The burn moves who RECEIVES the forfeit,
        // never what filing costs.
        assertEq(challengerBefore - wood.balanceOf(challenger), 10_000e18, "bond forfeited in full");
        // guardianA carried the defence alone, so it takes all of the DISTRIBUTED
        // upside: its contribution back (net 0) plus 100% of the 80% that was not
        // burned.
        assertEq(wood.balanceOf(guardianA) - aBefore, 8_000e18, "contribution returned plus the unburned forfeit");
        assertEq(
            wood.balanceOf(guardianB) - bBefore, 0, "40% of the coverage but 0% of the defence, so 0% of the winnings"
        );
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), 2_000e18, "and 20% of the forfeit left the system entirely");
        _assertLiveBondsBacked();
    }

    /// @notice THE ANTI-FREE-RIDE SPLIT. The forfeit is pro-rata to what each
    ///         guardian CONTRIBUTED to the counter-bond, not to what it covered.
    ///         The two shares are deliberately unequal AND deliberately inverted
    ///         against the coverage weights, so the assertion can only pass on
    ///         the contribution key: guardianA covers 77.77% but funds 30% of the
    ///         defence, and takes 30% of the winnings.
    function test_resolve_forfeitIsProRataToContributionAndLeavesNoDust() public {
        _setCoverage(PROPOSAL, 7_777e18, 2_223e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.ProposerLinkedOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 aBefore = wood.balanceOf(guardianA);
        uint256 bBefore = wood.balanceOf(guardianB);

        // 30 / 70 of the pool, against 77.77 / 22.23 of the coverage.
        uint256 aPut = (bond * 30) / 100;
        vm.prank(guardianA);
        game.dispute(id, aPut);
        assertEq(
            uint8(game.challengeOf(id).status),
            uint8(IChallengeGame.Status.Filed),
            "a part-funded pool is not a dispute"
        );
        vm.prank(guardianB);
        game.dispute(id, type(uint256).max); // takes the 70% shortfall
        uint256 bPut = bond - aPut;
        assertEq(game.counterBondContributionOf(id, guardianB), bPut);

        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        // Each gets its stake back plus its contribution-weighted slice of what
        // survives the burn. The BURN CHANGES THE POT, NOT THE KEY: the split is
        // still `mine / pool`, applied to `bond - burn`.
        uint256 burned = (bond * game.forfeitBurnBps()) / 10_000;
        uint256 payout = bond - burned;
        uint256 aGain = wood.balanceOf(guardianA) - aBefore;
        uint256 bGain = wood.balanceOf(guardianB) - bBefore;
        uint256 pool = aPut + bPut; // a completed pool, i.e. the challenger's bond
        assertEq(aGain, (payout * aPut) / pool, "the contribution key: (forfeit - burn) * mine / pool");
        assertEq(aGain, (payout * 30) / 100, "which here is 30%");
        assertNotEq(aGain, (payout * 7_777e18) / 10_000e18, "and emphatically NOT the coverage share");
        assertNotEq(aGain, bGain, "unequal contributions produce an unequal split");
        assertEq(aGain + bGain + burned, bond, "burn + distributed accounts for every wei of the forfeit");
        assertEq(wood.balanceOf(address(game)), 0, "no dust stranded in the game");
        _assertLiveBondsBacked();
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
        game.dispute(failed, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(failed);
        ledger.releaseApproval(address(gov), 2, guardianA);
    }

    /// @notice ONCE THE LIABILITY HAS BEEN COLLECTED THERE IS NOTHING LEFT TO
    ///         CHALLENGE (PR #25 review 🟡F12). The approvers underwrote ONE
    ///         proposal and owe ONE liability, which `_convicted` records as
    ///         collected. A filing after that can never reach a slash — it
    ///         settles straight into the `VerdictAlreadyCollected` branch — yet
    ///         it still froze the coverage on the way, and the freeze is what
    ///         bars every accused approver from `claimUnstakeGuardian`.
    ///
    ///         That made it a cheap way to keep already-slashed collateral
    ///         locked. The accused have no reason to dispute a filing that
    ///         cannot take anything more from them, so the filer reliably
    ///         reaches settle and is refunded all but `settleBurnBps` — a net
    ///         cost of 20% of (5% of coverage), or 0.1% of coverage USD, for
    ///         another `autoSlashDelay` of lock. Slots are per-challenger, so N
    ///         addresses buy N concurrent filings, chainable to the end of
    ///         `challengeWindow`.
    ///
    ///         A filing that cannot reach a verdict has no legitimate purpose,
    ///         so it is refused at the door rather than priced.
    function test_file_rejectsAProposalWhoseVerdictWasAlreadyCollected() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(_filedAt(id) + game.autoSlashDelay());
        game.resolve(id);

        // The window is still open — that is exactly the griefing window.
        assertLt(vm.getBlockTimestamp(), _executedAt(PROPOSAL) + game.challengeWindow(), "still challengeable by time");

        address griefer = makeAddr("griefer");
        wood.mint(griefer, 1_000_000e18);
        vm.startPrank(griefer);
        wood.approve(address(game), type(uint256).max);
        vm.expectRevert(IChallengeGame.AlreadyConvicted.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);
        vm.stopPrank();

        // And the coverage the settled challenge released stays released.
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "no re-freeze");
    }

    /// @notice A resolved challenge unblocks a later, legitimate filing against
    ///         the same proposal — the liveness check reads status, not history.
    ///         Still true for a challenge that FAILED: nothing was collected, so
    ///         the liability is still outstanding and a fresh filing is
    ///         legitimate. Only a COLLECTED verdict closes the proposal (🟡F12).
    function test_resolve_allowsALaterFilingOnTheSameProposal() public {
        // The ledger's own window must widen FIRST (Part C): the game's
        // `challengeWindow` is now capped at whatever the ledger reports live.
        ledger.setChallengeWindow(90 days);
        vm.prank(owner);
        game.setChallengeWindow(90 days); // outlive the dispute timeout
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(id);

        vm.prank(challenger);
        uint256 second =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);
        assertEq(game.liveChallengeOf(address(gov), PROPOSAL), second);
    }

    // ── The detector incentive is off-chain ──

    /// @notice AN UNCONTESTED win pays the challenger its bond back and nothing
    ///         else, because there is nothing else to pay it FROM: no guardian
    ///         funded a counter-bond, so no pool exists to forfeit. The
    ///         challenger's upside comes strictly out of the accused side's own
    ///         stake — never out of protocol funds, and never out of WOOD sitting
    ///         on this contract. That is what the stray-WOOD assertion below
    ///         pins: there is no bounty pot here, and no path invents one.
    function test_resolve_returnsBondAndPaysNoBounty() public {
        // WOOD sitting on the game beyond its live bonds is NOT a bounty pot:
        // no path spends it, so it is still here, untouched, afterwards.
        wood.mint(address(game), 5_000e18);

        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;
        assertEq(bond, 10_000e18);

        uint256 before = wood.balanceOf(challenger);
        uint256 burnBefore = wood.balanceOf(0x000000000000000000000000000000000000dEaD);
        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay());
        game.resolve(id);

        // A CORRECT FILING IS CHEAP, NOT FREE (review 🟠F4). The full refund
        // made an attacker whose payoff is the CONSEQUENCE — the approvers
        // slashed, the named adapter demoted — fully subsidised: the whole
        // attack cost gas. 20% of the bond burns; the rest comes back.
        uint256 burned = (bond * game.settleBurnBps()) / 10_000;
        assertEq(burned, 2_000e18, "20% of a 10,000 WOOD bond");
        assertEq(wood.balanceOf(challenger) - before, bond - burned, "the bond back less the burn, to the wei");
        assertEq(wood.balanceOf(0x000000000000000000000000000000000000dEaD) - burnBefore, burned, "the slice is burned");
        assertEq(game.bondedWood(), 0, "no challenge is live");
        assertEq(wood.balanceOf(address(game)), 5_000e18, "stray WOOD is never spent on a settlement");
    }

    /// @notice 🔴F1 regression, at the boundary that matters: the slash basis
    ///         must predate every instant the accused could have reacted to the
    ///         accusation. Anchored at `filedAt`, an approver zeroed its own
    ///         stake checkpoint with one reversible, cooldown-free transaction
    ///         and a 100% conviction recovered nothing.
    function test_resolve_slashBasisPredatesAnythingTheAccusedCanMove() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 executedAt = _executedAt(PROPOSAL);
        uint256 filedAt = _filedAt(id);

        // The accused has this whole span to move state. The basis must sit
        // before ALL of it, not at the far end.
        assertGt(filedAt, executedAt, "fixture: the filing trails execution");

        vm.warp(filedAt + game.autoSlashDelay());
        game.resolve(id);

        assertEq(swood.lastOpenedAt(), executedAt, "basis is the execution instant");
    }

    /// @notice 🟠F5: the clocks a challenge runs on are the ones it received.
    ///         Read live, the owner could shorten `autoSlashDelay` after a
    ///         filing and retroactively erase a dispute window the accused was
    ///         still inside — the exact griefing `MIN_AUTO_SLASH_DELAY`'s own
    ///         natspec promises it prevents, and did not.
    function test_dispute_windowIsPinnedAtFilingNotReadLive() public {
        uint256 id = _fileStandard(PROPOSAL);
        assertEq(game.challengeOf(id).autoSlashDelayAtFiling, 7 days, "the window this filing got");

        // Three days into a seven-day window, the owner collapses the parameter
        // to its floor. That is still a legal parameter — the floor bounds the
        // PARAMETER, not the window any given challenge already received.
        vm.warp(_filedAt(id) + 3 days);
        // Hoisted: a call in argument position consumes the pending prank.
        uint256 floorDelay = game.MIN_AUTO_SLASH_DELAY();
        vm.prank(owner);
        game.setAutoSlashDelay(floorDelay);

        // The accused still has the window it was accused under.
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
        assertEq(
            uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed), "window survived the setter"
        );

        // And resolution still waits for the pinned clock, not the new one.
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(id);
    }

    /// @notice 🟠F5, the other direction: raising `disputeTimeout` must not
    ///         extend a freeze that is already live.
    function test_resolve_disputeTimeoutIsPinnedAtFiling() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
        assertEq(game.challengeOf(id).disputeTimeoutAtFiling, 30 days);

        vm.prank(owner);
        game.setDisputeTimeout(60 days); // 2x, at the new ceiling (Part B)

        // The challenge times out on its own clock, so the coverage it pinned
        // is released when it always would have been.
        vm.warp(_filedAt(id) + 30 days);
        game.resolve(id);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Failed));
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "freeze released on the original clock");
    }

    /// @notice 🟠F4, the other half: a filing may not name an adapter the
    ///         proposal never touched. Paired with a full refund, that made
    ///         demoting ANY certified adapter in the registry cost gas and a
    ///         7-day wait — the slash of the approvers came along for free.
    function test_file_rejectsAnAdapterTheProposalNeverTouched() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        gov.setExecuteCall(PROPOSAL, ADAPTER, SELECTOR);

        vm.startPrank(challenger);
        // Right target, wrong selector.
        vm.expectRevert(IChallengeGame.AdapterNotInProposal.selector);
        game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, bytes4(0xdeadbeef), EVIDENCE
        );
        // Wrong target entirely — the arbitrary-demotion case.
        vm.expectRevert(IChallengeGame.AdapterNotInProposal.selector);
        game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0xC0FFEE), SELECTOR, EVIDENCE
        );
        // The adapter the proposal actually called goes through.
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        vm.stopPrank();
        assertGt(id, 0);
        assertEq(tiers.demoteCount(), 0, "nothing demoted by a filing alone");
    }

    /// @notice A filing that accuses NO adapter is still legal — predicates 2, 3
    ///         and 5 often indict a price or a destination rather than a
    ///         certification — and skips the membership test entirely.
    function test_file_zeroAdapterSkipsTheMembershipTest() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        gov.setExecuteCall(PROPOSAL, ADAPTER, SELECTOR);

        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OraclePriceDeviation, address(0), bytes4(0), EVIDENCE
        );
        vm.warp(_filedAt(id) + game.autoSlashDelay());
        game.resolve(id);
        assertEq(tiers.demoteCount(), 0, "a filing that names nothing demotes nothing");
        assertEq(swood.callCount(), 1, "but it still convicts");
    }

    /// @notice 🟠F4: governance can retire the burn without an upgrade, and a
    ///         zero burn restores the exact pre-finding refund.
    function test_setSettleBurnBps_boundedAndZeroRestoresTheFullRefund() public {
        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setSettleBurnBps(5_001);
        // `setSettleBurnBps` now refuses to drop below the live
        // `inconclusiveBurnBps` (review round 2, 2026-07-30) — zero it first,
        // or the default 500 `inconclusiveBurnBps` would refuse this call.
        game.setInconclusiveBurnBps(0);
        game.setSettleBurnBps(0);
        vm.stopPrank();

        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 before = wood.balanceOf(challenger);
        vm.warp(vm.getBlockTimestamp() + game.autoSlashDelay());
        game.resolve(id);
        assertEq(wood.balanceOf(challenger) - before, bond, "zero burn: the whole bond comes back");
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
        game.dispute(id, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

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
        game.setDisputeTimeout(61 days); // above the new 60-day ceiling (Part B)
        game.setDisputeTimeout(60 days);
        vm.stopPrank();
        assertEq(game.disputeTimeout(), 60 days);
    }

    /// @notice Part A / B3: `setDisputeTimeout(8 days)` used to be legal on its
    ///         own bound (`> autoSlashDelay`, 7 days by default) despite
    ///         leaving NEGATIVE room for `voteWindow + FINALIZE_BUFFER` (5d + 1d
    ///         on the wired `MockRecordingCourt`) — the exact defeat this task
    ///         closes: the accused could stall a counter-bond pool to the edge
    ///         of `autoSlashDelay` and guarantee `refer` can never fit.
    function test_setDisputeTimeout_revertsWindowInvariantViolated() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.WindowInvariantViolated.selector);
        game.setDisputeTimeout(8 days); // 7d autoSlashDelay + 5d voteWindow + 1d buffer = 13d > 8d
    }

    /// @notice Part A / B3, the other side: `setAutoSlashDelay(25 days)` was
    ///         also legal on its own bound (`< disputeTimeout`, 30 days by
    ///         default) despite the same negative-window defeat.
    function test_setAutoSlashDelay_revertsWindowInvariantViolated() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.WindowInvariantViolated.selector);
        game.setAutoSlashDelay(25 days); // 25d + 5d voteWindow + 1d buffer = 31d > 30d disputeTimeout
    }

    /// @notice The invariant is VACUOUS with no court wired — there is no
    ///         referral to fit, so neither setter has anything to check against.
    function test_setDisputeTimeout_vacuousWithNoCourtWired() public {
        vm.startPrank(owner);
        game.setCourt(address(0));
        game.setDisputeTimeout(8 days); // would violate the invariant if a court were wired
        vm.stopPrank();
        assertEq(game.disputeTimeout(), 8 days);
    }

    /// @notice The vacuous case, other side.
    function test_setAutoSlashDelay_vacuousWithNoCourtWired() public {
        vm.startPrank(owner);
        game.setCourt(address(0));
        game.setAutoSlashDelay(25 days); // would violate the invariant if a court were wired
        vm.stopPrank();
        assertEq(game.autoSlashDelay(), 25 days);
    }

    /// @notice BLOCKER (review 2026-07-29 audit, item 1): re-wiring to a NEW
    ///         court is itself a setter that can break the window invariant,
    ///         and it was completely unguarded. A fresh court whose own
    ///         `voteWindow` cannot fit this game's CURRENT clocks must be
    ///         refused at the door, not accepted and left for `refer` to
    ///         discover later.
    function test_setCourt_revertsWindowInvariantViolated_whenNewCourtCannotFit() public {
        MockRecordingCourt tooSlow = new MockRecordingCourt();
        tooSlow.setVoteWindow(25 days); // 7d autoSlashDelay + 25d + 1d buffer = 33d > 30d disputeTimeout
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.WindowInvariantViolated.selector);
        game.setCourt(address(tooSlow));
    }

    /// @notice THE PROVEN 3-STEP BYPASS ITSELF (review 2026-07-29 audit, item
    ///         1 BLOCKER), as a single test: the two guarded setters
    ///         (`setAutoSlashDelay`/`setDisputeTimeout`) and the previously
    ///         UNGUARDED `setCourt` compose into a full defeat of the B3
    ///         invariant using the very vacuous branch the guarded setters'
    ///         own tests establish as intended. `setCourt(0)` is legal (the
    ///         fail-safe off-switch); `setAutoSlashDelay(25 days)` then passes
    ///         ONLY because no court is wired to check against; re-wiring the
    ///         real court must now re-validate against that value and refuse,
    ///         or the composition lands the exact violation the individual
    ///         setters exist to prevent.
    function test_setCourt_bypassClosed_rewiringAfterVacuousAutoSlashDelayChangeReverts() public {
        vm.startPrank(owner);
        game.setCourt(address(0));
        game.setAutoSlashDelay(25 days); // legal while vacuous: would violate if court were wired (25+5+1=31>30)
        vm.expectRevert(IChallengeGame.WindowInvariantViolated.selector);
        game.setCourt(court); // rewiring must catch what the vacuous branch let through
        vm.stopPrank();
    }

    /// @notice The bypass composition still fails to LAND when the vacuous
    ///         change kept the invariant fitting — re-wiring is guarded, not
    ///         merely blocked outright.
    function test_setCourt_succeedsWhenRewiringToAFittingCourtAfterAVacuousChange() public {
        vm.startPrank(owner);
        game.setCourt(address(0));
        game.setAutoSlashDelay(3 days); // still fits: 3+5+1=9<=30
        game.setCourt(court);
        vm.stopPrank();
        assertEq(game.court(), court);
    }

    function test_setStakedWood_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.ZeroAddress.selector);
        game.setStakedWood(address(0));
    }

    /// @notice The prosecutor's fee no longer rides on sWOOD, so re-pointing
    ///         the slasher cannot strand a pinned rate. sWOOD is handed no rate
    ///         at all now — the fee is paid by `ProposerBondEscrow`, which
    ///         bounds it itself on every forfeiture.
    function test_setStakedWood_doesNotConstrainTheProsecutorFee() public {
        MockChallengeStakedWood other = new MockChallengeStakedWood();
        other.setAuthorizedSlasher(address(game));
        vm.prank(owner);
        game.setStakedWood(address(other)); // no rate check to fail
        assertEq(address(game.stakedWood()), address(other), "re-point accepted");
        assertEq(game.prosecutorFeeBps(), 500, "and the fee rate is untouched");
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
    ///         subset disputed, an arbitrary resolution order, AND an arbitrary
    ///         resolution PATH.
    /// @dev    `verdictSeed` is what adds that last dimension. Before it, every
    ///         resolution in this fuzz ran through `game.resolve`, which only
    ///         ever reaches `_settle` (an undisputed silence) or `_fail` (a
    ///         disputed challenge past its timeout) — `rule`'s `Inconclusive`
    ///         branch (`_refundAll`) was never once exercised under fuzzing,
    ///         despite being a THIRD accounting path with its own pool-refund
    ///         shape. For each DISPUTED challenge, a 2-bit slice of
    ///         `verdictSeed` now independently chooses between the timeout
    ///         (`resolve`, unchanged) and a court ruling (`rule`, as `court`)
    ///         with a fuzzed verdict — so `_settle`, `_fail` and `_refundAll`
    ///         are all reachable in the same run, and the custody invariant is
    ///         checked across whichever mix the fuzzer picks. A `Filed`
    ///         (undisputed) challenge always resolves via `resolve`: `rule`
    ///         demands `Disputed`, so routing an undisputed one through it
    ///         would just revert `WrongStatus` rather than exercise anything.
    function testFuzz_woodBalanceEqualsLiveBonds(
        uint96[3] memory coverage,
        uint8 disputeMask,
        uint8 orderSeed,
        uint8 verdictSeed
    ) public {
        uint256[3] memory ids;
        bool[3] memory disputed;
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
                game.dispute(ids[i], type(uint256).max);
                disputed[i] = true;
                _assertLiveBondsBacked();
            }
        }

        // Past BOTH deadlines, so every challenge is resolvable whichever state
        // it is in and the order is genuinely free. `rule` itself checks only
        // `status == Disputed`, never the clock, so warping this far forecloses
        // nothing for the rule() path exercised below.
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());

        // All six orderings of {0,1,2}.
        uint256 seed = orderSeed % 6;
        uint256 first = seed % 3;
        uint256 second = (first + 1 + (seed / 3)) % 3;
        uint256 third = 3 - first - second;
        uint256[3] memory order = [first, second, third];

        for (uint256 i = 0; i < 3; i++) {
            uint256 idx = order[i];
            // 2-bit slice per ORIGINAL challenge index: 0 => timeout via
            // `resolve`; 1/2/3 => a court ruling via `rule`, one fuzzed verdict
            // apiece. Only meaningful for a DISPUTED challenge — `rule` demands
            // `Disputed`, so an undisputed (`Filed`) one always takes `resolve`.
            uint256 choice = (uint256(verdictSeed) >> (2 * idx)) & 0x3;
            if (disputed[idx] && choice != 0) {
                IChallengeGame.Verdict v = choice == 1
                    ? IChallengeGame.Verdict.Guilty
                    : choice == 2 ? IChallengeGame.Verdict.NotGuilty : IChallengeGame.Verdict.Inconclusive;
                vm.prank(court);
                game.rule(ids[idx], v);
            } else {
                game.resolve(ids[idx]);
            }
            _assertLiveBondsBacked();
        }
        // "Nothing stranded" now means "nothing UNACCOUNTED": resolution records
        // entitlements instead of pushing them out, so whatever the game still
        // holds is owed to a funder that has not collected yet.
        assertEq(
            wood.balanceOf(address(game)),
            game.unclaimedWood(),
            "every wei still held is owed to a funder, none is stranded"
        );
        assertEq(game.bondedWood(), 0, "and no challenge is live");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Plan E Task 1 — the court-only ruling entrypoint
    // ─────────────────────────────────────────────────────────────────────────

    function _file() internal returns (uint256 id) {
        id = _fileStandard(PROPOSAL);
    }

    function _fileAndDispute() internal returns (uint256 id) {
        id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
    }

    function test_rule_onlyCourt() public {
        uint256 id = _fileAndDispute();
        vm.expectRevert(IChallengeGame.NotCourt.selector);
        game.rule(id, IChallengeGame.Verdict.Guilty);
    }

    /// @notice A guilty ruling routes into the SAME settle path an undisputed
    ///         challenge takes — slash into the escrow, adapter demoted, bond
    ///         returned — so the court supplies only the verdict bit (D7).
    function test_rule_guiltySettles() public {
        uint256 id = _fileAndDispute();
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Guilty);
        assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Settled));
    }

    /// @notice A not-guilty ruling fails the challenge: the challenger's bond
    ///         forfeits to the accused, exactly as a timeout would.
    function test_rule_notGuiltyFails() public {
        uint256 id = _fileAndDispute();
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.NotGuilty);
        assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Failed));
    }

    /// @notice The court may only rule on a DISPUTED challenge. A `Filed` one is
    ///         still inside its own auto-slash clock and has not been escalated.
    function test_rule_onlyFromDisputed() public {
        uint256 id = _file();
        vm.prank(court);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.rule(id, IChallengeGame.Verdict.Guilty);
    }

    /// @notice A ruling BEATS the timeout: once the court has ruled, the challenge
    ///         is terminal and `resolve` cannot re-resolve it.
    function test_rule_thenResolveReverts() public {
        uint256 id = _fileAndDispute();
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Guilty);
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout() + 1);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(id);
    }

    /// @notice With no court wired, Plan D's timeout behaviour is unchanged — a
    ///         disputed challenge still fails to the accused. This is what makes
    ///         the court additive rather than a breaking change.
    function test_noCourtWired_timeoutStillFailsToAccused() public {
        vm.prank(owner);
        game.setCourt(address(0));
        uint256 id = _fileAndDispute();
        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout() + 1);
        game.resolve(id);
        assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Failed));
    }

    /// @notice THE COUNTER-BOND FORFEITS TO THE CHALLENGER ON A GUILTY VERDICT.
    ///         This is the on-chain detector incentive, and it REVERSES the rule
    ///         this test used to pin (the pool returning to whoever posted it).
    ///         A refunded counter-bond did no work: disputing turned a certain
    ///         slash into a delayed one with some chance the court errs, at zero
    ///         bond cost, so a guilty approver always disputed — while a winning
    ///         challenger got only its own bond back and so had no on-chain
    ///         reason to do forensic work at all. Forfeited, the escalation costs
    ///         the accused what it is worth and pays the party that was right.
    function test_rule_guiltyForfeitsThePoolToTheChallenger() public {
        uint256 id = _fileAndDispute();
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 pool = game.challengeOf(id).counterBondWood;
        assertEq(pool, bond, "a complete pool matches the challenger's bond");

        uint256 challengerBefore = wood.balanceOf(challenger);
        uint256 disputerBefore = wood.balanceOf(guardianA);

        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Guilty);

        assertEq(
            wood.balanceOf(challenger) - challengerBefore, bond + pool, "its own bond back PLUS the forfeited pool"
        );
        assertEq(wood.balanceOf(guardianA), disputerBefore, "the accused loses the counter-bond it staked");
        _assertLiveBondsBacked();
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded once the ruling is terminal");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task 2 — three-valued Verdict: Inconclusive unwinds both sides (pool
    // whole, challenger bond minus the inconclusive burn — review #1 below)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `Inconclusive` is a NON-VERDICT: nothing was adjudicated, so the
    ///         challenger's bond comes back WHOLE (no `settleBurnBps` slice —
    ///         that burn prices an unanswered filing, and this one WAS
    ///         answered, just not decided) and the pool is booked for pull-claims
    ///         rather than pushed, exactly like the part-funded settle path.
    /// @dev Renamed from `test_rule_inconclusive_refundsBothSidesWhole` (review
    ///      #1, 2026-07-30): the POOL still comes back whole — nothing was won
    ///      or lost by the accused's defenders — but the CHALLENGER's bond no
    ///      longer does, since a slice is now burned (see the
    ///      `test_inconclusive_*` block below). "Both sides whole" stopped
    ///      being true the moment the freeze itself got priced.
    /// @dev ROUND 2, NOT ROUND 1 (owner decision 2026-07-30, review round 3):
    ///      round 1 against a fresh proposal is priced at 0 bps under the
    ///      escalating schedule (see `_inconclusiveBurnBpsForRound`), so
    ///      measuring this property on a single `_fileAndDispute()` would
    ///      exercise only the degenerate zero-burn case. A first, unmeasured
    ///      round establishes the escalation before the assertions below run.
    function test_rule_inconclusive_poolWholeChallengerBondMinusBurn() public {
        uint256 firstRoundId = _fileAndDispute();
        vm.prank(court);
        game.rule(firstRoundId, IChallengeGame.Verdict.Inconclusive); // round 1: free, unmeasured

        uint256 id = _fileAndDispute(); // round 2: escalated, this is what the test measures
        uint256 challengerBefore = wood.balanceOf(challenger);
        uint256 bondedBefore = game.bondedWood();
        // Round 1's own pool is ALREADY booked into `unclaimedWood` at this
        // point (it went through the same `_bookRefund` path) — the
        // assertion below must measure round 2's OWN contribution to it, not
        // the running total.
        uint256 unclaimedBefore = game.unclaimedWood();
        IChallengeGame.Challenge memory before = game.challengeOf(id);
        assertGt(before.inconclusiveBurnBpsAtFiling, 0, "fixture must reach an escalated, non-zero round");

        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint256(c.status), uint256(IChallengeGame.Status.Inconclusive), "terminal status");
        // Challenger bond back MINUS the inconclusive-path burn (review #1):
        // an unwind no longer refunds the bond whole, unlike before this fix.
        uint256 expectedBurn = before.bondWood * before.inconclusiveBurnBpsAtFiling / 10_000;
        assertEq(
            wood.balanceOf(challenger) - challengerBefore, before.bondWood - expectedBurn, "challenger bond minus burn"
        );
        // Pool booked as pull-claims, not pushed — untouched by the burn.
        assertEq(game.unclaimedWood() - unclaimedBefore, before.counterBondWood, "pool booked");
        assertEq(game.bondedWood(), bondedBefore - before.bondWood - before.counterBondWood, "bonded released");
        // Freeze released: the proposal's coverage is live again.
        assertEq(game.liveChallengeCountOf(address(gov), PROPOSAL), 0, "freeze released");
        _assertLiveBondsBacked();
    }

    /// @notice The pool's funders get their own stake back, one-for-one — no
    ///         winnings, because nothing was won: the escalation they bought
    ///         was never decided on the merits.
    function test_rule_inconclusive_contributorsClaimExactlyTheirStake() public {
        uint256 id = _fileAndDispute();
        uint256 stake = game.counterBondContributionOf(id, guardianA);
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        assertEq(game.claimableContribution(id, guardianA), stake, "stake back, no winnings");
        uint256 before = wood.balanceOf(guardianA);
        vm.prank(guardianA);
        game.claimContribution(id);
        assertEq(wood.balanceOf(guardianA) - before, stake, "claimed");
    }

    /// @notice The three verdicts route to three distinct terminal statuses:
    ///         `Guilty` settles, `NotGuilty` fails, `Inconclusive` (covered
    ///         above) refunds both sides whole.
    function test_rule_verdictMapping() public {
        uint256 g = _fileAndDispute();
        vm.prank(court);
        game.rule(g, IChallengeGame.Verdict.Guilty);
        assertEq(uint256(game.challengeOf(g).status), uint256(IChallengeGame.Status.Settled));

        uint256 n = _fileStandard(2); // a second proposal so the two rulings don't collide
        vm.prank(guardianA);
        game.dispute(n, type(uint256).max);
        vm.prank(court);
        game.rule(n, IChallengeGame.Verdict.NotGuilty);
        assertEq(uint256(game.challengeOf(n).status), uint256(IChallengeGame.Status.Failed));
    }

    /// @notice No `_convicted` mark and no demotion on the inconclusive path, so
    ///         the SAME proposal stays challengeable — a fresh filing must
    ///         succeed rather than revert `AlreadyConvicted`/`AlreadyChallenged`.
    function test_rule_inconclusive_allowsRefilingSameProposal() public {
        uint256 id = _fileAndDispute();
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        vm.prank(challenger);
        uint256 refiled = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        assertEq(uint256(game.challengeOf(refiled).status), uint256(IChallengeGame.Status.Filed), "refiling succeeds");
    }

    /// @notice `Inconclusive` is as terminal as `Settled`/`Failed`: the timeout
    ///         can no longer resolve it, and the court cannot rule on it twice.
    function test_rule_inconclusive_beatsTimeoutAndBarsASecondRuling() public {
        uint256 id = _fileAndDispute();
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout() + 1);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(id);

        vm.prank(court);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.rule(id, IChallengeGame.Verdict.Guilty);
    }

    /// @notice Multiple contributors, each claims EXACTLY its own stake back —
    ///         no pro-rata split of anything, because an unwind has no forfeit
    ///         to divide. Contrasts with the failed-path pro-rata tests: there
    ///         the pot is `bond - burn` split by contribution key; here each
    ///         funder's payout is just its own deposit, independent of the
    ///         other funder's share.
    function test_rule_inconclusive_multiContributorClaimsExactStake() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 aPut = (bond * 30) / 100;

        vm.prank(guardianA);
        game.dispute(id, aPut);
        vm.prank(guardianB);
        game.dispute(id, type(uint256).max); // takes the 70% shortfall, completes the pool
        uint256 bPut = bond - aPut;
        assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Disputed), "pool completed");

        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        assertEq(game.claimableContribution(id, guardianA), aPut, "guardianA's own stake, nothing pro-rated");
        assertEq(game.claimableContribution(id, guardianB), bPut, "guardianB's own stake, nothing pro-rated");

        uint256 aBefore = wood.balanceOf(guardianA);
        uint256 bBefore = wood.balanceOf(guardianB);
        vm.prank(guardianA);
        game.claimContribution(id);
        vm.prank(guardianB);
        game.claimContribution(id);
        assertEq(wood.balanceOf(guardianA) - aBefore, aPut, "guardianA claimed exactly its stake");
        assertEq(wood.balanceOf(guardianB) - bBefore, bPut, "guardianB claimed exactly its stake");
        assertEq(game.unclaimedWood(), 0, "fully claimed, nothing stranded");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Review #1 (2026-07-30) — the Inconclusive path prices the freeze too
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ROUND 1 IS FREE (owner decision 2026-07-30, review round 3 —
    ///         escalating the Inconclusive burn). A proposal's first-ever
    ///         attempt — or its first since the escalation last reset — is not
    ///         charged: an honest one-shot filer whose vote merely missed the
    ///         participation floor pays nothing, exactly as before review #1.
    ///         The escalation prices REPETITION, not a single unlucky vote.
    function test_inconclusive_firstRoundIsFree() public {
        uint256 id = _fileAndDispute();
        assertEq(game.challengeOf(id).inconclusiveBurnBpsAtFiling, 0, "round 1 pins a free rate");

        uint256 before = wood.balanceOf(challenger);
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);
        assertEq(wood.balanceOf(challenger) - before, game.challengeOf(id).bondWood, "the whole bond came back");
    }

    /// @notice THE FULL SCHEDULE, ROUND BY ROUND: 1 free, 2 at 5%, 3 at 10%,
    ///         4 (and beyond) at the `inconclusiveBurnBps` steady state (20%
    ///         by default). Each round reuses `_fileAndDispute`, which
    ///         re-executes the same proposal (`_fileStandard` always
    ///         re-stamps `executedAt`) and refiles well inside the window
    ///         `_refundAll` just re-armed, so `inconclusiveRounds` climbs by
    ///         exactly one per round without ever resetting.
    function test_inconclusive_escalationSchedule() public {
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);

        uint256 r1 = _fileAndDispute();
        assertEq(game.challengeOf(r1).inconclusiveBurnBpsAtFiling, 0, "round 1: free");
        vm.prank(court);
        game.rule(r1, IChallengeGame.Verdict.Inconclusive);
        assertEq(game.inconclusiveRounds(key), 1, "one round recorded");

        uint256 r2 = _fileAndDispute();
        assertEq(game.challengeOf(r2).inconclusiveBurnBpsAtFiling, 500, "round 2: 5%");
        vm.prank(court);
        game.rule(r2, IChallengeGame.Verdict.Inconclusive);

        uint256 r3 = _fileAndDispute();
        assertEq(game.challengeOf(r3).inconclusiveBurnBpsAtFiling, 1_000, "round 3: 10%");
        vm.prank(court);
        game.rule(r3, IChallengeGame.Verdict.Inconclusive);

        uint256 r4 = _fileAndDispute();
        assertEq(game.challengeOf(r4).inconclusiveBurnBpsAtFiling, 2_000, "round 4: the steady state");
        vm.prank(court);
        game.rule(r4, IChallengeGame.Verdict.Inconclusive);

        uint256 r5 = _fileAndDispute();
        assertEq(game.challengeOf(r5).inconclusiveBurnBpsAtFiling, 2_000, "round 5 (4+): stays at the steady state");
    }

    // ── Issue #95: an Inconclusive re-arm must pin exposure to match ──

    /// @notice `_refundAll` releases the LIVE freeze but re-arms
    ///         `challengeableUntil[rk]` for another `challengeWindow` — this
    ///         test pins that the SAME call now also extends the ledger's
    ///         exposure pin to match, via `pinCoverageUntil`, rather than
    ///         leaving the re-armed window unprotected.
    /// @dev    MUTATION-CHECKED: deleting the `pinCoverageUntil` call from
    ///         `_refundAll` makes `pinCoverageUntilCallCount` stay `0` here,
    ///         failing the first assertion — this is the exact call the fix
    ///         adds, not incidental mock plumbing.
    function test_inconclusive_pinsExposureThroughTheReArmedDeadline() public {
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        uint256 id = _fileAndDispute();

        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        assertEq(ledger.pinCoverageUntilCallCount(), 1, "the re-arm calls pinCoverageUntil exactly once");
        uint256 rearmed = game.challengeableUntil(key);
        assertGt(rearmed, block.timestamp, "the window is genuinely re-armed");
        assertEq(
            ledger.pinnedUntil(address(gov), PROPOSAL),
            rearmed,
            "pinned through the SAME instant the re-armed deadline reads, not a stale or independent one"
        );
    }

    /// @notice THE ESCALATION IS REAL WOOD, NOT JUST A BIGGER BPS NUMBER: round
    ///         3 must burn strictly more WOOD than round 2, on the same
    ///         proposal with essentially the same bond size.
    function test_inconclusive_escalationCostsMoreWoodEachRound() public {
        uint256 r1 = _fileAndDispute();
        vm.prank(court);
        game.rule(r1, IChallengeGame.Verdict.Inconclusive); // round 1: free, establishes the streak

        uint256 r2 = _fileAndDispute();
        uint256 burnedBeforeR2 = wood.balanceOf(game.BURN_ADDRESS());
        vm.prank(court);
        game.rule(r2, IChallengeGame.Verdict.Inconclusive);
        uint256 round2Burn = wood.balanceOf(game.BURN_ADDRESS()) - burnedBeforeR2;
        assertGt(round2Burn, 0, "round 2 burns something");

        uint256 r3 = _fileAndDispute();
        uint256 burnedBeforeR3 = wood.balanceOf(game.BURN_ADDRESS());
        vm.prank(court);
        game.rule(r3, IChallengeGame.Verdict.Inconclusive);
        uint256 round3Burn = wood.balanceOf(game.BURN_ADDRESS()) - burnedBeforeR3;
        assertGt(round3Burn, round2Burn, "round 3 burns strictly more WOOD than round 2");
    }

    /// @notice The round-4+ tier's rate is pinned at filing, mirroring
    ///         `settleBurnBpsAtFiling` and `forfeitBurnBpsAtFiling`: a
    ///         post-filing raise of `inconclusiveBurnBps` must not bite a
    ///         challenger who already committed its bond under the old rate.
    ///         Exercised at round 4 specifically, since rounds 1-3 are fixed
    ///         literals this setter cannot move at all.
    function test_inconclusive_burnIsPinnedAtFiling() public {
        uint256 r1 = _fileAndDispute();
        vm.prank(court);
        game.rule(r1, IChallengeGame.Verdict.Inconclusive);
        uint256 r2 = _fileAndDispute();
        vm.prank(court);
        game.rule(r2, IChallengeGame.Verdict.Inconclusive);
        uint256 r3 = _fileAndDispute();
        vm.prank(court);
        game.rule(r3, IChallengeGame.Verdict.Inconclusive);

        uint256 id = _fileAndDispute(); // round 4: reads inconclusiveBurnBps at filing
        vm.prank(owner);
        game.setInconclusiveBurnBps(500); // lower AFTER filing (still legal: <= live settleBurnBps)
        uint256 before = wood.balanceOf(challenger);
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(c.inconclusiveBurnBpsAtFiling, 2_000, "the challenge keeps its filing-time rate");
        assertEq(
            wood.balanceOf(challenger) - before,
            c.bondWood - (c.bondWood * 2_000 / 10_000),
            "burned at the pinned rate, not the lowered one"
        );
    }

    /// @notice THE GRIND RESETS WHEN THE WINDOW LAPSES NATURALLY (owner
    ///         decision 2026-07-30): if nobody refiles before the re-armed
    ///         `challengeableUntil` passes, the repetition streak is over, so
    ///         an old, cold proposal must not keep punishing a later,
    ///         unrelated legitimate filer at an escalated rate forever.
    function test_inconclusive_roundsResetAfterTheWindowLapsesNaturally() public {
        uint256 r1 = _fileAndDispute();
        vm.prank(court);
        game.rule(r1, IChallengeGame.Verdict.Inconclusive);
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        assertEq(game.inconclusiveRounds(key), 1, "round 1 recorded");

        // Let the re-armed window lapse naturally: nobody refiles inside it.
        vm.warp(game.challengeableUntil(key) + 1);

        uint256 r2 = _fileAndDispute(); // a fresh execution makes this legal again
        assertEq(game.inconclusiveRounds(key), 0, "the streak reset before this filing incremented anything");
        assertEq(game.challengeOf(r2).inconclusiveBurnBpsAtFiling, 0, "priced as a fresh round 1, not round 2");
    }

    /// @notice SYBIL-RESISTANCE: the escalation is keyed on the PROPOSAL
    ///         (`reviewKey`), not on the challenger. A different address
    ///         filing round 2 against the same proposal, still inside the
    ///         re-armed window, still pays the escalated rate — switching
    ///         identity buys no reset. Same tradeoff `_convicted` and
    ///         `challengeableUntil` already make, for the same reason.
    function test_inconclusive_sybilCannotResetTheEscalationWithADifferentChallenger() public {
        uint256 r1 = _fileAndDispute(); // filed by `challenger`
        vm.prank(court);
        game.rule(r1, IChallengeGame.Verdict.Inconclusive);

        address sybil = makeAddr("sybilChallenger");
        wood.mint(sybil, 10_000_000e18);
        vm.prank(sybil);
        wood.approve(address(game), type(uint256).max);
        vm.prank(sybil);
        uint256 r2 = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        assertEq(game.challengeOf(r2).inconclusiveBurnBpsAtFiling, 500, "the sybil still pays the escalated rate");
    }

    /// @notice THE CLAMP, NOT A REVERT, WHEN `settleBurnBps` SITS BELOW THE
    ///         SCHEDULE. Rounds 2/3 are fixed literals (500/1,000 bps), not
    ///         covered by the `setSettleBurnBps`/`setInconclusiveBurnBps`
    ///         cross-check pair (that pair only bounds the round-4+ tier), so
    ///         lowering `settleBurnBps` below one of them must not revert
    ///         `file` — it must silently clamp the pinned rate down instead,
    ///         since a revert here would block filing entirely.
    function test_inconclusive_clampsToTheLiveSettleBurnBpsWhenLoweredBelowTheSchedule() public {
        vm.startPrank(owner);
        // The two-sided setter check refuses `settleBurnBps` below the live
        // `inconclusiveBurnBps`, so the round-4+ tier must come down first.
        game.setInconclusiveBurnBps(800);
        game.setSettleBurnBps(800); // now below the round-3 schedule step (1_000)
        vm.stopPrank();

        uint256 r1 = _fileAndDispute();
        vm.prank(court);
        game.rule(r1, IChallengeGame.Verdict.Inconclusive);

        uint256 r2 = _fileAndDispute();
        assertEq(game.challengeOf(r2).inconclusiveBurnBpsAtFiling, 500, "round 2's 5% is still under the ceiling");
        vm.prank(court);
        game.rule(r2, IChallengeGame.Verdict.Inconclusive);

        uint256 r3 = _fileAndDispute();
        assertEq(
            game.challengeOf(r3).inconclusiveBurnBpsAtFiling,
            800,
            "round 3's 1_000bps schedule step clamps to the live settleBurnBps instead of reverting"
        );
    }

    /// @notice Bounded [0, `MAX_INCONCLUSIVE_BURN_BPS`], owner-only. The
    ///         ceiling is exercised with `settleBurnBps` first raised to its
    ///         own ceiling, isolating this bound from the cross-setter
    ///         ordering check covered separately below — otherwise `5_000`
    ///         would collide with the default 2,000 `settleBurnBps` and this
    ///         test would be proving the wrong revert.
    function test_setInconclusiveBurnBps_boundsAndOwner() public {
        vm.startPrank(owner);
        game.setSettleBurnBps(5_000); // headroom for the ceiling case below
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setInconclusiveBurnBps(5_001);
        game.setInconclusiveBurnBps(5_000); // the ceiling itself is allowed
        assertEq(game.inconclusiveBurnBps(), 5_000);
        vm.stopPrank();

        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, challenger));
        game.setInconclusiveBurnBps(100);

        vm.prank(owner);
        game.setInconclusiveBurnBps(0); // zero legal - burn off
        assertEq(game.inconclusiveBurnBps(), 0);
    }

    /// @notice THE CROSS-SETTER ORDERING, BOTH DIRECTIONS (review round 2,
    ///         2026-07-30). Equal ceilings (`MAX_INCONCLUSIVE_BURN_BPS ==
    ///         MAX_SETTLE_BURN_BPS`) bound the two rates' maximums
    ///         identically but say nothing about where the LIVE rates sit —
    ///         each setter must additionally check the OTHER's current value,
    ///         or the owner could legally invert the ordering one call at a
    ///         time. This is direction 1: `setInconclusiveBurnBps` must refuse
    ///         to rise above the live `settleBurnBps`.
    function test_setInconclusiveBurnBps_revertsAboveTheLiveSettleBurnBps() public {
        assertEq(game.settleBurnBps(), 2_000, "sanity: the default this bound is checked against");
        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setInconclusiveBurnBps(2_001); // one bps above the live settleBurnBps
        game.setInconclusiveBurnBps(2_000); // equal to it is fine
        assertEq(game.inconclusiveBurnBps(), 2_000);
        vm.stopPrank();
    }

    /// @notice Direction 2 of the same ordering: `setSettleBurnBps` must
    ///         refuse to drop below the live `inconclusiveBurnBps`. Both
    ///         default to 2,000 now (owner decision 2026-07-30 changed
    ///         `inconclusiveBurnBps`'s default from 500 to 2,000, repurposing
    ///         it as the round-4+ steady state), so the probe values shift
    ///         accordingly from the review-round-2 version of this test.
    function test_setSettleBurnBps_revertsBelowTheLiveInconclusiveBurnBps() public {
        assertEq(game.inconclusiveBurnBps(), 2_000, "sanity: the default this bound is checked against");
        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setSettleBurnBps(1_999); // one bps below the live inconclusiveBurnBps
        game.setSettleBurnBps(2_000); // equal to it is fine
        assertEq(game.settleBurnBps(), 2_000);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task 4 (review M3) — Inconclusive extends the re-challenge window
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Mirrors `ChallengeGame._reviewKey` exactly — the two must derive
    ///      the same key or every `challengeableUntil` lookup below means
    ///      nothing.
    function _reviewKeyFor(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    /// @dev Like `_fileStandard`, but files `offset` after execution instead
    ///      of the fixed 3 days — needed to put the filing close enough to
    ///      execution that a pool stalled to the edge of `autoSlashDelay` can
    ///      still land an `Inconclusive` verdict past
    ///      `executedAt + challengeWindow`.
    function _fileStandardAt(uint256 proposalId, uint256 offset) internal returns (uint256 id) {
        _setCoverage(proposalId, 6_000e18, 4_000e18);
        _execute(proposalId);
        vm.warp(vm.getBlockTimestamp() + offset);
        vm.prank(challenger);
        id = game.file(
            address(gov), proposalId, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
    }

    /// @dev Completes a filed challenge's counter-bond pool at `filedAt +
    ///      instant` — standing in for the accused choosing exactly when
    ///      inside `autoSlashDelay` to stop stalling. `instant` must be
    ///      strictly less than the challenge's `autoSlashDelayAtFiling`, or
    ///      the contribution window has already closed.
    function _completePoolAt(uint256 id, uint256 instant) internal {
        vm.warp(_filedAt(id) + instant);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
    }

    /// @dev Completes a filed challenge's counter-bond pool right now, with no
    ///      stall — the ordinary case, used where the timing of completion
    ///      does not matter to the assertion.
    function _completePool(uint256 id) internal {
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
    }

    /// @dev Files against `proposalId` from `who` WITHOUT re-executing it —
    ///      unlike `_fileStandard`, which always re-stamps `executedAt` to
    ///      "now" and so would silently reset any re-challenge deadline back
    ///      to a fresh `executedAt + challengeWindow`. Needed whenever a test
    ///      must file a SECOND time against the SAME execution instant, to
    ///      prove a re-challenge window was — or was not — actually extended,
    ///      rather than merely reset by a fresh execution.
    function _fileStandardFrom(address who, uint256 proposalId) internal returns (uint256 id) {
        vm.prank(who);
        id = game.file(
            address(gov), proposalId, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
    }

    /// @notice M3: without extending `challengeableUntil` on an `Inconclusive`
    ///         unwind, `Inconclusive` is a PERMANENT acquittal for any
    ///         challenge filed more than roughly `challengeWindow -
    ///         autoSlashDelay - voteWindow` after execution — the accused
    ///         simply stalls the counter-bond pool to the last legal instant
    ///         inside `autoSlashDelay`, and the verdict lands past
    ///         `executedAt + challengeWindow` with no filing gate left
    ///         standing. Filed at day 3, stalled to the edge of the 7-day
    ///         `autoSlashDelay`, ruled `Inconclusive` the same instant: this
    ///         proposal must still be re-challengeable five days later, well
    ///         past the original 14-day window.
    function test_inconclusive_extendsTheRechallengeWindow() public {
        uint256 id = _fileStandardAt(PROPOSAL, 3 days);
        _completePoolAt(id, 7 days - 1);
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        assertGt(game.challengeableUntil(key), vm.getBlockTimestamp(), "window was extended");

        vm.warp(vm.getBlockTimestamp() + 5 days); // well past executedAt + 14 days
        uint256 refiled = _fileStandardFrom(challenger, PROPOSAL); // MUST NOT revert WindowClosed
        assertGt(refiled, 0, "the proposal is genuinely re-challengeable");
    }

    /// @notice A second inconclusive round must never pull the deadline back
    ///         in — NOT because block.timestamp only moves forward (round 2
    ///         is chronologically later than round 1 no matter what, which
    ///         would make a bare `assertGe` true even with the guard deleted
    ///         and the write made unconditional), but because the guard
    ///         itself refuses to shrink a bigger stored value.
    ///
    ///         To tell those two apart, round 1 STALLS (`_completePoolAt`,
    ///         `autoSlashDelay - 1`) so it rules LATE and its extension —
    ///         `ruledAt1 + challengeWindow` at the DEFAULT 14-day window — is
    ///         inflated well past what an un-stalled round 2 would compute on
    ///         its own. `challengeWindow` is then shrunk before round 2, so
    ///         round 2's own `block.timestamp + challengeWindow` comes out
    ///         SMALLER than round 1's stored value even though round 2 rules
    ///         strictly later in wall-clock time — the only way an
    ///         unconditional write could ever produce a smaller number here.
    ///         `assertEq` (not `assertGe`) is what makes that shrink visible.
    function test_challengeableUntil_onlyEverLengthens() public {
        uint256 id = _fileStandardAt(PROPOSAL, 3 days);
        _completePoolAt(id, 7 days - 1); // stall to the edge of autoSlashDelay: rules late
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        uint256 first = game.challengeableUntil(key);

        // Shrink the window so round 2's OWN extension is smaller than round
        // 1's, despite ruling strictly later.
        vm.prank(owner);
        game.setChallengeWindow(1 days);

        uint256 again = _fileStandard(PROPOSAL); // no stall; re-executes and rules promptly
        _completePool(again);
        vm.prank(court);
        game.rule(again, IChallengeGame.Verdict.Inconclusive);

        // Sanity-check the fixture itself: if this ever fails, the timeline
        // no longer produces a smaller round-2 extension and the assertion
        // below would pass for the wrong reason (or for no reason at all).
        uint256 round2Extension = vm.getBlockTimestamp() + game.challengeWindow();
        assertLt(round2Extension, first, "fixture must make round 2's own extension smaller than round 1's");

        assertEq(game.challengeableUntil(key), first, "never shortens");
    }

    /// @notice A proposal that never went inconclusive must behave exactly as
    ///         before: the gate is `executedAt + challengeWindow`, unextended,
    ///         and filing past it reverts.
    function test_challengeableUntil_unsetFallsBackToExecutedAtPlusWindow() public {
        _fileStandard(PROPOSAL);
        assertEq(game.challengeableUntil(_reviewKeyFor(address(gov), PROPOSAL)), 0, "unset until an unwind");
        vm.warp(vm.getBlockTimestamp() + 15 days);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        _fileStandardFrom(makeAddr("otherChallenger"), PROPOSAL);
    }

    /// @notice Review blocker: a TEMPORARY shortening of `challengeWindow`
    ///         around an `Inconclusive` unwind must not PERMANENTLY shrink a
    ///         proposal's re-challenge deadline below what the RESTORED
    ///         window would give it. `_refundAll` reads `challengeWindow`
    ///         live, so an owner who shortens it, lets a challenge unwind
    ///         while it is short, then restores it, must not leave
    ///         `challengeableUntil` holding a deadline smaller than
    ///         `executedAt + challengeWindow` computed against the RESTORED
    ///         value — there is no setter for `challengeableUntil` to undo
    ///         that, so `file`'s gate must take the max of the two on every
    ///         call rather than trusting whichever was stored at the last
    ///         write.
    function test_challengeableUntil_survivesATemporarilyShortenedWindow() public {
        uint256 id = _fileStandard(PROPOSAL);

        // Shorten the window to almost nothing, and unwind while it is short.
        vm.prank(owner);
        game.setChallengeWindow(1);
        _completePool(id);
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        // Restore the ordinary window.
        vm.prank(owner);
        game.setChallengeWindow(14 days);

        // Still well inside `executedAt + 14 days` (the restored window),
        // but past the tiny stored extension the shortened window produced.
        vm.warp(vm.getBlockTimestamp() + 5 days);

        uint256 refiled = _fileStandardFrom(challenger, PROPOSAL); // MUST NOT revert WindowClosed
        assertGt(refiled, 0, "restoring the window must restore full challengeability");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The pooled counter-bond
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Three covering approvers — needed for the Sybil-split comparison,
    ///      where one operator shows up as two guardian identities.
    function _setCoverage3(uint256 proposalId, address g0, uint256 usd0, address g1, uint256 usd1, uint256 usd2)
        internal
    {
        address[] memory guardians = new address[](3);
        uint256[] memory usd = new uint256[](3);
        guardians[0] = g0;
        guardians[1] = g1;
        guardians[2] = guardianB;
        usd[0] = usd0;
        usd[1] = usd1;
        usd[2] = usd2;
        ledger.setApprovers(address(gov), proposalId, guardians, usd);
    }

    function _fund(address who) internal {
        wood.mint(who, 10_000_000e18);
        vm.prank(who);
        wood.approve(address(game), type(uint256).max);
    }

    /// @notice CONTRIBUTIONS ACCUMULATE, AND THE POOL OPENS THE DISPUTE. A
    ///         part-funded pool leaves the challenge `Filed` — the auto-slash
    ///         clock is still running, because a partial defence is not a
    ///         defence. The contribution that completes the pool is the one that
    ///         flips the status, in the same call.
    function test_dispute_poolAccumulatesAndOpensTheDisputeOnCompletion() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;

        vm.prank(guardianA);
        game.dispute(id, 3_000e18);
        IChallengeGame.Challenge memory mid = game.challengeOf(id);
        assertEq(uint8(mid.status), uint8(IChallengeGame.Status.Filed), "still Filed - the pool is short");
        assertEq(mid.counterBondWood, 3_000e18);
        assertEq(game.bondedWood(), bond + 3_000e18, "the partial pool is custodied and accounted");
        assertEq(wood.balanceOf(address(game)), bond + 3_000e18);
        _assertLiveBondsBacked();

        // A top-up from the SAME guardian must not append a second list entry.
        vm.prank(guardianA);
        game.dispute(id, 1_000e18);
        assertEq(game.counterBondContributionOf(id, guardianA), 4_000e18, "topped up in place");
        assertEq(game.counterBondContributors(id).length, 1, "and listed only once");

        // The completing contribution flips the status.
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.CounterBondContributed(id, guardianB, 6_000e18, bond);
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeDisputed(id, bond);
        vm.prank(guardianB);
        game.dispute(id, 6_000e18);

        IChallengeGame.Challenge memory done = game.challengeOf(id);
        assertEq(uint8(done.status), uint8(IChallengeGame.Status.Disputed), "the pool bought the escalation");
        assertEq(done.counterBondWood, bond);
        address[] memory funders = game.counterBondContributors(id);
        assertEq(funders.length, 2);
        assertEq(funders[0], guardianA, "first-contribution order");
        assertEq(funders[1], guardianB);
        _assertLiveBondsBacked();
    }

    /// @notice THE PARTIAL-POOL REFUND, which is where this design most easily
    ///         strands funds forever. The pool never reached its target, so it
    ///         never bought a dispute: the auto-slash clock ran out and `_settle`
    ///         is entered from `Filed` WITH MONEY IN THE POOL — a state Plan D
    ///         and Plan E could both assume was impossible. Those contributions
    ///         must go back to the people who made them. Forfeiting them to the
    ///         challenger would charge for a good never delivered; keeping them
    ///         would break §4's custody invariant permanently.
    function test_resolve_undisputedRefundsAPartialPool() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 aBefore = wood.balanceOf(guardianA);
        uint256 bBefore = wood.balanceOf(guardianB);
        uint256 challengerBefore = wood.balanceOf(challenger);

        // Unequal partial contributions that together fall short of the target.
        vm.prank(guardianA);
        game.dispute(id, 2_500e18);
        vm.prank(guardianB);
        game.dispute(id, 1_500e18);
        assertEq(game.challengeOf(id).counterBondWood, 4_000e18, "a pool short of the 10,000 target");
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Filed), "so no dispute was bought");

        // The clock runs out on the part-funded defence.
        vm.warp(_filedAt(id) + game.autoSlashDelay());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled), "silence was the verdict");
        assertEq(swood.callCount(), 1, "the contributors are still slashed - the refund is not an acquittal");

        // Exact balances: each contributor is made whole, to the wei.
        assertEq(wood.balanceOf(guardianA), aBefore, "guardianA's 2,500 came back");
        assertEq(wood.balanceOf(guardianB), bBefore, "guardianB's 1,500 came back");
        // Less F4's settle burn. This is the UNADJUDICATED path, which is
        // exactly the scope that burn has: a filing nobody answered used to buy
        // the slash and the demotion for the price of gas. The pool is still not
        // the challenger's — that is what this test is really pinning.
        uint256 settleBurn = (bond * game.settleBurnBps()) / 10_000;
        assertEq(
            wood.balanceOf(challenger) - challengerBefore,
            bond - settleBurn,
            "the challenger gets its bond less the settle burn, and NOT the pool"
        );

        assertEq(game.bondedWood(), 0, "nothing left accounted");
        assertEq(wood.balanceOf(address(game)), 0, "and nothing left stranded");
        _assertLiveBondsBacked();
    }

    /// @notice An over-sized contribution takes only the shortfall, so nobody
    ///         can overpay and there is no refund-of-excess path to get wrong.
    function test_dispute_overContributionTakesOnlyTheShortfall() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;

        vm.prank(guardianA);
        game.dispute(id, 9_000e18);

        uint256 bBefore = wood.balanceOf(guardianB);
        // Asks for far more than the 1,000 still needed.
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.CounterBondContributed(id, guardianB, 1_000e18, bond);
        vm.prank(guardianB);
        game.dispute(id, 500_000e18);

        assertEq(bBefore - wood.balanceOf(guardianB), 1_000e18, "only the shortfall was pulled");
        assertEq(game.challengeOf(id).counterBondWood, bond, "the pool never exceeds its target");
        assertEq(game.counterBondContributionOf(id, guardianB), 1_000e18);
        _assertLiveBondsBacked();
    }

    /// @notice A zero-value contribution moves nothing and is rejected, rather
    ///         than appending an empty entry to the contributor list.
    function test_dispute_revertsOnAZeroContribution() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        vm.expectRevert(IChallengeGame.NothingToContribute.selector);
        game.dispute(id, 0);
    }

    /// @notice A PARTIAL contribution does not open a contribution window past
    ///         the deadline: the pool is still short, the challenge is still
    ///         `Filed`, and at `filedAt + autoSlashDelay` the silence verdict is
    ///         already final, so no further WOOD may be added to the defence.
    function test_dispute_revertsAfterTheDeadlineEvenWithAPartialPool() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 filedAt = _filedAt(id);
        vm.prank(guardianA);
        game.dispute(id, 4_000e18);

        vm.warp(filedAt + game.autoSlashDelay());
        vm.prank(guardianB);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.dispute(id, 6_000e18);

        // Same for a top-up from the guardian that already paid in.
        vm.prank(guardianA);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.dispute(id, 6_000e18);
    }

    /// @notice SPLITTING AN IDENTITY BUYS NO DISCOUNT. This is the constraint
    ///         that forced the target to stay pinned to the challenger's bond
    ///         instead of being charged per-guardian by coverage share: the
    ///         accused side picks who disputes, so any rule keyed to the payer's
    ///         OWN share is answered by nominating — or manufacturing — the
    ///         cheapest identity.
    ///
    ///         Same operator, same coverage, two shapes. Whole: one guardian
    ///         covering $6,000. Split: two guardians covering $3,000 each, both
    ///         contributing. The operator's total outlay is identical.
    function test_dispute_sybilSplitPaysTheSameTotal() public {
        // ── Shape 1: the operator is a single identity.
        uint256 whole = _fileStandard(PROPOSAL); // guardianA $6,000 / guardianB $4,000
        uint256 wholeBond = game.challengeOf(whole).bondWood;
        uint256 aBefore = wood.balanceOf(guardianA);
        vm.prank(guardianA);
        game.dispute(whole, type(uint256).max);
        uint256 wholeOutlay = aBefore - wood.balanceOf(guardianA);

        // ── Shape 2: the SAME operator, split into two guardian identities that
        //    together cover exactly what guardianA covered alone. Same summed
        //    coverage overall, so the challenger's bond — and the pool target —
        //    is the same number.
        address sybil1 = makeAddr("sybil1");
        address sybil2 = makeAddr("sybil2");
        _fund(sybil1);
        _fund(sybil2);
        _setCoverage3(2, sybil1, 3_000e18, sybil2, 3_000e18, 4_000e18);
        _execute(2);
        vm.prank(challenger);
        uint256 split =
            game.file(address(gov), 2, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);
        uint256 splitBond = game.challengeOf(split).bondWood;
        assertEq(splitBond, wholeBond, "same summed coverage, so the same bond and the same pool target");

        uint256 s1Before = wood.balanceOf(sybil1);
        uint256 s2Before = wood.balanceOf(sybil2);
        vm.prank(sybil1);
        game.dispute(split, splitBond / 2);
        vm.prank(sybil2);
        game.dispute(split, type(uint256).max);

        uint256 splitOutlay = (s1Before - wood.balanceOf(sybil1)) + (s2Before - wood.balanceOf(sybil2));
        assertEq(uint8(game.challengeOf(split).status), uint8(IChallengeGame.Status.Disputed), "escalation bought");
        assertEq(splitOutlay, wholeOutlay, "SPLITTING BOUGHT NO DISCOUNT - the total is invariant");
        assertEq(splitOutlay, splitBond, "and it is still exactly the challenger's bond");
        _assertLiveBondsBacked();
    }

    /// @notice And the split changes only WHO is repaid, never how much: on the
    ///         failure path the two identities recover exactly what the single
    ///         identity would have, in the proportion each put in.
    function test_resolve_sybilSplitRecoversTheSameTotal() public {
        address sybil1 = makeAddr("sybil1");
        address sybil2 = makeAddr("sybil2");
        _fund(sybil1);
        _fund(sybil2);
        _setCoverage3(PROPOSAL, sybil1, 3_000e18, sybil2, 3_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);
        uint256 bond = game.challengeOf(id).bondWood;

        uint256 s1Before = wood.balanceOf(sybil1);
        uint256 s2Before = wood.balanceOf(sybil2);
        // Deliberately uneven, so an equal-split bug would be visible.
        vm.prank(sybil1);
        game.dispute(id, (bond * 25) / 100);
        vm.prank(sybil2);
        game.dispute(id, type(uint256).max);

        vm.warp(vm.getBlockTimestamp() + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        _claim(id, sybil1);
        _claim(id, sybil2);

        uint256 payout = bond - (bond * game.forfeitBurnBps()) / 10_000;
        uint256 s1Gain = wood.balanceOf(sybil1) - s1Before;
        uint256 s2Gain = wood.balanceOf(sybil2) - s2Before;
        assertEq(s1Gain, (payout * 25) / 100, "25% of the pool bought 25% of the distributed forfeit");
        // Within rounding: lazy shares floor independently, so the split can be
        // short by under one wei per identity. The POINT of this test is that
        // splitting identities buys no advantage, and that survives exactly —
        // the shortfall is dust and it costs the sybil, never the protocol.
        assertLe(s1Gain + s2Gain, payout, "identity-splitting never recovers MORE than the unburned forfeit");
        assertGt(s1Gain + s2Gain + 2, payout, "and recovers it to within rounding");
        assertNotEq(s1Gain, s2Gain, "and not by halves");
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The forfeit burn — pricing the self-challenge
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice THE ATTACK THE BURN EXISTS FOR. Keying the forfeit to contribution
    ///         killed free-riding and opened this: the challenger and the funder
    ///         of the counter-bond can be the SAME operator. It files against its
    ///         own executed proposal, funds the entire pool itself, waits out the
    ///         timeout and — under a pure pro-rata payout — recovers its
    ///         contribution plus 100% of its own forfeited bond. Net zero, while
    ///         every co-approver's coverage sat frozen for a month.
    ///
    ///         With the burn it ends DOWN by exactly `burnAmount`, and that
    ///         number is the price of the grief. Nothing else about its position
    ///         changed: it still got its bond and its contribution back.
    function test_selfChallenge_roundTripCostsExactlyTheBurn() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // guardianA is an approver here
        _execute(PROPOSAL);
        uint256 attackerBefore = wood.balanceOf(guardianA);

        // Step 1: the approver challenges its OWN proposal.
        vm.prank(guardianA);
        uint256 id =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);
        uint256 bond = game.challengeOf(id).bondWood;
        assertEq(game.challengeOf(id).challenger, guardianA, "challenger and accused are one address");

        // Step 2: and funds the whole counter-bond pool itself.
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
        assertEq(game.counterBondContributionOf(id, guardianA), bond, "100% of the pool");

        // Step 3: nobody rules, so it times out not guilty — the attacker's own
        //         forfeit comes back to the only contributor, which is itself.
        vm.warp(_filedAt(id) + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        uint256 burnAmount = (bond * game.forfeitBurnBps()) / 10_000;
        assertGt(burnAmount, 0, "a zero burn would leave the round trip free");
        assertEq(
            attackerBefore - wood.balanceOf(guardianA), burnAmount, "the round trip is DOWN by exactly the burn, not 0"
        );
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burnAmount, "and that is where the difference went");
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded");
        _assertLiveBondsBacked();
    }

    /// @notice AND A TWO-ADDRESS OPERATOR IS NO BETTER OFF, which is why a
    ///         `msg.sender != challenger` guard would have been theatre. The
    ///         filer and the funder are different addresses here — a sender check
    ///         passes — and the operator's COMBINED position still ends down by
    ///         exactly the burn.
    function test_selfChallenge_twoAddressOperatorPaysTheSameBurn() public {
        address filer = makeAddr("attackerFiler"); // the operator's second key
        _fund(filer);
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // guardianA is the funding half
        _execute(PROPOSAL);

        uint256 filerBefore = wood.balanceOf(filer);
        uint256 funderBefore = wood.balanceOf(guardianA);

        vm.prank(filer);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.ProposerLinkedOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        uint256 bond = game.challengeOf(id).bondWood;
        assertNotEq(game.challengeOf(id).challenger, guardianA, "a sender check would see two unrelated parties");

        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);

        vm.warp(_filedAt(id) + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        uint256 burnAmount = (bond * game.forfeitBurnBps()) / 10_000;
        uint256 combinedBefore = filerBefore + funderBefore;
        uint256 combinedAfter = wood.balanceOf(filer) + wood.balanceOf(guardianA);
        assertEq(combinedBefore - combinedAfter, burnAmount, "identity-splitting buys the griefer no discount");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burnAmount);
        _assertLiveBondsBacked();
    }

    /// @notice THE HONEST SIDE STILL PROFITS. A guardian that correctly beat a
    ///         bad-faith filing recovers its whole contribution plus 80% of the
    ///         forfeited bond. That is the number the ceiling on `forfeitBurnBps`
    ///         protects: if answering a challenge stopped paying, the counter-bond
    ///         would stop being funded and the burn would have cured the griefing
    ///         by killing the defence.
    function test_resolve_honestSoleDefenderKeepsEightyPercentOfTheForfeit() public {
        uint256 id = _fileStandard(PROPOSAL); // filed by `challenger`, not by an approver
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 aBefore = wood.balanceOf(guardianA);

        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
        assertEq(aBefore - wood.balanceOf(guardianA), bond, "the defender is out its whole stake while it waits");

        vm.warp(_filedAt(id) + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        uint256 gain = wood.balanceOf(guardianA) - aBefore;
        assertEq(gain, (bond * 8_000) / 10_000, "contribution back, plus 80% of the bond it defeated");
        assertGt(gain, 0, "defending a good-faith position must still pay");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), bond - gain, "the other 20% was destroyed, not withheld");
    }

    /// @notice THE ANTI-FREE-RIDE PROPERTY SURVIVES THE BURN. It is taken off the
    ///         TOP, before the pro-rata pass, so it changes the size of the pot
    ///         and nothing about its key: an accused approver that funded none of
    ///         the defence still collects exactly zero, and the whole distributed
    ///         forfeit lands on the one that paid.
    function test_resolve_burnDoesNotPayNonContributors() public {
        uint256 id = _fileStandard(PROPOSAL); // guardianA $6,000 / guardianB $4,000
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 bBefore = wood.balanceOf(guardianB);
        uint256 aBefore = wood.balanceOf(guardianA);

        vm.prank(guardianA);
        game.dispute(id, type(uint256).max); // guardianB sits it out entirely

        vm.warp(_filedAt(id) + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        assertEq(wood.balanceOf(guardianB), bBefore, "40% of the coverage, 0% of the defence, 0% of the forfeit");
        assertEq(game.counterBondContributionOf(id, guardianB), 0, "and it is the contribution that is zero");
        uint256 burnAmount = (bond * game.forfeitBurnBps()) / 10_000;
        assertEq(wood.balanceOf(guardianA) - aBefore, bond - burnAmount, "the funder takes all of what is distributed");
    }

    /// @notice WEI-EXACT: `burn + sum(distributed) == bond`, with three UNEQUAL
    ///         contributions, a bond that is not a round number, and a burn rate
    ///         chosen so BOTH divisions truncate. The burn is subtracted first
    ///         and the pro-rata pass is keyed to what is left, so the last
    ///         recipient must absorb the remainder of the PAYOUT — absorbing the
    ///         remainder of the bond instead would over-pay by exactly the burn.
    function test_resolve_burnPlusDistributedEqualsTheBondToTheWei() public {
        vm.prank(owner);
        game.setForfeitBurnBps(1_777); // deliberately not a divisor of anything here

        address sybil1 = makeAddr("sybil1");
        _fund(sybil1);
        // $10,000.000...027 of coverage → a bond that is not a round number.
        _setCoverage3(PROPOSAL, guardianA, 4_000e18 + 7, sybil1, 3_000e18 + 11, 3_000e18 + 9);
        _execute(PROPOSAL);
        vm.prank(challenger);
        uint256 id =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);
        uint256 bond = game.challengeOf(id).bondWood;
        assertEq(bond, 10_000e18 + 20, "an odd bond, so the rounding has somewhere to hide");
        assertTrue((bond * 1_777) % 10_000 != 0, "and the burn itself truncates");

        uint256 aBefore = wood.balanceOf(guardianA);
        uint256 sBefore = wood.balanceOf(sybil1);
        uint256 bBefore = wood.balanceOf(guardianB);

        // Three unequal, deliberately un-round contributions. guardianB takes the
        // clamped shortfall, so it is last in the list and absorbs the remainder.
        uint256 aPut = 1_234e18 + 7;
        uint256 sPut = 4_321e18 + 11;
        vm.prank(guardianA);
        game.dispute(id, aPut);
        vm.prank(sybil1);
        game.dispute(id, sPut);
        vm.prank(guardianB);
        game.dispute(id, type(uint256).max);
        uint256 bPut = bond - aPut - sPut;
        assertEq(game.counterBondContributionOf(id, guardianB), bPut, "the pool is exactly the bond");

        uint256 burnAmount = (bond * 1_777) / 10_000;
        uint256 payout = bond - burnAmount;
        // Every floor() is short of the total, so the remainder is real: a
        // distribution that ignored it would strand these wei in the contract.
        assertLt(
            (payout * aPut) / bond + (payout * sPut) / bond + (payout * bPut) / bond,
            payout,
            "flooring genuinely loses wei here"
        );

        vm.warp(_filedAt(id) + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        _claim(id, sybil1);

        uint256 aGain = wood.balanceOf(guardianA) - aBefore;
        uint256 sGain = wood.balanceOf(sybil1) - sBefore;
        uint256 bGain = wood.balanceOf(guardianB) - bBefore;

        // EVERY share floors independently now. The push version handed the last
        // recipient `payout - distributed` so the forfeit landed to the wei —
        // but that required the loop `claimContribution` exists to remove, so
        // the exactness was bought with the unbounded-list hazard. Each funder
        // now gets exactly its own floor, the last one included.
        assertEq(aGain, (payout * aPut) / bond, "pro-rata on the PAYOUT, not on the bond");
        assertEq(sGain, (payout * sPut) / bond);
        assertEq(bGain, (payout * bPut) / bond, "the last funder floors like everyone else");

        // WHAT REPLACES "to the wei": never over-paid, and short by less than one
        // wei per funder. That bound is the entire cost of dropping the loop.
        uint256 distributed = aGain + sGain + bGain;
        assertLe(distributed + burnAmount, bond, "the forfeit can never over-pay");
        assertGt(distributed + burnAmount + 3, bond, "and is short by under one wei per funder");

        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burnAmount, "the dead address got exactly the burn");

        // The dust is not lost track of — it stays counted in `unclaimedWood`,
        // which is why the custody invariant is `>=` and not `==`.
        uint256 dust = bond - distributed - burnAmount;
        assertEq(wood.balanceOf(address(game)), dust, "only the rounding dust is left behind");
        assertEq(game.unclaimedWood(), dust, "and it is still accounted, not silently stranded");
        assertEq(game.bondedWood(), 0, "no challenge is live");
        _assertLiveBondsBacked();
    }

    /// @notice `forfeitBurnBps == 0` reproduces the pre-burn behaviour exactly:
    ///         the whole forfeit reaches the funders and the dead address is
    ///         never touched. This is the off-switch, and it is why zero is a
    ///         legal setting here where it is not for `challengerBondBps`.
    function test_resolve_zeroBurnBpsDistributesTheWholeBond() public {
        vm.prank(owner);
        game.setForfeitBurnBps(0);

        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 aBefore = wood.balanceOf(guardianA);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);

        vm.warp(_filedAt(id) + game.disputeTimeout());
        game.resolve(id);
        _claimAll(id); // pull-payment: funders collect before balances are asserted

        assertEq(wood.balanceOf(guardianA) - aBefore, bond, "the entire forfeit, exactly as before the burn existed");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), 0, "and nothing was sent to the dead address at all");
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded");
        _assertLiveBondsBacked();
    }

    /// @notice The winning path is UNTOUCHED by the burn: a guilty ruling still
    ///         pays the challenger its bond back plus the whole pool. The burn
    ///         prices a round trip that only exists on the failure path, where
    ///         the forfeit flows back toward the side that posted it.
    function test_rule_guiltyPathBurnsNothing() public {
        uint256 id = _fileAndDispute();
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 pool = game.challengeOf(id).counterBondWood;
        uint256 challengerBefore = wood.balanceOf(challenger);

        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Guilty);

        assertEq(wood.balanceOf(challenger) - challengerBefore, bond + pool, "bond back plus the WHOLE pool");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), 0, "a settled challenge burns nothing");
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded");
    }

    // ── The parameter ──

    function test_forfeitBurnBps_defaultIsTwentyPercent() public view {
        assertEq(game.forfeitBurnBps(), 2_000);
        assertEq(game.BURN_ADDRESS(), 0x000000000000000000000000000000000000dEaD, "the conventional dead address");
    }

    function test_setForfeitBurnBps_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setForfeitBurnBps(1_000);
    }

    /// @notice Bounded [0, 5_000]. ZERO IS LEGAL — it is the off-switch, not a
    ///         broken state — and the ceiling keeps an honest defender's share
    ///         the larger one, which is what stops the cure for griefing from
    ///         killing the defence it is meant to protect.
    function test_setForfeitBurnBps_bounded() public {
        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setForfeitBurnBps(5_001); // more than half the forfeit destroyed
        game.setForfeitBurnBps(5_000); // the ceiling itself is allowed
        assertEq(game.forfeitBurnBps(), 5_000);
        game.setForfeitBurnBps(0); // and so is switching it off entirely
        assertEq(game.forfeitBurnBps(), 0);
        vm.stopPrank();
    }

    function test_setForfeitBurnBps_emits() public {
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ForfeitBurnBpsSet(2_000, 3_500);
        vm.prank(owner);
        game.setForfeitBurnBps(3_500);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task 3 — filings pause: the owner's ONLY lever over adjudication
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The pause gates `file` ALONE. In-flight challenges (already
    ///         filed or disputed before the pause) keep running end to end —
    ///         `dispute`, permissionless `resolve`, `rule` and claims all
    ///         still work — and unpausing restores filing.
    function test_setFilingsPaused_gatesFileOnly() public {
        uint256 id = _fileAndDispute(); // in-flight, already disputed, BEFORE the pause
        uint256 partialId = _fileStandard(4); // in-flight, still Filed, BEFORE the pause
        uint256 undisputed = _fileStandard(5); // in-flight, still Filed, BEFORE the pause

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.FilingsPausedSet(false, true);
        game.setFilingsPaused(true);
        assertTrue(game.filingsPaused());

        // New filings refused... (inlined from `_fileStandard`: `vm.expectRevert`
        // only arms the NEXT call, and the fixture makes several external calls
        // of its own before reaching `file`).
        _setCoverage(2, 6_000e18, 4_000e18);
        _execute(2);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.FilingsPaused.selector);
        game.file(address(gov), 2, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);

        // ...but every in-flight right still runs.

        // `dispute`, partially funding the pool — still runs while paused.
        vm.prank(guardianA);
        game.dispute(partialId, 1_000e18); // well short of the ~10_000e18 pool target
        assertEq(
            uint256(game.challengeOf(partialId).status),
            uint256(IChallengeGame.Status.Filed),
            "short of the pool target, but the contribution itself was not refused by the pause"
        );

        // Permissionless `resolve` — an undisputed challenge still auto-slashes
        // past its silence window while paused.
        vm.warp(_filedAt(undisputed) + game.autoSlashDelay());
        game.resolve(undisputed);
        assertEq(
            uint256(game.challengeOf(undisputed).status),
            uint256(IChallengeGame.Status.Settled),
            "the silence verdict still lands while paused"
        );

        // `rule` and claims.
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);
        vm.prank(guardianA);
        game.claimContribution(id);

        // And unpausing restores filing.
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.FilingsPausedSet(true, false);
        game.setFilingsPaused(false);
        assertFalse(game.filingsPaused());
        _fileStandard(3);
    }

    function test_setFilingsPaused_onlyOwner() public {
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, challenger));
        game.setFilingsPaused(true);
    }

    function test_setFilingsPaused_emits() public {
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.FilingsPausedSet(false, true);
        vm.prank(owner);
        game.setFilingsPaused(true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task 2 (court-incentives) — conviction bounty, pinned at filing,
    // paid ONLY on an escalated (Guilty-ruled) conviction
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A second proposal's silence-path challenge, escalated by guardianA
    ///      alone — the same shape as `_fileAndDispute`, just on proposal 2 so
    ///      it can run alongside a challenge already live on `PROPOSAL`.
    function _fileAndDisputeSecondProposal() internal returns (uint256 id) {
        id = _fileStandard(2);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);
    }

    /// @dev Two concurrent silence-path challenges against the SAME proposal,
    ///      by two different challengers — the exact fixture
    ///      `test_resolve_concurrentSettlesConvictOnlyOnce` already exercises,
    ///      just returning both ids so a caller can resolve them in order and
    ///      watch the second hit the `_convicted` short-circuit.
    function _twoConcurrentChallenges() internal returns (uint256 first, uint256 second) {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);

        vm.prank(challenger);
        first = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );

        address other = makeAddr("otherChallenger");
        wood.mint(other, 1_000_000e18);
        vm.startPrank(other);
        wood.approve(address(game), type(uint256).max);
        second = game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);
        vm.stopPrank();
    }

    /// @notice THE SLASH PAYS NO ONE. sWOOD is handed a case key, a basis and
    ///         the rates — and nothing else. There is no recipient argument to
    ///         misdirect and no bounty leg to divert, which is the whole point
    ///         of moving the prosecutor's fee onto the proposer's bond: the
    ///         slash pot is one a prosecutor can fund for itself by staking and
    ///         approving the proposal it is about to accuse.
    function test_slash_carriesNoPayoutRecipient() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        game.resolve(id);

        assertEq(swood.callCount(), 1, "the slash ran");
        // The mock records everything sWOOD is given. A recipient is not among
        // it, because the ABI no longer has one.
        assertEq(swood.lastCaseKey(), _reviewKeyFor(address(gov), PROPOSAL), "case key forwarded");
        assertGt(swood.lastApprovers().length, 0, "and the cohort");
    }

    /// @notice THE FEE IS PINNED AT FILING, like every other rate the challenge
    ///         is priced against — a live read would change what the challenger
    ///         stood to collect on a conviction it had already bonded against.
    function test_prosecutorFee_pinnedAtFiling() public {
        uint256 id = _fileStandard(PROPOSAL);
        assertEq(game.challengeOf(id).prosecutorFeeBpsAtFiling, 500, "pinned at the filing rate");

        vm.prank(owner);
        game.setProsecutorFeeBps(1_000);

        assertEq(game.challengeOf(id).prosecutorFeeBpsAtFiling, 500, "the open challenge keeps its rate");
        uint256 later = _fileStandard(2);
        assertEq(game.challengeOf(later).prosecutorFeeBpsAtFiling, 1_000, "a later filing takes the new one");
    }

    /// @notice The game's ceiling MIRRORS the escrow's; the escrow is the
    ///         authority. Pinned so the two cannot drift apart silently.
    function test_prosecutorFee_ceilingMirrorsTheEscrow() public view {
        assertEq(game.MAX_PROSECUTOR_FEE_BPS(), 2_000, "the game's convenience guard");
        assertLe(game.prosecutorFeeBps(), game.MAX_PROSECUTOR_FEE_BPS(), "the default sits under it");
    }

    function test_setProsecutorFeeBps_boundsAndOwner() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setProsecutorFeeBps(2_001); // above MAX_PROSECUTOR_FEE_BPS
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, challenger));
        game.setProsecutorFeeBps(100);
        vm.prank(owner);
        game.setProsecutorFeeBps(0); // zero is legal - bounty off
        assertEq(game.prosecutorFeeBps(), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Review PR #56 — cross-deployment verdict dedup (B1) and two-sided role
    // grants (M2). Both are WEDGES: states in which a live challenge has no
    // terminal exit at all, so every assertion below ends on the money.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A SECOND `ChallengeGame` against the SAME sWOOD and the SAME ledger —
    ///      the migration path this contract actually has, since it is not
    ///      upgradeable and every role it needs is re-pointable. Its `_convicted`
    ///      mapping starts empty; sWOOD's `_verdictSlashed`, keyed on
    ///      `(governor, proposalId)`, does not.
    function _redeployGame() internal returns (ChallengeGame v2) {
        v2 = new ChallengeGame(owner, address(wood), address(ledger), address(tiers));
        // Re-pointing the roles is exactly what a migration does.
        ledger.setCoverageFreezer(address(v2));
        swood.setAuthorizedSlasher(address(v2));
        vm.startPrank(owner);
        v2.setStakedWood(address(swood));
        v2.setCourt(court);
        vm.stopPrank();
    }

    /// @notice B1: A REDEPLOYED GAME MUST NOT ACCEPT A FILING IT COULD NEVER
    ///         TERMINATE. V1 convicts the cohort; V2 is deployed and wired; a
    ///         filing against the same proposal reaches V2 with `_convicted`
    ///         empty. Before the fix it was accepted, took the bond, froze the
    ///         coverage — and then `_settle`'s `slashToEscrow` reverted
    ///         `ApproverAlreadySlashed` forever, with `rule` unreachable from
    ///         `Filed`. The money assertions are the point: the bond is never
    ///         taken and the coverage is never re-frozen.
    function test_file_refusesWhenAnEarlierDeploymentAlreadyCollectedTheVerdict() public {
        // V1 collects the one liability.
        uint256 v1Id = _fileStandard(PROPOSAL);
        vm.warp(_filedAt(v1Id) + game.autoSlashDelay());
        game.resolve(v1Id);
        assertEq(swood.callCount(), 1, "fixture: V1 really slashed");
        assertTrue(swood.verdictSlashed(_reviewKeyFor(address(gov), PROPOSAL), guardianA), "sWOOD marked the cohort");

        ChallengeGame v2 = _redeployGame();
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "fixture: V1 released its freeze");

        address filer = makeAddr("v2filer");
        wood.mint(filer, 1_000_000e18);
        vm.prank(filer);
        wood.approve(address(v2), type(uint256).max);

        uint256 filerBefore = wood.balanceOf(filer);
        vm.prank(filer);
        vm.expectRevert(IChallengeGame.AlreadyConvicted.selector);
        v2.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);

        assertEq(wood.balanceOf(filer), filerBefore, "no bond taken by a filing that could never convict");
        assertEq(wood.balanceOf(address(v2)), 0, "V2 custodies nothing");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage not re-frozen");
        assertEq(v2.liveChallengeCountOf(address(gov), PROPOSAL), 0, "no live challenge pinning the freeze");
    }

    /// @notice B1: A PARTIAL PRIOR SLASH IS ENOUGH. The norm is a partialPool
    ///         conviction — the approvers keep live stake, so nothing about the
    ///         cohort's later state advertises that its liability is spent.
    ///         `slashToEscrow` reverts if ANY member of the array it is handed is
    ///         already marked, so one marked approver out of two must refuse the
    ///         filing, not one out of one.
    function test_file_refusesWhenOnlyOneAccusedApproverWasPreviouslySlashed() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        // Exactly what a previous deployment's partialPool verdict leaves behind.
        swood.setVerdictSlashed(_reviewKeyFor(address(gov), PROPOSAL), guardianB, true);

        uint256 before = wood.balanceOf(challenger);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.AlreadyConvicted.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);
        assertEq(wood.balanceOf(challenger), before, "bond untouched");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage untouched");
    }

    /// @notice B1, THE OTHER HALF: `file`'s gate reads the slasher wired AT
    ///         FILING TIME, so it cannot be the only defence — sWOOD can be
    ///         re-pointed (or the prior deployment can settle a concurrent
    ///         challenge) after a perfectly legal filing. `_settle` must then
    ///         DIVERT into `VerdictAlreadyCollected` rather than revert.
    ///
    ///         THE MONEY IS THE ASSERTION: the challenge reaches `Settled`, the
    ///         challenger is refunded all but the pinned `settleBurnBps`, the
    ///         part-funded pool is claimable back to its contributor, and the
    ///         coverage genuinely unfreezes — proven through a real
    ///         `releaseApproval`, not a flag.
    function test_settle_divertsWhenTheVerdictWasCollectedAfterFiling() public {
        uint256 id = _fileStandard(PROPOSAL);
        IChallengeGame.Challenge memory filed = game.challengeOf(id);
        uint256 bond = filed.bondWood;

        // A PART-FUNDED defence: `Filed` is preserved, and its contributor must
        // still get its stake back on the diverted settle.
        uint256 partialPool = bond / 4;
        vm.prank(guardianB);
        game.dispute(id, partialPool);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Filed), "still Filed");

        // The liability is collected out from under the live challenge — the
        // shape a prior deployment settling concurrently leaves behind.
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        swood.setVerdictSlashed(key, guardianA, true);
        swood.setVerdictSlashed(key, guardianB, true);

        uint256 challengerBefore = wood.balanceOf(challenger);
        uint256 guardianBefore = wood.balanceOf(guardianB);
        uint256 slashesBefore = swood.callCount();

        vm.warp(_filedAt(id) + game.autoSlashDelay());
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.VerdictAlreadyCollected(id, address(gov), PROPOSAL);
        game.resolve(id); // must NOT revert `ApproverAlreadySlashed`

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled), "terminal");
        assertEq(swood.callCount(), slashesBefore, "no second slash attempted");

        // The bond comes back, less the pinned settle burn — the ordinary
        // undisputed-settle payout, not a stranded balance.
        uint256 burned = (bond * filed.settleBurnBpsAtFiling) / 10_000;
        assertEq(wood.balanceOf(challenger) - challengerBefore, bond - burned, "challenger refunded");

        // The part-funded pool is claimable, which `ChallengeNotTerminal` made
        // impossible for the whole life of the wedge.
        assertEq(game.claimableContribution(id, guardianB), partialPool, "pool owed back");
        vm.prank(guardianB);
        game.claimContribution(id);
        assertEq(wood.balanceOf(guardianB) - guardianBefore, partialPool, "pool returned");

        // And the freeze is genuinely gone.
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "unfrozen");
        ledger.releaseApproval(address(gov), PROPOSAL, guardianA);
        _assertLiveBondsBacked();
    }

    /// @notice A DIVERTED SETTLE MUST NOT SPEND THE DEMOTER ROLE. The
    ///         `VerdictAlreadyCollected` branch adjudicates nothing — it
    ///         slashes no one and forfeits no bond — so it has no conviction to
    ///         carry a consequence for. The demotion used to sit AFTER the
    ///         if/else and therefore fired on this branch too.
    ///
    ///         That was cheap to farm. Concurrency is unguarded by design:
    ///         `_liveByChallenger` is keyed per challenger, `_convicted` is
    ///         false for every filing made before the first settle, and
    ///         `_liveCount` is uncapped. File N challenges from N addresses
    ///         naming N different certified adapters the proposal touched, let
    ///         the first collect the liability, and the remaining N-1 divert
    ///         here while still revoking a certification apiece — for
    ///         `settleBurnBps` of a bond that is itself `challengerBondBps` of
    ///         coverage, roughly 1% of the proposal's coverage per adapter.
    function test_settle_divertedVerdictDoesNotDemoteTheAdapter() public {
        uint256 id = _fileStandard(PROPOSAL);
        assertTrue(game.challengeOf(id).adapterTarget != address(0), "fixture: the filing named an adapter");

        // Collect the liability out from under the live challenge, so the
        // settle takes the diverted branch.
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        swood.setVerdictSlashed(key, guardianA, true);
        swood.setVerdictSlashed(key, guardianB, true);

        uint256 demotesBefore = tiers.demoteCount();

        vm.warp(_filedAt(id) + game.autoSlashDelay());
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.VerdictAlreadyCollected(id, address(gov), PROPOSAL);
        game.resolve(id);

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled), "still terminal");
        assertEq(tiers.demoteCount(), demotesBefore, "a settle that collected nothing must revoke nothing");
    }

    /// @notice ...and the collecting settle still DOES demote, so the fix
    ///         narrowed the branch rather than disabling the consequence.
    function test_settle_collectingVerdictStillDemotesTheAdapter() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 demotesBefore = tiers.demoteCount();

        vm.warp(_filedAt(id) + game.autoSlashDelay());
        game.resolve(id);

        assertEq(tiers.demoteCount(), demotesBefore + 1, "a real conviction still demotes the named adapter");
    }

    /// @notice B1 END TO END ON THE REDEPLOY ITSELF: a V2 filing that was legal
    ///         when made (nothing collected yet) but whose liability V1 collects
    ///         while it is live. This is the case `file`'s gate structurally
    ///         cannot catch, and it must still terminate with the money back.
    function test_redeployedGame_liveChallengeStillTerminatesWhenV1CollectsFirst() public {
        // Two live filings against the same proposal, one per deployment.
        uint256 v1Id = _fileStandard(PROPOSAL);

        ChallengeGame v2 = _redeployGame();
        address filer = makeAddr("v2filer");
        wood.mint(filer, 1_000_000e18);
        vm.startPrank(filer);
        wood.approve(address(v2), type(uint256).max);
        uint256 v2Id =
            v2.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);
        vm.stopPrank();
        IChallengeGame.Challenge memory v2c = v2.challengeOf(v2Id);
        assertGt(v2c.bondWood, 0, "fixture: V2 took a bond");

        // V1 settles first and collects the one liability.
        vm.warp(_filedAt(v1Id) + game.autoSlashDelay());
        game.resolve(v1Id);

        uint256 filerBefore = wood.balanceOf(filer);
        vm.warp(v2.challengeOf(v2Id).filedAt + v2.autoSlashDelay());
        v2.resolve(v2Id); // pre-fix: reverts `ApproverAlreadySlashed`, forever

        assertEq(uint8(v2.challengeOf(v2Id).status), uint8(IChallengeGame.Status.Settled), "V2 terminal");
        uint256 burned = (v2c.bondWood * v2c.settleBurnBpsAtFiling) / 10_000;
        assertEq(wood.balanceOf(filer) - filerBefore, v2c.bondWood - burned, "V2 bond refunded");
        assertEq(v2.liveChallengeCountOf(address(gov), PROPOSAL), 0, "V2 released its refcount");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage released");
        ledger.releaseApproval(address(gov), PROPOSAL, guardianA);
    }

    /// @notice M2: RE-POINTING THE LEDGER MID-CHALLENGE IS REFUSED. A fresh
    ///         ledger's `coverageFreezer` is the zero address, so every terminal
    ///         path of the live challenge would have gone into
    ///         `NotCoverageFreezer` — bond and pool stranded, the OLD ledger
    ///         frozen forever with its own `setCoverageFreezer` bricked by
    ///         `CoverageFrozen`. The setter refuses, and the live challenge
    ///         still terminates with the money back.
    function test_setExposureLedger_refusesALedgerThatHasNotNamedThisGame() public {
        uint256 id = _fileStandard(PROPOSAL);
        assertTrue(ledger.isCoverageFrozen(address(gov), PROPOSAL), "fixture: live freeze");

        MockChallengeLedger fresh = new MockChallengeLedger(0.05e8);
        fresh.setChallengeWindow(30 days); // window bound satisfied: isolate the role check
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.RoleNotGranted.selector);
        game.setExposureLedger(address(fresh));
        assertEq(address(game.exposureLedger()), address(ledger), "ledger unchanged");

        // The live challenge is untouched and still reaches a terminal state.
        uint256 challengerBefore = wood.balanceOf(challenger);
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        vm.warp(_filedAt(id) + game.autoSlashDelay());
        game.resolve(id);
        uint256 burned = (c.bondWood * c.settleBurnBpsAtFiling) / 10_000;
        assertEq(wood.balanceOf(challenger) - challengerBefore, c.bondWood - burned, "bond home");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "unfrozen on the ledger that froze it");
    }

    /// @notice M2, the other side: a CORRECTLY wired re-point still succeeds. The
    ///         guard enforces an order, not a prohibition — grant the role on the
    ///         new ledger first, exactly as `DeployPlanD` does.
    function test_setExposureLedger_acceptsACorrectlyWiredRePoint() public {
        MockChallengeLedger fresh = new MockChallengeLedger(0.05e8);
        fresh.setChallengeWindow(30 days);
        fresh.setCoverageFreezer(address(game));
        vm.prank(owner);
        game.setExposureLedger(address(fresh));
        assertEq(address(game.exposureLedger()), address(fresh), "re-pointed");

        // And the new ledger is genuinely usable: a filing freezes on IT.
        address[] memory guardians = new address[](2);
        uint256[] memory usd = new uint256[](2);
        guardians[0] = guardianA;
        guardians[1] = guardianB;
        usd[0] = 6_000e18;
        usd[1] = 4_000e18;
        fresh.setApprovers(address(gov), 7, guardians, usd);
        _execute(7);
        vm.prank(challenger);
        uint256 id = game.file(address(gov), 7, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);
        assertTrue(fresh.isCoverageFrozen(address(gov), 7), "new ledger froze");
        vm.warp(_filedAt(id) + game.autoSlashDelay());
        game.resolve(id);
        assertFalse(fresh.isCoverageFrozen(address(gov), 7), "new ledger unfroze");
    }

    /// @notice M2 mirrored onto the slasher: a sWOOD that has not named this game
    ///         `authorizedSlasher` would reject every `_settle`, which is the same
    ///         wedge from the other rail.
    function test_setStakedWood_refusesASlasherThatHasNotNamedThisGame() public {
        MockChallengeStakedWood ungranted = new MockChallengeStakedWood();
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.RoleNotGranted.selector);
        game.setStakedWood(address(ungranted));
        assertEq(address(game.stakedWood()), address(swood), "slasher unchanged");

        ungranted.setAuthorizedSlasher(address(game));
        vm.prank(owner);
        game.setStakedWood(address(ungranted));
        assertEq(address(game.stakedWood()), address(ungranted), "granted re-point succeeds");
    }

    /// @notice The constructor's own copy of the window bound — the third door
    ///         onto the same mismatch, and the one no setter could ever catch
    ///         because a deployment need never call one.
    function test_constructor_rejectsALedgerWhoseWindowIsBelowTheDefault() public {
        MockChallengeLedger tooSmall = new MockChallengeLedger(0.05e8);
        tooSmall.setChallengeWindow(7 days); // below the 14-day default
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        new ChallengeGame(owner, address(wood), address(tooSmall), address(tiers));

        // Exactly at the default is legal — the bound is `>`, not `>=`.
        MockChallengeLedger exact = new MockChallengeLedger(0.05e8);
        exact.setChallengeWindow(14 days);
        ChallengeGame ok = new ChallengeGame(owner, address(wood), address(exact), address(tiers));
        assertEq(ok.challengeWindow(), 14 days);
    }

    /// @notice `renounceOwnership` is disabled: `setStakedWood` is the documented
    ///         un-wedge and `setCourt(0)` the documented off-switch, and both are
    ///         owner-only with no permissionless equivalent.
    function test_renounceOwnership_isDisabled() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.RenounceDisabled.selector);
        game.renounceOwnership();
        assertEq(game.owner(), owner, "still owned");

        // A non-owner is still rejected on ownership, not on the new error.
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, challenger));
        game.renounceOwnership();

        // Handing ownership over is untouched — only abandoning it is refused.
        address successor = makeAddr("successor");
        vm.prank(owner);
        game.transferOwnership(successor);
        vm.prank(successor);
        game.acceptOwnership();
        assertEq(game.owner(), successor, "transfer still works");
    }
}
