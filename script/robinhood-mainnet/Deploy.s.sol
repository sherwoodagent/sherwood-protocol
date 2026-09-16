// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {DeploySherwood} from "../Deploy.s.sol";

/// @notice The Robinhood-specific half of the core ceremony: the owner-gated writes that only the
///         deployer can make, the multisig handoff, and the post-deploy validation table.
///         An abstract mixin — `DeployAll` owns `run()`, the broadcast and the address book.
///
///         Robinhood Chain is an Arbitrum Orbit L2 with no ENS registrar. The canonical ERC-8004
///         IdentityRegistry is live on 4663, but v1 ships with identity gating OFF, so the factory
///         is deployed with address(0) for both registrars.
abstract contract DeployRobinhoodMainnet is DeploySherwood {
    /// @notice Every `onlyOwner` write the deployer must make before `_handoffRobinhood` moves the
    ///         owner. Grouped so the set can be asserted as a set — scattered inline, one of them
    ///         went missing for the whole life of this script.
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

    /// @dev THE OWNERSHIP MODELS ARE NOT UNIFORM, and treating them as if they
    ///      were is what made this script revert on every real mainnet run.
    ///      Beacon / factory / registry / sWOOD are one-step `Ownable`, so
    ///      `transferOwnership` moves `owner()` immediately. `ProtocolConfig`
    ///      and `TierRegistry` are `Ownable2Step`, so the same call only ARMS
    ///      the transfer: `owner()` stays the deployer and the multisig has to
    ///      call `acceptOwnership()`. Validation has to expect each shape.
    ///
    ///      `TierRegistry` was missing here entirely. `deployCore` mints it
    ///      owned by the deployer and wires it into the factory, and nothing
    ///      afterwards moved it — so a mainnet ceremony handed five contracts to
    ///      the Safe and left the adapter-certification authority
    ///      (`proposeCertification`, `demote`, `setCounterpartyAllowed`) on the
    ///      deployer key, with no assertion anywhere to notice.
    function _handoffRobinhood(Deployed memory d, address ownerMultisig) internal {
        // Per-vault governors: the beacon (shared impl) and ProtocolConfig
        // (global fee params) are the governance handles — there is no
        // singleton governor proxy to hand off.
        Ownable(d.beacon).transferOwnership(ownerMultisig);
        Ownable(d.factoryProxy).transferOwnership(ownerMultisig);
        Ownable(d.registryProxy).transferOwnership(ownerMultisig);
        Ownable(d.swoodProxy).transferOwnership(ownerMultisig);

        Ownable2Step(d.protocolConfig).transferOwnership(ownerMultisig);
        Ownable2Step(d.tierRegistry).transferOwnership(ownerMultisig);
        console.log("RUNBOOK: the multisig MUST call acceptOwnership() on ProtocolConfig AND TierRegistry");
        // BOTH FEE LEGS CURRENTLY PAY THE DEPLOYER KEY. They are seeded there
        // because a zero recipient is worse — it folds the leg into the agent's
        // remainder silently — but the deployer is a seed value, not the
        // destination. Until the Safe re-points them, protocol revenue and the
        // entire guardian budget accrue to a single EOA.
        console.log("RUNBOOK: then, from the Safe, setProtocolFeeRecipient(treasury)");
        console.log("RUNBOOK: and setGuardiansFeeRecipient(guardian payout address)");
        console.log("RUNBOOK: until both are re-pointed, BOTH fee legs pay the deployer key.");
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

        // BOTH RECIPIENTS, because a zero one folds its leg into the agent's
        // remainder rather than failing. Asserting only the protocol leg would
        // leave the guardian budget — the whole reason MANAGEMENT_FEE_BPS is
        // 200 — silently payable to the proposer.
        ProtocolConfig protocolConfig = ProtocolConfig(d.protocolConfig);
        _checkAddr("protocolConfig.protocolFeeRecipient", protocolConfig.protocolFeeRecipient(), deployer);
        _checkAddr("protocolConfig.guardiansFeeRecipient", protocolConfig.guardiansFeeRecipient(), deployer);

        _checkAddr("factory.beacon", factory.beacon(), d.beacon);
        // The FUNDING CEILING is deliberately not asserted here. `tier2CallCapBps`
        // is per-governor and governors are minted at `createSyndicate`, so there
        // is no instance to seed at deploy time; and it is being left at its
        // 10,000 default (no tier-2-specific ceiling) by explicit decision. What
        // still bounds a proposal is its own envelope, the guardian coverage
        // scaling, and the vault's buffer and queue-reserve checks.
        //
        // NOT IN CONFLICT WITH `script/DeployPlanB.s.sol`, which pins
        // `TIER2_CALL_CAP_BPS = 200` and pre-flights it. THE TWO ACT AT DIFFERENT
        // LIFECYCLE POINTS: this assertion block runs during the CORE ceremony,
        // before any governor exists, so the only honest thing it can say about
        // the ceiling is that it has no subject. Plan B's constant is not a value
        // that script seats either — `setTier2CallCapBps` is `onlyVaultOwner`, a
        // role no deploy script holds — it is the POLICY figure its post-broadcast
        // MANUAL NEXT tells each vault owner to call with, AFTER `createSyndicate`
        // (`script/DeployPlanB.s.sol:327`, `:672`, `:1087`). Neither script writes
        // this parameter; one records that the ceremony leaves it inert, the other
        // recommends what the owner should later make it. Seeding it per vault is
        // the escape hatch, and the gate that catches an owner who never did is
        // `script/CheckSyndicateParams.s.sol` (issue SHE-127/SHE-42;
        // `docs/pre-deployment-parameter-review.md`).
        _checkAddr("factory.tierRegistry", address(factory.tierRegistry()), d.tierRegistry);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), address(0));
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), address(0));

        _checkAddr("swood.wood", address(StakedWood(d.swoodProxy).wood()), wood);
        _checkAddr("swood.registry", StakedWood(d.swoodProxy).registry(), d.registryProxy);
    }
}
