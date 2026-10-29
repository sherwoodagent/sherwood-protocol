// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./RouterIntegrationBase.sol";

/// @notice Q2: does the router as `protocolFeeRecipient` change ANY settlement behaviour vs an EOA?
///         Each scenario runs the identical settlement twice from one snapshot — once paying an EOA,
///         once paying the router — and asserts byte-identical outcomes after normalising the
///         recipient address out of the logs.
contract RouterDifferentialTest is RouterIntegrationBase {
    address internal eoaRecipient = makeAddr("eoaRecipient");

    struct Outcome {
        uint256 totalAssets;
        uint256 pps;
        uint256 agentBal;
        uint256 ownerBal;
        uint256 guardianBal;
        uint256 recipientBal;
        uint256 escrow;
        uint256 recipientOwed;
        uint256 guardianOwed;
        uint256 lpRedeemable;
        uint256 nLogs;
        uint256 nGuardianAccrued;
        uint256 nEscrowCapped;
        bytes32 logDigest;
    }

    enum Mode {
        Clean,
        Blacklisted,
        EscrowCapped,
        EscrowZero,
        GuardianAlsoBlacklisted
    }

    function _run(address recipient, Mode mode) internal returns (Outcome memory o) {
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(recipient);
        uint256 id = _propose();
        _voteAndExecute(governor, id, lp1);

        if (mode == Mode.Blacklisted || mode == Mode.GuardianAlsoBlacklisted) usdg.setBlacklisted(recipient, true);
        if (mode == Mode.GuardianAlsoBlacklisted) usdg.setBlacklisted(guardianRecipient, true);
        if (mode == Mode.EscrowCapped || mode == Mode.EscrowZero) {
            vm.mockCallRevert(
                address(vault),
                abi.encodeWithSelector(ISyndicateVault.transferPerformanceFee.selector, address(usdg), recipient),
                "boom"
            );
            vm.mockCall(
                address(vault),
                abi.encodeCall(ISyndicateVault.spendableFee, (address(usdg))),
                abi.encode(mode == Mode.EscrowCapped ? uint256(1234) : uint256(0))
            );
        }

        vm.recordLogs();
        _settle(vault, governor, id, 50_000e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        o.totalAssets = vault.totalAssets();
        o.pps = vault.pricePerShare();
        o.agentBal = usdg.balanceOf(agent);
        o.ownerBal = usdg.balanceOf(owner);
        o.guardianBal = usdg.balanceOf(guardianRecipient);
        o.recipientBal = usdg.balanceOf(recipient);
        o.escrow = governor.outstandingEscrow(address(vault), address(usdg));
        o.recipientOwed = governor.unclaimedFees(address(vault), recipient, address(usdg));
        o.guardianOwed = governor.unclaimedFees(address(vault), guardianRecipient, address(usdg));
        o.lpRedeemable = vault.previewRedeem(vault.balanceOf(lp1));
        o.nLogs = logs.length;
        bytes32 accrued = ISyndicateGovernor.GuardianFeeAccrued.selector;
        bytes32 capped = ISyndicateGovernor.FeeEscrowCapped.selector;
        bytes32 d;
        bytes32 rWord = bytes32(uint256(uint160(recipient)));
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == accrued) o.nGuardianAccrued++;
            if (logs[i].topics.length > 0 && logs[i].topics[0] == capped) o.nEscrowCapped++;
            bytes32[] memory t = logs[i].topics;
            for (uint256 j; j < t.length; ++j) {
                if (t[j] == rWord) t[j] = bytes32(0);
            }
            bytes memory data = logs[i].data;
            for (uint256 off; off + 32 <= data.length; off += 32) {
                bytes32 w;
                assembly {
                    w := mload(add(add(data, 0x20), off))
                }
                if (w == rWord) {
                    assembly {
                        mstore(add(add(data, 0x20), off), 0)
                    }
                }
            }
            d = keccak256(abi.encode(d, logs[i].emitter, t, data));
        }
        o.logDigest = d;
    }

    function _diff(Mode mode) internal returns (Outcome memory a, Outcome memory b) {
        uint256 snap = vm.snapshotState();
        a = _run(eoaRecipient, mode);
        vm.revertToState(snap);
        b = _run(address(router), mode);

        assertEq(a.totalAssets, b.totalAssets, "totalAssets");
        assertEq(a.pps, b.pps, "pps");
        assertEq(a.agentBal, b.agentBal, "agent");
        assertEq(a.ownerBal, b.ownerBal, "owner");
        assertEq(a.guardianBal, b.guardianBal, "guardian");
        assertEq(a.recipientBal, b.recipientBal, "recipient balance");
        assertEq(a.escrow, b.escrow, "escrow");
        assertEq(a.recipientOwed, b.recipientOwed, "recipient owed");
        assertEq(a.guardianOwed, b.guardianOwed, "guardian owed");
        assertEq(a.lpRedeemable, b.lpRedeemable, "LP redeemable");
        assertEq(a.nLogs, b.nLogs, "log count");
        assertEq(a.nGuardianAccrued, b.nGuardianAccrued, "GuardianFeeAccrued count");
        assertEq(a.nEscrowCapped, b.nEscrowCapped, "FeeEscrowCapped count");
        assertEq(a.logDigest, b.logDigest, "normalised log stream");
    }

    function test_diff_clean() public {
        (Outcome memory a,) = _diff(Mode.Clean);
        assertGt(a.recipientBal, 0);
        assertEq(a.escrow, 0);
        assertEq(a.nGuardianAccrued, 2, "mgmt + perf guardian legs both delivered");
    }

    function test_diff_recipientBlacklisted_escrows_identically() public {
        (Outcome memory a,) = _diff(Mode.Blacklisted);
        assertEq(a.recipientBal, 0);
        assertGt(a.recipientOwed, 0);
        assertEq(a.escrow, a.recipientOwed);
        assertEq(a.nGuardianAccrued, 2, "guardian unaffected by protocol-leg escrow");
    }

    function test_diff_escrowCapped_identically() public {
        (Outcome memory a,) = _diff(Mode.EscrowCapped);
        assertEq(a.nEscrowCapped, 2, "both protocol legs capped");
        assertEq(a.recipientOwed, 2 * 1234);
    }

    function test_diff_escrowZero_dropsFee_identically() public {
        (Outcome memory a,) = _diff(Mode.EscrowZero);
        assertEq(a.recipientOwed, 0);
        assertEq(a.escrow, 0);
        assertEq(a.recipientBal, 0, "fee neither delivered nor escrowed (stays LP equity) - recipient-agnostic");
    }

    function test_diff_guardianAlsoBlacklisted_noAccrualEvent() public {
        (Outcome memory a,) = _diff(Mode.GuardianAlsoBlacklisted);
        assertEq(a.nGuardianAccrued, 0);
        assertGt(a.guardianOwed, 0);
    }

    /// @notice Recovery leg of the escrow path: EOA claims itself, router claim is triggered by a stranger.
    ///         End states must match.
    function test_diff_escrowRecovery_endStateIdentical() public {
        uint256 snap = vm.snapshotState();
        _run(eoaRecipient, Mode.Blacklisted);
        usdg.setBlacklisted(eoaRecipient, false);
        vm.prank(eoaRecipient);
        governor.claimUnclaimedFees(address(vault), address(usdg));
        uint256 aBal = usdg.balanceOf(eoaRecipient);
        uint256 aTA = vault.totalAssets();
        uint256 aEsc = governor.outstandingEscrow(address(vault), address(usdg));
        vm.revertToState(snap);

        _run(address(router), Mode.Blacklisted);
        usdg.setBlacklisted(address(router), false);
        vm.prank(makeAddr("stranger"));
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        assertEq(usdg.balanceOf(address(router)), aBal);
        assertEq(vault.totalAssets(), aTA);
        assertEq(governor.outstandingEscrow(address(vault), address(usdg)), aEsc);
        assertEq(aEsc, 0);
    }
}
