// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "./mocks/MockRegistryMinimal.sol";
import {MockWoodTwapOracle} from "./mocks/MockWoodTwapOracle.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {TierRegistry} from "../src/TierRegistry.sol";

/// @dev Minimal sWOOD read surface the ExposureLedger constructor consumes.
///      `coolDownPeriod` (45d) covers epochLength (28d) + challengeWindow (14d).
contract MockSwood {
    mapping(address => uint256) public guardianStake;
    uint256 public coolDownPeriod = 45 days;

    function setStake(address g, uint256 own) external {
        guardianStake[g] = own;
    }
}

/// @dev Approver source for the approve-quorum check (spec §3.3a). The ledger
///      reads `getApproverWeights` off its configured guardian registry; only
///      the address list matters here — the ledger re-reads each approver's
///      bond LIVE from sWOOD rather than trusting the recorded vote weight.
contract MockApproverRegistry {
    address[] internal _approvers;

    function setApprovers(address[] memory a) external {
        _approvers = a;
    }

    function getApproverWeights(address, uint256)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 total)
    {
        approvers = _approvers;
        weights = new uint128[](approvers.length);
        total = 0;
    }
}

/// @dev Chainlink-shaped feed: fixed answer, `decimals`, fresh `updatedAt`.
contract MockFeed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Stands in for `ChallengeGame` as the ledger's `coverageFreezer`, with
///      only the two views the governor's filing-deadline gate reads
///      (`challengeWindow()` and `challengeableUntil(bytes32)`). A stub rather
///      than the real game because what is under test here is the GOVERNOR's
///      arithmetic over those two numbers — the `max`, and the strict
///      comparison — and a stub is the only way to drive them independently:
///      the real game's own setters forbid exactly the window divergence one of
///      these tests needs. The full `_refundAll` re-arm arc against the real
///      game lives in `ChallengeEndToEnd.t.sol`.
contract MockFilingDeadline {
    uint256 public challengeWindow;
    mapping(bytes32 => uint256) public challengeableUntil;

    constructor(uint256 window_) {
        challengeWindow = window_;
    }

    function setChallengeableUntil(bytes32 key, uint256 until) external {
        challengeableUntil[key] = until;
    }
}

/// @dev A non-zero freezer that answers neither of those views — a slot rotated
///      to something that is not a game, or simply a broken address.
contract MuteFreezer {}

/// @dev Escrow auth surface (separate from the governor's guardian registry):
///      the escrow only reads `isAuthorizedGovernor`.
contract MockEscrowAuth {
    mapping(address => bool) public isAuthorizedGovernor;

    function set(address gov, bool ok) external {
        isAuthorizedGovernor[gov] = ok;
    }
}

/// @notice Task 8 — propose-time covered-TVL cap + risk-scaled proposer bond
///         (spec 2026-07-22 §3.7 + §3.9). The governor, once wired with an
///         ExposureLedger and a ProposerBondEscrow, rejects proposals whose USD
///         coverage exceeds the covered-TVL cap and locks a WOOD bond scaled to
///         coverage. Unwired governors skip both gates (pre-ledger safe default).
///
///         Fixture is test-as-factory (the test contract is passed as `factory`
///         at init, so it calls the onlyFactory setters directly), mirroring
///         `test/governor/TierResolution.t.sol`. No TierRegistry is wired, so
///         every proposal resolves to tier 2 / full notional (coverage ==
///         maxCapital) — the simplest coverage arithmetic.
contract GovernorCoverageGatesTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    SyndicateGovernor public unwiredGovernor;
    SyndicateVault public unwiredVault;

    BatchExecutorLib public executorLib;
    ERC20Mock public usdg; // vault asset, 6-dec, $1.00
    ERC20Mock public wood; // bond token, 18-dec
    ERC20Mock public targetToken; // execute-call target
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;

    ExposureLedger public ledger;
    ProposerBondEscrow public escrow;
    MockEscrowAuth public escrowAuth;
    MockSwood public swood;
    MockFeed public feed;

    address public owner = makeAddr("owner");
    address public ledgerOwner = makeAddr("ledgerOwner");
    /// @dev Stands in for the GuardianRegistry as the ledger's record/release caller.
    address public ledgerRegistry = makeAddr("ledgerRegistry");
    address public agent = makeAddr("agent");
    address public agent2 = makeAddr("agent2");
    address public coAgent = makeAddr("coAgent");
    address public lp1 = makeAddr("lp1");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;

    function setUp() public {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();

        // ── Ledger: $0.05 WOOD, $1.00 USDG feed, generous cap, default bps 100.
        swood = new MockSwood();
        ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        feed = new MockFeed(1e8, 8); // $1.00, 8-dec
        // Design revision 2: `woodUsdPriceX8` is a CAP, never a price. WOOD is
        // valued from the TWAP oracle at $0.05, with the cap 2x ABOVE it and
        // therefore NOT binding — the configuration production ships.
        MockWoodTwapOracle woodTwap = new MockWoodTwapOracle(0.05e8);
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.1e8);
        ledger.setWoodTwapOracle(address(woodTwap));
        // Generous staleness bound: the §3.3a quorum re-reads this feed at
        // EXECUTE time, which is a voting period (+ review window) after
        // propose. A `maxDelay` shorter than that lifecycle would make every
        // execution fail `StalePrice` regardless of coverage — see
        // `test_execute_staleFeedBlocksQuorum`, which pins that coupling
        // deliberately. Feed staleness itself is covered in ExposureLedger.t.sol.
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18); // $10M — generous
        // The ledger books commitments itself and the quorum reads its OWN
        // approver list, so this slot is only the record/release authorization.
        // Nothing is committed by default — the cold-start case the quorum must
        // fail closed on; `_seatApprovers` books real commitments.
        ledger.setGuardianRegistry(ledgerRegistry);
        vm.stopPrank();

        // ── The wired syndicate (governor + vault). Test contract is factory.
        (governor, vault) = _deploySyndicate();

        // ── Escrow: auth registry recognizes the wired governor only.
        escrowAuth = new MockEscrowAuth();
        escrowAuth.set(address(governor), true);
        escrow = new ProposerBondEscrow(address(wood), address(escrowAuth), address(ledger));

        // ── Wire ledger + escrow into the governor (as factory).
        governor.setExposureLedger(address(ledger));
        governor.setBondEscrow(address(escrow));

        // ── A second, UNWIRED governor (never gets the setters).
        (unwiredGovernor, unwiredVault) = _deploySyndicate();

        // ── Each vault reads its governor from the factory (the test contract).
        //    Map each vault to its own governor so vault-side auth resolves.
        vm.mockCall(
            address(this), abi.encodeWithSignature("governorOf(address)", address(vault)), abi.encode(address(governor))
        );
        vm.mockCall(
            address(this),
            abi.encodeWithSignature("governorOf(address)", address(unwiredVault)),
            abi.encode(address(unwiredGovernor))
        );

        // ── Register agents on their vaults.
        vm.startPrank(owner);
        vault.registerAgent(agentRegistry.mint(agent), agent);
        vault.registerAgent(agentRegistry.mint(coAgent), coAgent);
        unwiredVault.registerAgent(agentRegistry.mint(agent2), agent2);
        vm.stopPrank();

        // ── Fund both vaults with LP capital (maxCapital ceiling headroom).
        usdg.mint(lp1, 200_000e6);
        vm.startPrank(lp1);
        usdg.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        usdg.approve(address(unwiredVault), 60_000e6);
        unwiredVault.deposit(60_000e6, lp1);
        vm.stopPrank();

        // ── Agent holds WOOD and approves the escrow (proposer posts the bond).
        wood.mint(agent, 1_000_000e18);
        vm.prank(agent);
        wood.approve(address(escrow), type(uint256).max);

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _deploySyndicate() internal returns (SyndicateGovernor gov, SyndicateVault v) {
        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdg),
                    name: "Sherwood Vault",
                    symbol: "swUSDG",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 50
                }))
        );
        v = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(v),
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
                address(this), // factory (test contract)
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        gov = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
    }

    function _envelope(uint256 cap) internal pure returns (ISyndicateGovernor.RiskEnvelope memory) {
        return ISyndicateGovernor.RiskEnvelope({maxCapital: cap, maxDrawdownBps: 10_000});
    }

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(targetToken), data: abi.encodeCall(targetToken.approve, (address(usdg), 1)), value: 0
        });
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdg), data: abi.encodeCall(usdg.approve, (address(targetToken), 0)), value: 0
        });
    }

    /// @dev One co-proposer at 30% — lead keeps 70% (>= the 10% floor).
    function _coProposers() internal view returns (ISyndicateGovernor.CoProposer[] memory cps) {
        cps = new ISyndicateGovernor.CoProposer[](1);
        cps[0] = ISyndicateGovernor.CoProposer({agent: coAgent, splitBps: 3000});
    }

    function _proposeSolo(SyndicateGovernor gov, address v, address as_, uint256 cap) internal returns (uint256) {
        vm.prank(as_);
        return gov.propose(
            v,
            address(0),
            "uri",
            7 days,
            _envelope(cap),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    // ── Tests ──

    /// @notice Coverage above the covered-TVL cap fails closed at propose. $1,000
    ///         coverage (tier-2 flat) vs a $100 cap → CoveredTvlCapExceeded.
    function test_propose_revertsOverCoveredTvlCap() public {
        vm.prank(ledgerOwner);
        ledger.setCoveredTvlCapUsd(100e18); // $100 cap
        vm.prank(agent);
        vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
        governor.propose(
            address(vault),
            address(0),
            "uri",
            7 days,
            _envelope(1_000e6),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @notice The bond is coverage × bps ÷ WOOD price. $1,000 coverage, 100 bps
    ///         (1%) = $10; at $0.05/WOOD = 200 WOOD. Both the escrow record and
    ///         the stored `proposerBondWood` must reflect it.
    function test_propose_locksRiskScaledBond() public {
        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "uri",
            7 days,
            _envelope(1_000e6),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
        (address p, uint256 amt) = escrow.bondOf(address(governor), pid);
        assertEq(p, agent);
        assertEq(amt, 200e18);
        assertEq(governor.getProposal(pid).proposerBondWood, 200e18);
        // Escrow actually pulled the WOOD.
        assertEq(wood.balanceOf(address(escrow)), 200e18);
    }

    /// @notice With no WOOD allowance the escrow's transferFrom reverts, aborting
    ///         propose (fail-closed: no bond, no proposal).
    /// @dev OZ 5.x `SafeERC20._safeTransferFrom` runs with `bubble = true`, so it
    ///      re-raises the token's OWN revert data rather than wrapping it in
    ///      `SafeERC20FailedOperation` — the surfaced error is therefore
    ///      `ERC20InsufficientAllowance(escrow, 0, 200e18)`.
    function test_propose_insufficientWoodAllowanceReverts() public {
        vm.prank(agent);
        wood.approve(address(escrow), 0);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, 200e18)
        );
        governor.propose(
            address(vault),
            address(0),
            "uri",
            7 days,
            _envelope(1_000e6),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @notice A governor with no ledger wired skips both gates: no cap check, no
    ///         bond, `proposerBondWood` stays zero.
    function test_propose_ledgerUnwired_skipsGates() public {
        vm.prank(agent2);
        uint256 pid = unwiredGovernor.propose(
            address(unwiredVault),
            address(0),
            "uri",
            7 days,
            _envelope(1_000e6),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertEq(unwiredGovernor.getProposal(pid).proposerBondWood, 0);
    }

    // ── Review fixes: collaborative Drafts, escrow binding, gate branches ──

    /// @notice (a) A COLLABORATIVE proposal bonds like a solo one AND is still a
    ///         Draft afterwards. `_snapshotTierAndGate` (which locks the bond)
    ///         runs before `_storeCoProposers`, so the Draft's lifecycle fields
    ///         must already be complete by then — otherwise `_resolveStateView`
    ///         maps the zero `collaborationDeadline` to Expired.
    function test_propose_collaborativeDraft_bondsAndStaysDraft() public {
        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault), address(0), "uri", 7 days, _envelope(1_000e6), _execCalls(), _settleCalls(), _coProposers()
        );

        // Bond locked against the collaborative Draft.
        (address p, uint256 amt) = escrow.bondOf(address(governor), pid);
        assertEq(p, agent);
        assertEq(amt, 200e18);
        assertEq(governor.getProposal(pid).proposerBondWood, 200e18);

        // `getProposal` returns the RESOLVED state — Draft, not Expired.
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Draft));
        // Committing the resolution permissionlessly keeps it a Draft.
        governor.resolveProposalState(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Draft));
        // And the collaboration path is live: the co-proposer can approve, which
        // flips the Draft to Pending (it is the only co-proposer).
        vm.prank(coAgent);
        governor.approveCollaboration(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Pending));
    }

    /// @notice (b) Propose-reentrancy regression. `lockBond` pulls WOOD, so a WOOD
    ///         with a transfer hook re-enters the governor mid-`propose`. Before
    ///         the fix, `collaborationDeadline` was written by
    ///         `_storeCoProposers` AFTER the bond call, so the re-entrant
    ///         `resolveProposalState` saw `state == Draft` with a ZERO deadline,
    ///         committed Expired, and permanently bricked the proposal
    ///         (`approveCollaboration` → `NotDraftState` forever, bond stranded).
    ///         The deadline write is now hoisted into `propose`'s isCollaborative
    ///         branch, ahead of every external call.
    function test_propose_collaborative_reentrantWoodCannotExpireDraft() public {
        // Escrow bound to a hostile WOOD (immutable), authorized for `governor`.
        ReentrantWood rwood = new ReentrantWood();
        ProposerBondEscrow rEscrow = new ProposerBondEscrow(address(rwood), address(escrowAuth), address(ledger));
        governor.setBondEscrow(address(rEscrow));

        rwood.mint(agent, 1_000_000e18);
        vm.prank(agent);
        rwood.approve(address(rEscrow), type(uint256).max);

        uint256 pid = governor.proposalCount() + 1;
        rwood.arm(address(governor), pid);

        vm.prank(agent);
        uint256 got = governor.propose(
            address(vault), address(0), "uri", 7 days, _envelope(1_000e6), _execCalls(), _settleCalls(), _coProposers()
        );
        assertEq(got, pid);
        // The hook really did re-enter (otherwise this test proves nothing).
        assertTrue(rwood.reentered(), "reentry did not fire");
        assertTrue(rwood.reentryOk(), "reentrant resolveProposalState reverted");

        // The Draft survived: NOT committed to Expired.
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Draft));
        vm.prank(coAgent);
        governor.approveCollaboration(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Pending));
    }

    /// @notice (c) Ledger wired, escrow UNwired: the covered-TVL cap still binds,
    ///         but no bond is locked and `proposerBondWood` stays zero.
    function test_propose_escrowUnwired_capEnforcedNoBond() public {
        governor.setBondEscrow(address(0));

        // Cap still enforced.
        vm.prank(ledgerOwner);
        ledger.setCoveredTvlCapUsd(100e18);
        vm.prank(agent);
        vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
        governor.propose(
            address(vault),
            address(0),
            "uri",
            7 days,
            _envelope(1_000e6),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );

        // Under the cap: proposal goes through with no bond.
        vm.prank(ledgerOwner);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        assertEq(governor.getProposal(pid).proposerBondWood, 0);
        assertEq(governor.getProposal(pid).proposerBondEscrow, address(0));
        assertEq(wood.balanceOf(address(escrow)), 0);
    }

    /// @notice (d) `proposerBondBps == 0` → zero bond: no `lockBond` call at all
    ///         (the escrow has no record) and the stored fields stay zero.
    function test_propose_zeroBondBps_noLockBond() public {
        vm.prank(ledgerOwner);
        ledger.setProposerBondBps(0);

        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);

        assertEq(governor.getProposal(pid).proposerBondWood, 0);
        assertEq(governor.getProposal(pid).proposerBondEscrow, address(0));
        (address p, uint256 amt) = escrow.bondOf(address(governor), pid);
        assertEq(p, address(0));
        assertEq(amt, 0);
        assertEq(wood.balanceOf(address(escrow)), 0);
    }

    /// @notice (e) The bond binds to the escrow that HOLDS it. Re-pointing the
    ///         governor's live `_bondEscrow` must not rewrite the stored address
    ///         — Task 9's `reclaimProposerBond` releases against the stored one,
    ///         so an outstanding bond can never be stranded by a re-point.
    function test_propose_bondBindsToEscrowAtProposeTime() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        assertEq(governor.getProposal(pid).proposerBondEscrow, address(escrow));

        ProposerBondEscrow escrow2 = new ProposerBondEscrow(address(wood), address(escrowAuth), address(ledger));
        governor.setBondEscrow(address(escrow2));

        assertEq(governor.bondEscrow(), address(escrow2));
        // The existing proposal still points at the escrow holding its WOOD.
        assertEq(governor.getProposal(pid).proposerBondEscrow, address(escrow));
        (, uint256 amt) = escrow.bondOf(address(governor), pid);
        assertEq(amt, 200e18);
        assertEq(wood.balanceOf(address(escrow)), 200e18);
        assertEq(wood.balanceOf(address(escrow2)), 0);
    }

    // ── Task 9: approve quorum at execute + bond reclaim ──────────────────

    /// @dev Drive a proposal to Approved. `MockRegistryMinimal.reviewPeriod` is
    ///      0, so `reviewEnd == voteEnd` and the (unblocked) review resolves the
    ///      moment voting closes. Nobody votes — optimistic passage is exactly
    ///      what the quorum gate is meant to override for tier-2.
    function _toApproved(uint256 pid) internal {
        vm.warp(governor.getProposal(pid).voteEnd + 1);
        governor.resolveProposalState(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    /// @dev Stake each guardian and book a REAL commitment against `pid`
    ///      through the ledger's registry-only entrypoint. The quorum sums the
    ///      ledger's own committed shares, so coverage has to be booked, not
    ///      merely asserted by a mock approver list. At $0.05/WOOD, 20,000 WOOD
    ///      == $1,000 of slashable bond.
    function _seatApprovers(uint256 pid, address[] memory gs, uint256 ownStakeEach) internal {
        for (uint256 i = 0; i < gs.length; i++) {
            swood.setStake(gs[i], ownStakeEach);
            vm.prank(address(ledgerRegistry));
            ledger.recordApproval(address(governor), pid, gs[i]);
        }
    }

    /// @notice §3.3a: a tier-2 proposal cannot execute on silence. The cohort
    ///         produced ZERO approvers, so there is no identified, stake-backed
    ///         signer to hold liable (R1) — execution fails closed and the
    ///         proposal simply expires instead of executing unreviewed.
    function test_execute_tier2NoApprovers_reverts() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        _toApproved(pid);
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        governor.executeProposal(pid);
    }

    /// @notice §3.3a happy path: approvers whose aggregate slashableBond covers
    ///         the proposal's coverage let it through. $1,000 coverage vs one
    ///         guardian holding 20,000 WOOD ($1,000 at the haircut price).
    function test_execute_coveredByApprovers_succeeds() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        address[] memory gs = new address[](1);
        gs[0] = makeAddr("g1");
        _seatApprovers(pid, gs, 20_000e18);
        _toApproved(pid);
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice Under-covering approvers are as good as none: the quorum is a
    ///         DOLLAR test, not a headcount. One guardian at 10,000 WOOD ($500)
    ///         cannot cover $1,000 of extractable value.
    function test_execute_underCoveredApprovers_reverts() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        address[] memory gs = new address[](1);
        gs[0] = makeAddr("g1");
        _seatApprovers(pid, gs, 10_000e18); // $500 — half the needed coverage
        _toApproved(pid);
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        governor.executeProposal(pid);
    }

    /// @notice Below the tier threshold, optimistic passage is preserved — the
    ///         lane the §3.10 ROE gate depends on (spec §4 gate 2). Threshold 3
    ///         puts every tier below it, which is the same branch a tier-0/1
    ///         proposal takes at the launch threshold of 2.
    function test_execute_tierBelowThreshold_skipsQuorum() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        vm.prank(ledgerOwner);
        ledger.setQuorumTierThreshold(3); // no tier qualifies
        _toApproved(pid);
        governor.executeProposal(pid); // zero approvers, still executes
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice OPERATIONAL COUPLING, pinned deliberately: the quorum re-reads
    ///         the asset feed at EXECUTE time, so a feed that goes stale between
    ///         propose and execute blocks execution — even for a fully covered
    ///         proposal. Fail-closed is the intended direction (an unpriceable
    ///         asset cannot be coverage-checked), but it means feed liveness is
    ///         a prerequisite for the whole proposal lifecycle, not just for
    ///         propose. The proposal stays Approved and can execute once the
    ///         feed recovers, provided `executeBy` has not passed.
    function test_execute_staleFeedBlocksQuorum() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        address[] memory gs = new address[](1);
        gs[0] = makeAddr("g1");
        _seatApprovers(pid, gs, 20_000e18); // fully covered
        vm.prank(ledgerOwner);
        ledger.setAssetFeed(address(usdg), address(feed), 1 hours); // tight bound
        _toApproved(pid); // warps a full voting period ahead
        vm.expectRevert(IExposureLedger.StalePrice.selector);
        governor.executeProposal(pid);
    }

    // ── ADR 2026-07-27: quorumTierThreshold == 0 (coverage required at EVERY tier) ──

    /// @dev Wires a TierRegistry and certifies BOTH the execute and settlement
    ///      calls at `tier` with `bound` bps, so the proposal resolves to that
    ///      tier with `requiredCoverage = maxCapital × 2 × bound / 10_000`.
    ///      Created inside the tests rather than in `setUp` so the rest of this
    ///      suite keeps its simpler tier-2 / full-notional arithmetic.
    ///
    ///      Two-step certification (design.md / tasks.md 2.1): the test
    ///      contract IS the registry owner (`new TierRegistry(address(this))`),
    ///      so no prank is needed — propose, warp past the pinned `readyAt`
    ///      (via `vm.getBlockTimestamp()`, never a cached `block.timestamp`
    ///      local — this repo's optimizer CSEs it across `vm.warp`), execute.
    ///      Called before proposal creation in every site, so the forward warp
    ///      never interacts with an in-flight proposal's execution window.
    function _wireTierRegistryCertifiedAt(uint8 tier, uint16 bound) internal returns (TierRegistry reg) {
        reg = new TierRegistry(address(this));
        governor.setTierRegistry(address(reg)); // test contract is the factory
        reg.setAdapterAllowed(address(targetToken), true);
        reg.setAdapterAllowed(address(usdg), true);
        reg.proposeCertification(address(targetToken), targetToken.approve.selector, tier, bound, address(0), address(targetToken).codehash);
        reg.proposeCertification(address(usdg), usdg.approve.selector, tier, bound, address(0), address(usdg).codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(address(targetToken), targetToken.approve.selector);
        reg.certify(address(usdg), usdg.approve.selector);
    }

    /// @notice The launch default is 0 — every tier fail-closed. The §3.10 ROE
    ///         gate that held this at 2 is resolved (ADR 2026-07-27).
    function test_quorumTierThresholdDefaultsToZero() public view {
        assertEq(ledger.quorumTierThreshold(), 0);
    }

    /// @notice THE enforcement gap this ADR closes. A tier-0 proposal carrying
    ///         non-zero `requiredCoverage` and NO covering approver used to
    ///         execute optimistically, because the quorum was only checked at
    ///         tier 2. Coverage was always sized correctly per tier; it simply
    ///         was not enforced below the threshold. At threshold 0 it is.
    function test_execute_tier0WithCoverageAndNoApprovers_reverts() public {
        _wireTierRegistryCertifiedAt(0, 500); // closed-loop, 5% extractable
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        assertEq(governor.getProposalTier(pid), 0);
        // (500 exec + 500 settle) bps of 1_000e6 == $100 of extractable value.
        assertEq(governor.getRequiredCoverage(pid), 100e6);

        _toApproved(pid);
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        governor.executeProposal(pid);
    }

    /// @notice Same tier-0 proposal, but with an approver whose slashable bond
    ///         actually covers it, executes. The guardian layer is mandatory at
    ///         tier 0 now, not impassable. 2,000 WOOD == $100 at $0.05.
    function test_execute_tier0WithCoveringApprover_succeeds() public {
        _wireTierRegistryCertifiedAt(0, 500);
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        address[] memory gs = new address[](1);
        gs[0] = makeAddr("g1");
        _seatApprovers(pid, gs, 2_000e18); // $100 — exactly the coverage needed

        _toApproved(pid);
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice Review finding M-1, preserved: `requiredCoverage == 0` still
    ///         passes optimistically at threshold 0, with zero approvers. Not an
    ///         exception to the rule above but the same rule evaluated at zero —
    ///         a proposal that can extract nothing has nothing to underwrite,
    ///         and demanding a covering signer for it is pure throughput loss.
    ///
    /// @dev    Reached by ROUNDING, not by a zero bound: `TierRegistry.certify`
    ///         rejects `extractableBoundBps == 0` (`BoundRequired`), so the only
    ///         way to a zero coverage figure is a `maxCapital` small enough that
    ///         `maxCapital × boundBps / 10_000` floors to 0. That makes this the
    ///         genuine reachable case rather than a synthetic one.
    function test_execute_zeroRequiredCoverage_passesOptimistically() public {
        _wireTierRegistryCertifiedAt(0, 1); // 1 bp — the smallest certifiable bound
        // 1 unit × 1 bp / 10_000 == 0 after integer division, on both calls.
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1);
        assertEq(governor.getProposalTier(pid), 0);
        assertEq(governor.getRequiredCoverage(pid), 0);

        _toApproved(pid);
        governor.executeProposal(pid); // no approvers, still executes
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice An unwired governor keeps Plan A behaviour — no quorum at all.
    function test_execute_ledgerUnwired_skipsQuorum() public {
        uint256 pid = _proposeSolo(unwiredGovernor, address(unwiredVault), agent2, 1_000e6);
        vm.warp(unwiredGovernor.getProposal(pid).voteEnd + 1);
        unwiredGovernor.executeProposal(pid);
        assertEq(uint256(unwiredGovernor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice §3.9: an EXPIRED proposal returns its bond. Expiry moved no
    ///         funds and is not a conviction — forfeiture belongs to the
    ///         challenge game (Plan C), not to the lifecycle.
    function test_reclaimBond_afterExpiry() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        uint256 balBefore = wood.balanceOf(agent);
        vm.warp(governor.getProposal(pid).executeBy + 1); // Approved -> Expired (lazy)
        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), balBefore + 200e18);
        (, uint256 amt) = escrow.bondOf(address(governor), pid);
        assertEq(amt, 0);
        assertEq(governor.getProposal(pid).proposerBondWood, 0);
    }

    /// @notice A guardian block is not a conviction either — a Cancelled
    ///         proposal returns its bond in full.
    function test_reclaimBond_afterCancel() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        uint256 balBefore = wood.balanceOf(agent);
        vm.prank(agent);
        governor.cancelProposal(pid);
        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), balBefore + 200e18);
    }

    /// @notice The bond stays locked while the proposal can still execute.
    function test_reclaimBond_activeProposalReverts() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        vm.expectRevert(ISyndicateGovernor.ProposalNotTerminal.selector);
        governor.reclaimProposerBond(pid);
    }

    /// @notice Reclaim is idempotent: zeroing the stored amount before the
    ///         external release makes a second call revert rather than
    ///         double-pay (and closes a re-entrant double-release).
    function test_reclaimBond_idempotent() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        vm.prank(agent);
        governor.cancelProposal(pid);
        governor.reclaimProposerBond(pid);
        vm.expectRevert(ISyndicateGovernor.NoBondToReclaim.selector);
        governor.reclaimProposerBond(pid);
    }

    /// @notice Permissionless: a third party may accelerate the refund, but the
    ///         escrow pays the proposer it recorded — never the caller.
    function test_reclaimBond_permissionlessPaysProposer() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        vm.prank(agent);
        governor.cancelProposal(pid);
        address stranger = makeAddr("stranger");
        uint256 agentBefore = wood.balanceOf(agent);
        vm.prank(stranger);
        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), agentBefore + 200e18);
        assertEq(wood.balanceOf(stranger), 0);
    }

    /// @notice The Task 8 escrow binding pays off here: after the governor is
    ///         re-pointed at a NEW escrow, the old proposal still reclaims from
    ///         the escrow that actually holds its WOOD. Releasing against the
    ///         live slot would strand it forever (no owner, no discretionary
    ///         exit, bond keyed by (governor, proposalId)).
    function test_reclaimBond_releasesAgainstStoredEscrow() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        ProposerBondEscrow escrow2 = new ProposerBondEscrow(address(wood), address(escrowAuth), address(ledger));
        governor.setBondEscrow(address(escrow2));

        uint256 balBefore = wood.balanceOf(agent);
        vm.prank(agent);
        governor.cancelProposal(pid);
        governor.reclaimProposerBond(pid);

        assertEq(wood.balanceOf(agent), balBefore + 200e18);
        assertEq(wood.balanceOf(address(escrow)), 0); // drained from the ORIGINAL escrow
    }

    /// @notice EXECUTED is the state a bond is most likely to be prematurely
    ///         reclaimed from — capital is deployed and the strategy is live, so
    ///         the bond must stay locked until settlement (review finding I-6).
    function test_reclaimBond_executedProposalReverts() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        address[] memory gs = new address[](1);
        gs[0] = makeAddr("g1");
        _seatApprovers(pid, gs, 20_000e18);
        _toApproved(pid);
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));

        vm.expectRevert(ISyndicateGovernor.ProposalNotTerminal.selector);
        governor.reclaimProposerBond(pid);
    }

    /// @notice REJECTED returns the bond in full. A veto is the LP body
    ///         declining the strategy, not a finding of misconduct — forfeiture
    ///         belongs exclusively to a passed challenge (Plan C).
    function test_reclaimBond_afterRejected() public {
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        uint256 balBefore = wood.balanceOf(agent);

        // lp1 holds the entire share supply; voting Against clears the 4000 bps
        // veto threshold, so the proposal resolves Rejected at voteEnd.
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        vm.warp(governor.getProposal(pid).voteEnd + 1);
        governor.resolveProposalState(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Rejected));

        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), balBefore + 200e18);
    }

    /// @notice A proposal that never locked a bond (zero bond bps) has nothing
    ///         to reclaim — the terminal check passes, the amount check doesn't.
    function test_reclaimBond_noBondReverts() public {
        vm.prank(ledgerOwner);
        ledger.setProposerBondBps(0);
        uint256 pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        assertEq(governor.getProposal(pid).proposerBondWood, 0);
        vm.prank(agent);
        governor.cancelProposal(pid);
        vm.expectRevert(ISyndicateGovernor.NoBondToReclaim.selector);
        governor.reclaimProposerBond(pid);
    }

    // ── Reclaim vs. the challenge game's filing deadline (issue #94) ───────

    /// @dev Executed and then self-settled an hour in — the terminal state a
    ///      proposer reaches fastest, and therefore the one every reclaim gate
    ///      below is measured against.
    function _executeThenSettle() internal returns (uint256 pid) {
        pid = _proposeSolo(governor, address(vault), agent, 1_000e6);
        address[] memory gs = new address[](1);
        gs[0] = makeAddr("g1");
        _seatApprovers(pid, gs, 20_000e18);
        _toApproved(pid);
        governor.executeProposal(pid);

        vm.warp(governor.getProposal(pid).executedAt + 1 hours + 1);
        vm.prank(agent);
        governor.settleProposal(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
    }

    /// @notice REGRESSION, and the shape of every deployment with no game
    ///         wired: with `coverageFreezer` unset the filing-deadline gate is
    ///         skipped entirely and an executed proposal reclaims on exactly
    ///         the schedule it always did — at `executedAt + challengeWindow`,
    ///         not a second later.
    ///
    ///         The skip is structural, not charitable. Without a freezer
    ///         nothing can call `ExposureLedger.freezeCoverage` (`onlyFreezer`)
    ///         and nothing can reach `ProposerBondEscrow.forfeitBond` (the
    ///         caller must BE the freezer), so no conviction is reachable and
    ///         there is nothing for the gate to protect. An unwired or
    ///         rotated-away freezer must never strand an honest bond.
    function test_reclaimBond_unsetCoverageFreezer_reclaimsOnTheOrdinarySchedule() public {
        assertEq(ledger.coverageFreezer(), address(0), "this fixture wires no game");
        uint256 pid = _executeThenSettle();
        uint256 opensAt = governor.getProposal(pid).executedAt + ledger.challengeWindow();
        uint256 balBefore = wood.balanceOf(agent);

        vm.warp(opensAt - 1);
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        governor.reclaimProposerBond(pid);

        vm.warp(opensAt);
        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), balBefore + 200e18, "unchanged schedule: opens AT the ledger's deadline");
    }

    /// @notice The unchallenged case WITH a game wired. `challengeableUntil` is
    ///         zero for a key the game never touched and zero is NOT a
    ///         sentinel, so the gate collapses to the game's ordinary window
    ///         and an honest proposer waits no longer than it did before.
    ///
    ///         The one second is the strict comparison, and it is deliberate:
    ///         `ChallengeGame.file` admits while `block.timestamp <= deadline`,
    ///         so at the deadline itself an accusation is still legal.
    function test_reclaimBond_gameWiredNeverChallenged_opensOneSecondPastTheDeadline() public {
        uint256 pid = _executeThenSettle();
        MockFilingDeadline stubGame = new MockFilingDeadline(ledger.challengeWindow());
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(stubGame));

        bytes32 rk = keccak256(abi.encode(address(governor), pid));
        assertEq(stubGame.challengeableUntil(rk), 0, "an untouched key reads zero");

        uint256 deadline = governor.getProposal(pid).executedAt + ledger.challengeWindow();
        vm.warp(deadline);
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        governor.reclaimProposerBond(pid);

        uint256 balBefore = wood.balanceOf(agent);
        vm.warp(deadline + 1);
        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), balBefore + 200e18);
    }

    /// @notice DESIGN D2 — why the gate is a `max` and not `challengeableUntil`
    ///         alone. The two windows can diverge with no `Inconclusive`
    ///         anywhere in the picture: `ChallengeGame`'s own setters floor its
    ///         window under the ledger's, but `ExposureLedger.setChallengeWindow`
    ///         floors only against the registry's review period and has no
    ///         game-side check, so the ledger owner can drop the ledger's window
    ///         below the game's afterwards.
    ///
    ///         Here `challengeableUntil` is ZERO throughout — a gate reading
    ///         only that value would have released on the ledger's deadline
    ///         while the game still admitted a filing for another week. The
    ///         divergence is set up from the game's side (a stub with a longer
    ///         window) because it is the identical condition and does not
    ///         require an `ExposureLedger` setter whose floor this fixture's
    ///         EOA registry cannot answer.
    function test_reclaimBond_gameWindowAboveTheLedgers_waitsForTheGame() public {
        uint256 pid = _executeThenSettle();
        uint256 gameWindow = ledger.challengeWindow() + 7 days;
        MockFilingDeadline stubGame = new MockFilingDeadline(gameWindow);
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(stubGame));

        uint256 executedAt = governor.getProposal(pid).executedAt;
        assertEq(
            stubGame.challengeableUntil(keccak256(abi.encode(address(governor), pid))),
            0,
            "no Inconclusive here -- the divergence IS the two windows"
        );

        // Both original gates are open at the ledger's deadline...
        vm.warp(executedAt + ledger.challengeWindow());
        assertFalse(ledger.isCoverageFrozen(address(governor), pid), "and nothing is frozen");
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        governor.reclaimProposerBond(pid);

        // ...and the hold runs to the GAME's deadline, strictly.
        vm.warp(executedAt + gameWindow);
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        governor.reclaimProposerBond(pid);

        uint256 balBefore = wood.balanceOf(agent);
        vm.warp(executedAt + gameWindow + 1);
        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), balBefore + 200e18);
    }

    /// @notice The other arm of the same `max`: a `challengeableUntil` raised
    ///         above the ordinary window — what `ChallengeGame._refundAll`
    ///         writes on an `Inconclusive` unwind — holds the bond past
    ///         `executedAt + challengeWindow`. Placed exactly, from a stub; the
    ///         real unwind that produces it is in `ChallengeEndToEnd.t.sol`.
    function test_reclaimBond_challengeableUntilAboveTheWindow_waitsForIt() public {
        uint256 pid = _executeThenSettle();
        MockFilingDeadline stubGame = new MockFilingDeadline(ledger.challengeWindow());
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(stubGame));

        uint256 executedAt = governor.getProposal(pid).executedAt;
        uint256 rearmed = executedAt + 38 days; // issue #94's own figure
        stubGame.setChallengeableUntil(keccak256(abi.encode(address(governor), pid)), rearmed);

        vm.warp(executedAt + ledger.challengeWindow() + 1);
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        governor.reclaimProposerBond(pid);

        vm.warp(rearmed);
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        governor.reclaimProposerBond(pid);

        uint256 balBefore = wood.balanceOf(agent);
        vm.warp(rearmed + 1);
        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), balBefore + 200e18);
    }

    /// @notice FAIL CLOSED. A non-zero freezer that cannot answer the game's
    ///         views blocks the reclaim rather than waving it through — a
    ///         freezer we cannot read is indistinguishable from one that lies,
    ///         and under fail-open a lying freezer releases early. Matches this
    ///         function's existing posture for an unset ledger, and is
    ///         recoverable the same way: the ledger owner rotates the slot.
    function test_reclaimBond_freezerThatCannotAnswer_failsClosedButIsRecoverable() public {
        uint256 pid = _executeThenSettle();
        address mute = address(new MuteFreezer());
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(mute);

        vm.warp(governor.getProposal(pid).executedAt + ledger.challengeWindow() + 365 days);
        vm.expectRevert();
        governor.reclaimProposerBond(pid);
        assertEq(governor.getProposal(pid).proposerBondWood, 200e18, "nothing was released");

        // Not a permanent strand: rotating the slot reopens the ordinary path.
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(0));
        uint256 balBefore = wood.balanceOf(agent);
        governor.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), balBefore + 200e18);
    }
}

/// @notice Hostile WOOD: `transferFrom` re-enters the governor's permissionless
///         `resolveProposalState` before moving the tokens, exactly as a
///         transfer-hook token would. Mirrors the PoC from review.
contract ReentrantWood is ERC20Mock {
    address public governor;
    uint256 public pid;
    bool public reentered;
    bool public reentryOk;

    constructor() ERC20Mock("Reentrant Sherwood", "rWOOD", 18) {}

    function arm(address governor_, uint256 pid_) external {
        governor = governor_;
        pid = pid_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (governor != address(0) && !reentered) {
            reentered = true;
            // Best-effort: swallow a revert so the outer propose still completes
            // and the test can assert on the resulting proposal state. `reentryOk`
            // records whether the callback itself succeeded.
            (reentryOk,) = governor.call(abi.encodeWithSignature("resolveProposalState(uint256)", pid));
        }
        return super.transferFrom(from, to, value);
    }
}
