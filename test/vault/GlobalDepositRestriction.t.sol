// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../../src/interfaces/IStakedWood.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice The factory's `depositsRestricted` flag closes every vault to non-whitelisted
///         depositors, whatever the vault's own `openDeposits`, and never touches exits.
contract GlobalDepositRestrictionTest is Test {
    event DepositsRestrictedUpdated(bool restricted);

    SyndicateFactory factory;
    SyndicateVault vault;
    ERC20Mock usdc;
    address governor;

    address owner = makeAddr("owner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice"); // not whitelisted
    address carol = makeAddr("carol"); // whitelisted
    address guardianRegistry = makeAddr("guardianRegistry");
    address swood = makeAddr("swood");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        MockAgentRegistry agentRegistry = new MockAgentRegistry();
        GovernorBeacon beacon = new GovernorBeacon(address(new SyndicateGovernor(24 hours, 1 hours)), owner);

        bytes memory init = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(new BatchExecutorLib()),
                    vaultImpl: address(new SyndicateVault()),
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(new ProtocolConfig(owner)),
                    managementFeeBps: 50,
                    guardianRegistry: guardianRegistry,
                    tierRegistry: address(new TierRegistry(owner))
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(new SyndicateFactory()), init)));

        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.addGovernor.selector), "");
        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.swood.selector), abi.encode(swood));
        vm.mockCall(swood, abi.encodeWithSelector(IStakedWood.canCreateVault.selector), abi.encode(true));
        vm.mockCall(swood, abi.encodeWithSelector(IStakedWood.bindOwnerStake.selector), "");

        uint256 agentId = agentRegistry.mint(creator);
        vm.prank(creator);
        (, address v) = factory.createSyndicate(
            agentId,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://QmTest",
                asset: usdc,
                name: "Open Vault",
                symbol: "oV",
                openDeposits: true,
                subdomain: "open-vault"
            })
        );
        vault = SyndicateVault(payable(v));
        governor = factory.governorOf(v);

        vm.prank(creator);
        vault.approveDepositor(carol);
        _fund(alice);
        _fund(carol);
    }

    function _fund(address who) internal {
        usdc.mint(who, 1_000e6);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _restrict(bool restricted) internal {
        vm.prank(owner);
        factory.setDepositsRestricted(restricted);
    }

    function _openProposal() internal {
        vm.mockCall(governor, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(1)));
        vm.mockCall(governor, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(1)));
    }

    /// @notice Restricted, a non-whitelisted receiver is refused on every deposit path of an open vault.
    function test_restricted_refusesNonWhitelistedOnEveryDepositPath() public {
        _restrict(true);
        assertTrue(vault.openDeposits(), "the per-vault flag is untouched");
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit");
        assertEq(vault.maxMint(alice), 0, "maxMint");

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.NotApprovedDepositor.selector);
        vault.deposit(100e6, alice);

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.NotApprovedDepositor.selector);
        vault.mint(100e6, alice);

        _openProposal();
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.NotApprovedDepositor.selector);
        vault.requestDeposit(100e6, alice);
    }

    /// @notice Restricted, an approved depositor still deposits and mints.
    function test_restricted_whitelistedDepositorStillDeposits() public {
        _restrict(true);
        assertEq(vault.maxDeposit(carol), type(uint256).max, "maxDeposit");

        vm.startPrank(carol);
        vault.deposit(100e6, carol);
        vault.mint(1e6, carol);
        vm.stopPrank();
        assertGt(vault.balanceOf(carol), 0, "carol holds shares");
    }

    /// @notice Restricted, an existing holder still withdraws, redeems and queues an exit.
    function test_restricted_existingHolderStillExits() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(300e6, alice);
        _restrict(true);

        vm.startPrank(alice);
        vault.withdraw(100e6, alice, alice);
        vault.redeem(shares / 3, alice, alice);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 700e6 + 100e6 + vault.convertToAssets(shares / 3), "paid out");

        _openProposal();
        uint256 rest = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(rest, alice);
        assertGt(requestId, 0, "queued exit accepted");
        assertEq(vault.balanceOf(alice), 0, "shares escrowed in the queue");
    }

    /// @notice Lifting the restriction reopens an open vault to non-whitelisted depositors.
    function test_lift_restoresOpenDeposits() public {
        _restrict(true);
        assertEq(vault.maxDeposit(alice), 0, "restricted");
        _restrict(false);
        assertEq(vault.maxDeposit(alice), type(uint256).max, "lifted");
        vm.prank(alice);
        vault.deposit(100e6, alice);
        assertGt(vault.balanceOf(alice), 0, "alice deposited");
    }

    /// @notice Only the factory owner flips the flag, and each flip is logged.
    function test_setDepositsRestricted_onlyOwnerAndEmits() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, creator));
        factory.setDepositsRestricted(true);
        assertFalse(factory.depositsRestricted(), "unchanged");

        vm.expectEmit(address(factory));
        emit DepositsRestrictedUpdated(true);
        _restrict(true);
        assertTrue(factory.depositsRestricted(), "set");
    }
}
