// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @title Vault_redemptionLockSemantics — MS-H4 / SHE-258 regression
/// @notice Both the deposit-side and the redeem-side lock cover the full
///         Pending → GuardianReview → Approved → Executed window via
///         `openProposalCount`: no share is minted or burned while a proposal
///         is open, so the audit's late-deposit window and SHE-205's
///         exit-inflated veto bar are both closed for all four states.
/// @dev Drives the vault directly with mocked governor reads. The two
///      governor selectors that matter:
///        - `getActiveProposal()` = 0 outside Executed, != 0 during Executed
///          (drives `activeStrategyAdapter()` only).
///        - `openProposalCount()` = 0 outside Pending..Executed, != 0 from
///          Pending through Executed (drives BOTH locks).
contract VaultRedemptionLockSemanticsTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address constant MOCK_GOVERNOR = address(0xF00D);

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = SyndicateVault(payable(address(proxy)));

        // factory.governor() returns the mock governor address.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        // Inert post-retirement (issue #54): nothing calls `priceRouter()` anymore.
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));
        // Default: no active proposal anywhere — deposits/withdraws unlocked.
        _mockState({active: false, openCount: 0});

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Mocks the two governor view selectors used by the vault locks.
    ///      `openCount` drives both locks (Pending..Executed); `active` only
    ///      selects the strategy adapter for Executed. Optional
    ///      `strategy` parameter (defaults to address(0)) is the address the
    ///      vault will resolve as `activeStrategyAdapter()` via
    ///      `strategyOf(activePid)`.
    function _mockState(bool active, uint256 openCount) internal {
        _mockStateWithStrategy(active, openCount, address(0));
    }

    function _mockStateWithStrategy(bool active, uint256 openCount, address strategy) internal {
        uint256 pid = active ? uint256(1) : uint256(0);
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(pid));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(openCount));
        if (active) {
            vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("strategyOf(uint256)", pid), abi.encode(strategy));
        }
    }

    // ──────────────────────── MS-H4: deposit lock during Pending ────────────────────────

    /// @notice Pending state: `openProposalCount > 0` but no active proposal yet.
    ///         Deposits MUST revert (closes the late-deposit window).
    function test_deposit_revertsDuringPending() public {
        _mockState({active: false, openCount: 1});
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice GuardianReview state: same `openProposalCount > 0`, no active
    ///         proposal yet. Deposits MUST revert.
    function test_deposit_revertsDuringGuardianReview() public {
        _mockState({active: false, openCount: 1});
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice Approved state: same `openProposalCount > 0`, no active
    ///         proposal yet. Deposits MUST revert (this is the audit's
    ///         worst-case late-deposit window: the very next block can
    ///         `executeProposal` and pull the fresh USDC into a strategy).
    function test_deposit_revertsDuringApproved() public {
        _mockState({active: false, openCount: 1});
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice Executed state: instant deposits revert. During an active
    ///         proposal LPs must use the async deposit queue — the vault never
    ///         mints against an unrealized, strategy-influenced NAV (the V2
    ///         live-NAV redesign removed the live-deposit-forward path).
    function test_deposit_revertsDuringExecuted() public {
        _mockState({active: true, openCount: 1});
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice Settled (terminal) — `openProposalCount` decrements to 0,
    ///         `getActiveProposal` clears. Deposits MUST succeed.
    function test_deposit_allowedAfterSettle() public {
        // Simulate Pending→Approved blocked, then settled (counter drops).
        _mockState({active: false, openCount: 1});
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);

        // Settled: counter back to 0, adapter cleared.
        _mockState({active: false, openCount: 0});
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "deposit unlocked post-settle");
    }

    // ──────────────────────── MS-H4: withdraw lock asymmetry ────────────────────────

    /// @notice Withdrawals during Pending..Approved (no active proposal yet)
    ///         MUST revert: a share that leaves mid-vote shrinks the supply the
    ///         veto bar was snapshotted against (SHE-205). Symmetric with the
    ///         deposit lock.
    function test_withdraw_revertsDuringPending() public {
        _mockState({active: false, openCount: 0});
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        uint256 shares = vault.balanceOf(alice);

        _mockState({active: false, openCount: 1});
        assertTrue(vault.redemptionsLocked(), "locked from propose");
        assertEq(vault.maxWithdraw(alice), 0, "withdraw blocked during Pending");
        assertEq(vault.maxRedeem(alice), 0, "redeem blocked during Pending");

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);
    }

    /// @notice Withdrawals during Executed MUST revert — instant exit is closed
    ///         during a proposal; LPs use the async redeem queue.
    function test_withdraw_revertsDuringExecuted() public {
        _mockState({active: false, openCount: 0});
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        _mockState({active: true, openCount: 1});
        // OZ ERC4626's maxRedeem-zero path causes ERC4626ExceededMaxRedeem.
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(1, alice, alice);
    }

    // ──────────────────────── Sanity: rescue lock unchanged ────────────────────────

    /// @notice Rescue paths gate on `redemptionsLocked()`, which now rises at
    ///         propose: blocked during Pending as well as Executed.
    function test_rescueERC20_blockedDuringPending() public {
        ERC20Mock other = new ERC20Mock("Other", "OTH", 18);
        other.mint(address(vault), 100e18);

        _mockState({active: false, openCount: 1}); // Pending
        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.RedemptionsLocked.selector);
        vault.rescueERC20(address(other), owner, 100e18);
    }

    function test_rescueERC20_blockedDuringExecuted() public {
        ERC20Mock other = new ERC20Mock("Other", "OTH", 18);
        other.mint(address(vault), 100e18);

        _mockState({active: true, openCount: 1}); // Executed
        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.RedemptionsLocked.selector);
        vault.rescueERC20(address(other), owner, 100e18);
    }
}
