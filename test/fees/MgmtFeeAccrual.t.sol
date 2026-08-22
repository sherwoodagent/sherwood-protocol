// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {FeeConstants} from "../../src/FeeConstants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice Covers `specs/management-fee/spec.md`: the accrual base is
///         time-weighted over fund assets, it is consumed and reset at
///         settlement, and capital idle between proposals accrues nothing.
///
/// @dev Every test reads the clock with `vm.getBlockTimestamp()` rather than
///      caching `block.timestamp` in a local. Under this repo's optimizer
///      config the compiler CSEs `block.timestamp` ACROSS `vm.warp`, so a
///      cached "before" anchor silently becomes the post-warp value. Warps are
///      forward-only for the same family of reasons.
contract MgmtFeeAccrualTest is Test {
    SyndicateVault internal vault;
    VaultWithdrawalQueue internal queue;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    MockAgentRegistry internal agentRegistry;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant MOCK_GOVERNOR = address(0xF00D);
    address internal constant STRAT = address(0x57A7);
    uint256 internal constant PID = 1;

    uint256 internal constant YEAR = 365 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        _setLocked(false);

        usdc.mint(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(bob, 10_000_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setLocked(bool locked) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(locked ? PID : uint256(0))
        );
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(locked ? uint256(1) : 0));
        if (locked) {
            ISyndicateGovernor.StrategyProposal memory p;
            p.id = PID;
            p.vault = address(vault);
            p.strategy = STRAT;
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, PID), abi.encode(p)
            );
            // `_activeStrategy` resolves the active strategy through the lighter
            // `strategyOf(pid)` getter, not `getProposal`.
            vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("strategyOf(uint256)", PID), abi.encode(STRAT));
        }
    }

    /// @dev Open a proposal and start the management-fee clock, the way
    ///      `executeProposal` does.
    function _executeProposal() internal {
        _setLocked(true);
        vm.prank(MOCK_GOVERNOR);
        vault.startManagementAccrual();
    }

    function _settle() internal returns (uint256 assetSeconds) {
        vm.prank(MOCK_GOVERNOR);
        assetSeconds = vault.consumeManagementAccrual();
        _setLocked(false);
    }

    /// @dev The fee the governor will charge for a given integral.
    function _feeFor(uint256 assetSeconds, uint256 rateBps) internal pure returns (uint256) {
        return assetSeconds * rateBps / (FeeConstants.BPS_DENOMINATOR * YEAR);
    }

    // ── Time weighting ──

    /// @notice Half the duration owes half the fee.
    function test_halfTheDurationOwesHalfTheFee() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _executeProposal();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 long = _settle();

        _executeProposal();
        vm.warp(vm.getBlockTimestamp() + 15 days);
        uint256 short = _settle();

        assertEq(long, 2 * short, "30 days should integrate to exactly twice 15 days on the same base");
    }

    /// @notice A full year at a flat base charges exactly the headline rate.
    function test_aFullYearAtTheHeadlineRateChargesTwoPercent() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _executeProposal();
        vm.warp(vm.getBlockTimestamp() + YEAR);
        uint256 assetSeconds = _settle();

        // 2%/yr on $1M is $20k.
        assertApproxEqAbs(_feeFor(assetSeconds, 200), 20_000e6, 1, "2%/yr on 1M should be 20k");
    }

    // ── Consume and reset ──

    /// @notice Two consecutive proposals must not double-charge the first
    ///         proposal's accrual.
    function test_consecutiveProposalsDoNotDoubleChargeTheFirstAccrual() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _executeProposal();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 first = _settle();

        _executeProposal();
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 second = _settle();

        assertEq(first, 1_000_000e6 * uint256(30 days));
        assertEq(second, 1_000_000e6 * uint256(10 days), "the second charge must cover only its own window");
    }

    function test_consumeLeavesNothingBehind() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _executeProposal();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _settle();

        assertEq(vault.managementAssetSeconds(), 0, "accrual must be zeroed by consume");
        assertFalse(vault.isAccruingManagementFee(), "the clock must stop at settle");
    }

    // ── Idle capital ──

    /// @notice The cooldown gap between two proposals generates no fee.
    function test_theGapBetweenProposalsGeneratesNoFee() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _executeProposal();
        vm.warp(vm.getBlockTimestamp() + 10 days);
        _settle();

        // Idle for 100 days between proposals.
        vm.warp(vm.getBlockTimestamp() + 100 days);
        assertEq(vault.managementAssetSeconds(), 0, "idle capital must accrue nothing");

        _executeProposal();
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 second = _settle();

        assertEq(second, 1_000_000e6 * uint256(10 days), "the idle gap must not leak into the next proposal");
    }

    /// @notice A dormant fund — depositors in, agent never proposes — charges
    ///         nothing. Accepted behaviour, not a defect (design.md Decision 4).
    function test_aDormantFundChargesNothing() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        vm.warp(vm.getBlockTimestamp() + 365 days);

        assertFalse(vault.isAccruingManagementFee());
        assertEq(vault.managementAssetSeconds(), 0, "no proposal, no management fee");
    }

    // ── Access control ──

    function test_onlyGovernorMayStartAccrual() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.startManagementAccrual();
    }

    function test_onlyGovernorMayConsumeAccrual() public {
        _executeProposal();
        vm.prank(alice);
        vm.expectRevert();
        vault.consumeManagementAccrual();
    }

    // ── The live view ──

    /// @notice The view must include the interval still in progress, otherwise
    ///         an integrator polling it would see the fee move in steps rather
    ///         than continuously.
    function test_theViewIncludesTheInProgressInterval() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _executeProposal();
        assertEq(vault.managementAssetSeconds(), 0, "nothing has elapsed yet");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(vault.managementAssetSeconds(), 1_000_000e6 * uint256(1 days), "one day at the full base");
    }
}
