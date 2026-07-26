// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverageEpochs} from "src/CoverageEpochs.sol";
import {ICoverageEpochs} from "src/interfaces/ICoverageEpochs.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";

/// @dev Minimal sWOOD stub: the ledger's constructor reads `coolDownPeriod`
///      only, and `maxDelegatedSlashBps` on the exposure paths Task 4 uses.
contract MockCoverageSwood {
    uint256 public coolDownPeriod = 45 days;
    uint256 public maxDelegatedSlashBps = 2_000;

    mapping(address guardian => uint256) public guardianStake;
    mapping(address guardian => uint256) public delegatedInbound;

    function setStake(address g, uint256 own, uint256 inbound) external {
        guardianStake[g] = own;
        delegatedInbound[g] = inbound;
    }
}

/// @dev Governor stub. `openCover` reads exactly three fields off
///      `getProposal`: `state`, `strategy` and `maxDrawdownBps`.
contract MockCoverageGovernor {
    mapping(uint256 proposalId => ISyndicateGovernor.StrategyProposal) internal _proposals;

    function setProposal(
        uint256 proposalId,
        address vault,
        address strategy,
        uint16 maxDrawdownBps,
        ISyndicateGovernor.ProposalState state
    ) external {
        ISyndicateGovernor.StrategyProposal storage p = _proposals[proposalId];
        p.id = proposalId;
        p.vault = vault;
        p.strategy = strategy;
        p.maxDrawdownBps = maxDrawdownBps;
        p.state = state;
        p.executedAt = block.timestamp;
    }

    function setState(uint256 proposalId, ISyndicateGovernor.ProposalState state) external {
        _proposals[proposalId].state = state;
    }

    function setStrategy(uint256 proposalId, address strategy) external {
        _proposals[proposalId].strategy = strategy;
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
    }
}

/// @dev Price-router stub. Mirrors the real router's G2 Option A contract: when
///      the position is not instantly priceable the value returned is ZERO, not
///      a stale number. That zero is exactly the trap `CoverageEpochs` must not
///      record — see `test_openCover_revertsWhenTheRouterCannotPrice`.
contract MockCoverageRouter {
    mapping(address strategy => uint256) internal _value;
    mapping(address strategy => bool) internal _ok;

    function setValue(address strategy, uint256 value, bool instantOK) external {
        _value[strategy] = value;
        _ok[strategy] = instantOK;
    }

    function valueStrategy(address strategy) external view returns (uint256, bool) {
        if (!_ok[strategy]) return (0, false);
        return (_value[strategy], true);
    }
}

/// @dev Vault stub whose ONLY job is to report a wildly wrong `totalAssets()`.
///      `CoverageEpochs` must never read it (D1): `totalAssets()` is
///      `idle float + liveNav`, and `liveNav` silently collapses to zero during
///      a router outage. If the baseline ever tracked this number, a single
///      oracle hiccup would fabricate a ~100% drawdown and slash honest
///      guardians.
contract MockCoverageVault {
    uint256 public totalAssets;

    function setTotalAssets(uint256 v) external {
        totalAssets = v;
    }
}

/// @title CoverageEpochsTest
/// @notice Task 1 — cover open and baseline NAV (spec 2026-07-22 §3.4a).
contract CoverageEpochsTest is Test {
    uint256 internal constant EPOCH_LENGTH = 28 days;
    uint256 internal constant BASELINE = 1_000e18;

    address internal owner = makeAddr("owner");
    address internal strategy = makeAddr("strategy");

    CoverageEpochs internal epochs;
    ExposureLedger internal ledger;
    MockCoverageGovernor internal governor;
    MockCoverageRouter internal router;
    MockCoverageVault internal vault;
    MockCoverageSwood internal swood;

    uint256 internal pid = 1;

    function setUp() public {
        // Start somewhere realistic: `epochGenesis` is pinned to deploy time and
        // a genesis of 1 makes boundary arithmetic hard to read.
        vm.warp(1_800_000_000);

        swood = new MockCoverageSwood();
        ledger = new ExposureLedger(owner, address(swood), EPOCH_LENGTH);
        router = new MockCoverageRouter();
        vault = new MockCoverageVault();
        governor = new MockCoverageGovernor();

        epochs = new CoverageEpochs(owner, address(router), address(ledger));

        governor.setProposal(pid, address(vault), strategy, 2_000, ISyndicateGovernor.ProposalState.Executed);
    }

    // ── Task 1 tests ──

    /// @dev THE RULE OF THIS PLAN. The vault reports a nonsense `totalAssets()`
    ///      and the baseline must still be exactly what `valueStrategy` said.
    function test_openCover_snapshotsBaselineFromTheRouterNotTotalAssets() public {
        router.setValue(strategy, BASELINE, true);
        vault.setTotalAssets(999_999e18); // must be ignored

        epochs.openCover(address(governor), pid);

        assertEq(epochs.baselineNavOf(address(governor), pid), BASELINE, "baseline must come from valueStrategy");
        assertTrue(
            epochs.baselineNavOf(address(governor), pid) != vault.totalAssets(),
            "baseline must not track the vault's totalAssets"
        );
    }

    /// @dev D1 fail-closed. `instantOK == false` means the router refused to
    ///      price; opening anyway would pin a baseline of zero (or of a value
    ///      nobody vouched for) and measure every later drawdown against it.
    function test_openCover_revertsWhenTheRouterCannotPrice() public {
        router.setValue(strategy, 0, false); // instantOK == false
        vm.expectRevert(ICoverageEpochs.NavUnavailable.selector);
        epochs.openCover(address(governor), pid);
    }

    function test_openCover_revertsBeforeExecution() public {
        router.setValue(strategy, BASELINE, true);
        governor.setState(pid, ISyndicateGovernor.ProposalState.Approved);
        vm.expectRevert(ICoverageEpochs.NotExecuted.selector);
        epochs.openCover(address(governor), pid);
    }

    function test_openCover_isIdempotentlyRefused() public {
        router.setValue(strategy, BASELINE, true);
        epochs.openCover(address(governor), pid);
        vm.expectRevert(ICoverageEpochs.AlreadyOpened.selector);
        epochs.openCover(address(governor), pid);
    }

    /// @dev D3. The schedule is copied onto the cover at open so a future ledger
    ///      re-point cannot retroactively re-slice a live strategy's epochs.
    function test_openCover_copiesTheLedgerEpochSchedule() public {
        router.setValue(strategy, BASELINE, true);
        epochs.openCover(address(governor), pid);

        assertEq(epochs.epochLengthOf(address(governor), pid), ledger.epochLength());
        assertEq(epochs.epochGenesisOf(address(governor), pid), ledger.epochGenesis());
    }

    /// @dev A queue-only proposal has no strategy for the router to value, so
    ///      there is nothing to cover and nothing to checkpoint.
    function test_openCover_revertsWithoutAStrategy() public {
        governor.setStrategy(pid, address(0));
        vm.expectRevert(ICoverageEpochs.NoStrategy.selector);
        epochs.openCover(address(governor), pid);
    }

    /// @dev D2. `openCover` is permissionless and may land well after
    ///      execution; the record must say when the number was actually read.
    function test_openCover_recordsTheObservationTimeNotExecutedAt() public {
        router.setValue(strategy, BASELINE, true);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 observedAt = vm.getBlockTimestamp();

        epochs.openCover(address(governor), pid);

        ICoverageEpochs.Cover memory c = epochs.coverOf(address(governor), pid);
        assertEq(c.openedAt, observedAt, "openedAt is when the NAV was observed");
        assertEq(c.maxDrawdownBps, 2_000, "envelope snapshotted from the proposal");
        assertEq(c.strategy, strategy);
        assertTrue(c.opened);
        assertFalse(c.breached);
        assertFalse(c.windDown);
    }
}
