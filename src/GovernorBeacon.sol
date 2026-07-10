// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title GovernorBeacon
/// @notice Thin wrapper around OZ `UpgradeableBeacon`. Holds the shared
///         `SyndicateGovernor` implementation for all per-vault BeaconProxy
///         governors. `upgradeTo(newImpl)` is a mass-upgrade primitive: it
///         upgrades EVERY vault governor atomically (same blast radius as the
///         old shared-governor `upgradeTo`). Owner is the factory-owner
///         multisig (Gnosis Safe + Zodiac Delay).
contract GovernorBeacon is UpgradeableBeacon {
    constructor(address implementation_, address owner_) UpgradeableBeacon(implementation_, owner_) {}
}
