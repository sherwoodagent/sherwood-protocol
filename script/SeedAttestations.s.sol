// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {IEAS, AttestationRequest, AttestationRequestData} from "eas-contracts/IEAS.sol";

/// @title  SeedAttestations
/// @notice Writes one attestation per Sherwood schema against the EAS deployed
///         by DeployEAS. Purpose is to give the indexer and the agent page real
///         data to render — the six schemas alone produce an empty UI.
///
///         Reads EAS from chains/{chainId}.json, so it follows the deploy.
///
///         Deliberately cheap and repeatable: every attestation is revocable =
///         the schema's own flag, recipient is the deployer, and no ETH is sent.
///         Re-running it adds MORE attestations rather than replacing them —
///         attestations are append-only, there is no upsert.
///
///   Usage:
///     forge script script/SeedAttestations.s.sol:SeedAttestations \
///       --rpc-url <rpc> --broadcast
contract SeedAttestations is ScriptBase {
    bytes32 constant JOIN_REQUEST = 0x1e7ce17b16233977ba913b156033e98f52029f4bee273a4abefe6c15ce11d5ef;
    bytes32 constant AGENT_APPROVED = 0x1013f7b38f433b2a93fc5ac162482813081c64edd67cea9b5a90698531ddb607;
    bytes32 constant X402_RESEARCH = 0x86c67f0a59acb3093ecbeb6c4d1d4352e4a48143672e92ef9dd2fdfc8a9ca708;
    bytes32 constant VENICE_PROVISION = 0x76d4d6baa72307826cd2fd4ce069bb42ee54cdda6ed6ab208c8d233c893fb7f1;
    bytes32 constant VENICE_INFERENCE = 0xf9b4e530f3016c19439b67372a1c213c9339857627fb817032614b97433a2a14;
    bytes32 constant TRADE_EXECUTED = 0x06bb488363a468f7f857ddc8cfffe918d048b8746a0d59eca9cd7f58dbdb4af6;

    function run() external {
        IEAS eas = IEAS(_readAddress("EAS"));
        address me = msg.sender;

        // A stand-in vault/agent so the decoded fields are not all zero. These
        // are NOT real Sherwood deployments — chain 4663 has no core contracts
        // yet — they exist so the agent page has something to render.
        uint256 syndicateId = 1;
        uint256 agentId = 42;
        address vault = address(uint160(uint256(keccak256("sherwood.seed.vault"))));

        vm.startBroadcast();

        _attest(
            eas,
            JOIN_REQUEST,
            me,
            true,
            abi.encode(syndicateId, agentId, vault, "Seed join request - indexer smoke test")
        );

        _attest(eas, AGENT_APPROVED, me, true, abi.encode(syndicateId, agentId, vault));

        _attest(
            eas,
            X402_RESEARCH,
            vault,
            false,
            abi.encode(
                "venice", "market-analysis", "Summarise NVDA momentum", "0.02", "ipfs://seed-research-placeholder"
            )
        );

        _attest(eas, VENICE_PROVISION, vault, false, abi.encode(me, "provisioned"));

        _attest(
            eas,
            VENICE_INFERENCE,
            vault,
            false,
            abi.encode("venice-uncensored", uint256(1280), uint256(430), "seed-prompt-hash")
        );

        _attest(
            eas,
            TRADE_EXECUTED,
            vault,
            false,
            abi.encode(
                address(uint160(uint256(keccak256("seed.tokenIn")))),
                address(uint160(uint256(keccak256("seed.tokenOut")))),
                uint256(1e18),
                "2500.00",
                "0xseedtxhash",
                "uniswap-v3"
            )
        );

        vm.stopBroadcast();

        console.log("Seeded 6 attestations against EAS", address(eas));
    }

    function _attest(IEAS eas, bytes32 schema, address recipient, bool revocable, bytes memory data) internal {
        bytes32 uid = eas.attest(
            AttestationRequest({
                schema: schema,
                data: AttestationRequestData({
                    recipient: recipient,
                    expirationTime: 0, // NO_EXPIRATION_TIME
                    revocable: revocable,
                    refUID: bytes32(0),
                    data: data,
                    value: 0
                })
            })
        );
        console.log("  attested ->", vm.toString(uid));
    }
}
