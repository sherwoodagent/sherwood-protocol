// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./RouterIntegrationBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BlacklistingERC20Mock} from "../../mocks/BlacklistingERC20Mock.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev A "governor" that, when the router calls it, tries every router entry point and a claim on
///      the real governor. Records each outcome.
contract MaliciousGovernor {
    ProtocolFeeRouter public immutable router;
    address public immutable realGov;
    address public immutable token;
    bytes4[] public reverts;
    bool public claimOnRealOk;

    constructor(ProtocolFeeRouter r, address g, address t) {
        router = r;
        realGov = g;
        token = t;
    }

    function claimUnclaimedFees(address vault, address) external {
        address[] memory ts = new address[](1);
        ts[0] = token;
        _try(abi.encodeCall(router.distribute, (token)));
        _try(abi.encodeCall(router.distributeMany, (ts)));
        _try(abi.encodeCall(router.claimEscrowedFees, (realGov, vault, token)));
        _try(abi.encodeCall(router.rescue, (token, address(this), 1)));
        _try(abi.encodeCall(router.setAllocations, (new ProtocolFeeRouter.Allocation[](0))));
        _try(abi.encodeCall(Ownable.transferOwnership, (address(this))));
        // msg.sender here is THIS contract, so this can only claim escrow owed to the attacker.
        (claimOnRealOk,) = realGov.call(abi.encodeWithSignature("claimUnclaimedFees(address,address)", vault, token));
    }

    function _try(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(router).call(data);
        require(!ok, "router call unexpectedly succeeded");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 0x20))
        }
        reverts.push(sel);
    }

    function nReverts() external view returns (uint256) {
        return reverts.length;
    }
}

/// @dev A token whose transfer re-enters the router.
contract ReentrantToken is ERC20 {
    ProtocolFeeRouter public router;
    address public other;
    bytes4 public lastRevert;
    uint256 public attempts;

    constructor() ERC20("R", "R") {}

    function arm(ProtocolFeeRouter r, address o) external {
        router = r;
        other = o;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (address(router) != address(0) && from == address(router)) {
            attempts++;
            (bool ok, bytes memory ret) = address(router).call(abi.encodeCall(router.distribute, (other)));
            require(!ok, "reentry succeeded");
            bytes4 sel;
            assembly {
                sel := mload(add(ret, 0x20))
            }
            lastRevert = sel;
        }
    }
}

contract RouterAttacksTest is RouterIntegrationBase {
    // ───────────────────────── (1) arbitrary governor / token ─────────────────────────

    function test_maliciousGovernor_cannotReenterOrActAsRouter() public {
        // Fund the router with real fees first.
        _executeAndSettle(_propose(), 50_000e6);
        uint256 held = usdg.balanceOf(address(router));
        assertGt(held, 0);
        vm.prank(safe);
        router.setAllocations(_alloc1(foundation)); // allocation mode: distribute WOULD move funds

        MaliciousGovernor mg = new MaliciousGovernor(router, address(governor), address(usdg));
        vm.prank(makeAddr("attacker"));
        router.claimEscrowedFees(address(mg), address(vault), address(usdg));

        assertEq(mg.nReverts(), 6);
        bytes4 reent = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        bytes4 unauth = Ownable.OwnableUnauthorizedAccount.selector;
        assertEq(mg.reverts(0), reent, "distribute");
        assertEq(mg.reverts(1), reent, "distributeMany");
        assertEq(mg.reverts(2), reent, "claimEscrowedFees");
        assertEq(mg.reverts(3), unauth, "rescue");
        assertEq(mg.reverts(4), unauth, "setAllocations");
        assertEq(mg.reverts(5), unauth, "transferOwnership");
        assertTrue(mg.claimOnRealOk(), "real claim succeeds but owes the attacker nothing");
        assertEq(usdg.balanceOf(address(mg)), 0);
        assertEq(usdg.balanceOf(address(router)), held, "router untouched");
        assertEq(usdg.balanceOf(foundation), 0);
        assertEq(router.owner(), safe);
    }

    function test_maliciousToken_cannotReenterDistribute() public {
        _executeAndSettle(_propose(), 50_000e6);
        uint256 held = usdg.balanceOf(address(router));
        vm.prank(safe);
        router.setAllocations(_alloc1(foundation));
        ReentrantToken rt = new ReentrantToken();
        rt.mint(address(router), 100);
        rt.arm(router, address(usdg));

        address[] memory ts = new address[](1);
        ts[0] = address(rt);
        router.distributeMany(ts);
        assertEq(rt.attempts(), 1);
        assertEq(rt.lastRevert(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(usdg.balanceOf(address(router)), held, "usdg not distributed via reentry");
    }

    // ───────────────────────── (1) claim timing / griefing ─────────────────────────

    function _escrowForRouter() internal returns (uint256 owed) {
        usdg.setBlacklisted(address(router), true);
        _executeAndSettle(_propose(), 50_000e6);
        usdg.setBlacklisted(address(router), false);
        owed = governor.unclaimedFees(address(vault), address(router), address(usdg));
        assertGt(owed, 0);
    }

    /// @notice A stranger's claim between proposals is NAV-neutral for LPs.
    function test_strangerClaimBetweenProposals_isNavNeutral() public {
        uint256 owed = _escrowForRouter();
        uint256 ta = vault.totalAssets();
        uint256 pps = vault.pricePerShare();
        uint256 lpOut = vault.previewRedeem(vault.balanceOf(lp1));
        uint256 rawBefore = usdg.balanceOf(address(vault));

        vm.prank(makeAddr("griefer"));
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));

        assertEq(usdg.balanceOf(address(vault)), rawBefore - owed, "only the escrow left");
        assertEq(vault.totalAssets(), ta, "totalAssets unchanged");
        assertEq(vault.pricePerShare(), pps, "pps unchanged");
        assertEq(vault.previewRedeem(vault.balanceOf(lp1)), lpOut, "LP exit unchanged");
        // Repeat is a no-op, not a revert.
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        assertEq(usdg.balanceOf(address(router)), owed);
    }

    /// @notice Claim while the vault's next proposal is Pending (pre-execute) is allowed and does not
    ///         distort the execute-time capital snapshot / pnl of that proposal.
    function test_strangerClaimWhileNextProposalPending_doesNotDistortPnl() public {
        uint256 owed = _escrowForRouter();
        vm.warp(vm.getBlockTimestamp() + 2 hours); // cooldown
        uint256 id2 = _propose();
        vm.prank(makeAddr("griefer"));
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        assertEq(usdg.balanceOf(address(router)), owed);
        _voteAndExecute(governor, id2, lp1);
        vm.recordLogs();
        _settle(vault, governor, id2, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 perf = ISyndicateGovernor.PerformanceFeeCharged.selector;
        bytes32 settled = ISyndicateGovernor.ProposalSettled.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != perf, "no performance fee on a flat proposal");
            if (logs[i].topics[0] == settled) {
                found = true;
                (int256 pnl,,) = abi.decode(logs[i].data, (int256, uint256, uint256));
                assertEq(pnl, 0, "pnl exactly zero: the pre-execute claim did not leak into pnl");
            }
        }
        assertTrue(found, "ProposalSettled was emitted");
    }

    /// @notice During Executed the claim reverts the WHOLE tx (VaultProposalActive), no partial state.
    function test_strangerClaimDuringExecuted_revertsAtomically() public {
        uint256 owed = _escrowForRouter();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 id2 = _propose();
        _voteAndExecute(governor, id2, lp1);
        vm.expectRevert(ISyndicateGovernor.VaultProposalActive.selector);
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        assertEq(governor.unclaimedFees(address(vault), address(router), address(usdg)), owed);
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    // ───────────────────────── (3) cross-vault ─────────────────────────

    function test_crossVault_escrowKeyedPerGovernorVault_poolDistributes() public {
        address lp2 = makeAddr("lp2");
        (SyndicateVault v2, SyndicateGovernor g2) = _deployPair(lp2);
        usdg.setBlacklisted(address(router), true);
        uint256 a = _proposeOn(vault, governor);
        uint256 b = _proposeOn(v2, g2);
        vm.prank(lp1);
        governor.vote(a, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        g2.vote(b, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(a);
        g2.executeProposal(b);
        _settle(vault, governor, a, 10_000e6);
        vm.prank(agent);
        g2.settleProposal(b);
        usdg.setBlacklisted(address(router), false);

        uint256 owedA = governor.unclaimedFees(address(vault), address(router), address(usdg));
        uint256 owedB = g2.unclaimedFees(address(v2), address(router), address(usdg));
        assertGt(owedA, owedB, "vault A had profit");

        // Wrong pairings pull nothing (keys are per (vault, recipient, token) inside each governor).
        router.claimEscrowedFees(address(governor), address(v2), address(usdg));
        router.claimEscrowedFees(address(g2), address(vault), address(usdg));
        assertEq(usdg.balanceOf(address(router)), 0);

        uint256 taB = v2.totalAssets();
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        assertEq(v2.totalAssets(), taB, "claim on A does not touch B");
        assertEq(g2.outstandingEscrow(address(v2), address(usdg)), owedB);
        router.claimEscrowedFees(address(g2), address(v2), address(usdg));
        assertEq(usdg.balanceOf(address(router)), owedA + owedB);

        vm.prank(safe);
        router.setAllocations(_alloc1(foundation));
        router.distribute(address(usdg));
        assertEq(usdg.balanceOf(foundation), owedA + owedB, "pooled, no per-vault attribution in the router");
    }

    // ───────────────────────── Low / Info PoCs ─────────────────────────

    /// @notice L-1: accrued balance is committed to the CURRENT legs; a Safe re-allocation (e.g. to drop
    ///         a compromised target) is front-runnable by anyone calling distribute.
    function test_L1_frontRunReallocation_pushesBalanceToOldLeg() public {
        address compromised = makeAddr("compromisedTarget");
        vm.prank(safe);
        router.setAllocations(_alloc1(compromised));
        // Fees accrue between distributes (e.g. several settlements).
        usdg.mint(address(router), 500_000e6);

        // Safe submits setAllocations(foundation). Attacker's distribute lands first.
        vm.prank(makeAddr("frontrunner"));
        router.distribute(address(usdg));
        vm.prank(safe);
        router.setAllocations(_alloc1(foundation));

        assertEq(usdg.balanceOf(compromised), 500_000e6, "whole accrued balance went to the leg being removed");
        assertEq(usdg.balanceOf(foundation), 0);
        // Hold-first is equally front-runnable: setAllocations([]) itself can be preceded by distribute.
    }

    /// @notice L-2: one frozen leg bricks distribute (and distributeMany) for that token until the Safe acts.
    function test_L2_frozenLegBricksDistribute() public {
        ProtocolFeeRouter.Allocation[] memory a = new ProtocolFeeRouter.Allocation[](2);
        a[0] = ProtocolFeeRouter.Allocation({target: foundation, bps: 5000});
        a[1] = ProtocolFeeRouter.Allocation({target: makeAddr("frozen"), bps: 5000});
        vm.prank(safe);
        router.setAllocations(a);
        usdg.mint(address(router), 1000e6);
        address frozen = makeAddr("frozen");
        usdg.setBlacklisted(frozen, true);
        vm.expectRevert(abi.encodeWithSelector(BlacklistingERC20Mock.Blacklisted.selector, frozen));
        router.distribute(address(usdg));
        assertEq(usdg.balanceOf(foundation), 0, "healthy leg also gets nothing");
        // Fees keep accruing into the router fine (settlement unaffected), recoverable by the Safe.
    }

    /// @notice I-3: claimEscrowedFees is an open "call(selector claimUnclaimedFees, any target, any args)
    ///         from the router". Harmless today because the router holds no authority anywhere except
    ///         as an escrow creditor. A codeless target simply reverts (high-level call extcodesize check).
    function test_I3_codelessGovernorReverts() public {
        vm.expectRevert(bytes(""));
        router.claimEscrowedFees(makeAddr("eoa"), address(vault), address(usdg));
    }

    // ───────────────────────── (4) transition ─────────────────────────

    /// @notice Recipient re-pointed to a not-yet-deployed CREATE3 address: transfers to the codeless
    ///         address succeed and the balance is reachable once the router is deployed there.
    function test_transition_recipientSetBeforeRouterDeployed_feesNotLost() public {
        address future = makeAddr("futureRouterAddress");
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(future);
        _executeAndSettle(_propose(), 50_000e6);
        uint256 got = usdg.balanceOf(future);
        assertGt(got, 0);
        assertEq(governor.outstandingEscrow(address(vault), address(usdg)), 0, "no escrow: delivered");
        vm.etch(future, address(router).code);
        // Ownable storage slot 0 = owner; set it so the etched router has an owner (CREATE3 deploy would).
        vm.store(future, bytes32(uint256(0)), bytes32(uint256(uint160(safe))));
        vm.prank(safe);
        ProtocolFeeRouter(future).rescue(address(usdg), foundation, got);
        assertEq(usdg.balanceOf(foundation), got);
    }

    /// @notice Proposals that straddle the switch: old-snapshot ones pay the old recipient, new ones pay
    ///         the router, across Draft/Pending/Executed at switch time. Sum is conserved (nothing lost).
    function test_transition_straddlingProposals_conserveFees() public {
        address oldR = makeAddr("deployerKey");
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(oldR);
        uint256 id1 = _propose(); // snapshot = oldR
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(address(router)); // switch while id1 Pending
        _executeAndSettle(id1, 10_000e6);
        uint256 oldGot = usdg.balanceOf(oldR);
        assertGt(oldGot, 0);
        assertEq(usdg.balanceOf(address(router)), 0);

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 id2 = _propose();
        // Switch AWAY mid-flight must not reach id2 either.
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(address(0));
        _executeAndSettle(id2, 10_000e6);
        assertGt(usdg.balanceOf(address(router)), 0, "id2 snapshot = router");
        assertEq(usdg.balanceOf(oldR), oldGot);
    }
}
