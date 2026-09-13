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
    mapping(uint256 proposalId => BatchExecutorLib.Call[]) internal _settlementCalls;

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

    function setSettlementCall(uint256 proposalId, address target, bytes4 selector) external {
        delete _settlementCalls[proposalId];
        _settlementCalls[proposalId].push(
            BatchExecutorLib.Call({target: target, data: abi.encodePacked(selector), value: 0})
        );
    }

    function getSettlementCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory) {
        return _settlementCalls[proposalId];
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
    /// @dev The PLEDGE. In the real ledger this and `_committed` are now ONE
    ///      lock (declared coverage locks collapsed booking and pledge and
    ///      deleted `settleCoverage`). The mock keeps them separate so the
    ///      tests that pin WHICH selector `ChallengeGame` reads (`pledgedOf`,
    ///      pashov #24) can still drive the two apart: a game that ever went
    ///      back to `approversOf` would be caught here, not on chain.
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

    /// @dev Rewrites the mock's BOOKING only, leaving the pledge alone — the
    ///      divergence the real ledger's since-deleted `settleCoverage` used to
    ///      produce. Retained purely as the lever that proves the game reads
    ///      `pledgedOf` (see `_pledged` above).
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

    function freezeCoverage(address governor, uint256 proposalId, uint256) external {
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

    /// @dev `ChallengeGame.file`'s ACTUAL bond-sizing basis (Pashov re-audit
    ///      of #158, finding 3): the real ledger's `unsharedLiabilityUsd` is a
    ///      separate function from `liabilityUsd` precisely so the challenger
    ///      bond does not shrink under `liabilityUsd`'s cross-proposal
    ///      sharing. This mock mirrors that split with its own independent
    ///      default/override pair, so a test that calls `setLiabilityUsd`
    ///      alone (exercising some OTHER consumer of `liabilityUsd`) does not
    ///      silently also move the bond `file()` charges, and vice versa.
    ///      DEFAULTS identically to `liabilityUsd` above — the sum of
    ///      reservations — so a suite that never calls either setter sees the
    ///      same bond sizing regardless of which function `file()` calls.
    mapping(bytes32 reviewKey => uint256) internal _unsharedLiabilityUsd;
    mapping(bytes32 reviewKey => bool) internal _unsharedLiabilitySet;

    function setUnsharedLiabilityUsd(address governor, uint256 proposalId, uint256 usd) external {
        bytes32 k = _key(governor, proposalId);
        _unsharedLiabilityUsd[k] = usd;
        _unsharedLiabilitySet[k] = true;
    }

    /// @dev Under declared coverage locks the real ledger returns
    ///      `min(needUsd, sum of min(lock_i, basis_i) x price)` and `file()`
    ///      trusts that figure outright (the game's own uncapped fallback is
    ///      gone). The override therefore plays the NEED: a value below the
    ///      cohort sum is what is takeable, a value above it is capped by the
    ///      cohort exactly as the ledger caps it, so the test that pins "never
    ///      inflated by the need" exercises the contract the game relies on.
    function unsharedLiabilityUsd(address governor, uint256 proposalId) external view returns (uint256) {
        bytes32 k = _key(governor, proposalId);
        address[] storage list = _approvers[k];
        uint256 total;
        for (uint256 i = 0; i < list.length; i++) {
            total += _committed[k][list[i]];
        }
        if (_unsharedLiabilitySet[k] && _unsharedLiabilityUsd[k] < total) return _unsharedLiabilityUsd[k];
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

    /// @dev The electorate the challenge vote reads. Held flat rather than
    ///      time-keyed: no test in this suite moves a guardian's stake between
    ///      a filing and its vote, so one value answers every lookup and the
    ///      timestamp argument is deliberately ignored.
    mapping(address guardian => uint256) internal _stake;
    mapping(address guardian => bool) internal _active;
    uint256 internal _totalVotes;

    function setStake(address guardian, uint256 amount) external {
        _totalVotes = _totalVotes + amount - _stake[guardian];
        _stake[guardian] = amount;
        _active[guardian] = amount != 0;
    }

    function stakeOf(address guardian) external view returns (uint256) {
        return _stake[guardian];
    }

    function getPastStake(address guardian, uint256) external view returns (uint256) {
        return _stake[guardian];
    }

    function getPastTotalVotes(uint256) external view returns (uint256) {
        return _totalVotes;
    }

    function isActiveGuardian(address guardian) external view returns (bool) {
        return _active[guardian];
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
            // The stake really falls, so a test can assert the slash landed on
            // the accused rather than merely that the mock was called.
            uint256 taken = (_stake[approvers[i]] * slashBpsPer[i]) / 10_000;
            _stake[approvers[i]] -= taken;
            _totalVotes -= taken;
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
    /// @dev The guardian that never covers a proposal in this suite, and so is
    ///      the only address the challenge vote will accept. `guardianA` and
    ///      `guardianB` are the accused cohort everywhere here.
    address internal nonApproverGuardian = makeAddr("nonApproverGuardian");
    address internal proposer = makeAddr("proposer");
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
        // Every proposal touches the adapter these tests accuse, so the 🟠F4
        // membership test passes by default; the mismatch cases override it.
        gov.setDefaultCall(ADAPTER, SELECTOR);
        ledger = new MockChallengeLedger(0.05e8); // $0.05, the governance haircut price
        tiers = new MockChallengeTierRegistry();
        swood = new MockChallengeStakedWood();
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tiers));
        // BOTH HALVES OF BOTH GRANTS, IN THE ORDER `DeployPlanD` uses (review PR
        // #56 M2): the target contract names the game FIRST, then the game is
        // pointed at it. `setStakedWood` below now enforces that order.
        ledger.setCoverageFreezer(address(game));
        swood.setAuthorizedSlasher(address(game));
        vm.prank(owner);
        game.setStakedWood(address(swood));

        // The electorate. Only `nonApproverGuardian` is outside the accused
        // cohort, so it alone carries votable weight — and alone it is the
        // whole of it, which is what lets one vote reach the quorum.
        swood.setStake(guardianA, 300_000e18);
        swood.setStake(guardianB, 200_000e18);
        swood.setStake(nonApproverGuardian, 100_000e18);

        wood.mint(challenger, 10_000_000e18);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);
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

    /// @dev Reaches the convict quorum from the one guardian the filing does
    ///      not accuse. A settle needs it: silence at the deadline fails.
    function _convict(uint256 challengeId) internal {
        vm.prank(nonApproverGuardian);
        game.voteOnChallenge(challengeId, true);
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

    /// @dev Mirrors `ChallengeGame.file`'s bond formula exactly, including its
    ///      integer-division order, and reads `challengerBondBps` LIVE off the
    ///      contract rather than hardcoding it — audit #181 finding 18a moved
    ///      it from 500 to 150, and a future parameter change should not have
    ///      to touch every fixture built on top of this.
    function _expectedBondWood(uint256 coverageUsd, uint256 priceX8) internal view returns (uint256) {
        return (((coverageUsd * game.challengerBondBps()) / 10_000) * 1e8) / priceX8;
    }

    /// @dev The bond `_fileStandard` produces: $10,000 of coverage at the
    ///      governance haircut price wired in `setUp` (0.05e8).
    function _standardBondWood() internal view returns (uint256) {
        return _expectedBondWood(10_000e18, 0.05e8);
    }

    // ── Filing ──

    /// @notice D4: with no proof required, the bond is the ONLY thing deterring
    ///         a frivolous filing, so it must scale with the exposure it freezes.
    ///         $10,000 x `challengerBondBps` at $0.05/WOOD.
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
        assertEq(
            smallBond,
            ((10_000e18 * game.challengerBondBps()) / 10_000) * 1e8 / 0.05e8,
            "coverageUsd * challengerBondBps at 0.05 USD/WOOD"
        );
        assertEq(smallBond, _standardBondWood());
        assertEq(bigBond, _expectedBondWood(20_000e18, 0.05e8));
        assertEq(bigBond, 2 * smallBond, "twice the frozen exposure, twice the bond");
        assertEq(wood.balanceOf(address(game)), smallBond + bigBond, "both bonds custodied");
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
        _convict(a);
        _convict(b);

        vm.warp(_filedAt(b) + game.voteWindow());
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

        // `challengerBondBps` of $10,000, converted at the composed $0.04
        // rather than the raw $0.05 — a stale-high scalar would under-charge
        // by exactly the same 20% either way. The bond DIVIDES by the price,
        // so the composed (lower) price yields the LARGER WOOD amount.
        assertEq(
            game.challengeOf(id).bondWood,
            _expectedBondWood(10_000e18, 0.04e8),
            "bond divides by the composed price, not the raw scalar"
        );
        assertEq(game.challengeOf(id).bondWood, (_standardBondWood() * 5) / 4, "20% under-charge at the raw scalar");
    }

    function test_file_bondIsSizedOnLiabilityNotReservations() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // reservations sum to $10,000
        // `file()` reads `unsharedLiabilityUsd`, not `liabilityUsd` (Pashov
        // re-audit of #158, finding 3) — see the mock's own note on the two
        // functions' independent defaults/overrides.
        ledger.setUnsharedLiabilityUsd(address(gov), PROPOSAL, 8_000e18); // but only $8,000 is takeable
        _execute(PROPOSAL);

        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );

        // `challengerBondBps` of $8,000 at $0.05/WOOD. Against the
        // reservations it would have been the $10,000 figure instead — a 25%
        // over-charge on this cohort alone.
        assertEq(
            game.challengeOf(id).bondWood,
            _expectedBondWood(8_000e18, 0.05e8),
            "the bond follows the liability, not the reservations"
        );
        assertEq(game.challengeOf(id).frozenCoverageUsd, 8_000e18, "and the recorded coverage is the liability too");
    }

    /// @notice The cap only ever REDUCES. An under-covered cohort — whose
    ///         reservations fall short of the proposal's need — is still priced
    ///         on what it actually pledged, because that is all a conviction
    ///         could take from it.
    function test_file_bondUsesReservationsWhenTheyAreTheSmallerFigure() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // reservations sum to $10,000
        // `file()` reads `unsharedLiabilityUsd`, not `liabilityUsd` — see the
        // note on `test_file_bondIsSizedOnLiabilityNotReservations`. The cap at
        // the cohort lives in the ledger now (declared coverage locks); the mock
        // mirrors it, and this test pins that the game passes the capped figure
        // through rather than re-deriving anything from the need.
        ledger.setUnsharedLiabilityUsd(address(gov), PROPOSAL, 25_000e18); // a larger need
        _execute(PROPOSAL);

        vm.prank(challenger);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );

        assertEq(game.challengeOf(id).bondWood, _standardBondWood(), "capped by the cohort, never inflated by the need");
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
            assertEq(c.bondWood, _standardBondWood(), "identical bond regardless of predicate");
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

    // ── Parameters ──

    function test_setters_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setVoteWindow(3 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setStakedWood(makeAddr("rogue"));
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

    /// @notice §3.4: filing pulls the bond, pins the accused coverage, and lands
    ///         the challenge in `Filed` awaiting its verdict.
    function test_file_pullsBondFreezesCoverageAndRecords() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // $10,000 committed
        _execute(PROPOSAL);

        uint256 challengerBefore = wood.balanceOf(challenger);
        uint256 expectedBond = _standardBondWood();

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeFiled(
            1, address(gov), PROPOSAL, challenger, IChallengeGame.Predicate.OutOfAdapterOutflow, expectedBond, EVIDENCE
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
        assertEq(c.bondWood, expectedBond);
        assertEq(uint8(c.predicate), uint8(IChallengeGame.Predicate.OutOfAdapterOutflow));
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Filed));
        assertEq(c.filedAt, vm.getBlockTimestamp());
        assertEq(c.frozenCoverageUsd, 10_000e18);

        assertTrue(ledger.isCoverageFrozen(address(gov), PROPOSAL), "coverage pinned by the live challenge");
        assertEq(game.liveChallengeOf(address(gov), PROPOSAL), id);

        assertEq(wood.balanceOf(address(game)), expectedBond, "bond custodied by the game");
        assertEq(challengerBefore - wood.balanceOf(challenger), expectedBond, "bond pulled from the challenger");
    }

    /// @notice The freeze exists only while the challenge is live. Once it
    ///         terminates the guardian can genuinely recycle its budget again —
    ///         asserted through a real `releaseApproval`, not a flag.
    function test_resolve_unfreezesAndReleaseWorksAgain() public {
        uint256 settled = _fileStandard(PROPOSAL);
        vm.expectRevert(MockChallengeLedger.CoverageFrozen.selector);
        ledger.releaseApproval(address(gov), PROPOSAL, guardianA);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(settled);
        ledger.releaseApproval(address(gov), PROPOSAL, guardianA);
    }

    /// @notice The pause gates `file` ALONE. A challenge filed before the pause
    ///         still resolves end to end while it is on, and unpausing restores
    ///         filing.
    function test_setFilingsPaused_gatesFileOnly() public {
        uint256 undisputed = _fileStandard(5); // in-flight, BEFORE the pause
        _convict(undisputed);

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

        // ...but the permissionless `resolve` still runs.
        vm.warp(_filedAt(undisputed) + game.voteWindow());
        game.resolve(undisputed);
        assertEq(
            uint256(game.challengeOf(undisputed).status),
            uint256(IChallengeGame.Status.Settled),
            "the verdict still lands while paused"
        );

        // And unpausing restores filing.
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.FilingsPausedSet(true, false);
        game.setFilingsPaused(false);
        assertFalse(game.filingsPaused());
        _fileStandard(3);
    }

    /// @notice 🔵F15: THE BURN RATES ARE PINNED AT FILING, like the clock. The
    ///         challenger relies on `settleBurnBps` when it decides to file and
    ///         cannot withdraw, so a mid-window raise from 0 to 5,000 would take
    ///         half the refund of a filing that turned out to be correct.
    function test_resolve_settleBurnIsPinnedAtFiling() public {
        vm.prank(owner);
        game.setSettleBurnBps(0); // filed under a full-refund regime
        uint256 id = _fileStandard(PROPOSAL);
        _convict(id);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 before = wood.balanceOf(challenger);

        vm.prank(owner);
        game.setSettleBurnBps(5_000); // governance changes its mind mid-window

        vm.warp(_filedAt(id) + game.voteWindow());
        game.resolve(id);

        assertEq(wood.balanceOf(challenger) - before, bond, "refunded at the rate it filed under, not the new one");
    }

    /// @notice 🟠F4: governance can retire the burn without an upgrade, and a
    ///         zero burn refunds the whole bond.
    function test_setSettleBurnBps_boundedAndZeroRestoresTheFullRefund() public {
        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setSettleBurnBps(5_001);
        game.setSettleBurnBps(0);
        vm.stopPrank();

        uint256 id = _fileStandard(PROPOSAL);
        _convict(id);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 before = wood.balanceOf(challenger);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);
        assertEq(wood.balanceOf(challenger) - before, bond, "zero burn: the whole bond comes back");
    }

    /// @notice 🔴F3, the squat itself: the accused cohort files to block the
    ///         slot, and it no longer blocks anything. The freeze is refcounted,
    ///         so the squatter's own resolution does not release coverage the
    ///         honest challenge is still pinning.
    function test_file_aSquattedSlotNoLongerDeniesTheHonestChallenge() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);

        // The cohort's sybil files: under a per-PROPOSAL slot this pinned the
        // only one for the whole window.
        address sybil = makeAddr("sybil");
        wood.mint(sybil, 1_000_000e18);
        vm.startPrank(sybil);
        wood.approve(address(game), type(uint256).max);
        uint256 squat =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);
        vm.stopPrank();
        _convict(squat);

        // Deep into the window, the honest challenger still files.
        vm.warp(vm.getBlockTimestamp() + 13 days);
        vm.prank(challenger);
        uint256 honest = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        assertEq(game.liveChallengeCountOf(address(gov), PROPOSAL), 2);
        _convict(honest);

        // The squat resolves first and takes nothing with it: coverage stays
        // frozen for the honest filing behind it.
        vm.warp(_filedAt(squat) + game.voteWindow());
        game.resolve(squat);
        assertTrue(ledger.isCoverageFrozen(address(gov), PROPOSAL), "the honest challenge still pins the coverage");
        assertEq(game.liveChallengeCountOf(address(gov), PROPOSAL), 1);

        // And the honest challenge still terminates, unfreezing on the way out.
        vm.warp(_filedAt(honest) + game.voteWindow());
        game.resolve(honest);
        assertEq(uint8(game.challengeOf(honest).status), uint8(IChallengeGame.Status.Settled));
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "last one out unfreezes");
    }

    /// @notice Spec §4 requires an invariant + fuzz per accounting path. The
    ///         game's WOOD custody must equal the bonds of the challenges still
    ///         live, at EVERY point — across fuzzed bond sizes and an arbitrary
    ///         resolution order.
    function testFuzz_woodBalanceEqualsLiveBonds(uint96[3] memory coverage, uint8 orderSeed) public {
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

        vm.warp(vm.getBlockTimestamp() + game.voteWindow());

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
        assertEq(game.bondedWood(), 0, "no live challenge, nothing bonded");
    }

    /// @notice B1, THE OTHER HALF: `file`'s gate reads the slasher wired AT
    ///         FILING TIME, so it cannot be the only defence — sWOOD can be
    ///         re-pointed (or the prior deployment can settle a concurrent
    ///         challenge) after a perfectly legal filing. `_settle` must then
    ///         DIVERT into `VerdictAlreadyCollected` rather than revert.
    ///
    ///         THE MONEY IS THE ASSERTION: the challenge reaches `Settled`, the
    ///         challenger is refunded all but the pinned `settleBurnBps`, and
    ///         the coverage genuinely unfreezes — proven through a real
    ///         `releaseApproval`, not a flag.
    function test_settle_divertsWhenTheVerdictWasCollectedAfterFiling() public {
        uint256 id = _fileStandard(PROPOSAL);
        _convict(id);
        IChallengeGame.Challenge memory filed = game.challengeOf(id);
        uint256 bond = filed.bondWood;

        // The liability is collected out from under the live challenge — the
        // shape a prior deployment settling concurrently leaves behind.
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        swood.setVerdictSlashed(key, guardianA, true);
        swood.setVerdictSlashed(key, guardianB, true);

        uint256 challengerBefore = wood.balanceOf(challenger);
        uint256 slashesBefore = swood.callCount();

        vm.warp(_filedAt(id) + game.voteWindow());
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.VerdictAlreadyCollected(id, address(gov), PROPOSAL);
        game.resolve(id); // must NOT revert `ApproverAlreadySlashed`

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled), "terminal");
        assertEq(swood.callCount(), slashesBefore, "no second slash attempted");

        uint256 burned = (bond * filed.settleBurnBpsAtFiling) / 10_000;
        assertEq(wood.balanceOf(challenger) - challengerBefore, bond - burned, "challenger refunded");

        // And the freeze is genuinely gone.
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "unfrozen");
        ledger.releaseApproval(address(gov), PROPOSAL, guardianA);
        _assertLiveBondsBacked();
    }

    /// @dev The §4 invariant, asserted point-by-point. `bondedWood` means
    ///      exactly the bonds of the LIVE challenges, and custody must cover it.
    function _assertLiveBondsBacked() internal view {
        uint256 n = game.challengeCount();
        uint256 live;
        for (uint256 i = 1; i <= n; i++) {
            IChallengeGame.Challenge memory c = game.challengeOf(i);
            if (c.status != IChallengeGame.Status.Filed) continue;
            live += c.bondWood;
        }
        assertEq(game.bondedWood(), live, "accounted bonds != live bonds");
        assertGe(wood.balanceOf(address(game)), game.bondedWood(), "custody < accounted obligations");
    }

    /// @notice §3.4 + D1: nobody contested within `voteWindow`, so the
    ///         silence IS the adjudication. The accused are slashed into the
    ///         compensation escrow as a case pinned to the block before the
    ///         challenged proposal executed (D6), the named adapter is demoted,
    ///         and the challenger gets its bond back.
    function test_resolve_undisputedSlashesDemotesAndReturnsBond() public {
        uint256 id = _fileStandard(PROPOSAL);
        _convict(id);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 executedAt = _executedAt(PROPOSAL);
        uint256 filedAt = _filedAt(id);
        assertEq(filedAt, executedAt + 3 days, "the filing trails execution, so the two are distinguishable");
        uint256 challengerBefore = wood.balanceOf(challenger);

        swood.setNextResult(9_999e18);
        vm.warp(filedAt + game.voteWindow());

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
        uint256 settleBurn = (bond * game.settleBurnBps()) / 10_000;
        assertEq(wood.balanceOf(challenger) - challengerBefore, bond - settleBurn, "bond returned less the settle burn");
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
        _convict(id);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 challengerBefore = wood.balanceOf(challenger);

        // Governance rotates the demoter role out from under the live challenge.
        tiers.setReverting(true);

        swood.setNextResult(9_999e18);
        vm.warp(_filedAt(id) + game.voteWindow());

        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.AdapterDemotionFailed(id, ADAPTER, SELECTOR);
        game.resolve(id);

        // Everything that actually holds value still happened.
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Settled), "the verdict still lands");
        assertEq(swood.callCount(), 1, "the slash still executed");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "the coverage is still released");
        uint256 settleBurn = (bond * game.settleBurnBps()) / 10_000;
        assertEq(wood.balanceOf(challenger) - challengerBefore, bond - settleBurn, "the bond still comes back");
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

        _convict(id);
        vm.warp(_filedAt(id) + game.voteWindow());
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

        _convict(id);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
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
        _convict(id);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);

        assertEq(swood.callCount(), 1, "still slashed");
        assertEq(tiers.demoteCount(), 0, "nothing was accused, so nothing is demoted");
    }

    /// @notice The window is the guardians' entire chance to notice and contest
    ///         (D1) — it cannot be short-circuited by an impatient challenger.
    function test_resolve_revertsBeforeTheVoteWindow() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow() - 1);
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
        _convict(id);
        vm.warp(_filedAt(id) + game.voteWindow());

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
        _convict(id);
        vm.warp(_filedAt(id) + game.voteWindow());

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
        _convict(id);
        vm.warp(_filedAt(id) + game.voteWindow());

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
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);

        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(id); // no double-slash
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(999); // never existed
    }

    /// @notice The slash path has no sink without sWOOD wired, and the game
    ///         fails closed AT THE DOOR rather than taking a bond it could
    ///         never adjudicate: the electorate a filing pins is read off
    ///         sWOOD, so with none wired there is nothing to pin and nobody to
    ///         decide the challenge.
    function test_file_revertsWhenStakedWoodUnset() public {
        ChallengeGame bare = new ChallengeGame(owner, address(wood), address(ledger), address(tiers));
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.startPrank(challenger);
        wood.approve(address(bare), type(uint256).max);
        vm.expectRevert(IChallengeGame.ZeroAddress.selector);
        bare.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);
        vm.stopPrank();

        assertEq(wood.balanceOf(address(bare)), 0, "no bond taken by a game that cannot adjudicate");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "and no coverage frozen");
    }

    // ── Coverage is released on BOTH terminal paths ──

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
    ///         another `voteWindow` of lock. Slots are per-challenger, so N
    ///         addresses buy N concurrent filings, chainable to the end of
    ///         `challengeWindow`.
    ///
    ///         A filing that cannot reach a verdict has no legitimate purpose,
    ///         so it is refused at the door rather than priced.
    function test_file_rejectsAProposalWhoseVerdictWasAlreadyCollected() public {
        uint256 id = _fileStandard(PROPOSAL);
        _convict(id);
        vm.warp(_filedAt(id) + game.voteWindow());
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
        _convict(id);
        uint256 bond = game.challengeOf(id).bondWood;
        assertEq(bond, _standardBondWood(), "fixture: $10,000 coverage at the live challengerBondBps");

        uint256 before = wood.balanceOf(challenger);
        uint256 burnBefore = wood.balanceOf(0x000000000000000000000000000000000000dEaD);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);

        // A CORRECT FILING IS CHEAP, NOT FREE (review 🟠F4). The full refund
        // made an attacker whose payoff is the CONSEQUENCE — the approvers
        // slashed, the named adapter demoted — fully subsidised: the whole
        // attack cost gas. `settleBurnBps` of the bond burns; the rest comes back.
        uint256 burned = (bond * game.settleBurnBps()) / 10_000;
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
        _convict(id);
        uint256 executedAt = _executedAt(PROPOSAL);
        uint256 filedAt = _filedAt(id);

        // The accused has this whole span to move state. The basis must sit
        // before ALL of it, not at the far end.
        assertGt(filedAt, executedAt, "fixture: the filing trails execution");

        vm.warp(filedAt + game.voteWindow());
        game.resolve(id);

        assertEq(swood.lastOpenedAt(), executedAt, "basis is the execution instant");
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

    /// @notice A settlement-leg adapter is part of the proposal too: the caps
    ///         and the coverage price it, so a filing may name it.
    function test_file_acceptsAnAdapterOnlyTheSettlementLegCalls() public {
        address settlementAdapter = address(0x5E77);
        bytes4 settlementSelector = bytes4(0x11223344);
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        gov.setExecuteCall(PROPOSAL, ADAPTER, SELECTOR);
        gov.setSettlementCall(PROPOSAL, settlementAdapter, settlementSelector);

        vm.startPrank(challenger);
        // In neither leg: still refused.
        vm.expectRevert(IChallengeGame.AdapterNotInProposal.selector);
        game.file(
            address(gov),
            PROPOSAL,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            settlementAdapter,
            bytes4(0xdeadbeef),
            EVIDENCE
        );
        // Present only in the settlement leg: accepted.
        uint256 id = game.file(
            address(gov),
            PROPOSAL,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            settlementAdapter,
            settlementSelector,
            EVIDENCE
        );
        vm.stopPrank();
        assertGt(id, 0);
        assertEq(game.challengeOf(id).adapterTarget, settlementAdapter);
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
        _convict(id);
        vm.warp(_filedAt(id) + game.voteWindow());
        game.resolve(id);
        assertEq(tiers.demoteCount(), 0, "a filing that names nothing demotes nothing");
        assertEq(swood.callCount(), 1, "but it still convicts");
    }

    /// @notice And with nothing donated, the game's custody returns to exactly
    ///         `bondedWood` — zero once the only challenge is terminal.
    function test_resolve_leavesTheGameHoldingExactlyItsLiveBonds() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);
        _assertLiveBondsBacked();
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded, nothing withheld");
    }

    // ── Parameters ──

    /// @notice The window is the guardians' whole chance to notice an unproven
    ///         assertion (D1), so it has a hard floor.
    function test_setVoteWindow_bounded() public {
        // Read the bound BEFORE arming `expectRevert` — it latches onto the
        // very next call, and a getter is a call.
        uint256 floor = game.MIN_VOTE_WINDOW();
        assertEq(floor, 2 days);

        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setVoteWindow(floor - 1);
        game.setVoteWindow(floor);
        vm.stopPrank();
        assertEq(game.voteWindow(), floor);
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
        uint256 feeBefore = game.prosecutorFeeBps();
        MockChallengeStakedWood other = new MockChallengeStakedWood();
        other.setAuthorizedSlasher(address(game));
        vm.prank(owner);
        game.setStakedWood(address(other)); // no rate check to fail
        assertEq(address(game.stakedWood()), address(other), "re-point accepted");
        assertEq(game.prosecutorFeeBps(), feeBefore, "and the fee rate is untouched");
    }

    function test_defaultTimings() public view {
        assertEq(game.voteWindow(), 7 days);
        assertGt(game.voteWindow(), game.MIN_VOTE_WINDOW());
    }

    /// @dev Mirrors `ChallengeGame._reviewKey` exactly — the two must derive
    ///      the same key or every `challengeableUntil` lookup below means
    ///      nothing.
    function _reviewKeyFor(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    /// @dev Like `_fileStandard`, but files `offset` after execution instead
    ///      of the fixed 3 days — needed to put the filing close enough to
    ///      execution that a pool stalled to the edge of `voteWindow` can
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

    /// @notice With nothing re-arming it, the gate is
    ///         `executedAt + challengeWindow`, unextended, and filing past it
    ///         reverts.
    function test_challengeableUntil_unsetFallsBackToExecutedAtPlusWindow() public {
        _fileStandard(PROPOSAL);
        assertEq(game.challengeableUntil(_reviewKeyFor(address(gov), PROPOSAL)), 0, "unset until an unwind");
        vm.warp(vm.getBlockTimestamp() + 15 days);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        _fileStandardFrom(makeAddr("otherChallenger"), PROPOSAL);
    }

    function _fund(address who) internal {
        wood.mint(who, 10_000_000e18);
        vm.prank(who);
        wood.approve(address(game), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The forfeit burn — pricing the self-challenge
    // ─────────────────────────────────────────────────────────────────────────

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

    /// @notice THE SLASH PAYS NO ONE. sWOOD is handed a case key, a basis and
    ///         the rates — and nothing else. There is no recipient argument to
    ///         misdirect and no bounty leg to divert, which is the whole point
    ///         of moving the prosecutor's fee onto the proposer's bond: the
    ///         slash pot is one a prosecutor can fund for itself by staking and
    ///         approving the proposal it is about to accuse.
    function test_slash_carriesNoPayoutRecipient() public {
        uint256 id = _fileStandard(PROPOSAL);
        _convict(id);
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
        uint256 defaultRate = game.prosecutorFeeBps();
        uint256 id = _fileStandard(PROPOSAL);
        assertEq(game.challengeOf(id).prosecutorFeeBpsAtFiling, defaultRate, "pinned at the filing rate");

        vm.prank(owner);
        game.setProsecutorFeeBps(1_000);

        assertEq(game.challengeOf(id).prosecutorFeeBpsAtFiling, defaultRate, "the open challenge keeps its rate");
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
        vm.prank(owner);
        v2.setStakedWood(address(swood));
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
        _convict(v1Id);
        vm.warp(_filedAt(v1Id) + game.voteWindow());
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
        _convict(id);
        assertTrue(game.challengeOf(id).adapterTarget != address(0), "fixture: the filing named an adapter");

        // Collect the liability out from under the live challenge, so the
        // settle takes the diverted branch.
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        swood.setVerdictSlashed(key, guardianA, true);
        swood.setVerdictSlashed(key, guardianB, true);

        uint256 demotesBefore = tiers.demoteCount();

        vm.warp(_filedAt(id) + game.voteWindow());
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
        _convict(id);
        uint256 demotesBefore = tiers.demoteCount();

        vm.warp(_filedAt(id) + game.voteWindow());
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
        _convict(v1Id);
        vm.prank(nonApproverGuardian);
        v2.voteOnChallenge(v2Id, true);

        // V1 settles first and collects the one liability.
        vm.warp(_filedAt(v1Id) + game.voteWindow());
        game.resolve(v1Id);

        uint256 filerBefore = wood.balanceOf(filer);
        vm.warp(v2.challengeOf(v2Id).filedAt + v2.voteWindow());
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
        _convict(id);
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
        vm.warp(_filedAt(id) + game.voteWindow());
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
        vm.warp(_filedAt(id) + game.voteWindow());
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
    ///         un-wedge and `setExposureLedger` the only way to move the freeze
    ///         rail, and both are owner-only with no permissionless equivalent.
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

    // ─────────────────────────────────────────────────────────────────────────
    // The guardian vote: a quorum convicts, silence fails
    // ─────────────────────────────────────────────────────────────────────────

    function test_filingOpensAGuardianVoteAndQuorumSlashes() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 stakeBefore = swood.stakeOf(guardianA);
        vm.prank(nonApproverGuardian);
        game.voteOnChallenge(id, true);
        (uint256 convictWeight, uint256 votable, uint256 qBps) = game.challengeTallyOf(id);
        assertGe(convictWeight * 10_000, qBps * votable, "quorum reached");
        game.resolve(id);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled), "settled");
        assertLt(swood.stakeOf(guardianA), stakeBefore, "approver slashed");
    }

    function test_missedQuorumFailsToTheAccusedAndBurnsOneFixedFraction() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 bond = game.challengeOf(id).bondWood;
        uint256 burnBps = game.challengeOf(id).forfeitBurnBpsAtFiling;
        uint256 deadBefore = wood.balanceOf(game.BURN_ADDRESS());
        uint256 challengerBefore = wood.balanceOf(challenger);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Failed), "failed");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()) - deadBefore, bond * burnBps / 10_000, "one fixed fraction");
        assertEq(wood.balanceOf(challenger) - challengerBefore, bond - bond * burnBps / 10_000, "remainder back");
    }

    function test_accusedApproversCannotVoteOnTheirOwnChallenge() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(guardianA);
        vm.expectRevert(IChallengeGame.AccusedCannotVote.selector);
        game.voteOnChallenge(id, false);
    }

    function test_honestChallengerNeverForfeitsToTheAccused() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 approverBefore = wood.balanceOf(guardianA);
        uint256 proposerBefore = wood.balanceOf(proposer);
        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);
        assertEq(wood.balanceOf(guardianA), approverBefore, "accused gains nothing on a failed challenge");
        assertEq(wood.balanceOf(proposer), proposerBefore, "proposer gains nothing either");
    }

    /// @notice The accused file their own challenge first; it must buy the later
    ///         honest one nothing.
    function test_selfFiledDecoyProvidesNoShield() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);
        vm.prank(guardianB);
        uint256 decoy =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, "decoy");
        uint256 honest = _fileStandard(PROPOSAL);
        vm.prank(nonApproverGuardian);
        game.voteOnChallenge(honest, true);
        game.resolve(honest);
        assertEq(uint8(game.challengeOf(honest).status), uint8(IChallengeGame.Status.Settled), "no shield to buy");
        assertTrue(decoy != honest, "distinct filings");
    }

    function test_voteIsOneShotPerGuardian() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(nonApproverGuardian);
        game.voteOnChallenge(id, true);
        assertTrue(game.hasVotedOn(id, nonApproverGuardian), "recorded");
        vm.prank(nonApproverGuardian);
        vm.expectRevert(IChallengeGame.AlreadyVoted.selector);
        game.voteOnChallenge(id, false);
    }

    function test_quorumIsMeasuredAgainstStakeMinusTheAccused() public {
        uint256 id = _fileStandard(PROPOSAL);
        (, uint256 votable,) = game.challengeTallyOf(id);
        uint256 snapshotAt = game.challengeOf(id).filedAt - 1;
        assertEq(
            votable,
            swood.getPastTotalVotes(snapshotAt) - swood.getPastStake(guardianA, snapshotAt)
                - swood.getPastStake(guardianB, snapshotAt),
            "accused weight is out of the denominator"
        );
    }

    function test_anAcquitVoteDoesNotCountTowardTheQuorum() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(nonApproverGuardian);
        game.voteOnChallenge(id, false);
        (uint256 convictWeight,,) = game.challengeTallyOf(id);
        assertEq(convictWeight, 0, "acquit adds nothing");
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(id);
    }

    /// @notice SILENCE RE-ARMS. A missed quorum adjudicated nothing, so it must
    ///         not spend the proposal's challengeability — the negative case,
    ///         where guardians actually voted to acquit, is below.
    function test_silentFailureReArmsTheWindow() public {
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        uint256 id = _fileStandard(PROPOSAL);
        assertEq(game.challengeableUntil(key), 0, "nothing re-armed yet");

        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Failed), "missed quorum");
        assertEq(
            game.challengeableUntil(key),
            vm.getBlockTimestamp() + game.challengeWindow(),
            "the window moved, with no acquittal exception"
        );
    }

    /// @notice AND A VOTED ACQUITTAL DOES NOT. Guardians that looked at the
    ///         accusation and cleared it have spent the window; re-arming on
    ///         their verdict would make a cleared proposal permanently
    ///         re-challengeable at the price of the forfeit burn.
    function test_votedAcquittalDoesNotReArmTheWindow() public {
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        uint256 id = _fileStandard(PROPOSAL);

        vm.prank(nonApproverGuardian);
        game.voteOnChallenge(id, false);

        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        uint256 pinCallsBefore = ledger.pinCoverageUntilCallCount();
        game.resolve(id);

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Failed), "acquitted");
        assertGt(game.challengeOf(id).acquitWeight, 0, "and on a real vote, not on silence");
        assertEq(game.challengeableUntil(key), 0, "a verdict on the merits does not re-arm");
        assertEq(ledger.pinCoverageUntilCallCount(), pinCallsBefore, "and pins nothing on the ledger");
    }

    /// @notice The re-arm carries the ledger pin with it: `challengeableUntil`
    ///         and the coverage pin must name the same instant, or the deadline
    ///         a filing is still admissible under outlives the exposure a
    ///         conviction could take.
    function test_missedQuorum_reArmsReChallengeWindowAndPinsTheLedger() public {
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        uint256 id = _fileStandard(PROPOSAL);
        assertEq(game.challengeableUntil(key), 0, "sanity: no re-arm has happened yet");

        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        uint256 pinCallsBefore = ledger.pinCoverageUntilCallCount();
        game.resolve(id);

        assertEq(
            uint8(game.challengeOf(id).status),
            uint8(IChallengeGame.Status.Failed),
            "the payout path is unchanged: still a forfeit charged to the challenger"
        );

        uint256 rearmed = game.challengeableUntil(key);
        assertGt(rearmed, vm.getBlockTimestamp(), "THE RE-CHALLENGE WINDOW MUST RE-ARM");
        assertEq(rearmed, vm.getBlockTimestamp() + game.challengeWindow(), "re-armed to the ordinary window from now");
        assertEq(ledger.pinCoverageUntilCallCount(), pinCallsBefore + 1, "the ledger pin must accompany the re-arm");
        assertEq(ledger.pinnedUntil(address(gov), PROPOSAL), rearmed, "pinned through the SAME instant");
    }

    /// @notice An electorate with no non-accused stake can never reach a
    ///         quorum, so the filing is refused at the door rather than taking a
    ///         bond it could only burn. A cohort that covers the entire stake
    ///         cannot convict itself, and an empty denominator must never read
    ///         as a quorum met.
    function test_file_revertsWhenNoStakeCanVote() public {
        swood.setStake(nonApproverGuardian, 0);
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18);
        _execute(PROPOSAL);

        uint256 before = wood.balanceOf(challenger);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.NoVotableStake.selector);
        game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.OutOfAdapterOutflow, ADAPTER, SELECTOR, EVIDENCE);

        assertEq(wood.balanceOf(challenger), before, "no bond taken by a filing nobody could decide");
        assertFalse(ledger.isCoverageFrozen(address(gov), PROPOSAL), "and no coverage frozen");
    }

    function test_voteOnChallenge_refusesAnOutsiderAndAClosedWindow() public {
        uint256 id = _fileStandard(PROPOSAL);

        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(IChallengeGame.NoVotableStake.selector);
        game.voteOnChallenge(id, true);

        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        vm.prank(nonApproverGuardian);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.voteOnChallenge(id, true);
    }

    function test_setChallengeQuorumBps_boundedAndOwnerOnly() public {
        assertEq(game.challengeQuorumBps(), 3_000, "the shipped default");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        game.setChallengeQuorumBps(4_000);

        vm.startPrank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setChallengeQuorumBps(999);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setChallengeQuorumBps(10_001);
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ChallengeQuorumBpsSet(3_000, 10_000);
        game.setChallengeQuorumBps(10_000);
        vm.stopPrank();
        assertEq(game.challengeQuorumBps(), 10_000);
    }

    /// @dev Three guardians outside the accused cohort, so a convict vote can
    ///      sit strictly below, exactly at, or above the quorum. The suite's
    ///      default electorate is one guardian holding 100% of the votable
    ///      stake, which no threshold can be read off.
    function _threeVotableGuardians() internal returns (address second, address third) {
        second = makeAddr("nonApproverGuardian2");
        third = makeAddr("nonApproverGuardian3");
        swood.setStake(second, 150_000e18);
        swood.setStake(third, 50_000e18);
    }

    /// @notice THE QUORUM IS A THRESHOLD, NOT A HEADCOUNT. A convict vote short
    ///         of it settles nothing, and the vote that carries it is the one
    ///         that lands EXACTLY on the bar — `>=`, not `>`.
    function test_theQuorumIsAThresholdNotASingleVote() public {
        (, address third) = _threeVotableGuardians();
        vm.prank(owner);
        game.setChallengeQuorumBps(5_000);

        uint256 id = _fileStandard(PROPOSAL);
        (, uint256 votable, uint256 qBps) = game.challengeTallyOf(id);
        assertEq(votable, 300_000e18, "three guardians outside the accused cohort");
        assertEq(qBps, 5_000, "and a quorum the fixture straddles");

        // 100,000 of 300,000 — a third of the electorate, short of the bar.
        vm.prank(nonApproverGuardian);
        game.voteOnChallenge(id, true);
        (uint256 convictWeight,,) = game.challengeTallyOf(id);
        assertLt(convictWeight * 10_000, qBps * votable, "fixture: strictly sub-quorum");
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(id);

        // 150,000 of 300,000 — exactly the bar, which must carry it.
        vm.prank(third);
        game.voteOnChallenge(id, true);
        (convictWeight,,) = game.challengeTallyOf(id);
        assertEq(convictWeight * 10_000, qBps * votable, "fixture: exactly at the bar, not past it");
        game.resolve(id);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled), "the bar itself settles");
    }

    /// @notice And a convict vote that never reaches the bar fails at the
    ///         deadline like silence does — a minority is not a verdict.
    function test_aSubQuorumConvictVoteFailsAtTheDeadline() public {
        _threeVotableGuardians();
        vm.prank(owner);
        game.setChallengeQuorumBps(5_000);

        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(nonApproverGuardian);
        game.voteOnChallenge(id, true);

        vm.warp(vm.getBlockTimestamp() + game.voteWindow());
        game.resolve(id);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Failed), "a minority convicts nobody");
        assertEq(swood.callCount(), 0, "and nothing was slashed");
    }

    /// @notice The quorum is pinned at filing like every other rate: an owner
    ///         cannot raise it under a vote that has already been won. The
    ///         convict weight sits BETWEEN the pinned bar and the raised one, so
    ///         dropping the pin flips the outcome.
    function test_challengeQuorum_isPinnedAtFiling() public {
        _threeVotableGuardians();
        uint256 id = _fileStandard(PROPOSAL);
        assertEq(game.challengeOf(id).quorumBpsAtFiling, 3_000, "pinned");

        vm.prank(owner);
        game.setChallengeQuorumBps(10_000);

        // 100,000 of 300,000: past the pinned 3,000 bps, far short of 10,000.
        _convict(id);
        (uint256 convictWeight, uint256 votable,) = game.challengeTallyOf(id);
        assertGe(convictWeight * 10_000, 3_000 * votable, "fixture: over the pinned bar");
        assertLt(convictWeight * 10_000, game.challengeQuorumBps() * votable, "and under the live one");

        game.resolve(id);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled), "the pinned quorum stands");
    }

    // ── Re-arm claims that only the failure path can reach ──

    /// @notice A second failure must never pull the deadline back in — NOT
    ///         because `block.timestamp` only moves forward (round 2 is
    ///         chronologically later than round 1 no matter what, which would
    ///         make a bare `assertGe` true even with the guard deleted and the
    ///         write made unconditional), but because the guard itself refuses
    ///         to shrink a bigger stored value.
    ///
    ///         `challengeWindow` is shrunk before round 2, so round 2's own
    ///         `block.timestamp + challengeWindow` comes out SMALLER than round
    ///         1's stored value even though round 2 resolves strictly later in
    ///         wall-clock time — the only way an unconditional write could ever
    ///         produce a smaller number here. `assertEq` (not `assertGe`) is
    ///         what makes that shrink visible.
    function test_challengeableUntil_onlyEverLengthens() public {
        uint256 id = _fileStandardAt(PROPOSAL, 3 days);
        vm.warp(vm.getBlockTimestamp() + game.challengeOf(id).voteWindowAtFiling);
        game.resolve(id);
        bytes32 key = _reviewKeyFor(address(gov), PROPOSAL);
        uint256 first = game.challengeableUntil(key);

        // Shrink the window so round 2's OWN extension is smaller than round
        // 1's, despite resolving strictly later.
        vm.prank(owner);
        game.setChallengeWindow(1 days);

        uint256 again = _fileStandard(PROPOSAL); // re-executes, so the filing is admissible
        vm.warp(vm.getBlockTimestamp() + game.challengeOf(again).voteWindowAtFiling);
        game.resolve(again);

        // Sanity-check the fixture itself: if this ever fails, the timeline
        // no longer produces a smaller round-2 extension and the assertion
        // below would pass for the wrong reason (or for no reason at all).
        uint256 round2Extension = vm.getBlockTimestamp() + game.challengeWindow();
        assertLt(round2Extension, first, "fixture must make round 2's own extension smaller than round 1's");

        assertEq(game.challengeableUntil(key), first, "never shortens");
    }

    /// @notice Review blocker: a TEMPORARY shortening of `challengeWindow`
    ///         around a failure must not PERMANENTLY shrink a proposal's
    ///         re-challenge deadline below what the RESTORED window would give
    ///         it. `_rearmChallengeWindow` reads `challengeWindow` live, so an
    ///         owner who shortens it, lets a challenge fail while it is short,
    ///         then restores it, must not leave `challengeableUntil` holding a
    ///         deadline smaller than `executedAt + challengeWindow` computed
    ///         against the RESTORED value — there is no setter for
    ///         `challengeableUntil` to undo that, so `file`'s gate must take the
    ///         max of the two on every call rather than trusting whichever was
    ///         stored at the last write.
    function test_challengeableUntil_survivesATemporarilyShortenedWindow() public {
        uint256 id = _fileStandard(PROPOSAL);

        // Shorten the window to almost nothing, and fail the challenge while it
        // is short.
        vm.prank(owner);
        game.setChallengeWindow(1);
        vm.warp(vm.getBlockTimestamp() + game.challengeOf(id).voteWindowAtFiling);
        game.resolve(id);

        // Restore the ordinary window.
        vm.prank(owner);
        game.setChallengeWindow(14 days);

        // Still well inside `executedAt + 14 days` (the restored window), but
        // past the tiny stored extension the shortened window produced.
        vm.warp(vm.getBlockTimestamp() + 2 days);

        uint256 refiled = _fileStandardFrom(challenger, PROPOSAL); // MUST NOT revert WindowClosed
        assertGt(refiled, 0, "restoring the window must restore full challengeability");
    }

    /// @notice A resolved challenge unblocks a later, legitimate filing against
    ///         the same proposal — the liveness check reads status, not history.
    ///         Still true for a challenge that FAILED: nothing was collected, so
    ///         the liability is still outstanding and a fresh filing is
    ///         legitimate. Only a COLLECTED verdict closes the proposal.
    function test_resolve_allowsALaterFilingOnTheSameProposal() public {
        // The ledger's own window must widen FIRST: the game's
        // `challengeWindow` is capped at whatever the ledger reports live.
        ledger.setChallengeWindow(90 days);
        vm.prank(owner);
        game.setChallengeWindow(90 days);
        uint256 id = _fileStandard(PROPOSAL);
        vm.warp(vm.getBlockTimestamp() + game.challengeOf(id).voteWindowAtFiling);
        game.resolve(id);

        vm.prank(challenger);
        uint256 second =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);
        assertEq(game.liveChallengeOf(address(gov), PROPOSAL), second);
    }

    // ── The forfeit burn prices the self-challenge ──

    /// @notice THE ATTACK THE BURN EXISTS FOR. An approver files against its own
    ///         executed proposal, lets the vote miss its quorum and takes its
    ///         bond back. Under a full refund that is a round trip at net zero,
    ///         while every co-approver's coverage sat frozen for a whole window.
    ///
    ///         With the burn it ends DOWN by exactly `burnAmount`, and that
    ///         number is the price of the grief. Nothing else about its position
    ///         changed: it still got its bond back.
    function test_selfChallenge_roundTripCostsExactlyTheBurn() public {
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // guardianA is an approver here
        _execute(PROPOSAL);
        uint256 attackerBefore = wood.balanceOf(guardianA);

        // The approver challenges its OWN proposal.
        vm.prank(guardianA);
        uint256 id =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.RogueAllowance, ADAPTER, SELECTOR, EVIDENCE);
        uint256 bond = game.challengeOf(id).bondWood;
        assertEq(game.challengeOf(id).challenger, guardianA, "challenger and accused are one address");

        // Nobody convicts, so the filing fails and the bond comes back short.
        vm.warp(_filedAt(id) + game.challengeOf(id).voteWindowAtFiling);
        game.resolve(id);

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
    ///         filer and the accused approver are different addresses here — a
    ///         sender check passes — and the operator's COMBINED position still
    ///         ends down by exactly the burn.
    function test_selfChallenge_twoAddressOperatorPaysTheSameBurn() public {
        address filer = makeAddr("attackerFiler"); // the operator's second key
        _fund(filer);
        _setCoverage(PROPOSAL, 6_000e18, 4_000e18); // guardianA is the accused half
        _execute(PROPOSAL);

        uint256 filerBefore = wood.balanceOf(filer);
        uint256 accusedBefore = wood.balanceOf(guardianA);

        vm.prank(filer);
        uint256 id = game.file(
            address(gov), PROPOSAL, IChallengeGame.Predicate.ProposerLinkedOutflow, ADAPTER, SELECTOR, EVIDENCE
        );
        uint256 bond = game.challengeOf(id).bondWood;
        assertNotEq(game.challengeOf(id).challenger, guardianA, "a sender check would see two unrelated parties");

        vm.warp(_filedAt(id) + game.challengeOf(id).voteWindowAtFiling);
        game.resolve(id);

        uint256 burnAmount = (bond * game.forfeitBurnBps()) / 10_000;
        uint256 combinedBefore = filerBefore + accusedBefore;
        uint256 combinedAfter = wood.balanceOf(filer) + wood.balanceOf(guardianA);
        assertEq(combinedBefore - combinedAfter, burnAmount, "identity-splitting buys the griefer no discount");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burnAmount);
        _assertLiveBondsBacked();
    }
}
