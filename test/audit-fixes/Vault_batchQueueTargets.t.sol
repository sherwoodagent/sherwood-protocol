// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev A tier registry that allows nothing. Present only so
///      `_guardBatchCalls` does NOT take either of its early returns: a
///      governor with no `tierRegistry()` getter, or one returning the zero
///      address, skips the guard loop entirely. The defect under test is about
///      what the guard fails to check when it DOES run, so the fixture has to
///      get past both returns or it would prove nothing.
contract DenyAllTierRegistry {
    function isAdapterAllowed(address) external pure returns (bool) {
        return false;
    }
}

/// @title Vault_batchQueueTargets
/// @notice Issue #93 — a governor batch could reach the withdrawal queue's
///         `onlyVault` entrypoints, because `BatchExecutorLib.executeBatch`
///         runs under `delegatecall` (so every call carries
///         `msg.sender == vault`) while `calls[i].target` was constrained by
///         nothing: not `_guardBatchCalls`, which inspected `data` selectors
///         only; not the governor; not the TierRegistry.
///
///         Every test below was written against unpatched `main` and PASSED
///         there — the theft, the pre-brick and the deposit mint all worked.
///         They now assert `DisallowedBatchTarget` instead, so each one is a
///         live regression test for one reachable consequence rather than a
///         restatement of the same guard.
///
/// @dev    WHY EVERY EXISTING METER MISSES IT. `queueRedeem` moves zero
///         `asset()` out of the vault, so `netOutflow == 0` clears
///         `maxNetOutflow` for ANY `maxCapital`, `QueueReserveBreached` and
///         `BufferBreached` both compare balances that never moved, and the
///         selector is not one of {approve, increaseAllowance, transfer,
///         transferFrom}. The value leaves in a LATER transaction through
///         `queue.claim`, which no meter watches at all.
contract VaultBatchQueueTargetsTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    DenyAllTierRegistry tiers;

    address owner = makeAddr("owner");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");
    address constant MOCK_GOVERNOR = address(0xF00D);

    uint256 constant DEPOSIT = 1_000e6;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        tiers = new DenyAllTierRegistry();

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
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Test contract acts as factory; queue is deployed and bound by it.
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(0)));
        // The guard staticcalls this on the governor; a real address makes the
        // guard run its loop rather than degrade to "unset".
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("tierRegistry()"), abi.encode(address(tiers)));

        usdc.mint(victim, DEPOSIT);
        vm.prank(victim);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setProposalActive(bool active) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(active ? uint256(1) : uint256(0))
        );
    }

    /// @dev The victim deposits and escrows a redeem against pid 1, leaving its
    ///      shares in the queue's custody. Returns the escrowed share count.
    function _victimEscrowsRedeem() internal returns (uint256 shares) {
        vm.prank(victim);
        shares = vault.deposit(DEPOSIT, victim);

        _setProposalActive(true);
        vm.prank(victim);
        vault.requestRedeem(shares, victim);

        assertEq(vault.balanceOf(address(queue)), shares, "the queue custodies the victim's shares");
        assertEq(vault.balanceOf(victim), 0, "the victim holds none directly");
    }

    function _batch(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: target, value: 0, data: data});
    }

    /// @notice THE THEFT. A governor batch mints the attacker a redeem claim
    ///         against shares the VICTIM escrowed, then the attacker claims and
    ///         walks off with the victim's assets.
    /// @dev    `maxNetOutflow` is 1 wei — deliberately the smallest cap the
    ///         governor could ever pass. It never binds, because the batch
    ///         moves no `asset()` at all.
    function test_governorBatch_cannotMintRedeemClaimAgainstAnotherOwnersEscrow() public {
        uint256 shares = _victimEscrowsRedeem();

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        vault.executeGovernorBatch(
            _batch(address(queue), abi.encodeCall(IVaultWithdrawalQueue.queueRedeem, (attacker, shares, 1))),
            new uint256[](0),
            1
        );

        // No claim was minted, so there is nothing for the attacker to redeem.
        assertEq(queue.getRequestsByOwner(attacker).length, 0, "the attacker holds no claim");

        // And the victim's own claim still pays, in full, at the settled price:
        // the guard rejects the batch without disturbing honest queue flow.
        _setProposalActive(false);
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalSettled(1);

        uint256[] memory victimIds = queue.getRequestsByOwner(victim);
        assertEq(victimIds.length, 1);
        uint256 victimBefore = usdc.balanceOf(victim);
        vm.prank(victim);
        queue.claim(victimIds[0]);
        assertEq(usdc.balanceOf(victim) - victimBefore, DEPOSIT, "the victim is made whole");
    }

    /// @notice THE BRICK. `stampSettlement` is reachable for ANY pid, including
    ///         ones that have not happened yet, and the stamp is one-shot
    ///         (`AlreadySettled`). One batch can therefore pre-burn the
    ///         settlement slot of every future proposal, and each burned slot
    ///         makes `onProposalSettled` revert forever — which reverts the
    ///         governor's whole settlement transaction, stopping LP flow.
    /// @dev    FUTURE pids, not the executing one. Stamping the pid that owns
    ///         live queued redeems reserves assets mid-batch, and the existing
    ///         post-batch `QueueReserveBreached` check then reverts the whole
    ///         thing — an accidental partial mitigation that covers exactly one
    ///         case. A pid with no queued redeems reserves nothing and sails
    ///         through, so the guard has to reject the TARGET, not rely on a
    ///         balance side effect.
    function test_governorBatch_cannotPreBrickFutureSettlements() public {
        _victimEscrowsRedeem();

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] = BatchExecutorLib.Call({
                target: address(queue),
                value: 0,
                data: abi.encodeCall(IVaultWithdrawalQueue.stampSettlement, (i + 2, 1, 1))
            });
        }

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        vault.executeGovernorBatch(calls, new uint256[](0), 1);

        // No slot was burned, so every one of those settlements still lands.
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(queue.getSettlePrice(i + 2).stamped, "no future pid was stamped");
            _setProposalActive(false);
            vm.prank(MOCK_GOVERNOR);
            vault.onProposalSettled(i + 2);
            assertTrue(queue.getSettlePrice(i + 2).stamped, "and settlement stamps it normally");
        }
    }

    /// @notice THE DEPOSIT LEG. `queueDeposit` mints a claim on escrowed
    ///         assets the attacker never posted.
    function test_governorBatch_cannotMintDepositClaimOutOfThinAir() public {
        _victimEscrowsRedeem();

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        vault.executeGovernorBatch(
            _batch(address(queue), abi.encodeCall(IVaultWithdrawalQueue.queueDeposit, (attacker, DEPOSIT, 1))),
            new uint256[](0),
            1
        );

        assertEq(queue.getRequestsByOwner(attacker).length, 0, "no unfunded deposit claim exists");
    }

    /// @notice THE VAULT ITSELF is the other privileged callee reachable this
    ///         way — `msg.sender == vault` satisfies every `NotQueue`-style
    ///         self-gate exactly as it satisfies `onlyVault`.
    /// @dev    Asserted as a TARGET-CLASS property with a harmless view call
    ///         rather than through one specific self-call, so the guard is
    ///         pinned to reject the class and not merely today's worst
    ///         instance.
    function test_governorBatch_cannotTargetTheVaultItself() public {
        _victimEscrowsRedeem();

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(vault)));
        vault.executeGovernorBatch(
            _batch(address(vault), abi.encodeCall(ISyndicateVault.reservedQueueAssets, ())), new uint256[](0), 1
        );
    }

    /// @notice THE GATE DOES NOT INHERIT THE REGISTRY EXEMPTION. `_guardBatchCalls`
    ///         returns early when the governor exposes no `tierRegistry()` or
    ///         has none wired, and being unguarded there is a documented,
    ///         accepted default for the SELECTOR guard. The target gate must
    ///         still bite — a vault deployed without a registry is the one that
    ///         needs it most, and placing the check after those returns is the
    ///         easy way to get this wrong.
    function test_targetGate_bitesEvenWithNoTierRegistryWired() public {
        _victimEscrowsRedeem();
        // Registry unset: the selector guard below would return early here.
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("tierRegistry()"), abi.encode(address(0)));

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        vault.executeGovernorBatch(
            _batch(address(queue), abi.encodeCall(IVaultWithdrawalQueue.stampSettlement, (2, 1, 1))),
            new uint256[](0),
            1
        );
    }

    /// @notice THE GATE DOES NOT INHERIT IT FROM A MISSING GETTER EITHER — the
    ///         other early return, reached when the staticcall itself fails.
    function test_targetGate_bitesEvenWhenGovernorHasNoTierGetter() public {
        _victimEscrowsRedeem();
        vm.clearMockedCalls();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(0)));
        // No `tierRegistry()` mock at all: the staticcall fails, second return.

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchTarget.selector, address(queue)));
        vault.executeGovernorBatch(
            _batch(address(queue), abi.encodeCall(IVaultWithdrawalQueue.stampSettlement, (2, 1, 1))),
            new uint256[](0),
            1
        );
    }

    /// @notice ORDINARY TARGETS ARE UNAFFECTED. The gate rejects two specific
    ///         addresses, not batches in general — a guard that broke honest
    ///         strategy execution would be worse than the hole it closed.
    function test_ordinaryTargetsStillExecute() public {
        _victimEscrowsRedeem();

        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_batch(address(usdc), abi.encodeCall(ERC20Mock.decimals, ())), new uint256[](0), 1);
    }

    /// @notice ADAPTERS STAY REACHABLE — the regression that matters most.
    ///         `BaseStrategy.execute` / `settle` are `onlyVault` too, so they
    ///         are satisfied by the very same delegatecall credential that made
    ///         the queue reachable. But they are the LEGITIMATE batch surface:
    ///         a denylist that caught them would break every honest proposal,
    ///         which is worse than the hole it closed.
    ///
    /// @dev    The guard compares `calls[i].target` against exactly two
    ///         addresses and never inspects the callee's own access control, so
    ///         adapters are structurally out of reach of it. This test asserts
    ///         that rather than arguing it — an argument rots the moment someone
    ///         widens the denylist, an assertion fails loudly.
    ///
    ///         Uses a real `BaseStrategy` subclass (cloned, since the
    ///         constructor marks the template initialized), not a bare mock, so
    ///         the production `onlyVault` bodies are the ones being reached.
    function test_adapterOnlyVaultEntrypointsStayReachable() public {
        MockStrategy template = new MockStrategy();
        MockStrategy strategy = MockStrategy(Clones.clone(address(template)));
        strategy.initialize(address(vault), owner, abi.encode(address(usdc), address(0), uint256(0), uint256(0), false));

        // execute() — onlyVault, named as a batch target, runs.
        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(
            _batch(address(strategy), abi.encodeCall(BaseStrategy.execute, ())), new uint256[](0), 1
        );
        assertEq(strategy.executeCount(), 1, "adapter execute() ran through the batch");

        // settle() — same.
        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(
            _batch(address(strategy), abi.encodeCall(BaseStrategy.settle, ())), new uint256[](0), 1
        );
        assertEq(strategy.settleCount(), 1, "adapter settle() ran through the batch");
    }
}
