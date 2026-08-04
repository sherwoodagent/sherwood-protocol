// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {DeploySherwood} from "../../script/Deploy.s.sol";
import {DeployRobinhoodMainnet} from "../../script/robinhood-mainnet/Deploy.s.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice Stand-in for a Gnosis Safe. The script's only check is
///         `code.length > 0`, so any deployed bytecode satisfies it.
contract MockMultisig {
    receive() external payable {}
}

/// @notice A stand-in carrying the ownership SHAPE of a correctly handed-off
///         `Ownable2Step` contract, and nothing else. Used as the decoy in the
///         factory-pinning test: validation reads `owner()` and
///         `pendingOwner()` before it reads `factory.tierRegistry`, so a decoy
///         that answers neither reverts on empty returndata and hides which
///         assert actually fired.
contract MockOwned2Step {
    address public owner;
    address public pendingOwner;

    constructor(address owner_, address pendingOwner_) {
        owner = owner_;
        pendingOwner = pendingOwner_;
    }
}

/// @notice Exposes the two internals the ceremony's correctness actually lives
///         in. `run()` is not driven here: it reads its whole address book from
///         `vm.envAddress`, and `vm.setEnv` writes the shared process
///         environment that forge does not roll back between tests and that
///         every parallel suite races.
contract DeployRobinhoodMainnetHarness is DeployRobinhoodMainnet {
    function exposed_handoff(Deployed memory d, address ownerMultisig) external {
        _handoffRobinhood(d, ownerMultisig);
    }

    function exposed_validate(Deployed memory d, address deployer, address ownerMultisig, address wood) external view {
        _validateMainnet(d, deployer, ownerMultisig, wood);
    }
}

/// @title DeployRobinhoodMainnet — multisig handoff regression
///
/// @notice The Robinhood override reimplements `run()` rather than extending the
///         canonical one, and had NO test at all. Two defects had accumulated in
///         that gap, both of which only appear on the real mainnet path
///         (`SKIP_MULTISIG_HANDOFF` unset), which is why fork runs never saw them:
///
///           1. `TierRegistry` was never handed off. `deployCore` mints it owned
///              by the deployer and wires it into the factory; the override moved
///              five contracts to the Safe and left the adapter-certification
///              authority on the deployer key, unasserted.
///           2. `ProtocolConfig` is `Ownable2Step`, but validation asserted
///              `owner() == multisig`. A two-step transfer leaves `owner()` where
///              it was, so the assert could never pass — the ceremony reverted
///              AFTER `stopBroadcast`, i.e. with every contract already on-chain
///              and the address book never written.
contract DeployRobinhoodMainnetHandoffTest is Test {
    DeployRobinhoodMainnetHarness internal harness;
    MockMultisig internal multisig;
    ERC20Mock internal wood;
    DeploySherwood.Deployed internal d;

    function setUp() public {
        harness = new DeployRobinhoodMainnetHarness();
        multisig = new MockMultisig();
        wood = new ERC20Mock("WOOD", "WOOD", 18);

        DeploySherwood.Config memory cfg = DeploySherwood.Config({
            ensRegistrar: address(0),
            agentRegistry: address(0),
            managementFeeBps: 200,
            maxStrategyDays: 14,
            votingPeriod: 1 days,
            woodToken: address(wood),
            slashAppealSeed: 0,
            epochZeroSeed: 0
        });

        // `deployCore`'s inner `c3.deploy` calls run as the harness address, so
        // prank as the harness to keep the `Create3Factory` owner consistent —
        // same reason `RobinhoodMainnetIntegrationTest` does it.
        vm.prank(address(harness));
        d = harness.deployCore(cfg);

        // What `run()` does inside the broadcast before any handoff. BOTH
        // recipients: a zero one folds its leg into the agent's remainder
        // instead of failing, so validation asserts both and so does the run.
        vm.startPrank(address(harness));
        ProtocolConfig(d.protocolConfig).setProtocolFeeRecipient(address(harness));
        ProtocolConfig(d.protocolConfig).setGuardiansFeeRecipient(address(harness));
        vm.stopPrank();
    }

    // ── The fee recipients ──

    /// @dev THE GUARDIAN LEG IS NOT OPTIONAL. `MANAGEMENT_FEE_BPS = 200` is
    ///      sized so 20% of management funds the guardian pool, but an unset
    ///      `guardiansFeeRecipient` does not strand that slice — the governor
    ///      zeroes it and hands it to the agent as remainder. The failure is
    ///      therefore invisible on-chain: fees are charged at the rate the
    ///      guardian budget justifies, and the proposer collects the guardians'
    ///      share.
    function test_validate_bitesWhenTheGuardianFeeRecipientIsUnset() public {
        vm.prank(address(harness));
        ProtocolConfig(d.protocolConfig).setGuardiansFeeRecipient(address(0));

        vm.expectRevert(bytes("protocolConfig.guardiansFeeRecipient mismatch"));
        harness.exposed_validate(d, address(harness), address(0), address(wood));
    }

    /// @dev The complement, so the pair pins both recipients rather than only
    ///      the one that was missing.
    function test_validate_bitesWhenTheProtocolFeeRecipientIsUnset() public {
        vm.prank(address(harness));
        ProtocolConfig(d.protocolConfig).setProtocolFeeRecipient(address(0));

        vm.expectRevert(bytes("protocolConfig.protocolFeeRecipient mismatch"));
        harness.exposed_validate(d, address(harness), address(0), address(wood));
    }

    // ── The fork posture ──

    /// @dev `SKIP_MULTISIG_HANDOFF=true`: the deployer keeps everything and the
    ///      two-step pair has no pending owner. This is the path every fork run
    ///      in this repo exercises, and the one that stayed green while the
    ///      mainnet path was broken.
    function test_validate_passesWhenTheHandoffIsSkipped() public view {
        harness.exposed_validate(d, address(harness), address(0), address(wood));
    }

    // ── The mainnet posture ──

    function test_validate_passesAfterTheFullHandoff() public {
        vm.prank(address(harness));
        harness.exposed_handoff(d, address(multisig));

        harness.exposed_validate(d, address(harness), address(multisig), address(wood));
    }

    /// @dev DEFECT 2, pinned. The one-step contracts move immediately; the
    ///      `Ownable2Step` pair does NOT. An assert expecting `owner() ==
    ///      multisig` on ProtocolConfig — which is what shipped — can never pass.
    function test_handoff_movesOneStepOwnersButOnlyArmsTheTwoStepPair() public {
        vm.prank(address(harness));
        harness.exposed_handoff(d, address(multisig));

        assertEq(Ownable(d.beacon).owner(), address(multisig), "beacon is one-step");
        assertEq(Ownable(d.factoryProxy).owner(), address(multisig), "factory is one-step");
        assertEq(Ownable(d.registryProxy).owner(), address(multisig), "registry is one-step");
        assertEq(Ownable(d.swoodProxy).owner(), address(multisig), "swood is one-step");

        assertEq(Ownable(d.protocolConfig).owner(), address(harness), "ProtocolConfig owner must NOT have moved");
        assertEq(
            Ownable2Step(d.protocolConfig).pendingOwner(), address(multisig), "ProtocolConfig transfer must be armed"
        );
        assertEq(Ownable(d.tierRegistry).owner(), address(harness), "TierRegistry owner must NOT have moved");
        assertEq(Ownable2Step(d.tierRegistry).pendingOwner(), address(multisig), "TierRegistry transfer must be armed");
    }

    /// @dev DEFECT 1, pinned. Replays the exact handoff that shipped — the five
    ///      transfers, no TierRegistry — and requires validation to refuse it.
    ///      Without the `tierRegistry.pendingOwner` assert this passes silently,
    ///      which is precisely how the omission survived.
    function test_validate_bitesWhenTierRegistryWasNotHandedOff() public {
        vm.startPrank(address(harness));
        Ownable(d.beacon).transferOwnership(address(multisig));
        Ownable(d.factoryProxy).transferOwnership(address(multisig));
        Ownable(d.registryProxy).transferOwnership(address(multisig));
        Ownable(d.swoodProxy).transferOwnership(address(multisig));
        Ownable2Step(d.protocolConfig).transferOwnership(address(multisig));
        vm.stopPrank();

        vm.expectRevert(bytes("tierRegistry.pendingOwner mismatch"));
        harness.exposed_validate(d, address(harness), address(multisig), address(wood));
    }

    /// @dev The complement: validation must refuse a ceremony where the handoff
    ///      never ran at all, rather than only the one where TierRegistry was
    ///      skipped.
    function test_validate_bitesWhenNothingWasHandedOffAtAll() public {
        vm.expectRevert(bytes("beacon.owner mismatch"));
        harness.exposed_validate(d, address(harness), address(multisig), address(wood));
    }

    /// @dev The factory must still point at the TierRegistry that was handed
    ///      off. A handoff of some OTHER registry would leave the live adapter
    ///      gate on the deployer key while validation read a decoy.
    ///
    ///      THE DECOY HAS TO ANSWER `owner()` AND `pendingOwner()`. Validation
    ///      reads those BEFORE `factory.tierRegistry`, so a bare stub reverts on
    ///      empty returndata and a plain `vm.expectRevert()` would go green
    ///      without the factory check ever running — the test would pass while
    ///      pinning nothing. Give the decoy the ownership shape of a correctly
    ///      handed-off registry, so `factory.tierRegistry` is the only thing
    ///      left to fail, and assert that exact string.
    function test_validate_pinsTheFactoryToTheHandedOffTierRegistry() public {
        vm.prank(address(harness));
        harness.exposed_handoff(d, address(multisig));

        DeploySherwood.Deployed memory decoy = d;
        decoy.tierRegistry = address(new MockOwned2Step(address(harness), address(multisig)));

        vm.expectRevert(bytes("factory.tierRegistry mismatch"));
        harness.exposed_validate(decoy, address(harness), address(multisig), address(wood));
    }
}
