// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {DeploySherwood} from "../Deploy.s.sol";

/// @notice The Robinhood-specific half of the core ceremony: the owner-gated writes that only the
///         deployer can make, and the post-deploy validation table. `DeployAll._handoffAll` owns
///         the handoff itself — this mixin no longer carries one.
///         An abstract mixin — `DeployAll` owns `run()`, the broadcast and the address book.
///
///         Robinhood Chain is an Arbitrum Orbit L2 with no ENS registrar. The canonical ERC-8004
///         IdentityRegistry is live on 4663, but v1 ships with identity gating OFF, so the factory
///         is deployed with address(0) for both registrars.
abstract contract DeployRobinhoodMainnet is DeploySherwood {
    /// @notice Every `onlyOwner` write the deployer must make before `DeployAll._handoffAll` moves
    ///         the owner. Grouped so the set can be asserted as a set.
    /// @dev    Fee recipients are seeded to the DEPLOYER as a PLACEHOLDER: a zero recipient does not
    ///         strand its leg, it folds into the agent's remainder silently (both
    ///         `_chargeManagementFee` and `_chargePerformanceFee`). Set only when unset, so a
    ///         resumed run cannot repoint a recipient the Safe has already moved.
    ///         TierRegistry launch set: `deployCore` mints the registry EMPTY, and
    ///         `isCounterpartyAllowed` gates CLONE-INIT — an unseeded registry makes every
    ///         ConcentratedLiquidity clone revert `CounterpartyNotAllowed`.
    function _seatOwnerWrites(Deployed memory d, address deployer) internal {
        ProtocolConfig config = ProtocolConfig(d.protocolConfig);
        if (config.protocolFeeRecipient() == address(0)) config.setProtocolFeeRecipient(deployer);
        if (config.guardiansFeeRecipient() == address(0)) config.setGuardiansFeeRecipient(deployer);
        _seedTierRegistry(deployer, d.tierRegistry);
    }

    /// @param ownerMultisig the Safe the handoff targeted, or `address(0)` when
    ///        the handoff was skipped (fork posture: the deployer keeps all).
    function _validateMainnet(Deployed memory d, address deployer, address ownerMultisig, address wood) internal view {
        SyndicateFactory factory = SyndicateFactory(d.factoryProxy);

        bool handedOff = ownerMultisig != address(0);
        address oneStepOwner = handedOff ? ownerMultisig : deployer;
        // A two-step transfer never moves `owner()`; only `pendingOwner()`.
        address expectedPending = handedOff ? ownerMultisig : address(0);

        // Per-vault governors are minted at `createSyndicate`, so there is no
        // governor instance to inspect here. What's checkable at deploy time is
        // the beacon (shared impl + upgrade authority) and ProtocolConfig.
        _checkAddr("beacon.owner", Ownable(d.beacon).owner(), oneStepOwner);
        _checkAddr("factory.owner", Ownable(d.factoryProxy).owner(), oneStepOwner);
        _checkAddr("registry.owner", Ownable(d.registryProxy).owner(), oneStepOwner);
        _checkAddr("swood.owner", Ownable(d.swoodProxy).owner(), oneStepOwner);

        // The `Ownable2Step` pair. Asserting the PENDING owner is what catches a
        // deployer who never ran the `acceptOwnership()` runbook step.
        _checkAddr("protocolConfig.owner", Ownable(d.protocolConfig).owner(), deployer);
        _checkAddr("protocolConfig.pendingOwner", Ownable2Step(d.protocolConfig).pendingOwner(), expectedPending);
        _checkAddr("tierRegistry.owner", Ownable(d.tierRegistry).owner(), deployer);
        _checkAddr("tierRegistry.pendingOwner", Ownable2Step(d.tierRegistry).pendingOwner(), expectedPending);

        // BOTH LEGS, against the END STATE: a zero recipient folds its leg into the agent's
        // remainder rather than failing, and `_handoffAll` moves both with the owner — so a
        // handed-off ceremony still naming the deployer EOA is refused here, not accepted.
        ProtocolConfig protocolConfig = ProtocolConfig(d.protocolConfig);
        address feeRecipient = handedOff ? ownerMultisig : deployer;
        _checkAddr("protocolConfig.protocolFeeRecipient", protocolConfig.protocolFeeRecipient(), feeRecipient);
        _checkAddr("protocolConfig.guardiansFeeRecipient", protocolConfig.guardiansFeeRecipient(), feeRecipient);

        _checkAddr("factory.beacon", factory.beacon(), d.beacon);
        // `tier2CallCapBps` has no subject here: it is per-governor and governors are minted at
        // `createSyndicate`. Plan B's `TIER2_CALL_CAP_BPS` is a PRINTED policy figure for the
        // vault owner (`setTier2CallCapBps` is `onlyVaultOwner`); `CheckSyndicateParams` is the gate.
        _checkAddr("factory.tierRegistry", address(factory.tierRegistry()), d.tierRegistry);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), address(0));
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), address(0));

        _checkAddr("swood.wood", address(StakedWood(d.swoodProxy).wood()), wood);
        _checkAddr("swood.registry", StakedWood(d.swoodProxy).registry(), d.registryProxy);
    }
}
