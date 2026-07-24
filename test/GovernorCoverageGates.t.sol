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
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "./mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

/// @dev Minimal sWOOD read surface the ExposureLedger constructor consumes.
///      `coolDownPeriod` (45d) covers epochLength (28d) + challengeWindow (14d).
contract MockSwood {
    mapping(address => uint256) public guardianStake;
    mapping(address => uint256) public delegatedInbound;
    uint256 public maxDelegatedSlashBps = 2000;
    uint256 public coolDownPeriod = 45 days;
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
    address public agent = makeAddr("agent");
    address public agent2 = makeAddr("agent2");
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
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.05e8); // $0.05, conservative haircut
        ledger.setAssetFeed(address(usdg), address(feed), 1 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18); // $10M — generous
        vm.stopPrank();

        // ── The wired syndicate (governor + vault). Test contract is factory.
        (governor, vault) = _deploySyndicate();

        // ── Escrow: auth registry recognizes the wired governor only.
        escrowAuth = new MockEscrowAuth();
        escrowAuth.set(address(governor), true);
        escrow = new ProposerBondEscrow(address(wood), address(escrowAuth));

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
    function test_propose_insufficientWoodAllowanceReverts() public {
        vm.prank(agent);
        wood.approve(address(escrow), 0);
        vm.prank(agent);
        vm.expectRevert(); // SafeERC20 transferFrom failure inside lockBond
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
}
