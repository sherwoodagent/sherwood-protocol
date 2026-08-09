// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {INonfungiblePositionManager} from "../../src/vendor/uniswap/INonfungiblePositionManager.sol";
import {ITierRegistry} from "../../src/interfaces/ITierRegistry.sol";

/**
 * @notice Deploy the ConcentratedLiquidityStrategy template to Robinhood Chain
 *         mainnet (chain 4663).
 *
 *   Prerequisites:
 *     - Core stack already deployed via Deploy.s.sol.
 *     - UniswapSwapAdapter already deployed (DeployPortfolioStrategy).
 *     - chains/4663.json seeded with UNISWAP_V3_POSITION_MANAGER and
 *       UNISWAP_V3_FACTORY. Resolved values are recorded in addresses/4663.json.
 *     - REGISTRY OWNER has called
 *       `TierRegistry.setCounterpartyAllowed(UNISWAP_V3_FACTORY, true)`.
 *       Asserted below — see `_assertFactoryIsVouchedFor`.
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
        _assertFactoryIsVouchedFor(uniswapFactory);

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

    /// @dev A DEPLOY-TIME ASSERTION, NOT A RUNBOOK LINE, and that choice is the
    ///      whole point of this function.
    ///
    ///      Since the pashov 2026-08 finding-4 fix,
    ///      `ConcentratedLiquidityStrategy._initialize` binds its
    ///      proposer-supplied `uniswapFactory` through
    ///      `vault() -> governor() -> tierRegistry() -> isCounterpartyAllowed`
    ///      and reverts `CounterpartyNotAllowed` otherwise — because the pool's
    ///      provenance is settled by asking that factory `getPool`, and an
    ///      authority the proposer picked is no authority. So an unlisted
    ///      factory does not degrade this template, it makes it INERT: the
    ///      ceremony completes, `DeployStrategyFactory` allowlists the template,
    ///      agents write proposals, and every single one reverts at clone-init.
    ///      The cost is discovered a governance cycle late.
    ///
    ///      `DeployMorphoStrategy` documents its equivalent step as an operator
    ///      action in prose. That is the weaker form and this file deliberately
    ///      does not copy it: `Deploy.s.sol` already records what happens when a
    ///      required owner action has no assertion behind it — a mainnet
    ///      ceremony handed five contracts to the Safe and left the
    ///      certification authority on the deployer key, "with no assertion
    ///      anywhere to notice". A console line in a long ceremony log is not a
    ///      control.
    ///
    ///      The grant cannot be made HERE. `TierRegistry` is `Ownable2Step` and
    ///      is handed to the parameter multisig during the core phase, so the
    ///      deployer key that broadcasts this script cannot call
    ///      `setCounterpartyAllowed`. Nothing about that ordering prevents the
    ///      Safe from making the grant BEFORE this phase — it depends on no
    ///      artifact this script produces — so requiring it is a scheduling
    ///      constraint, not a circular one.
    ///
    ///      SKIPS ONLY WHEN THE REGISTRY IS GENUINELY UNKNOWABLE — the address
    ///      book has no `TIER_REGISTRY` key, i.e. a fork or partial deployment
    ///      where the core phase never ran. That is the one case where this
    ///      cannot be evaluated rather than the case where it is inconvenient.
    ///      A registry that IS in the book but cannot answer the selector fails
    ///      the run: a registry that cannot be asked has not vouched, matching
    ///      how `_readAllowed` treats the same silence at runtime.
    function _assertFactoryIsVouchedFor(address uniswapFactory) internal view {
        string memory book = vm.readFile(_chainsPath());
        address registry =
            vm.keyExistsJson(book, ".TIER_REGISTRY") ? vm.parseJsonAddress(book, ".TIER_REGISTRY") : address(0);
        _requireFactoryVouchedBy(registry, uniswapFactory);
    }

    /// @dev Split from the address-book read above so the DECISION is reachable
    ///      from a test without staging a chains JSON on disk. `registry ==
    ///      address(0)` means the book had no key.
    function _requireFactoryVouchedBy(address registry, address uniswapFactory) internal view {
        if (registry == address(0)) {
            console.log("RUNBOOK: no TIER_REGISTRY in the address book - cannot verify the factory allowlist here.");
            console.log("RUNBOOK: before any CL proposal, the registry owner must call:");
            console.log("RUNBOOK:   setCounterpartyAllowed(<UNISWAP_V3_FACTORY>, true)");
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
