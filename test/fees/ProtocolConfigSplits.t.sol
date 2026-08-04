// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {FeeConstants} from "../../src/FeeConstants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Covers the split-configuration requirements of
///         `specs/fee-splits/spec.md`: both splits must sum to full basis
///         points, a rejected split must leave prior state intact, a zero
///         share is legal, and only the owner may set either.
contract ProtocolConfigSplitsTest is Test {
    ProtocolConfig internal config;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    // The launch splits — guardian-weighted so the tier-1 guardian ROE clears
    // its hurdle at the 2-and-20 headline (ADR 2026-07-26, revalidated
    // 2026-08-04). Must match the `ProtocolConfig` constructor seeds.
    uint16 internal constant MGMT_AGENT = 6000;
    uint16 internal constant MGMT_PROTOCOL = 2000;
    uint16 internal constant MGMT_GUARDIAN = 2000;

    uint16 internal constant PERF_AGENT = 5000;
    uint16 internal constant PERF_PROTOCOL = 1500;
    uint16 internal constant PERF_GUARDIAN = 2500;
    uint16 internal constant PERF_OWNER = 1000;

    function setUp() public {
        config = new ProtocolConfig(owner);
    }

    function _mgmt(uint16 a, uint16 p, uint16 g) internal pure returns (IProtocolConfig.MgmtSplit memory) {
        return IProtocolConfig.MgmtSplit({agentBps: a, protocolBps: p, guardianBps: g});
    }

    function _perf(uint16 a, uint16 p, uint16 g, uint16 o) internal pure returns (IProtocolConfig.PerfSplit memory) {
        return IProtocolConfig.PerfSplit({agentBps: a, protocolBps: p, guardianBps: g, ownerBps: o});
    }

    function _setLaunchSplits() internal {
        vm.startPrank(owner);
        config.setMgmtSplit(_mgmt(MGMT_AGENT, MGMT_PROTOCOL, MGMT_GUARDIAN));
        config.setPerfSplit(_perf(PERF_AGENT, PERF_PROTOCOL, PERF_GUARDIAN, PERF_OWNER));
        vm.stopPrank();
    }

    // ── Management split ──

    function test_validMgmtSplitIsStoredAndEmitted() public {
        vm.expectEmit(true, true, true, true);
        emit IProtocolConfig.MgmtSplitSet(MGMT_AGENT, MGMT_PROTOCOL, MGMT_GUARDIAN);

        vm.prank(owner);
        config.setMgmtSplit(_mgmt(MGMT_AGENT, MGMT_PROTOCOL, MGMT_GUARDIAN));

        IProtocolConfig.MgmtSplit memory s = config.mgmtSplit();
        assertEq(s.agentBps, MGMT_AGENT);
        assertEq(s.protocolBps, MGMT_PROTOCOL);
        assertEq(s.guardianBps, MGMT_GUARDIAN);
    }

    function test_mgmtSplitUnderFullBasisPointsIsRejected() public {
        _setLaunchSplits();

        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidMgmtSplit.selector);
        config.setMgmtSplit(_mgmt(7000, 2000, 500)); // sums to 9500

        IProtocolConfig.MgmtSplit memory s = config.mgmtSplit();
        assertEq(s.guardianBps, MGMT_GUARDIAN, "a rejected split must not partially apply");
    }

    function test_mgmtSplitOverFullBasisPointsIsRejected() public {
        _setLaunchSplits();

        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidMgmtSplit.selector);
        config.setMgmtSplit(_mgmt(7000, 2000, 1001)); // sums to 10_001

        assertEq(config.mgmtSplit().guardianBps, MGMT_GUARDIAN);
    }

    /// @dev Only the sum is constrained — governance may route the whole fee to
    ///      one party.
    function test_mgmtSplitMayAllocateZeroToAParty() public {
        vm.prank(owner);
        config.setMgmtSplit(_mgmt(uint16(FeeConstants.BPS_DENOMINATOR), 0, 0));

        IProtocolConfig.MgmtSplit memory s = config.mgmtSplit();
        assertEq(s.agentBps, FeeConstants.BPS_DENOMINATOR);
        assertEq(s.protocolBps, 0);
        assertEq(s.guardianBps, 0);
    }

    function test_unauthorizedCallerCannotSetMgmtSplit() public {
        _setLaunchSplits();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        config.setMgmtSplit(_mgmt(5000, 3000, 2000));

        assertEq(config.mgmtSplit().agentBps, MGMT_AGENT, "stranger must not move the split");
    }

    // ── Performance split ──

    function test_validPerfSplitIsStoredAndEmitted() public {
        vm.expectEmit(true, true, true, true);
        emit IProtocolConfig.PerfSplitSet(PERF_AGENT, PERF_PROTOCOL, PERF_GUARDIAN, PERF_OWNER);

        vm.prank(owner);
        config.setPerfSplit(_perf(PERF_AGENT, PERF_PROTOCOL, PERF_GUARDIAN, PERF_OWNER));

        IProtocolConfig.PerfSplit memory s = config.perfSplit();
        assertEq(s.agentBps, PERF_AGENT);
        assertEq(s.protocolBps, PERF_PROTOCOL);
        assertEq(s.guardianBps, PERF_GUARDIAN);
        assertEq(s.ownerBps, PERF_OWNER);
    }

    function test_perfSplitOverFullBasisPointsIsRejected() public {
        _setLaunchSplits();

        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidPerfSplit.selector);
        config.setPerfSplit(_perf(6000, 1500, 1500, 1001)); // sums to 10_001

        assertEq(config.perfSplit().ownerBps, PERF_OWNER, "a rejected split must not partially apply");
    }

    function test_perfSplitUnderFullBasisPointsIsRejected() public {
        _setLaunchSplits();

        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidPerfSplit.selector);
        config.setPerfSplit(_perf(6000, 1500, 1500, 999)); // sums to 9999

        assertEq(config.perfSplit().ownerBps, PERF_OWNER);
    }

    function test_unauthorizedCallerCannotSetPerfSplit() public {
        _setLaunchSplits();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        config.setPerfSplit(_perf(2500, 2500, 2500, 2500));

        assertEq(config.perfSplit().agentBps, PERF_AGENT);
    }

    // ── Born valid ──

    /// @dev The contract is not upgradeable, so adopting this fee model means
    ///      deploying a fresh config. Seeding the launch splits at that moment
    ///      makes the invalid state unreachable instead of merely discouraged
    ///      (design.md Decision 8). A config that has never been touched by
    ///      governance must still be usable.
    function test_aFreshConfigIsBornWithValidSplits() public view {
        IProtocolConfig.MgmtSplit memory m = config.mgmtSplit();
        assertEq(uint256(m.agentBps) + m.protocolBps + m.guardianBps, FeeConstants.BPS_DENOMINATOR);

        IProtocolConfig.PerfSplit memory p = config.perfSplit();
        assertEq(uint256(p.agentBps) + p.protocolBps + p.guardianBps + p.ownerBps, FeeConstants.BPS_DENOMINATOR);
    }

    function test_theSeededSplitsAreTheLaunchNumbers() public view {
        IProtocolConfig.MgmtSplit memory m = config.mgmtSplit();
        assertEq(m.agentBps, MGMT_AGENT);
        assertEq(m.protocolBps, MGMT_PROTOCOL);
        assertEq(m.guardianBps, MGMT_GUARDIAN);

        IProtocolConfig.PerfSplit memory p = config.perfSplit();
        assertEq(p.agentBps, PERF_AGENT);
        assertEq(p.protocolBps, PERF_PROTOCOL);
        assertEq(p.guardianBps, PERF_GUARDIAN);
        assertEq(p.ownerBps, PERF_OWNER);
    }

    // ── The launch numbers ──

    /// @dev The agent must be the largest earner on both legs — the property
    ///      the whole product model rests on.
    function test_launchSplitsMakeTheAgentTheLargestEarner() public {
        _setLaunchSplits();

        IProtocolConfig.MgmtSplit memory m = config.mgmtSplit();
        assertGt(m.agentBps, uint256(m.protocolBps) + m.guardianBps, "agent should out-earn the rest on management");

        IProtocolConfig.PerfSplit memory p = config.perfSplit();
        // On carry the guardian-weighted rebalance leaves the agent with
        // exactly half — still the largest single earner, no longer strictly
        // more than everyone else combined.
        assertGe(
            p.agentBps, uint256(p.protocolBps) + p.guardianBps + p.ownerBps, "agent should take at least half the carry"
        );
        assertGt(p.agentBps, p.protocolBps, "agent out-earns the protocol on carry");
        assertGt(p.agentBps, p.guardianBps, "agent out-earns the guardian network on carry");
        assertGt(p.agentBps, p.ownerBps, "agent out-earns the owner on carry");
    }

    function test_bothLaunchSplitsSumToFullBasisPoints() public {
        _setLaunchSplits();

        IProtocolConfig.MgmtSplit memory m = config.mgmtSplit();
        assertEq(uint256(m.agentBps) + m.protocolBps + m.guardianBps, FeeConstants.BPS_DENOMINATOR);

        IProtocolConfig.PerfSplit memory p = config.perfSplit();
        assertEq(uint256(p.agentBps) + p.protocolBps + p.guardianBps + p.ownerBps, FeeConstants.BPS_DENOMINATOR);
    }

    // ── Fuzz ──

    /// @dev The rule is exactly "sums to 10 000", nothing more.
    function testFuzz_mgmtSplitAcceptedIffItSumsToFullBasisPoints(uint16 a, uint16 p, uint16 g) public {
        uint256 sum = uint256(a) + p + g;

        vm.prank(owner);
        if (sum != FeeConstants.BPS_DENOMINATOR) {
            vm.expectRevert(IProtocolConfig.InvalidMgmtSplit.selector);
            config.setMgmtSplit(_mgmt(a, p, g));
        } else {
            config.setMgmtSplit(_mgmt(a, p, g));
            assertEq(config.mgmtSplit().agentBps, a);
        }
    }

    function testFuzz_perfSplitAcceptedIffItSumsToFullBasisPoints(uint16 a, uint16 p, uint16 g, uint16 o) public {
        uint256 sum = uint256(a) + p + g + o;

        vm.prank(owner);
        if (sum != FeeConstants.BPS_DENOMINATOR) {
            vm.expectRevert(IProtocolConfig.InvalidPerfSplit.selector);
            config.setPerfSplit(_perf(a, p, g, o));
        } else {
            config.setPerfSplit(_perf(a, p, g, o));
            assertEq(config.perfSplit().agentBps, a);
        }
    }
}
