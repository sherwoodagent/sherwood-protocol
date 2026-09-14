// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../../src/SyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../../src/interfaces/IVaultWithdrawalQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Drives random deposit / requestRedeem / requestDeposit / claim /
///         cancel sequences across lock→settle proposal cycles (frozen Lane B).
///         Each `lock()` opens a fresh proposal id; `settle()` stamps that
///         proposal's frozen price (simulating `governor → vault.onProposalSettled`)
///         and unlocks. Bound to the AsyncRedeemInvariants harness.
contract AsyncRedeemHandler is Test {
    SyndicateVault public vault;
    VaultWithdrawalQueue public queue;
    IERC20 public asset;
    address public mockGovernor;

    address[] public actors;

    struct Tracked {
        uint256 id;
        address owner;
        uint256 amount;
        uint256 pid;
        bool isRedeem;
        bool open;
    }

    Tracked[] public tracked;

    bool public locked;
    uint256 public activePid;
    uint256 public pidCounter;
    mapping(uint256 => bool) public stamped;

    uint256 public expectedPending; // escrowed redeem shares (matches queue.pendingShares)
    uint256 public depositCalls;
    uint256 public requestCalls;
    uint256 public claimCalls;
    uint256 public cancelCalls;
    uint256 public lockToggleCalls;

    constructor(SyndicateVault vault_, VaultWithdrawalQueue queue_, IERC20 asset_, address mockGovernor_) {
        vault = vault_;
        queue = queue_;
        asset = asset_;
        mockGovernor = mockGovernor_;
        for (uint256 i; i < 4; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            deal(address(asset), a, 1_000_000e6);
            vm.prank(a);
            asset.approve(address(vault), type(uint256).max);
        }
        _mockLock(false, 0);
    }

    function _mockLock(bool l, uint256 pid) internal {
        vm.mockCall(mockGovernor, abi.encodeWithSignature("getActiveProposal()"), abi.encode(l ? pid : uint256(0)));
        vm.mockCall(
            mockGovernor, abi.encodeWithSignature("openProposalCount()"), abi.encode(l ? uint256(1) : uint256(0))
        );
    }

    function lock() external {
        lockToggleCalls++;
        if (locked) return;
        activePid = ++pidCounter;
        _mockLock(true, activePid);
        locked = true;
    }

    function settle() external {
        lockToggleCalls++;
        if (!locked) return;
        _mockLock(false, 0);
        locked = false;
        vm.prank(mockGovernor);
        vault.onProposalSettled(activePid);
        stamped[activePid] = true;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        depositCalls++;
        if (locked || vault.paused()) return; // instant deposit blocked while locked
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 100_000e6);
        if (asset.balanceOf(a) < amount) return;
        vm.prank(a);
        try vault.deposit(amount, a) {} catch {}
    }

    function requestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        requestCalls++;
        if (!locked) return;
        address a = actors[actorSeed % actors.length];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 s = bound(sharesSeed, 1, bal);
        vm.prank(a);
        try vault.requestRedeem(s, a) returns (uint256 reqId) {
            tracked.push(Tracked(reqId, a, s, activePid, true, true));
            expectedPending += s;
        } catch {}
    }

    function requestDeposit(uint256 actorSeed, uint256 amount) external {
        requestCalls++;
        if (!locked) return;
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 100_000e6);
        if (asset.balanceOf(a) < amount) return;
        vm.prank(a);
        try vault.requestDeposit(amount, a) returns (uint256 reqId) {
            tracked.push(Tracked(reqId, a, amount, activePid, false, true));
        } catch {}
    }

    function claimRandom(uint256 idSeed) external {
        claimCalls++;
        if (locked) return; // claims only in unlocked windows
        uint256 n = tracked.length;
        if (n == 0) return;
        for (uint256 k; k < n; k++) {
            Tracked storage t = tracked[(idSeed + k) % n];
            if (!t.open || !stamped[t.pid]) continue;
            try queue.claim(t.id) {
                if (t.isRedeem) expectedPending -= t.amount;
                t.open = false;
            } catch {}
            return;
        }
    }

    function cancelRandom(uint256 idSeed) external {
        cancelCalls++;
        uint256 n = tracked.length;
        if (n == 0) return;
        for (uint256 k; k < n; k++) {
            Tracked storage t = tracked[(idSeed + k) % n];
            if (!t.open || stamped[t.pid]) continue; // G7: cancel only before stamp
            vm.prank(t.owner);
            try queue.cancel(t.id) {
                if (t.isRedeem) expectedPending -= t.amount;
                t.open = false;
            } catch {}
            return;
        }
    }

    // Views for invariant assertions
    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
