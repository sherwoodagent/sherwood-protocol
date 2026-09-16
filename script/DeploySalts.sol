// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice CREATE3 salts for the Robinhood v1 ceremony. Every address is f(DEPLOYER, salt).
///         Bump `NS` to redeploy the whole set; bump one name (e.g. "vault-impl.2") to redeploy one.
library DeploySalts {
    string internal constant NS = "sherwood.robinhood.v1.";

    /// @dev Every constant below equals `salt(<name>)`; the literals are spelled out because
    ///      `abi.encodePacked` is not a compile-time constant expression.
    function salt(string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(NS, name));
    }

    // CREATE2 salt through CREATE2_DEPLOYER (0x4e59...); initcode = Create3Factory ++ abi.encode(deployer).
    bytes32 internal constant CREATE3_FACTORY = keccak256("sherwood.robinhood.v1.create3-factory");
    // keccak256(type(Create3Factory).creationCode) under the pinned toolchain (solc 0.8.28, via_ir,
    // 50 runs); asserted in _c3Factory so a compiler drift fails loudly instead of moving every address.
    // The trailing CBOR metadata hashes the SOURCE, so any edit to Create3Factory.sol or Create3.sol —
    // a comment included — moves this value and with it every CREATE3 address. Re-record it here.
    bytes32 internal constant CREATE3_FACTORY_INITCODE_HASH =
        0x44bc4edbbea879077cdecb78ef2f04be06eb9659cd79302d514d8b16c7a3db5a;

    // Core
    bytes32 internal constant EXECUTOR = keccak256("sherwood.robinhood.v1.batch-executor-lib");
    bytes32 internal constant VAULT_IMPL = keccak256("sherwood.robinhood.v1.vault-impl");
    bytes32 internal constant PROTOCOL_CONFIG = keccak256("sherwood.robinhood.v1.protocol-config");
    bytes32 internal constant GOVERNOR_IMPL = keccak256("sherwood.robinhood.v1.governor-impl");
    bytes32 internal constant GOVERNOR_BEACON = keccak256("sherwood.robinhood.v1.governor-beacon");
    bytes32 internal constant SWOOD_IMPL = keccak256("sherwood.robinhood.v1.staked-wood-impl");
    bytes32 internal constant SWOOD_PROXY = keccak256("sherwood.robinhood.v1.staked-wood-proxy");
    bytes32 internal constant REGISTRY_IMPL = keccak256("sherwood.robinhood.v1.guardian-registry-impl");
    bytes32 internal constant REGISTRY_PROXY = keccak256("sherwood.robinhood.v1.guardian-registry-proxy");
    bytes32 internal constant TIER_REGISTRY = keccak256("sherwood.robinhood.v1.tier-registry");
    bytes32 internal constant FACTORY_IMPL = keccak256("sherwood.robinhood.v1.factory-impl");
    bytes32 internal constant FACTORY_PROXY = keccak256("sherwood.robinhood.v1.factory-proxy");

    // Strategies
    bytes32 internal constant UNISWAP_SWAP_ADAPTER = keccak256("sherwood.robinhood.v1.uniswap-swap-adapter");
    bytes32 internal constant PORTFOLIO_TEMPLATE = keccak256("sherwood.robinhood.v1.portfolio-template");
    bytes32 internal constant MORPHO_SUPPLY_TEMPLATE = keccak256("sherwood.robinhood.v1.morpho-supply-template");
    bytes32 internal constant CL_TEMPLATE = keccak256("sherwood.robinhood.v1.concentrated-liquidity-template");
    bytes32 internal constant STRATEGY_FACTORY = keccak256("sherwood.robinhood.v1.strategy-factory");

    // Pricing. Distinct salts so a fork book can never be mistaken for a mainnet feed.
    bytes32 internal constant WOOD_USD_FEED = keccak256("sherwood.robinhood.v1.wood-pool-feed");
    bytes32 internal constant FORK_WOOD_FEED = keccak256("sherwood.robinhood.v1.fork-wood-feed-fixture");

    // Plan B / Plan D / TokenCourt
    bytes32 internal constant EXPOSURE_LEDGER = keccak256("sherwood.robinhood.v1.exposure-ledger");
    bytes32 internal constant PROPOSER_BOND_ESCROW = keccak256("sherwood.robinhood.v1.proposer-bond-escrow");
    bytes32 internal constant CHALLENGE_GAME = keccak256("sherwood.robinhood.v1.challenge-game");
    bytes32 internal constant TOKEN_COURT = keccak256("sherwood.robinhood.v1.token-court");
}
