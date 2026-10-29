// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolFeeRouter} from "../../../src/ProtocolFeeRouter.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {
    PaxosLikeMock,
    FeeOnTransferMock,
    RevertOnZeroMock,
    NoReturnMock,
    ReturnsFalseMock,
    RebasingMock,
    MaliciousToken
} from "./WeirdTokenMocks.sol";

/// @notice SHE-239 token-integration review of ProtocolFeeRouter (router-only, no governor).
contract RouterWeirdTokensTest is Test {
    ProtocolFeeRouter internal router;
    PaxosLikeMock internal usdg;
    ERC20Mock internal weth;

    address internal safe = makeAddr("safe");
    address internal foundation = makeAddr("foundation");
    address internal grants = makeAddr("grants");
    address internal coverage = makeAddr("coverage");

    function setUp() public {
        router = new ProtocolFeeRouter(safe);
        usdg = new PaxosLikeMock();
        weth = new ERC20Mock("WETH", "WETH", 18);
    }

    function _three() internal view returns (ProtocolFeeRouter.Allocation[] memory s) {
        s = new ProtocolFeeRouter.Allocation[](3);
        s[0] = ProtocolFeeRouter.Allocation({target: foundation, bps: 5000});
        s[1] = ProtocolFeeRouter.Allocation({target: grants, bps: 3000});
        s[2] = ProtocolFeeRouter.Allocation({target: coverage, bps: 2000});
    }

    function _set(ProtocolFeeRouter.Allocation[] memory a) internal {
        vm.prank(safe);
        router.setAllocations(a);
    }

    // ---------------------------------------------------------------- freeze / pause

    /// L-1: one Paxos-frozen leg reverts EVERY USDG distribution, and any distributeMany batch
    /// that includes USDG also strands the batch's other tokens. Funds stay put (no loss).
    function test_L1_frozenTargetBricksUsdgAndTheWholeBatch() public {
        _set(_three());
        usdg.mint(address(router), 1_000e6);
        weth.mint(address(router), 10e18);

        usdg.freeze(grants, true);

        vm.expectRevert(abi.encodeWithSelector(PaxosLikeMock.Frozen.selector, grants));
        router.distribute(address(usdg));

        address[] memory batch = new address[](2);
        batch[0] = address(weth);
        batch[1] = address(usdg);
        vm.expectRevert(abi.encodeWithSelector(PaxosLikeMock.Frozen.selector, grants));
        router.distributeMany(batch);
        assertEq(weth.balanceOf(address(router)), 10e18, "WETH stranded by the USDG leg in the same batch");

        // Single-token distribute of WETH still works: the DoS is per-token, not router-wide.
        router.distribute(address(weth));
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(usdg.balanceOf(address(router)), 1_000e6, "USDG held, not lost");

        // Only the owner unblocks it, and dropping the leg re-prices the backlog: everything that
        // accrued while grants was frozen now goes 5000:2000 to the remaining legs.
        ProtocolFeeRouter.Allocation[] memory two = new ProtocolFeeRouter.Allocation[](2);
        two[0] = ProtocolFeeRouter.Allocation({target: foundation, bps: 7143});
        two[1] = ProtocolFeeRouter.Allocation({target: coverage, bps: 2857});
        _set(two);
        router.distribute(address(usdg));
        assertEq(usdg.balanceOf(grants), 0, "frozen leg's 30% of the backlog redistributed to others");
        assertEq(usdg.balanceOf(foundation) + usdg.balanceOf(coverage), 1_000e6);
    }

    /// Pause behaves the same way as a frozen leg, router-wide for that token, until unpause.
    function test_pausedTokenRevertsDistributeUntilUnpause() public {
        _set(_three());
        usdg.mint(address(router), 1_000e6);
        usdg.setPaused(true);
        vm.expectRevert(PaxosLikeMock.Paused.selector);
        router.distribute(address(usdg));
        usdg.setPaused(false);
        router.distribute(address(usdg));
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    /// L-2: router itself frozen: held balance cannot be distributed OR rescued, and Paxos can wipe
    /// it. Hold mode concentrates the whole accrued protocol leg in this one freezable address.
    function test_L2_frozenRouterStrandsHeldBalanceAndRescueCannotHelp() public {
        usdg.mint(address(router), 1_000e6); // accrued in hold mode
        usdg.freeze(address(router), true);

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(PaxosLikeMock.Frozen.selector, address(router)));
        router.rescue(address(usdg), safe, 1_000e6);

        _set(_three());
        vm.expectRevert(abi.encodeWithSelector(PaxosLikeMock.Frozen.selector, address(router)));
        router.distribute(address(usdg));

        usdg.wipeFrozen(address(router));
        assertEq(usdg.balanceOf(address(router)), 0, "asset-protection wipe takes the whole backlog");
    }

    // ---------------------------------------------------------------- arbitrary / malicious tokens

    /// A malicious token passed to distribute/distributeMany cannot re-enter to move a real token,
    /// cannot reach rescue, and cannot touch real balances. Its only effect is a spoofed event.
    function test_maliciousTokenCannotMoveRealBalances() public {
        _set(_three());
        usdg.mint(address(router), 1_000e6);
        MaliciousToken evil = new MaliciousToken(router, address(usdg));

        vm.expectEmit(true, false, false, true, address(router));
        emit ProtocolFeeRouter.Distributed(address(evil), 1e30, router.allocationsHash());
        router.distribute(address(evil));

        assertFalse(evil.reentrySucceeded(), "no re-entry path succeeded");
        assertEq(
            keccak256(evil.reentryRevert()),
            keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector))
        );
        assertEq(usdg.balanceOf(address(router)), 1_000e6, "real balance untouched");
    }

    /// A malicious "governor" in claimEscrowedFees: the router makes one external call to it;
    /// re-entry is blocked and the router holds no approvals to abuse.
    function test_maliciousGovernorInClaimIsInert() public {
        _set(_three());
        usdg.mint(address(router), 1_000e6);
        MaliciousToken evil = new MaliciousToken(router, address(usdg));
        router.claimEscrowedFees(address(evil), address(0xdead), address(usdg));
        assertFalse(evil.reentrySucceeded());
        assertEq(usdg.balanceOf(address(router)), 1_000e6);
        assertEq(usdg.allowance(address(router), address(evil)), 0);
    }

    /// An EOA "governor" (no code) reverts: the high-level call checks extcodesize. Not a silent no-op.
    function test_claimAgainstANonContractReverts() public {
        vm.expectRevert(bytes(""));
        router.claimEscrowedFees(makeAddr("eoa"), address(1), address(usdg));
    }

    // ---------------------------------------------------------------- weird ERC-20 shapes

    function test_feeOnTransferLegsReceiveNetAndNothingStrands() public {
        _set(_three());
        FeeOnTransferMock fot = new FeeOnTransferMock();
        fot.mint(address(router), 10_000);
        router.distribute(address(fot));
        assertEq(fot.balanceOf(address(router)), 0, "no revert, no dust stranded");
        assertEq(fot.balanceOf(foundation), 4950);
        assertEq(fot.balanceOf(grants), 2970);
        assertEq(fot.balanceOf(coverage), 1980);
    }

    function test_revertOnZeroIsSkippedForFlooredLegs() public {
        _set(_three());
        RevertOnZeroMock z = new RevertOnZeroMock();
        z.mint(address(router), 3); // 3*5000/1e4 = 1, 3*3000/1e4 = 0 (skipped), last = 2
        router.distribute(address(z));
        assertEq(z.balanceOf(foundation), 1);
        assertEq(z.balanceOf(grants), 0);
        assertEq(z.balanceOf(coverage), 2);
    }

    function test_noReturnTokenWorks() public {
        _set(_three());
        NoReturnMock t = new NoReturnMock();
        t.mint(address(router), 10_000);
        router.distribute(address(t));
        assertEq(t.balanceOf(address(router)), 0);
        assertEq(t.balanceOf(foundation), 5000);
    }

    function test_returnsFalseTokenReverts() public {
        _set(_three());
        ReturnsFalseMock t = new ReturnsFalseMock();
        t.mint(address(router), 10_000);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        router.distribute(address(t));
    }

    function test_rebasingBalanceIsDistributedAsRead() public {
        _set(_three());
        RebasingMock r = new RebasingMock();
        r.mint(address(router), 10_000);
        r.rebase(1.5e18);
        router.distribute(address(r));
        assertEq(r.balanceOf(address(router)), 0, "positive rebase forwarded with the rest");
    }

    function test_highDecimalLargeBalanceDoesNotOverflow() public {
        _set(_three());
        ERC20Mock big = new ERC20Mock("Big", "BIG", 24);
        big.mint(address(router), type(uint256).max / 10_000);
        router.distribute(address(big));
        assertEq(big.balanceOf(address(router)), 0);
    }

    // ---------------------------------------------------------------- allocation-change races

    /// L-3: the accrued backlog follows whichever allocation set is live when ANYONE calls
    /// distribute. A Safe tx re-pointing legs is visible while signatures are collected, so any
    /// caller can push the backlog out under the old legs first (or, symmetrically, the owner's
    /// new legs capture fees that accrued under the old policy).
    function test_L3_backlogFollowsTheAllocationLiveAtCallTime() public {
        ProtocolFeeRouter.Allocation[] memory old = new ProtocolFeeRouter.Allocation[](1);
        old[0] = ProtocolFeeRouter.Allocation({target: grants, bps: 10_000});
        _set(old);
        usdg.mint(address(router), 1_000e6);

        // Safe intends to move 100% to foundation; a grants-side caller distributes first.
        vm.prank(grants);
        router.distribute(address(usdg));
        ProtocolFeeRouter.Allocation[] memory next = new ProtocolFeeRouter.Allocation[](1);
        next[0] = ProtocolFeeRouter.Allocation({target: foundation, bps: 10_000});
        _set(next);

        assertEq(usdg.balanceOf(grants), 1_000e6);
        assertEq(usdg.balanceOf(foundation), 0);
    }
}
