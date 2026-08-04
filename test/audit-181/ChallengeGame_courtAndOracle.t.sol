// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChallengeGame} from "src/ChallengeGame.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "src/BatchExecutorLib.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";

/// @dev Minimal governor stub — `file()` only reads `executedAt`/`vault` off
///      `getProposal`, and `getExecuteCalls` is never invoked by these tests
///      because every filing here names no adapter (`adapterTarget ==
///      address(0)` skips `_requireAdapterInProposal` entirely).
contract MockGovernorForOracleTest {
    mapping(uint256 => ISyndicateGovernor.StrategyProposal) internal _proposals;

    function setExecuted(uint256 proposalId, address vault, uint256 executedAt) external {
        _proposals[proposalId].vault = vault;
        _proposals[proposalId].executedAt = executedAt;
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
    }

    function getExecuteCalls(uint256) external pure returns (BatchExecutorLib.Call[] memory) {
        return new BatchExecutorLib.Call[](0);
    }
}

/// @dev Minimal `IExposureLedger` stand-in implementing exactly the
///      selectors `ChallengeGame` calls (see `ChallengeGame.sol`'s
///      `exposureLedger.*` call sites), with a controllable `woodPriceX8`
///      that can be made to REVERT — the real `ExposureLedger.woodPriceX8`
///      does exactly that (`NoWoodPrice`) whenever neither the Chainlink
///      feed nor the TWAP is live, and that is the exact condition
///      finding 12a is about.
contract MockLedgerForOracleTest {
    error MockNoWoodPrice();

    uint256 public challengeWindow = 14 days;

    uint256 internal _woodPriceX8;
    bool public revertOnWoodPriceX8;
    uint256 internal _woodUsdPriceX8;

    mapping(bytes32 => address[]) internal _approvers;
    mapping(bytes32 => mapping(address => uint256)) internal _committed;
    mapping(bytes32 => uint256) public freezeCalls;
    mapping(bytes32 => uint256) public unfreezeCalls;

    function setWoodPriceX8(uint256 p) external {
        _woodPriceX8 = p;
    }

    function setRevertOnWoodPriceX8(bool r) external {
        revertOnWoodPriceX8 = r;
    }

    function setWoodUsdPriceX8(uint256 p) external {
        _woodUsdPriceX8 = p;
    }

    function woodPriceX8() external view returns (uint256) {
        if (revertOnWoodPriceX8) revert MockNoWoodPrice();
        return _woodPriceX8;
    }

    function woodUsdPriceX8() external view returns (uint256) {
        return _woodUsdPriceX8;
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

    /// @dev Zero means "no override" at the `file()` call site — the raw
    ///      `approversOf` sum is used as-is, which keeps this mock's bond
    ///      arithmetic simple and predictable for the tests below.
    function unsharedLiabilityUsd(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function freezeCoverage(address governor, uint256 proposalId) external {
        freezeCalls[_key(governor, proposalId)]++;
    }

    function unfreezeCoverage(address governor, uint256 proposalId) external {
        unfreezeCalls[_key(governor, proposalId)]++;
    }

    function pinCoverageUntil(address, uint256, uint256) external {}

    function slashBpsFor(address, uint256) external pure returns (address[] memory, uint256[] memory) {
        return (new address[](0), new uint256[](0));
    }

    function _key(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }
}

contract MockTierRegistryForOracleTest {
    function demoteByChallenge(address, bytes4) external {}
}

/// @title ChallengeGame_courtAndOracle
/// @notice Regression coverage for audit issue #181, findings #2 and #12,
///         against `ChallengeGame`/`IChallengeGame` as fixed on
///         `fix/audit-181-critical-high`.
///
/// @dev    Finding #2 (CRITICAL): a Disputed challenge that times out with no
///         adjudicator ever pinned at filing must unwind as a NON-VERDICT
///         (`_refundAll`), not an acquittal (`_fail`) — under the pre-fix
///         code every such dispute was a guaranteed, risk-free forfeit to
///         whoever funded the counter-bond pool, funded entirely by the
///         challenger's bond, which made filing against an unwired game
///         strictly irrational. `test_disputedTimeout_withNoCourtAtFiling_refundsBothSides`
///         proves the fix.
///
/// @dev    Finding #12a (HIGH): `file()` used to read `woodPriceX8()`
///         unguarded, and that view now REVERTS (`NoWoodPrice`) rather than
///         returning zero whenever no market source is live — so an oracle
///         outage made filing impossible for as long as the outage lasted,
///         which — combined with `challengeWindow` being pure wall clock —
///         can convert a recoverable delay into permanent immunity.
///         `test_file_succeedsWhenWoodPriceX8Reverts` proves the fallback.
///
/// @dev    Finding #12b (HIGH): `inconclusiveBurnBpsAtFiling` was pinned from
///         `inconclusiveRounds[key]` alone, which only increments on an
///         actual `Inconclusive` unwind — so every challenge filed
///         concurrently, before the first one ever unwound, pinned the free
///         round-1 rate, regardless of how many were already live.
///         `test_concurrentFilings_pinDistinctEscalatingTiers` proves the
///         fix (`_liveCount[key]` folded into the round).
contract ChallengeGame_courtAndOracleTest is Test {
    ChallengeGame internal game;
    MockGovernorForOracleTest internal governor;
    MockLedgerForOracleTest internal ledger;
    MockTierRegistryForOracleTest internal tierRegistry;
    ERC20Mock internal wood;

    address internal owner = address(this);
    address internal approver1 = address(0xA9911);
    address internal vault = address(0x1A017);

    uint256 internal constant PROPOSAL_ID = 1;
    uint256 internal constant COVERAGE_USD = 100_000e18;
    uint256 internal constant PRICE_X8 = 1e8; // $1.00 / WOOD

    function setUp() public {
        governor = new MockGovernorForOracleTest();
        ledger = new MockLedgerForOracleTest();
        tierRegistry = new MockTierRegistryForOracleTest();
        wood = new ERC20Mock("WOOD", "WOOD", 18);

        game = new ChallengeGame(owner, address(wood), address(ledger), address(tierRegistry));

        governor.setExecuted(PROPOSAL_ID, vault, block.timestamp);

        address[] memory guardians = new address[](1);
        guardians[0] = approver1;
        uint256[] memory usd = new uint256[](1);
        usd[0] = COVERAGE_USD;
        ledger.setApprovers(address(governor), PROPOSAL_ID, guardians, usd);

        ledger.setWoodPriceX8(PRICE_X8);
        ledger.setRevertOnWoodPriceX8(false);

        // `game.court()` is never set in this suite — every test starts (and,
        // except where noted, stays) with the unwired-court configuration
        // finding #2 is about.
        assertEq(game.court(), address(0), "sanity: court starts unwired");
    }

    function _fund(address who, uint256 amount) internal {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(game), type(uint256).max);
    }

    /// @dev Expected undiscounted bond for `COVERAGE_USD` at `PRICE_X8`:
    ///      `coverageUsd * challengerBondBps / 10_000 * 1e8 / priceX8`, with
    ///      the default `challengerBondBps == 500`.
    function _expectedBondWood(uint256 priceX8) internal pure returns (uint256) {
        return (((COVERAGE_USD * 500) / 10_000) * 1e8) / priceX8;
    }

    // ── Finding #2 ──

    /// @notice A Disputed challenge whose game had no court wired AT FILING
    ///         must, on timeout, refund BOTH the challenger's bond and the
    ///         counter-bond pool — not forfeit the bond to the pool as an
    ///         acquittal-by-timeout would.
    /// @dev    FAILS AGAINST THE PRE-FIX CODE: `resolve`'s Disputed branch
    ///         used to call `_fail` unconditionally, which (a) leaves the
    ///         challenge `Failed`, not `Inconclusive`, and (b) pays the pool
    ///         funder `contributed + forfeitPayoutWood * contributed / pool`
    ///         — strictly more than it put in, entirely at the challenger's
    ///         expense, even though a `Guilty` ruling (the only way that pool
    ///         could ever have lost) was never reachable (`rule` requires
    ///         `msg.sender == court`, and `court` was never wired). Both
    ///         assertions below — the status and the funder's exact
    ///         break-even payout — catch that.
    function test_disputedTimeout_withNoCourtAtFiling_refundsBothSides() public {
        address challenger = address(0xC4A11E7);
        address funder = address(0xF00DE12);

        uint256 bondWood = _expectedBondWood(PRICE_X8);
        _fund(challenger, bondWood);
        _fund(funder, bondWood);

        vm.prank(challenger);
        uint256 id = game.file(
            address(governor), PROPOSAL_ID, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "ev"
        );

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(c.courtAtFiling, address(0), "courtAtFiling must pin the unwired court");
        assertEq(c.bondWood, bondWood, "sanity: bond sizing");
        // First-ever filing against this proposal: round 0, free.
        assertEq(c.inconclusiveBurnBpsAtFiling, 0, "sanity: round-1 pinned rate is free");

        // Fully fund the counter-bond pool — flips the challenge to Disputed
        // and (because `court == address(0)`) skips the auto-referral.
        vm.prank(funder);
        game.dispute(id, type(uint256).max);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed), "must be Disputed");

        // Run out the pinned dispute clock. The warp target is computed from
        // freshly-read contract state, not a locally-cached
        // `block.timestamp` — the optimizer can CSE a pre-warp local across
        // `vm.warp` in this repo's build.
        c = game.challengeOf(id);
        vm.warp(c.filedAt + c.disputeTimeoutAtFiling + 1);

        uint256 challengerBefore = wood.balanceOf(challenger);

        game.resolve(id);

        c = game.challengeOf(id);
        assertEq(
            uint8(c.status), uint8(IChallengeGame.Status.Inconclusive), "timeout with no court must be a non-verdict"
        );

        // Round-1 rate is 0 bps, so the challenger's bond returns whole.
        assertEq(wood.balanceOf(challenger) - challengerBefore, bondWood, "challenger must recover its whole bond");

        // The pool funder recovers exactly its stake — no forfeit share,
        // because nothing was forfeited.
        uint256 funderBefore = wood.balanceOf(funder);
        vm.prank(funder);
        uint256 claimed = game.claimContribution(id);
        assertEq(claimed, bondWood, "funder's claim must equal its own contribution, not a share of a forfeit");
        assertEq(wood.balanceOf(funder) - funderBefore, bondWood, "funder must not profit from an unruled timeout");
    }

    // ── Finding #12a ──

    /// @notice `file()` must still succeed when `woodPriceX8()` reverts, by
    ///         falling back to the governance cap `woodUsdPriceX8()`.
    /// @dev    FAILS AGAINST THE PRE-FIX CODE: `file()` used to read
    ///         `exposureLedger.woodPriceX8()` unguarded, so a revert there
    ///         (exactly what the real `ExposureLedger.woodPriceX8` does on
    ///         `NoWoodPrice`) propagated straight through and reverted the
    ///         whole filing.
    function test_file_succeedsWhenWoodPriceX8Reverts() public {
        ledger.setRevertOnWoodPriceX8(true);
        uint256 capX8 = 2e8; // $2.00 cap, deliberately above the $1.00 market used elsewhere in this file
        ledger.setWoodUsdPriceX8(capX8);

        address challenger = address(0xC4A11E7);
        uint256 expectedBond = _expectedBondWood(capX8);
        _fund(challenger, expectedBond);

        vm.prank(challenger);
        uint256 id = game.file(
            address(governor), PROPOSAL_ID, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "ev"
        );

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint8(c.status), uint8(IChallengeGame.Status.Filed), "filing must succeed despite the revert");
        assertEq(c.bondWood, expectedBond, "bond must be priced off the governance cap fallback");
    }

    /// @notice The zero-cap guard is live again on the fallback branch: with
    ///         `woodPriceX8()` reverting AND the cap unset, `file()` must
    ///         still revert `WoodPriceUnset` rather than pricing a bond of
    ///         zero (or dividing by zero).
    function test_file_revertsWoodPriceUnset_whenFallbackCapAlsoZero() public {
        ledger.setRevertOnWoodPriceX8(true);
        ledger.setWoodUsdPriceX8(0);

        address challenger = address(0xC4A11E7);
        _fund(challenger, 1 ether);

        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.WoodPriceUnset.selector);
        game.file(
            address(governor), PROPOSAL_ID, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "ev"
        );
    }

    // ── Finding #12b ──

    /// @notice Two challenges filed concurrently against the same proposal —
    ///         before either resolves — must pin DISTINCT, escalating
    ///         `inconclusiveBurnBpsAtFiling` rates, not the same free rate.
    /// @dev    FAILS AGAINST THE PRE-FIX CODE: the pinned rate used to be
    ///         `_inconclusiveBurnBpsForRound(inconclusiveRounds[key])` alone,
    ///         and `inconclusiveRounds[key]` only increments in `_refundAll`
    ///         — at unwind. Neither challenge below has unwound when the
    ///         second is filed, so the pre-fix code pins round-1 (0 bps) on
    ///         BOTH, letting an attacker file arbitrarily many challenges
    ///         from arbitrarily many addresses before the first ever
    ///         resolves and pay the free rate on every one.
    function test_concurrentFilings_pinDistinctEscalatingTiers() public {
        address challengerA = address(0xA11CE);
        address challengerB = address(0xB0B00);

        uint256 bondWood = _expectedBondWood(PRICE_X8);
        _fund(challengerA, bondWood);
        _fund(challengerB, bondWood);

        vm.prank(challengerA);
        uint256 idA = game.file(
            address(governor), PROPOSAL_ID, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "ev"
        );
        // First-ever filing against this proposal: round 1, free.
        assertEq(
            game.challengeOf(idA).inconclusiveBurnBpsAtFiling, 0, "first concurrent filing must pin round 1 (free)"
        );
        // Still live — neither settled, disputed, nor timed out.
        assertEq(uint8(game.challengeOf(idA).status), uint8(IChallengeGame.Status.Filed));

        vm.prank(challengerB);
        uint256 idB = game.file(
            address(governor), PROPOSAL_ID, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "ev"
        );

        // Second concurrent filing, still before any unwind: must escalate
        // to the round-2 fixed step (500 bps == `INCONCLUSIVE_BURN_ROUND2_BPS`
        // in `ChallengeGame.sol`; hardcoded here because that constant is
        // `internal`), not repeat the free tier.
        uint256 round2Bps = 500;
        assertEq(
            game.challengeOf(idB).inconclusiveBurnBpsAtFiling,
            round2Bps,
            "second concurrent filing must pin a distinct, escalated tier"
        );
        assertTrue(
            game.challengeOf(idA).inconclusiveBurnBpsAtFiling != game.challengeOf(idB).inconclusiveBurnBpsAtFiling,
            "concurrent filings must not both pin the free tier"
        );
    }
}
