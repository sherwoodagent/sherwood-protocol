// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {DeploySalts} from "../DeploySalts.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {RobinhoodParams} from "./RobinhoodParams.sol";
import {Inputs, Stack} from "./DeployTypes.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {INonfungiblePositionManager} from "../../src/vendor/uniswap/INonfungiblePositionManager.sol";
import {ITierRegistry} from "../../src/interfaces/ITierRegistry.sol";

/// @notice ConcentratedLiquidityStrategy template phase. An abstract mixin — `DeployAll`
///         owns `run()`, the broadcast and the address book.
abstract contract DeployConcentratedLiquidityStrategy is ScriptBase {
    function _deployCL(Stack memory s, Inputs memory i) internal {
        _assertIsPositionManager(i.uniswapV3PositionManager, i.uniswapV3Factory);
        require(i.morphoBlue.code.length != 0, "MORPHO_BLUE holds no code");
        _requireFactoryVouchedBy(s.core.tierRegistry, i.uniswapV3Factory);

        address template = _c3(
            Create3Factory(s.create3Factory), DeploySalts.CL_TEMPLATE, type(ConcentratedLiquidityStrategy).creationCode
        );

        // Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170), not 24,576.
        require(
            template.code.length <= RobinhoodParams.ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize"
        );

        s.concentratedLiquidityTemplate = template;
        console.log("ConcentratedLiquidityStrategy template:", template);
    }

    /// @dev A DEPLOY-TIME ASSERTION, NOT A RUNBOOK LINE. `ConcentratedLiquidityStrategy._initialize`
    ///      binds the proposer-supplied `uniswapFactory` through the tier registry, so an unlisted
    ///      factory does not degrade the template — it makes every clone-init revert.
    ///      A registry that cannot be asked has not vouched; `registry == 0` means no core phase yet.
    function _requireFactoryVouchedBy(address registry, address uniswapFactory) internal view {
        if (registry == address(0)) {
            console.log("RUNBOOK: no TIER_REGISTRY - cannot verify the factory allowlist here.");
            console.log("RUNBOOK: before any CL proposal, the owner must setCounterpartyAllowed(factory, true).");
            return;
        }

        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeCall(ITierRegistry.isCounterpartyAllowed, (uniswapFactory)));
        require(
            ok && ret.length == 32,
            "TIER_REGISTRY cannot answer isCounterpartyAllowed - wrong address, or a registry predating the counterparty axis"
        );

        require(
            abi.decode(ret, (bool)),
            "UNISWAP_V3_FACTORY is not counterparty-allowlisted: the registry owner must call setCounterpartyAllowed(UNISWAP_V3_FACTORY, true) or every CL clone-init reverts CounterpartyNotAllowed"
        );
        console.log("Uniswap V3 factory is counterparty-allowlisted on TierRegistry:", registry);
    }

    /// @dev IDENTITY, NOT CODE PRESENCE. The canonical Uniswap mainnet addresses each hold ~2110
    ///      bytes of an UNRELATED contract on 4663 (measured 2026-08-04), so a code-length check
    ///      passes on both and wires the wrong contract into every clone.
    function _assertIsPositionManager(address positionManager, address uniswapFactory) internal view {
        require(positionManager.code.length != 0, "position manager holds no code");
        require(uniswapFactory.code.length != 0, "uniswap factory holds no code");

        require(
            keccak256(bytes(INonfungiblePositionManager(positionManager).symbol())) == keccak256(bytes("UNI-V3-POS")),
            "not a Uniswap V3 position manager (symbol mismatch)"
        );
        require(
            INonfungiblePositionManager(positionManager).factory() == uniswapFactory,
            "position manager points at a different factory"
        );
    }
}
