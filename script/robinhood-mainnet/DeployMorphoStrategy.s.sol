// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScriptBase} from "../ScriptBase.sol";
import {DeploySalts} from "../DeploySalts.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {Stack} from "./DeployTypes.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";

/// @title  DeployMorphoStrategy
/// @notice `MorphoSupplyStrategy` template phase. An abstract mixin — `DeployAll` owns
///         `run()`, the broadcast and the address book.
///
/// @dev NO MORPHO ADDRESS AND NO MARKET PARAMS ARE NEEDED HERE. The template is an
///      ERC-1167 clone source: the Morpho singleton, the `MarketParams` tuple and the
///      supply amount all arrive PER CLONE through `_initialize(bytes)`. The template is
///      therefore deliberately left UNINITIALIZED — that is its correct resting state.
///
///      Morpho Blue itself is attested by the core launch set (`_seedTierRegistry`);
///      without that, every clone-init reverts `MorphoNotAllowed`.
abstract contract DeployMorphoStrategy is ScriptBase {
    function _deployMorpho(Stack memory s) internal {
        s.morphoSupplyTemplate = address(deploy());
        _checkAddr("morphoTemplate.create3Factory", address(_c3Factory(msg.sender)), s.create3Factory);
    }

    /// @notice Mint (or adopt) the template. Public so tests drive the real thing.
    /// @dev The caller must be the `Create3Factory` owner — `_c3Factory` bootstraps it
    ///      at `msg.sender`, exactly as `deployCore` does.
    function deploy() public returns (MorphoSupplyStrategy template) {
        Create3Factory c3 = _c3Factory(msg.sender);
        template =
            MorphoSupplyStrategy(_c3(c3, DeploySalts.MORPHO_SUPPLY_TEMPLATE, type(MorphoSupplyStrategy).creationCode));
    }
}
