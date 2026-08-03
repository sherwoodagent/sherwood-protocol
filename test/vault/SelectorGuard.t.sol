// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";

/// @notice Governor stand-in WITHOUT a `tierRegistry()` getter — models a
///         pre-tier-registry governor. The vault must treat it exactly like an
///         unset registry (guard off) instead of bricking every batch.
contract MockGovernorNoTierGetter {
    function getActiveProposal() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Findings 1+7 — value-moving-selector allowlist gate. The net-outflow
///         meter only sees the vault's own asset() balance delta, so a batch
///         call like `token.approve(attacker, max)` metered zero and let the
///         attacker drain via transferFrom in a later tx. `executeGovernorBatch`
///         now decodes the spender/recipient of approve / increaseAllowance /
///         transfer / transferFrom calls and requires it to be the vault itself
///         or an adapter allowlisted in the TierRegistry (resolved through the
///         calling governor). Applies to every batch path — execute, settle,
///         and both emergency paths all flow through `executeGovernorBatch`.
contract SelectorGuardTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    ERC20Mock otherToken;
    MockAgentRegistry agentRegistry;
    MockProposalStatus governor;
    TierRegistry tierRegistry;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address adapter = makeAddr("adapter");

    bytes4 constant SEL_APPROVE = 0x095ea7b3;
    bytes4 constant SEL_INCREASE_ALLOWANCE = 0x39509351;
    bytes4 constant SEL_TRANSFER = 0xa9059cbb;
    bytes4 constant SEL_TRANSFER_FROM = 0x23b872dd;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        otherToken = new ERC20Mock("Other", "OTH", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        tierRegistry = new TierRegistry(address(this));

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

        governor = new MockProposalStatus();
        governor.setTierRegistry(address(tierRegistry));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        tierRegistry.setAdapterAllowed(adapter, true);

        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    function _one(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _exec(BatchExecutorLib.Call[] memory calls) internal {
        vm.prank(address(governor));
        vault.executeGovernorBatch(calls, type(uint256).max);
    }

    function _expectDisallowed(address target, bytes4 sel, address recipient) internal {
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferTarget.selector, target, sel, recipient)
        );
    }

    // ── approve / increaseAllowance ──

    /// @notice THE core exfiltration vector: approve moves no balance, so the
    ///         net-outflow meter passes it — the selector guard must not.
    function test_approveToNonAllowlistedReverts() public {
        _expectDisallowed(address(usdc), SEL_APPROVE, attacker);
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (attacker, type(uint256).max))));
    }

    function test_approveToAllowlistedAdapterPasses() public {
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (adapter, 500e6))));
        assertEq(usdc.allowance(address(vault), adapter), 500e6);
    }

    function test_increaseAllowanceToNonAllowlistedReverts() public {
        _expectDisallowed(address(usdc), SEL_INCREASE_ALLOWANCE, attacker);
        _exec(_one(address(usdc), abi.encodeWithSelector(SEL_INCREASE_ALLOWANCE, attacker, type(uint256).max)));
    }

    /// @notice Guard covers EVERY token the vault holds, not just asset() —
    ///         the meter never sees non-asset balances at all.
    function test_approveNonAssetTokenToNonAllowlistedReverts() public {
        otherToken.mint(address(vault), 1_000e18);
        _expectDisallowed(address(otherToken), SEL_APPROVE, attacker);
        _exec(_one(address(otherToken), abi.encodeCall(otherToken.approve, (attacker, type(uint256).max))));
    }

    // ── transfer / transferFrom ──

    function test_transferToNonAllowlistedReverts() public {
        _expectDisallowed(address(usdc), SEL_TRANSFER, attacker);
        _exec(_one(address(usdc), abi.encodeCall(usdc.transfer, (attacker, 1e6))));
    }

    function test_transferToAllowlistedAdapterPasses() public {
        _exec(_one(address(usdc), abi.encodeCall(usdc.transfer, (adapter, 1e6))));
        assertEq(usdc.balanceOf(adapter), 1e6);
    }

    /// @notice issue #115 (LP-allowance confiscation). This test used to be
    ///         `test_transferFromIntoVaultPasses` and pinned "pull into the
    ///         vault always passes" as INTENDED behaviour: it minted `sink`
    ///         100e6, had `sink` approve the vault, then asserted a batch
    ///         `transferFrom(sink, vault, 100e6)` succeeded because `to ==
    ///         vault` reads as an inflow. That is exactly the confiscation
    ///         primitive — a governor batch runs under delegatecall, so
    ///         `msg.sender == vault` on every sub-call, and `transferFrom`
    ///         only needs `allowance[from][vault]` to be set. Any LP's deposit
    ///         allowance (routinely `type(uint256).max`) qualifies; net-outflow
    ///         reads 0 because the vault's OWN balance rises, so no other meter
    ///         sees it. The old assertion was deliberately removed and replaced
    ///         with this regression: the source (`from`) must equal the vault
    ///         itself, unconditionally, or the batch reverts.
    function test_transferFromThirdPartySourceReverts_LPAllowanceConfiscation() public {
        address sink = makeAddr("sink");
        usdc.mint(sink, 100e6);
        vm.prank(sink);
        usdc.approve(address(vault), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, address(usdc), sink)
        );
        _exec(_one(address(usdc), abi.encodeCall(usdc.transferFrom, (sink, address(vault), 100e6))));

        assertEq(usdc.balanceOf(sink), 100e6);
        assertEq(usdc.allowance(sink, address(vault)), type(uint256).max);
    }

    /// @notice Decision 1 (design.md): destination allowlisting confers no
    ///         source consent. `adapter` is allowlisted as a RECIPIENT
    ///         (`isAdapterAllowed`), which says nothing about whether a batch
    ///         may pull FROM it — guards against a future "symmetric" refactor
    ///         that reuses the destination allowlist as a source allowlist.
    function test_transferFromFromAllowlistedAdapterReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, address(usdc), adapter)
        );
        _exec(_one(address(usdc), abi.encodeCall(usdc.transferFrom, (adapter, address(vault), 1e6))));
    }

    /// @notice Decision 4 (design.md): `from == address(this)` stays permitted
    ///         — `transferFrom(vault, x, amt)` is semantically `transfer(x,
    ///         amt)`. The self-approve creates `allowance[vault][vault]`
    ///         (guarded by Part 2, recipient == vault); the pull then spends it
    ///         and lands on an allowlisted adapter.
    function test_vaultSourcedTransferFromToAllowlistedAdapterPasses() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(vault), 1e6)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transferFrom, (address(vault), adapter, 1e6)), value: 0
        });
        _exec(calls);
        assertEq(usdc.balanceOf(adapter), 1e6);
    }

    /// @notice Decision 4 companion: the source guard permits `from == vault`,
    ///         but Part 2's destination guard is untouched — a vault-sourced
    ///         pull to a non-allowlisted recipient still reverts
    ///         `DisallowedTransferTarget`. Also doubles as task 2.4's pinned
    ///         scenario (vault-sourced-to-non-allowlisted-recipient).
    function test_transferFromToNonAllowlistedReverts() public {
        _expectDisallowed(address(usdc), SEL_TRANSFER_FROM, attacker);
        _exec(_one(address(usdc), abi.encodeCall(usdc.transferFrom, (address(vault), attacker, 1e6))));
    }

    /// @notice Self-targets are harmless: approving/transferring to the vault
    ///         itself moves nothing out of custody.
    function test_approveToVaultItselfPasses() public {
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (address(vault), 1e6))));
    }

    // ── malformed calldata ──

    function test_guardedSelectorWithShortCalldataReverts() public {
        // approve selector + 8 bytes of args — cannot hold a full address word.
        vm.expectRevert(ISyndicateVault.MalformedCall.selector);
        _exec(_one(address(usdc), abi.encodePacked(SEL_APPROVE, uint64(0xdead))));
    }

    /// @notice transferFrom selector + a single 32-byte word — no `to`
    ///         argument. Now caught by the SOURCE guard's own length check in
    ///         PART 1 (`data.length < 68`), before Part 2 ever runs — still
    ///         `MalformedCall`, same as before this change, just from a
    ///         different (earlier, unconditional) site.
    function test_transferFromWithOnlyOneArgReverts() public {
        vm.expectRevert(ISyndicateVault.MalformedCall.selector);
        _exec(_one(address(usdc), abi.encodePacked(SEL_TRANSFER_FROM, uint256(uint160(attacker)))));
    }

    /// @notice Registry-less twin of the test above. Decision 2 (design.md)
    ///         accepted side effect: short `transferFrom` calldata now reverts
    ///         `MalformedCall` UNCONDITIONALLY, including with the registry
    ///         unset — previously this calldata was never inspected when the
    ///         registry was unset (Part 2 returned early) and the batch would
    ///         have proceeded to execute.
    function test_transferFromWithOnlyOneArgReverts_RegistryUnset() public {
        governor.setTierRegistry(address(0));
        vm.expectRevert(ISyndicateVault.MalformedCall.selector);
        _exec(_one(address(usdc), abi.encodePacked(SEL_TRANSFER_FROM, uint256(uint160(attacker)))));
    }

    // ── unset registry / legacy governor: guard off by design (Part 2 only) ──

    /// @notice Registry unset (address(0)) on the governor → the batch runs
    ///         UNguarded. Documented v1 posture: an unset registry already means
    ///         tier-2/full-notional pricing; hard-reverting here would brick
    ///         vaults deployed without a registry.
    function test_unsetRegistryExecutesWithoutGate() public {
        governor.setTierRegistry(address(0));
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 1e6))));
        assertEq(usdc.allowance(address(vault), attacker), 1e6);
    }

    /// @notice A governor without the `tierRegistry()` getter (pre-registry
    ///         deployment) resolves like an unset registry — guard off, batch
    ///         executes.
    function test_governorWithoutTierGetterExecutesWithoutGate() public {
        MockGovernorNoTierGetter legacy = new MockGovernorNoTierGetter();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(legacy)));

        vm.prank(address(legacy));
        vault.executeGovernorBatch(
            _one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 1e6))), type(uint256).max
        );
        assertEq(usdc.allowance(address(vault), attacker), 1e6);
    }

    // ── transferFrom source guard (PART 1b) is unconditional — degrade-open coverage ──

    /// @notice Decision 2 (design.md): the source check is UNCONDITIONAL, so it
    ///         must still bite with the registry unset — mirrors the #93
    ///         pattern (`test_targetGate_bitesEvenWithNoTierRegistryWired`).
    ///         The audit-diff placement (inside Part 2) would have let this
    ///         pass; this test pins that it doesn't.
    function test_transferFromSourceGuard_bitesEvenWithNoTierRegistryWired() public {
        governor.setTierRegistry(address(0));
        address sink = makeAddr("sink2");
        usdc.mint(sink, 50e6);
        vm.prank(sink);
        usdc.approve(address(vault), 50e6);

        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, address(usdc), sink)
        );
        _exec(_one(address(usdc), abi.encodeCall(usdc.transferFrom, (sink, address(vault), 50e6))));
    }

    /// @notice Decision 2 companion: same, but for a governor predating the
    ///         `tierRegistry()` getter entirely (mirrors
    ///         `test_targetGate_bitesEvenWhenGovernorHasNoTierGetter`).
    function test_transferFromSourceGuard_bitesEvenWhenGovernorHasNoTierGetter() public {
        MockGovernorNoTierGetter legacy = new MockGovernorNoTierGetter();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(legacy)));

        address sink = makeAddr("sink3");
        usdc.mint(sink, 50e6);
        vm.prank(sink);
        usdc.approve(address(vault), 50e6);

        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.DisallowedTransferFromSource.selector, address(usdc), sink)
        );
        vm.prank(address(legacy));
        vault.executeGovernorBatch(
            _one(address(usdc), abi.encodeCall(usdc.transferFrom, (sink, address(vault), 50e6))), type(uint256).max
        );
    }

    // ── non-guarded selectors stay unrestricted ──

    function test_nonGuardedSelectorPassesUntouched() public {
        // balanceOf(address) — harmless read selector routed through the batch.
        _exec(_one(address(usdc), abi.encodeCall(usdc.balanceOf, (attacker))));
    }
}
