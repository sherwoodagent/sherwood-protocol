// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
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
///         via the PriceRouter during a proposal, instant EXIT for existing
///         holders when available, and fail-closed to Lane B otherwise.
///         Instant entry is closed for the life of any open proposal
///         (finding #14 / Option B), so the G1 per-share lockup this suite
///         used to exercise on the entry side is now unreachable.
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
            vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("strategyOf(uint256)", PID), abi.encode(STRAT));
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

    /// @notice Instant entry is closed for the whole life of any open
    ///         proposal, Lane A live or not (finding #14 / Option B) — the
    ///         door never opens for bob to mint at live NAV in the first
    ///         place.
    function test_deposit_reverts_duringLaneA() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        _lockLaneA(500e6);

        vm.prank(bob);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(300e6, bob);
    }

    function test_deposit_reverts_whenLockedNoLaneA() public {
        _setLocked(true);
        router.set(0, false); // Lane A unavailable
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    // ── G1 lockup: dead. `_laneALockPid` can never be written now that no
    //    deposit reaches the vault while a proposal is open (finding #14 /
    //    Option B) — see `SyndicateVault._deposit` and `_isLaneALocked`. No
    //    shares can ever exist in the locked state these tests exercised.

    // ── Issue #99: a zero-value deposit locks the RECEIVER, not the caller ──

    /// @notice ISSUE #99, RESOLVED: `_deposit` now guards the Lane A lock
    ///         latch on `shares != 0`, so `vault.deposit(0, victim)` — no
    ///         approval from the victim, no shares of the caller's own,
    ///         nothing transferred at all — is a genuine no-op rather than a
    ///         free grief. Written against unpatched `main` first (it passed
    ///         there, confirming the exploit) before this assertion was
    ///         flipped to prove the fix.
    function test_zeroValueDeposit_doesNotLockAnExistingHolder() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000e6, alice); // genuine, pre-proposal deposit
        _lockLaneA(500e6);

        // Alice is not locked — the property the existing suite already
        // proves (`test_instantWithdraw_duringLaneA_existingHolder`).
        assertGt(vault.maxWithdraw(alice), 0, "before the attempted grief: alice can instant-exit");

        // Bob (unrelated, no approval from alice, no shares) attempts to grief.
        vm.prank(bob);
        vault.deposit(0, alice);

        assertEq(vault.balanceOf(alice), aliceShares, "not a single share moved");
        assertGt(vault.maxWithdraw(alice), 0, "alice can still instant-exit: the grief did nothing");
        assertGt(vault.maxRedeem(alice), 0, "same for redeem");
        vm.prank(alice);
        vault.transfer(bob, 1); // she can still move her own shares
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

    // ── governor without `strategyOf` (independent-upgrade skew) ──

    /// @dev Pins the `try/catch` in `SyndicateVault._activeStrategy`. The vault
    ///      is a UUPS proxy and the governor is a BEACON proxy, so a vault impl
    ///      that calls `strategyOf` can go live before the governor beacon
    ///      carries it — the call then reverts with no data. `_activeStrategy`
    ///      feeds `_laneState` and hence `maxWithdraw`/`maxRedeem`, so an
    ///      uncaught revert is a vault-wide brick rather than a degradation.
    ///      Delete the catch and this test fails with `EvmError: Revert`.
    function test_missingStrategyOfDoesNotBrickWithdrawLanes() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        _setLocked(true);
        vm.mockCallRevert(MOCK_GOVERNOR, abi.encodeWithSignature("strategyOf(uint256)", PID), "");

        assertEq(vault.maxWithdraw(alice), 0, "degrades to lane-locked, does not revert");
        assertEq(vault.maxRedeem(alice), 0, "degrades to lane-locked, does not revert");
        assertEq(vault.totalAssets(), 1_000e6, "float only");
    }
}
