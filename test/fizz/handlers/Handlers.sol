// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {ChallengeGameHandler} from "./ChallengeGameHandler.sol";
import {ExposureLedgerHandler} from "./ExposureLedgerHandler.sol";
import {GuardianRegistryHandler} from "./GuardianRegistryHandler.sol";
import {ProposerBondEscrowHandler} from "./ProposerBondEscrowHandler.sol";
import {StakedWoodHandler} from "./StakedWoodHandler.sol";
import {SyndicateGovernorHandler} from "./SyndicateGovernorHandler.sol";
import {SyndicateVaultHandler} from "./SyndicateVaultHandler.sol";
import {TierRegistryHandler} from "./TierRegistryHandler.sol";
import {TokenCourtHandler} from "./TokenCourtHandler.sol";
import {VaultWithdrawalQueueHandler} from "./VaultWithdrawalQueueHandler.sol";

/// @notice Inherits from all the handlers to expose all entry points in a single contract.
///         Manages environment changes (e.g. current actor, current token, mocks setup, etc.).
abstract contract Handlers is
    ChallengeGameHandler,
    ExposureLedgerHandler,
    GuardianRegistryHandler,
    ProposerBondEscrowHandler,
    StakedWoodHandler,
    SyndicateGovernorHandler,
    SyndicateVaultHandler,
    TierRegistryHandler,
    TokenCourtHandler,
    VaultWithdrawalQueueHandler
{
    function setCurrentActor(uint256 entropy) public {
        actor = actors[entropy % actors.length];
    }
}
