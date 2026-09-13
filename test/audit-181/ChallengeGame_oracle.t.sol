// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChallengeGame} from "src/ChallengeGame.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "src/BatchExecutorLib.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";

/// @dev Minimal governor stub — `file()` only reads `executedAt`/`vault` off
///      `getProposal`, and neither call list is invoked by these tests
///      because every filing here names no adapter (`adapterTarget ==
///      address(0)` skips `_requireAdapterInProposal` entirely). Both are
///      implemented anyway: a filing that DID name an adapter must reach
///      `AdapterNotInProposal`, not a missing-selector revert.
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

    function getSettlementCalls(uint256) external pure returns (BatchExecutorLib.Call[] memory) {
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

    /// @dev `ChallengeGame.file` reads the PLEDGE, not the booking (pashov
    ///      2026-08 finding #24). This stub does not model `settleCoverage`, so
    ///      the two never diverge here and the pledge is the same figure — the
    ///      point of the finding is that in the REAL ledger they diverge and
    ///      anyone can move the booking. Present so the typed call resolves;
    ///      without it every test in this file reverts undecodably.
    function pledgedOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory guardians, uint256[] memory pledgedUsd)
    {
        bytes32 k = _key(governor, proposalId);
        guardians = _approvers[k];
        pledgedUsd = new uint256[](guardians.length);
        for (uint256 i = 0; i < guardians.length; i++) {
            pledgedUsd[i] = _committed[k][guardians[i]];
        }
    }

    /// @dev Zero means "no override" at the `file()` call site — the raw
    ///      `approversOf` sum is used as-is, which keeps this mock's bond
    ///      arithmetic simple and predictable for the tests below.
    /// @dev Mirrors the real ledger under declared coverage locks: the cohort's
    ///      locks at value, PRICED INSIDE — the real `unsharedLiabilityUsd`
    ///      reads `woodPriceX8()` and reverts with it, which is the revert
    ///      `ChallengeGame.file` maps to `WoodPriceUnset`. A mock that priced
    ///      nothing here would let the bare `woodPriceX8()` read in `file` leak
    ///      the raw error instead, and prove nothing about that mapping.
    function unsharedLiabilityUsd(address governor, uint256 proposalId) external view returns (uint256 total) {
        if (revertOnWoodPriceX8) revert MockNoWoodPrice();
        bytes32 k = _key(governor, proposalId);
        address[] storage list = _approvers[k];
        for (uint256 i = 0; i < list.length; i++) {
            total += _committed[k][list[i]];
        }
    }

    function freezeCoverage(address governor, uint256 proposalId, uint256) external {
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

/// @dev sWOOD stand-in: `file` reads the electorate off it, so a game with
///      none wired takes no filing at all. One guardian outside the accused
///      cohort, which is all these price tests need.
contract MockStakedWoodForOracleTest {
    address public authorizedSlasher;
    mapping(address guardian => uint256) internal _stake;
    uint256 internal _total;

    function setAuthorizedSlasher(address slasher) external {
        authorizedSlasher = slasher;
    }

    function setStake(address guardian, uint256 amount) external {
        _total = _total + amount - _stake[guardian];
        _stake[guardian] = amount;
    }

    function getPastStake(address guardian, uint256) external view returns (uint256) {
        return _stake[guardian];
    }

    function getPastTotalVotes(uint256) external view returns (uint256) {
        return _total;
    }

    function isActiveGuardian(address guardian) external view returns (bool) {
        return _stake[guardian] != 0;
    }

    function verdictSlashed(bytes32, address) external pure returns (bool) {
        return false;
    }
}

/// @title ChallengeGame_oracle
/// @notice Regression coverage for audit issue #181, finding #12, against
///         `ChallengeGame`/`IChallengeGame`.
///
/// @dev    Finding #12a (HIGH): `file()` used to read `woodPriceX8()`
///         unguarded, and that view now REVERTS (`NoWoodPrice`) rather than
///         returning zero whenever no market source is live — so an oracle
///         outage made filing impossible for as long as the outage lasted,
///         which — combined with `challengeWindow` being pure wall clock —
///         can convert a recoverable delay into permanent immunity.
///         `test_file_succeedsWhenWoodPriceX8Reverts` proves the fallback.
contract ChallengeGame_oracleTest is Test {
    ChallengeGame internal game;
    MockGovernorForOracleTest internal governor;
    MockLedgerForOracleTest internal ledger;
    MockTierRegistryForOracleTest internal tierRegistry;
    MockStakedWoodForOracleTest internal swood;
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
        swood = new MockStakedWoodForOracleTest();
        swood.setAuthorizedSlasher(address(game));
        swood.setStake(address(0xB0B), 1_000e18);
        game.setStakedWood(address(swood));

        governor.setExecuted(PROPOSAL_ID, vault, block.timestamp);

        address[] memory guardians = new address[](1);
        guardians[0] = approver1;
        uint256[] memory usd = new uint256[](1);
        usd[0] = COVERAGE_USD;
        ledger.setApprovers(address(governor), PROPOSAL_ID, guardians, usd);

        ledger.setWoodPriceX8(PRICE_X8);
        ledger.setRevertOnWoodPriceX8(false);
    }

    function _fund(address who, uint256 amount) internal {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(game), type(uint256).max);
    }

    /// @dev Expected undiscounted bond for `COVERAGE_USD` at `priceX8`:
    ///      `coverageUsd * challengerBondBps / 10_000 * 1e8 / priceX8`, with
    ///      `challengerBondBps` read LIVE off the contract (audit #181
    ///      finding 18a moved the default from 500 to 150) rather than
    ///      hardcoded, so a future parameter change does not silently break
    ///      every fixture built on top of this.
    function _expectedBondWood(uint256 priceX8) internal view returns (uint256) {
        return (((COVERAGE_USD * game.challengerBondBps()) / 10_000) * 1e8) / priceX8;
    }

    // ── Finding #2 ──

    // ── Finding #12a ──

    /// @notice Declared coverage locks: a WOOD price the ledger cannot compose
    ///         makes filing WAIT. The pre-lock game fell back to the governance
    ///         cap (`woodUsdPriceX8`) and sized the bond off an uncapped
    ///         reservation sum; that fallback is gone, because the only thing a
    ///         fallback could do on a stale feed is make the bond LARGER than
    ///         what a conviction can recover. The cap being set — and above
    ///         market — is the control: it must not be consulted.
    function test_file_revertsWoodPriceUnset_whenWoodPriceX8Reverts() public {
        ledger.setRevertOnWoodPriceX8(true);
        uint256 capX8 = 2e8; // $2.00 cap, deliberately above the $1.00 market used elsewhere in this file
        ledger.setWoodUsdPriceX8(capX8);

        address challenger = address(0xC4A11E7);
        _fund(challenger, _expectedBondWood(capX8));

        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.WoodPriceUnset.selector);
        game.file(
            address(governor), PROPOSAL_ID, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "ev"
        );

        // Non-vacuity: the same filing goes through once the price composes.
        ledger.setRevertOnWoodPriceX8(false);
        _fund(challenger, _expectedBondWood(PRICE_X8));
        vm.prank(challenger);
        uint256 id = game.file(
            address(governor), PROPOSAL_ID, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "ev"
        );
        assertEq(game.challengeOf(id).bondWood, _expectedBondWood(PRICE_X8), "priced off the composed price only");
    }

    /// @notice Same revert with the governance cap at zero: the cap is not a
    ///         fallback in either state, so the selector does not change.
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
}
