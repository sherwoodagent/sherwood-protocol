// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {EAS} from "eas-contracts/EAS.sol";
import {SchemaRegistry} from "eas-contracts/SchemaRegistry.sol";
import {ISchemaRegistry, SchemaRecord} from "eas-contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "eas-contracts/resolver/ISchemaResolver.sol";

/// @title  DeployEAS
/// @notice Deploys EAS v1.4.0 + SchemaRegistry and registers Sherwood's six
///         attestation schemas. See docs/superpowers/specs/2026-08-26-eas-robinhood-mainnet-design.md
///         (sherwoodagent/sherwood) §6.
///
///         Both contracts go through the CREATE2 singleton factory
///         (0x4e59b448…, present on 4663 and 46630) with fixed salts, so the
///         addresses are reproducible across chains.
///
///         Schema UIDs are chain-independent — keccak256(schema, resolver,
///         revocable) carries no chainId — so re-registering these definitions
///         anywhere reproduces the UIDs already live on Base. They are pinned
///         below and asserted after registration; a mismatch means a definition
///         drifted and the deploy reverts.
///
///         EAS is vendored at 0.8.28 rather than its upstream 0.8.29 pin — see
///         lib/VENDOR-MANIFEST.json for why — so this script shares the repo
///         compiler and inherits ScriptBase like every other deploy script.
///
///   Usage:
///     forge script script/DeployEAS.s.sol:DeployEAS --rpc-url <rpc> --broadcast
contract DeployEAS is ScriptBase {
    bytes32 internal constant REGISTRY_SALT = keccak256("sherwood.eas.schema-registry.v1");
    bytes32 internal constant EAS_SALT = keccak256("sherwood.eas.v1");

    struct SchemaSpec {
        string name;
        string definition;
        bool revocable;
        bytes32 expectedUid;
    }

    function _schemas() internal pure returns (SchemaSpec[] memory s) {
        s = new SchemaSpec[](6);
        s[0] = SchemaSpec(
            "SYNDICATE_JOIN_REQUEST",
            "uint256 syndicateId, uint256 agentId, address vault, string message",
            true,
            0x1e7ce17b16233977ba913b156033e98f52029f4bee273a4abefe6c15ce11d5ef
        );
        s[1] = SchemaSpec(
            "AGENT_APPROVED",
            "uint256 syndicateId, uint256 agentId, address vault",
            true,
            0x1013f7b38f433b2a93fc5ac162482813081c64edd67cea9b5a90698531ddb607
        );
        s[2] = SchemaSpec(
            "X402_RESEARCH",
            "string provider, string queryType, string prompt, string costUsdc, string resultUri",
            false,
            0x86c67f0a59acb3093ecbeb6c4d1d4352e4a48143672e92ef9dd2fdfc8a9ca708
        );
        s[3] = SchemaSpec(
            "VENICE_PROVISION",
            "address agent, string status",
            false,
            0x76d4d6baa72307826cd2fd4ce069bb42ee54cdda6ed6ab208c8d233c893fb7f1
        );
        s[4] = SchemaSpec(
            "VENICE_INFERENCE",
            "string model, uint256 promptTokens, uint256 completionTokens, string promptHash",
            false,
            0xf9b4e530f3016c19439b67372a1c213c9339857627fb817032614b97433a2a14
        );
        s[5] = SchemaSpec(
            "TRADE_EXECUTED",
            "address tokenIn, address tokenOut, uint256 amountIn, string amountOut, string txHash, string routing",
            false,
            0x06bb488363a468f7f857ddc8cfffe918d048b8746a0d59eca9cd7f58dbdb4af6
        );
    }

    function run() external {
        SchemaSpec[] memory specs = _schemas();

        // Pinned UIDs must match the definitions before anything is broadcast —
        // a typo caught here costs nothing, caught after registration costs a
        // redeploy (schemas are immutable once registered).
        for (uint256 i = 0; i < specs.length; ++i) {
            bytes32 computed = keccak256(abi.encodePacked(specs[i].definition, address(0), specs[i].revocable));
            require(computed == specs[i].expectedUid, string.concat("UID mismatch (pre-flight): ", specs[i].name));
        }

        vm.startBroadcast();

        SchemaRegistry registry = new SchemaRegistry{salt: REGISTRY_SALT}();
        EAS eas = new EAS{salt: EAS_SALT}(ISchemaRegistry(address(registry)));

        for (uint256 i = 0; i < specs.length; ++i) {
            _register(registry, specs[i]);
        }

        vm.stopBroadcast();

        require(address(eas.getSchemaRegistry()) == address(registry), "EAS not bound to registry");

        console.log("SchemaRegistry:", address(registry));
        console.log("EAS:           ", address(eas));
        console.log("EAS version:   ", eas.version());
        console.log("Deploy block:  ", block.number);

        _patchAddress("EAS", address(eas));
        _patchAddress("EAS_SCHEMA_REGISTRY", address(registry));
    }

    /// @dev Idempotent: `register` reverts `AlreadyExists()` on a resumed run.
    ///      The tolerated path still verifies against the pinned UID — skipping
    ///      that would skip the whole point of pinning, and a partial resume is
    ///      exactly when a drifted definition would slip through.
    function _register(SchemaRegistry registry, SchemaSpec memory spec) internal {
        try registry.register(spec.definition, ISchemaResolver(address(0)), spec.revocable) returns (bytes32 uid) {
            require(uid == spec.expectedUid, string.concat("UID mismatch (registered): ", spec.name));
            console.log("registered %s -> %s", spec.name, vm.toString(uid));
        } catch {
            console.log("already registered %s - verifying", spec.name);
        }

        SchemaRecord memory rec = registry.getSchema(spec.expectedUid);
        require(rec.uid == spec.expectedUid, string.concat("schema absent at pinned UID: ", spec.name));
        require(
            keccak256(bytes(rec.schema)) == keccak256(bytes(spec.definition)),
            string.concat("definition drift: ", spec.name)
        );
        require(rec.revocable == spec.revocable, string.concat("revocable drift: ", spec.name));
        require(address(rec.resolver) == address(0), string.concat("unexpected resolver: ", spec.name));
    }
}
