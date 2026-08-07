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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @notice Stand-in for a strategy clone that currently custodies vault
///         capital. `settle()` is the call the vault MUST still be able to make
///         after the clone is demoted — it moves value in exactly one
///         direction, out of the strategy and back into the vault.
contract HoldingStrategyStub {
    IERC20 public immutable asset;
    address public immutable vault;

    constructor(address asset_, address vault_) {
        asset = IERC20(asset_);
        vault = vault_;
    }

    function settle() external {
        uint256 bal = asset.balanceOf(address(this));
        if (bal != 0) asset.transfer(vault, bal);
    }
}

/**
 * @title Finding #14 — demotion must not revoke the vault's ability to CALL
 * @notice `_adapterAllowed` answered two questions with one bit: "may this
 *         address RECEIVE vault-fund movements?" (`_guardBatchCalls` PART 2b)
 *         and "may the vault CALL this address in a governor batch?" (PART 2a).
 *         `_demote` cleared it, which is correct for the first and catastrophic
 *         for the second when the demoted target is the strategy clone holding
 *         the vault's capital: `settleProposal`, `unstick` AND
 *         `finalizeEmergencySettle` all revert `DisallowedBatchCallee`, the
 *         proposal pins in `Executed`, and every LP exit shuts.
 *
 *         These tests pin the SPLIT, and must be read as a set — any one alone
 *         is satisfiable by a wrong fix:
 *           - `remainsCallable` alone is satisfied by not demoting at all.
 *           - `cannotReceiveValue` alone is satisfied by today's buggy code.
 *           - `explicitRevocation` blocks "just never clear the bit".
 */
contract RegistryDemoteKeepsCalleeStandingTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockProposalStatus governor;
    TierRegistry tierRegistry;
    HoldingStrategyStub strategy;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    // Any selector present in the executed proposal's calldata is challengeable;
    // the execute batch always contains `(clone, execute.selector)`.
    bytes4 constant EXECUTE_SELECTOR = bytes4(keccak256("execute()"));

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
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

        strategy = new HoldingStrategyStub(address(usdc), address(vault));
        tierRegistry.setAdapterAllowed(address(strategy), true);
        tierRegistry.setAuthorizedDemoter(address(this));

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

    function _runBatch(BatchExecutorLib.Call[] memory calls) internal {
        vm.prank(address(governor));
        vault.executeGovernorBatch(calls, new uint256[](0), type(uint256).max);
    }

    /// @dev `demoteByChallenge` requires an existing certification for the pair
    ///      (its anti-grief guard), so the clone must be certified before a
    ///      challenge can demote it. No bond: `submitterBondWood` is 0 on a
    ///      fresh registry, which makes `certify` permissionless.
    function _certify(address target, bytes4 selector) internal {
        tierRegistry.proposeCertification(target, selector, 1, 500, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certify(target, selector);
    }

    /// @notice THE FINDING. The clone holds 5,000 USDC of vault capital when a
    ///         challenge convicts it. The vault must still be able to call
    ///         `settle()` to pull that capital back — otherwise the position is
    ///         stranded and every LP exit is frozen behind it.
    function test_demotedStrategyRemainsCallableSoCapitalCanBeRecovered() public {
        // The clone custodies vault capital (as it would mid-strategy).
        vm.prank(address(vault));
        usdc.transfer(address(strategy), 5_000e6);
        assertEq(usdc.balanceOf(address(strategy)), 5_000e6, "precondition: clone holds capital");

        // A challenge convicts the clone on the selector its execute batch named.
        _certify(address(strategy), EXECUTE_SELECTOR);
        tierRegistry.demoteByChallenge(address(strategy), EXECUTE_SELECTOR);
        assertFalse(tierRegistry.isAdapterAllowed(address(strategy)), "demotion revokes value-receiving standing");

        // The settlement batch must still reach the clone.
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        _runBatch(_one(address(strategy), abi.encodeWithSignature("settle()")));

        assertEq(usdc.balanceOf(address(strategy)), 0, "capital recovered from demoted clone");
        assertEq(usdc.balanceOf(address(vault)), vaultBefore + 5_000e6, "capital returned to vault");
    }

    /// @notice The other half of the split, and the reason this cannot be fixed
    ///         by simply not clearing the bit: a demoted clone must still be
    ///         refused as a RECIPIENT of vault funds. That is what demotion is
    ///         for, and a fix that restores callability must not restore this.
    function test_demotedStrategyStillCannotReceiveVaultFunds() public {
        _certify(address(strategy), EXECUTE_SELECTOR);
        tierRegistry.demoteByChallenge(address(strategy), EXECUTE_SELECTOR);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector,
                address(usdc),
                IERC20.transfer.selector,
                address(strategy)
            )
        );
        _runBatch(_one(address(usdc), abi.encodeCall(IERC20.transfer, (address(strategy), 1_000e6))));
    }

    /// @notice An EXPLICIT owner revocation is a different act from a demotion
    ///         and must still close both axes — otherwise the split becomes a
    ///         way to keep calling an address governance has fully delisted.
    function test_explicitOwnerRevocationClosesCalleeStandingToo() public {
        tierRegistry.setAdapterAllowed(address(strategy), false);

        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchCallee.selector, address(strategy)));
        _runBatch(_one(address(strategy), abi.encodeWithSignature("settle()")));
    }

    /// @notice THE CLASS-PATH VERSION OF THE TEST ABOVE, and the one that
    ///         actually bites. The address-entry version passes even with a
    ///         broken predicate, because a `new`-deployed stub has an address
    ///         entry for `setAdapterAllowed(a,false)` to clear — it never
    ///         reaches the class fallback at all.
    ///
    /// @dev    A CLASS-CERTIFIED CLONE HAS NO ADDRESS ENTRY. `_calleeAllowed`
    ///         is already false for it, so clearing that flag bites nothing,
    ///         and the class fallback re-allows it on the very next read. The
    ///         first cut of `isCallableTarget` dropped `_classAllowDenied`
    ///         wholesale to keep DEMOTED clones reachable — which also deleted
    ///         the only per-member denial lever an owner has over a class
    ///         member, permanently, and anyone may permissionlessly deploy an
    ///         ERC-1167 clone of a certified template to become one. Hence the
    ///         dedicated `_calleeRevoked` flag, which `_demote` never writes.
    function test_explicitOwnerRevocationClosesCalleeStandingForAClassMember() public {
        // A real class member: an ERC-1167 clone of a certified template, with
        // no address entry of its own.
        address clone = Clones.clone(address(strategy));
        tierRegistry.proposeClassCertification(
            address(strategy), EXECUTE_SELECTOR, 1, 500, address(0), address(strategy).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay() + 1);
        tierRegistry.certifyClass(address(strategy), EXECUTE_SELECTOR);
        tierRegistry.setClassAllowed(address(strategy), true);

        assertTrue(tierRegistry.isCallableTarget(clone), "precondition: reachable via the class path");

        // The owner delists this specific member. It has no address entry, so
        // this must bite through the class fallback or it bites nothing.
        tierRegistry.setAdapterAllowed(clone, false);

        assertFalse(tierRegistry.isCallableTarget(clone), "explicit revocation must close the class path too");
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchCallee.selector, clone));
        _runBatch(_one(clone, abi.encodeWithSignature("settle()")));
    }

    /// @notice The other half: a DEMOTED class member must STAY callable, or
    ///         the new flag has simply re-created the bug it was added to fix.
    function test_demotedClassMemberRemainsCallable() public {
        address clone = Clones.clone(address(strategy));
        tierRegistry.proposeClassCertification(
            address(strategy), EXECUTE_SELECTOR, 1, 500, address(0), address(strategy).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay() + 1);
        tierRegistry.certifyClass(address(strategy), EXECUTE_SELECTOR);
        tierRegistry.setClassAllowed(address(strategy), true);

        tierRegistry.demoteClassByChallenge(address(strategy), EXECUTE_SELECTOR);

        assertTrue(tierRegistry.isCallableTarget(clone), "a conviction must not strand the capital it holds");
    }
}
