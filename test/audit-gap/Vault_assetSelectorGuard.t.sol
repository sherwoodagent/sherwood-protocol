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

/// @notice Allowlisted batch target that accepts any calldata — stands in for
///         an adapter whose selectors the guard's switch does not (and should
///         not) enumerate, pinning that the terminal `continue` still holds
///         for every non-`asset()` target.
contract AcceptAllTarget {
    fallback() external payable {}
}

/// @title Vault_assetSelectorGuard
/// @notice Design-pin suite for PR #196's `_guardBatchCalls` PART 2b rule:
///         `asset()` is the sole target exempt from the PART 2a callee
///         allowlist, on the premise that the outer `netOutflow` balance diff
///         independently verifies it. A balance diff sees value MOVEMENT — it
///         cannot see an authorization GRANT. ERC-777 `authorizeOperator`
///         (0x959b8c3f) moves nothing in-batch and licenses an unbounded pull
///         in a later transaction, and (declared at cap 0) prices to zero
///         coverage, zero proposer bond, and an unchallengeable proposal. So
///         any unrecognized, non-view selector on `asset()` must revert
///         `UnrecognizedAssetSelector`, while the standard ERC-20 reads stay
///         allowed and every other target keeps the terminal `continue`.
contract Vault_assetSelectorGuardTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockProposalStatus governor;
    TierRegistry tierRegistry;
    AcceptAllTarget acceptAll;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address adapter = makeAddr("adapter");

    // ERC-777 operator-authorization grant — the canonical selector the
    // balance-diff premise cannot see (`cast sig "authorizeOperator(address)"`).
    bytes4 constant SEL_AUTHORIZE_OPERATOR = 0x959b8c3f;
    // ERC-777 send(address,uint256,bytes) — value-moving but unrecognized by
    // the PART 2b switch; must be refused on asset() rather than silently
    // metered.
    bytes4 constant SEL_ERC777_SEND = 0x9bd9bbc6;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        tierRegistry = new TierRegistry(address(this));
        acceptAll = new AcceptAllTarget();

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
        tierRegistry.setAdapterAllowed(address(acceptAll), true);

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
        vault.executeGovernorBatch(calls, new uint256[](0), type(uint256).max);
    }

    // ── The hazard itself ──

    /// @notice THE core pin: `authorizeOperator` on `asset()` moves zero
    ///         balance in-batch (invisible to `netOutflow`) and licenses an
    ///         unbounded later pull. Must revert, not slide through the old
    ///         terminal `continue`.
    function test_authorizeOperatorOnAssetReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.UnrecognizedAssetSelector.selector, SEL_AUTHORIZE_OPERATOR)
        );
        _exec(_one(address(usdc), abi.encodeWithSelector(SEL_AUTHORIZE_OPERATOR, attacker)));
    }

    /// @notice Any other unenumerated state-changing selector on `asset()`
    ///         gets the same treatment — the rule is default-deny, not an
    ///         `authorizeOperator` denylist.
    function test_erc777SendOnAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.UnrecognizedAssetSelector.selector, SEL_ERC777_SEND));
        _exec(_one(address(usdc), abi.encodeWithSelector(SEL_ERC777_SEND, attacker, uint256(1e6), bytes(""))));
    }

    // ── The carve-outs ──

    /// @notice The standard ERC-20 reads are a closed, enumerable set that
    ///         grants nothing — a batch legitimately calls them on `asset()`
    ///         (a strategy reading `balanceOf` mid-batch). All six must pass.
    function test_benignAssetReadsPass() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](6);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.balanceOf, (address(vault))), value: 0
        });
        calls[1] = BatchExecutorLib.Call({target: address(usdc), data: abi.encodeCall(usdc.decimals, ()), value: 0});
        calls[2] = BatchExecutorLib.Call({target: address(usdc), data: abi.encodeCall(usdc.totalSupply, ()), value: 0});
        calls[3] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.allowance, (address(vault), adapter)), value: 0
        });
        calls[4] = BatchExecutorLib.Call({target: address(usdc), data: abi.encodeCall(usdc.symbol, ()), value: 0});
        calls[5] = BatchExecutorLib.Call({target: address(usdc), data: abi.encodeCall(usdc.name, ()), value: 0});
        _exec(calls); // must not revert
    }

    /// @notice The recognized value-moving selectors keep their own gates —
    ///         they must NOT fall into the unrecognized-selector rejection.
    ///         `approve` to an allowlisted adapter passed PART 2b's spender
    ///         check before this change and must still pass after it.
    function test_recognizedSelectorOnAssetStillRoutesThroughItsOwnGate() public {
        _exec(_one(address(usdc), abi.encodeCall(usdc.approve, (adapter, 500e6))));
        assertEq(usdc.allowance(address(vault), adapter), 500e6);
    }

    // ── The scoping ──

    /// @notice The terminal `continue` is load-bearing for every NON-asset
    ///         target: an allowlisted adapter's arbitrary selectors (a
    ///         strategy's `execute()`, an adapter's `swap()`) are exactly
    ///         what a batch exists to call. The rejection must be scoped to
    ///         `asset()` alone.
    function test_unrecognizedSelectorOnAllowlistedNonAssetTargetPasses() public {
        _exec(_one(address(acceptAll), abi.encodeWithSelector(SEL_AUTHORIZE_OPERATOR, attacker)));
    }
}
