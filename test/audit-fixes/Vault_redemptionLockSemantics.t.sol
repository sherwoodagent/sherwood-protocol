// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @title Vault_redemptionLockSemantics — MS-H4 / SHE-258 regression
/// @notice The redeem lock covers Draft → Pending → GuardianReview → Approved →
///         Executed via `openProposalCount`: no share is burned while a proposal
///         is open, so SHE-205's exit-inflated veto bar is closed for every state.
///         The deposit lock covers Executed only (SHE-287): a deposit after the
///         stamp buys no vote weight, so the audit's late-deposit window is closed
///         by the snapshot.
/// @dev Drives the vault directly with mocked governor reads. The two
///      governor selectors that matter:
///        - `openProposalCount()` != 0 from Draft through Executed drives the
///          redeem lock and the owner rescue gates.
///        - `getActiveProposal()` != 0 (Executed) drives the deposit lock and
///          `activeStrategyAdapter()`.
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

    /// @dev Mocks the governor view selectors used by the vault locks.
    ///      `openCount` drives the redeem lock (Pending..Executed); `active`
    ///      drives the deposit lock and selects the strategy adapter. Optional
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

    // ───────────────── MS-H4 revisited (SHE-287): deposits open until execute ─────────────────

    /// @notice Pending..Approved (`openProposalCount > 0`, nothing executed): the vault
    ///         still holds everything, so the share price is knowable and instant deposit
    ///         stays open. A deposit here buys no vote weight — weight is read at the
    ///         propose snapshot — so MS-H4's late-deposit concern no longer applies.
    ///         Redeem is the side that stays locked (the voter stays at risk).
    function test_deposit_allowedWhilePendingRedeemStillLocked() public {
        _mockState({active: false, openCount: 1});
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "instant deposit open before execute");
        assertEq(vault.maxRedeem(alice), 0, "instant redeem locked from Pending");
        assertFalse(vault.depositsLocked(), "deposit lock waits for execute");
        assertTrue(vault.redemptionsLocked(), "redeem lock is on");
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

    /// @notice Settled (terminal) — `getActiveProposal` clears and the counters drop.
    ///         Deposits MUST succeed again.
    function test_deposit_allowedAfterSettle() public {
        // Executed: instant deposit closed.
        _mockState({active: true, openCount: 1});
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
    ///         MUST revert: the voter stays at risk for the whole cycle it voted
    ///         on (SHE-205). Deposits are open in the same window — the two
    ///         locks are not symmetric.
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
        vm.expectPartialRevert(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector);
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

    /// @notice A governor that cannot report `proposalCount()` reverts `requestRedeem` outright:
    ///         nothing is queued under a zero tag that no settlement would ever stamp.
    function test_requestRedeemRevertsWhenTheGovernorCannotReportAProposalCount() public {
        VaultWithdrawalQueue queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        uint256 shares = vault.balanceOf(alice);
        uint256 nextId = queue.nextRequestId();

        _mockState({active: false, openCount: 1}); // Pending: the tag comes from proposalCount()
        bytes memory reason = abi.encodeWithSelector(bytes4(keccak256("CountUnavailable()")));
        vm.mockCallRevert(MOCK_GOVERNOR, abi.encodeWithSignature("proposalCount()"), reason);

        vm.prank(alice);
        vm.expectRevert(reason);
        vault.requestRedeem(shares, alice);

        assertEq(vault.balanceOf(alice), shares, "shares never left the holder");
        assertEq(queue.nextRequestId(), nextId, "nothing queued");
    }

    /// @notice The deposit lane fails closed the same way: `requestDeposit` only opens once
    ///         a proposal executes, so its gate reads `getActiveProposal()`; an unreadable
    ///         governor reverts before any asset is escrowed.
    function test_requestDepositRevertsWhenTheGovernorCannotReportTheActiveProposal() public {
        VaultWithdrawalQueue queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 nextId = queue.nextRequestId();

        _mockState({active: true, openCount: 1}); // Executed: the only state the lane is open in
        bytes memory reason = abi.encodeWithSelector(bytes4(keccak256("ActiveUnavailable()")));
        vm.mockCallRevert(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), reason);

        vm.prank(alice);
        vm.expectRevert(reason);
        vault.requestDeposit(1_000e6, alice);

        assertEq(usdc.balanceOf(alice), aliceBefore, "assets never left the depositor");
        assertEq(queue.nextRequestId(), nextId, "nothing queued");
    }
}
