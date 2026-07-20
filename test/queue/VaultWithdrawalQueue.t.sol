// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @title VaultWithdrawalQueueTest
/// @notice Unit tests for the Lane B frozen request queue (deposit + redeem,
///         one settle price per proposal, G7 cancel-before-settle).
contract VaultWithdrawalQueueTest is Test {
    MockVault vault;
    VaultWithdrawalQueue queue;
    ERC20Mock asset;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant PID = 1;
    // Frozen price = num/den = 2 assets per share.
    uint256 constant NUM = 2;
    uint256 constant DEN = 1;

    function setUp() public {
        asset = new ERC20Mock("USD Coin", "USDC", 6);
        vault = new MockVault(address(asset));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setQueue(address(queue));
        // Fund the vault so it can pay redeem claims (shares are 1e18-scale in
        // these unit tests; fund generously in raw units).
        asset.mint(address(vault), 1_000_000e18);
    }

    // ── helpers ──

    function _queueRedeem(address owner_, uint256 shares) internal returns (uint256 id) {
        // Vault escrows shares into the queue, then records the request.
        vault.mint(address(queue), shares);
        vm.prank(address(vault));
        id = queue.queueRedeem(owner_, shares, PID);
    }

    function _queueDeposit(address owner_, uint256 assets) internal returns (uint256 id) {
        // Vault escrows assets into the queue, then records the request.
        asset.mint(address(queue), assets);
        vm.prank(address(vault));
        id = queue.queueDeposit(owner_, assets, PID);
    }

    function _stamp() internal {
        vm.prank(address(vault));
        queue.stampSettlement(PID, NUM, DEN);
    }

    // ── queueing ──

    function test_queueRedeem_recordsRequest() public {
        uint256 id = _queueRedeem(alice, 100e18);
        assertEq(id, 1);
        IVaultWithdrawalQueue.Request memory r = queue.getRequest(1);
        assertEq(r.owner, alice);
        assertEq(r.amount, 100e18);
        assertEq(r.pid, PID);
        assertEq(uint256(r.kind), uint256(IVaultWithdrawalQueue.RequestKind.Redeem));
        assertEq(queue.pendingShares(), 100e18);
    }

    function test_queueDeposit_recordsRequest() public {
        uint256 id = _queueDeposit(alice, 500e6);
        assertEq(id, 1);
        IVaultWithdrawalQueue.Request memory r = queue.getRequest(1);
        assertEq(r.amount, 500e6);
        assertEq(uint256(r.kind), uint256(IVaultWithdrawalQueue.RequestKind.Deposit));
        assertEq(queue.pendingDepositAssets(), 500e6);
    }

    function test_queueRedeem_onlyVault() public {
        vm.expectRevert(IVaultWithdrawalQueue.NotVault.selector);
        queue.queueRedeem(alice, 100e18, PID);
    }

    function test_queueDeposit_onlyVault() public {
        vm.expectRevert(IVaultWithdrawalQueue.NotVault.selector);
        queue.queueDeposit(alice, 100e6, PID);
    }

    function test_queueRedeem_zeroReverts() public {
        vm.prank(address(vault));
        vm.expectRevert(IVaultWithdrawalQueue.ZeroShares.selector);
        queue.queueRedeem(alice, 0, PID);
    }

    function test_queueDeposit_zeroReverts() public {
        vm.prank(address(vault));
        vm.expectRevert(IVaultWithdrawalQueue.ZeroAssets.selector);
        queue.queueDeposit(alice, 0, PID);
    }

    // ── stamp ──

    function test_stampSettlement_onlyVault() public {
        vm.expectRevert(IVaultWithdrawalQueue.NotVault.selector);
        queue.stampSettlement(PID, NUM, DEN);
    }

    function test_stampSettlement_twiceReverts() public {
        _stamp();
        vm.prank(address(vault));
        vm.expectRevert(IVaultWithdrawalQueue.AlreadySettled.selector);
        queue.stampSettlement(PID, NUM, DEN);
    }

    function test_stamp_reservesRedeemAssets() public {
        _queueRedeem(alice, 100e18);
        assertEq(queue.reservedAssets(), 0, "no reserve before stamp");
        _stamp();
        // reserve = 100 shares * 2/1 = 200
        assertEq(queue.reservedAssets(), 200e18, "reserve = frozen redeem assets");
    }

    // ── redeem claim (frozen) ──

    function test_claim_redeem_paysFrozenAssets() public {
        _queueRedeem(alice, 100e18);
        _stamp();
        uint256 out = queue.claim(1);
        assertEq(out, 200e18, "100 shares * 2 = 200 assets");
        assertEq(asset.balanceOf(alice), 200e18);
        assertEq(vault.lastRedeemTo(), alice);
        assertEq(queue.pendingShares(), 0);
        assertEq(queue.reservedAssets(), 0, "reserve released on claim");
        assertTrue(queue.getRequest(1).claimed);
    }

    function test_claim_redeem_revertsBeforeStamp() public {
        _queueRedeem(alice, 100e18);
        vm.expectRevert(IVaultWithdrawalQueue.NotSettled.selector);
        queue.claim(1);
    }

    function test_claim_revertsWhileVaultLocked() public {
        _queueRedeem(alice, 100e18);
        _stamp();
        vault.setLocked(true);
        vm.expectRevert(IVaultWithdrawalQueue.VaultLocked.selector);
        queue.claim(1);
    }

    function test_claim_anyoneCanCall_ownerReceives() public {
        _queueRedeem(alice, 100e18);
        _stamp();
        vm.prank(bob);
        queue.claim(1);
        assertEq(asset.balanceOf(alice), 200e18, "owner receives even when bob claims");
    }

    function test_claim_twiceReverts() public {
        _queueRedeem(alice, 100e18);
        _stamp();
        queue.claim(1);
        vm.expectRevert(IVaultWithdrawalQueue.AlreadyClaimed.selector);
        queue.claim(1);
    }

    // ── deposit claim (frozen) ──

    function test_claim_deposit_mintsFrozenShares() public {
        _queueDeposit(alice, 200e18);
        _stamp();
        uint256 out = queue.claim(1);
        // shares = 200 assets * den/num = 200 * 1/2 = 100
        assertEq(out, 100e18, "200 assets / price 2 = 100 shares");
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.lastDepositTo(), alice);
        assertEq(asset.balanceOf(address(vault)), 1_000_000e18 + 200e18, "escrowed assets pushed to vault");
        assertEq(queue.pendingDepositAssets(), 0);
    }

    function test_claim_deposit_revertsBeforeStamp() public {
        _queueDeposit(alice, 200e6);
        vm.expectRevert(IVaultWithdrawalQueue.NotSettled.selector);
        queue.claim(1);
    }

    // ── one frozen price for the whole proposal ──

    function test_batch_allClaimAtOnePrice() public {
        _queueRedeem(alice, 100e18);
        _queueRedeem(bob, 50e18);
        _stamp();
        assertEq(queue.claim(1), 200e18, "alice 100*2");
        assertEq(queue.claim(2), 100e18, "bob 50*2");
    }

    // ── cancel (G7: only before stamp) ──

    function test_cancel_redeem_beforeStamp_returnsShares() public {
        _queueRedeem(alice, 100e18);
        vm.prank(alice);
        queue.cancel(1);
        assertEq(vault.balanceOf(alice), 100e18, "shares returned");
        assertEq(queue.pendingShares(), 0);
        assertTrue(queue.getRequest(1).cancelled);
    }

    function test_cancel_deposit_beforeStamp_returnsAssets() public {
        _queueDeposit(alice, 200e6);
        vm.prank(alice);
        queue.cancel(1);
        assertEq(asset.balanceOf(alice), 200e6, "assets returned");
        assertEq(queue.pendingDepositAssets(), 0);
    }

    function test_cancel_afterStampReverts_G7() public {
        _queueRedeem(alice, 100e18);
        _stamp();
        vm.prank(alice);
        vm.expectRevert(IVaultWithdrawalQueue.AlreadySettled.selector);
        queue.cancel(1);
    }

    function test_cancel_nonOwnerReverts() public {
        _queueRedeem(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(IVaultWithdrawalQueue.NotQueueOwner.selector);
        queue.cancel(1);
    }

    function test_cancel_redeem_releasesReserveShareTracking() public {
        _queueRedeem(alice, 100e18);
        vm.prank(alice);
        queue.cancel(1);
        // After cancel, stamping should reserve nothing (the request is gone).
        _stamp();
        assertEq(queue.reservedAssets(), 0, "cancelled redeem not reserved at stamp");
    }

    // ── misc ──

    function test_claim_unknownReverts() public {
        vm.expectRevert(IVaultWithdrawalQueue.RequestNotFound.selector);
        queue.claim(99);
    }

    function test_getRequestsByOwner() public {
        _queueRedeem(alice, 10e18);
        _queueDeposit(alice, 20e6);
        uint256[] memory ids = queue.getRequestsByOwner(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    // ── reserve rounding (phantom-dust regression) ──

    /// @notice `stampSettlement` reserves `floor(Σshares·num/den)` (one aggregate
    ///         floor) while `claim` pays `floor(shareᵢ·num/den)` per request.
    ///         Since `floor(Σ) ≥ Σfloor`, a fully-claimed proposal must not
    ///         strand phantom reserve — else `reservedAssets` drifts above the
    ///         float that backs the true claimable and accumulates across
    ///         proposals (INV-Q2: `reserve ≤ float`). Pre-fix this left 1 wei.
    function test_reserve_noPhantomAfterFullClaim() public {
        // Price 10/9 ≈ 1.111. Three 3-share requests: each pays floor(30/9)=3
        // (Σ payout = 9), aggregate reserve floor(90/9)=10 → 1 wei of dust.
        address carol = makeAddr("carol");
        _queueRedeem(alice, 3);
        _queueRedeem(bob, 3);
        _queueRedeem(carol, 3);
        vm.prank(address(vault));
        queue.stampSettlement(PID, 10, 9);
        assertEq(queue.reservedAssets(), 10, "aggregate reserved at stamp");

        assertEq(queue.claim(1), 3, "per-request payout floors to 3");
        assertEq(queue.reservedAssets(), 7, "partial release tracks payout");
        assertEq(queue.claim(2), 3);
        assertEq(queue.reservedAssets(), 4);
        assertEq(queue.claim(3), 3);
        // Final claim frees the whole remainder (incl. the 1-wei dust).
        assertEq(queue.reservedAssets(), 0, "no phantom reserve after full claim");
    }

    /// @notice Reserve during partial claims always covers the still-unclaimed
    ///         obligations (never under-reserves); dust is released only on the
    ///         emptying claim.
    function test_reserve_partialClaim_staysCovered() public {
        address carol = makeAddr("carol");
        _queueRedeem(alice, 3);
        _queueRedeem(bob, 3);
        _queueRedeem(carol, 3);
        vm.prank(address(vault));
        queue.stampSettlement(PID, 10, 9);

        queue.claim(1);
        // Two requests still owed 3 each = 6; reserve holds 7 (≥ 6, dust retained
        // until the proposal is emptied). Never below the true remaining owed.
        assertGe(queue.reservedAssets(), 6, "reserve covers remaining owed");
    }
}
