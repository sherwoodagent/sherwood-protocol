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
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../../src/interfaces/IStakedWood.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice An owner-granted sponsorship waives exactly one creation fee for exactly one creator.
contract SponsoredCreationTest is Test {
    event CreationSponsored(address indexed creator, bool sponsored);

    uint256 constant FEE = 170_000e18;

    SyndicateFactory factory;
    MockAgentRegistry agentRegistry;
    ERC20Mock usdc;
    ERC20Mock wood;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address sponsored = makeAddr("sponsored");
    address stranger = makeAddr("stranger");
    address guardianRegistry = makeAddr("guardianRegistry");
    address swood = makeAddr("swood");
    uint256 nonce;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("Wood", "WOOD", 18);
        agentRegistry = new MockAgentRegistry();
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

        vm.prank(owner);
        factory.setCreationFee(address(wood), FEE, treasury);
    }

    function _sponsor(address creator, bool on) internal {
        vm.prank(owner);
        factory.setCreationSponsored(creator, on);
    }

    function _fundFee(address who) internal {
        wood.mint(who, FEE);
        vm.prank(who);
        wood.approve(address(factory), FEE);
    }

    function _create(address creator) internal {
        uint256 agentId = agentRegistry.mint(creator);
        string memory sub = string.concat("fund-", vm.toString(++nonce));
        SyndicateFactory.SyndicateConfig memory config = SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://QmTest", asset: usdc, name: "Fund", symbol: "F", openDeposits: false, subdomain: sub
        });
        vm.prank(creator);
        factory.createSyndicate(agentId, config);
    }

    /// @notice A sponsored creator creates holding no WOOD, and the credit is spent.
    function test_sponsored_createsWithoutFeeAndConsumesCredit() public {
        _sponsor(sponsored, true);
        _create(sponsored);
        assertEq(wood.balanceOf(treasury), 0, "no fee moved");
        assertFalse(factory.creationSponsored(sponsored), "credit spent");
    }

    /// @notice The credit is single use: the sponsored creator's second fund pays the fee.
    function test_sponsored_secondCreationPays() public {
        _sponsor(sponsored, true);
        _create(sponsored);
        _fundFee(sponsored);
        _create(sponsored);
        assertEq(wood.balanceOf(treasury), FEE, "second fund paid");
    }

    /// @notice An unsponsored creator pays exactly the fee to the recipient.
    function test_unsponsored_paysFeeToRecipient() public {
        _fundFee(stranger);
        _create(stranger);
        assertEq(wood.balanceOf(treasury), FEE, "fee paid");
        assertEq(wood.balanceOf(stranger), 0, "creator debited");
    }

    /// @notice A revoked credit waives nothing.
    function test_revoked_paysFee() public {
        _sponsor(sponsored, true);
        _sponsor(sponsored, false);
        _fundFee(sponsored);
        _create(sponsored);
        assertEq(wood.balanceOf(treasury), FEE, "fee paid");
    }

    /// @notice One creator's credit does not waive another creator's fee.
    function test_credit_boundToCreator() public {
        _sponsor(sponsored, true);
        _fundFee(stranger);
        _create(stranger);
        assertEq(wood.balanceOf(treasury), FEE, "stranger paid");
        assertTrue(factory.creationSponsored(sponsored), "credit untouched");
    }

    /// @notice With no fee set, creating leaves the credit for later.
    function test_zeroFee_leavesCreditUnspent() public {
        vm.prank(owner);
        factory.setCreationFee(address(0), 0, address(0));
        _sponsor(sponsored, true);
        _create(sponsored);
        assertTrue(factory.creationSponsored(sponsored), "credit kept");
    }

    /// @notice Only the owner grants credits, never to the zero address, and each grant is logged.
    function test_setCreationSponsored_onlyOwnerNonZeroAndEmits() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setCreationSponsored(stranger, true);

        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.ZeroAddress.selector);
        factory.setCreationSponsored(address(0), true);

        vm.expectEmit(address(factory));
        emit CreationSponsored(sponsored, true);
        _sponsor(sponsored, true);
        assertTrue(factory.creationSponsored(sponsored), "granted");
    }
}
