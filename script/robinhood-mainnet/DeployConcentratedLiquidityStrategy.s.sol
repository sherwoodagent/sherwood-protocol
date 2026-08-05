// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {INonfungiblePositionManager} from "../../src/vendor/uniswap/INonfungiblePositionManager.sol";

/**
 * @notice Deploy the ConcentratedLiquidityStrategy template to Robinhood Chain
 *         mainnet (chain 4663).
 *
 *   Prerequisites:
 *     - Core stack already deployed via Deploy.s.sol.
 *     - UniswapSwapAdapter already deployed (DeployPortfolioStrategy).
 *     - chains/4663.json seeded with UNISWAP_V3_POSITION_MANAGER and
 *       UNISWAP_V3_FACTORY. Resolved values are recorded in addresses/4663.json.
 *
 *   Usage:
 *     forge script script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol:DeployConcentratedLiquidityStrategy \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 */
contract DeployConcentratedLiquidityStrategy is ScriptBase {
    /// @dev Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170), not 24,576.
    uint256 constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    function run() external {
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 4663 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"
        );

        address positionManager = _readAddress("UNISWAP_V3_POSITION_MANAGER");
        address uniswapFactory = _readAddress("UNISWAP_V3_FACTORY");
        address morpho = _readAddress("MORPHO_BLUE");

        _assertIsPositionManager(positionManager, uniswapFactory);
        require(morpho.code.length != 0, "MORPHO_BLUE holds no code");

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood Chain (chain ID 4663)");

        ConcentratedLiquidityStrategy template = new ConcentratedLiquidityStrategy();

        vm.stopBroadcast();

        uint256 size = address(template).code.length;
        console.log("Template runtime size:", size);
        require(size <= ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");

        _patchAddress("CONCENTRATED_LIQUIDITY_TEMPLATE", address(template));
        console.log("ConcentratedLiquidityStrategy template:", address(template));
    }

    /// @dev IDENTITY, NOT CODE PRESENCE.
    ///
    ///      A `code.length != 0` assertion is NOT sufficient on this chain, and
    ///      that is measured rather than theoretical: as of 2026-08-04 the
    ///      canonical Uniswap mainnet addresses
    ///      `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` (position manager) and
    ///      `0x1F98431c8aD98523631AE4a59f267346ea31F984` (factory) each hold
    ///      ~2110 bytes of an unrelated contract on chain 4663 that answers no
    ///      Uniswap selector. A deploy that only checked for code would pass on
    ///      both and wire the wrong contract into every clone this template
    ///      produces. See `addresses/4663.json`.
    ///
    ///      So: prove it answers as a Uniswap position manager, and prove it
    ///      agrees with the factory we are about to trust.
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
