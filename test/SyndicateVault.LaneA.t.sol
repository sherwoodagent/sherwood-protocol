// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {VaultWithdrawalQueue} from "../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

/// @notice Mock PriceRouter returning a configurable strategy valuation.
contract MockLaneARouter {
    uint256 public v;
    bool public ok;

    function set(uint256 v_, bool ok_) external {
        v = v_;
        ok = ok_;
    }

    function valueStrategy(address) external view returns (uint256, bool) {
        return (v, ok);
    }
}

/// @title VaultLaneATest
/// @notice Unit tests for the Lane A instant-lane on the vault: live-NAV pricing
///         via the PriceRouter during a proposal, instant entry/exit when
///         available, fail-closed to Lane B otherwise, and the G1 per-share
///         lockup (Lane A entry → no exit until the proposal settles).
contract VaultLaneATest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockLaneARouter router;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address constant MOCK_GOVERNOR = address(0xF00D);
    address constant STRAT = address(0x57A7);
    uint256 constant PID = 1;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MockLaneARouter();

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

        // Test contract is the factory: expose governor() + priceRouter().
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        _setLocked(false);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(bob, 1_000_000e6);
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
        }
    }

    function _lockLaneA(uint256 liveValue) internal {
        _setLocked(true);
        router.set(liveValue, true);
    }

    // ── totalAssets ──

    function test_totalAssets_floatOnly_whenLaneAUnavailable() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        _setLocked(true);
        router.set(500e6, false); // priced but not instant-eligible
        assertEq(vault.totalAssets(), 1_000e6, "Lane A off, float only");
    }

    function test_totalAssets_includesLiveValue_whenLaneA() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        _lockLaneA(500e6);
        assertEq(vault.totalAssets(), 1_500e6, "float + live position value");
    }

    // ── instant deposit ──

    function test_deposit_instant_duringLaneA() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        _lockLaneA(500e6);

        // Bob deposits instantly at live NAV during the proposal.
        vm.prank(bob);
        uint256 shares = vault.deposit(300e6, bob);
        assertGt(shares, 0, "instant Lane A deposit mints");
        // Bob's shares are Lane-A-locked: he can't queue an exit this proposal.
        vm.prank(bob);
        vm.expectRevert(ISyndicateVault.SharesLocked.selector);
        vault.requestRedeem(shares, bob);
    }

    function test_deposit_reverts_whenLockedNoLaneA() public {
        _setLocked(true);
        router.set(0, false); // Lane A unavailable
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    // ── G1 lockup ──

    function test_laneALock_blocksInstantExit() public {
        _lockLaneA(0);
        vm.prank(alice);
        vault.deposit(1_000e6, alice); // Lane A entry, locked to PID
        assertEq(vault.maxWithdraw(alice), 0, "locked: no instant withdraw");
        assertEq(vault.maxRedeem(alice), 0, "locked: no instant redeem");
    }

    function test_laneALock_liftsAfterSettle() public {
        _lockLaneA(0);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        assertEq(vault.maxRedeem(alice), 0, "locked while proposal active");

        // Proposal settles → active proposal clears → lock lifts.
        _setLocked(false);
        assertGt(vault.maxRedeem(alice), 0, "unlocked after settle");
    }

    /// @notice G1 bypass regression (review #380): a Lane-A-locked holder must not
    ///         be able to escape the lock by transferring shares to a fresh
    ///         address that then instant-redeems at the higher mid-proposal NAV.
    ///         `_update` rejects transfers out of a locked holder.
    function test_laneALock_blocksTransferBypass() public {
        address charlie = makeAddr("charlie");
        vm.prank(alice);
        vault.deposit(1_000e6, alice); // pre-proposal float
        _lockLaneA(500e6);

        // Bob enters via Lane A → his shares are locked to this proposal.
        vm.prank(bob);
        uint256 shares = vault.deposit(300e6, bob);

        // Bypass attempt: move the locked shares to a fresh (unlocked) address.
        vm.prank(bob);
        vm.expectRevert(ISyndicateVault.SharesLocked.selector);
        vault.transfer(charlie, shares);

        // The lock lifts at settle; the transfer then succeeds.
        _setLocked(false);
        vm.prank(bob);
        vault.transfer(charlie, shares);
        assertEq(vault.balanceOf(charlie), shares, "transfer allowed after settle");
    }

    // ── instant exit during Lane A (existing holder, not locked) ──

    function test_instantWithdraw_duringLaneA_existingHolder() public {
        // Alice deposits BEFORE the proposal (not Lane-A-locked).
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        _lockLaneA(500e6);

        // Alice can exit instantly during the proposal via Lane A, up to float.
        uint256 mw = vault.maxWithdraw(alice);
        assertGt(mw, 0, "existing holder can instant-exit via Lane A");
        assertLe(mw, usdc.balanceOf(address(vault)), "capped by float");
        vm.prank(alice);
        vault.withdraw(mw, alice, alice);
    }
}
