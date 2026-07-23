// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScriptBase} from "./ScriptBase.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";

/**
 * @notice Propose the LeveragedAerodromeCLStrategy through the real SyndicateGovernor. Must be
 *         broadcast by the AGENT EOA (`propose` requires `vault.isAgent(msg.sender)`). Calls:
 *         exec = [USDC.transfer(strategy, PRINCIPAL), strategy.execute()], settle =
 *         [strategy.settle()], no co-proposers.
 *
 *   Env:
 *     VAULT             — REQUIRED. Live SyndicateVault.
 *     STRATEGY          — REQUIRED. The clone address from CloneAndInitLeveragedAero.
 *     SYNDICATE_GOVERNOR — governor addr (else read from chains.json).
 *     PRINCIPAL         — USDC (6dp) moved into the strategy at execute (default 50000e6).
 *     STRATEGY_DURATION_DAYS — proposal duration in days (default 3650).
 *
 *   Usage:
 *     VAULT=0x.. STRATEGY=0x.. \
 *     forge script script/ProposeLeveragedAero.s.sol:ProposeLeveragedAero \
 *       --rpc-url "$RPC" --broadcast --slow --private-key $AGENT_PK
 */
contract ProposeLeveragedAero is ScriptBase {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address vault = vm.envAddress("VAULT");
        address strategy = vm.envAddress("STRATEGY");
        uint256 principal = vm.envOr("PRINCIPAL", uint256(50_000e6));
        uint256 durationDays = vm.envOr("STRATEGY_DURATION_DAYS", uint256(3650));

        address governor = vm.envOr("SYNDICATE_GOVERNOR", address(0));
        if (governor == address(0)) governor = _readAddress("SYNDICATE_GOVERNOR");
        require(governor != address(0), "governor not set (env or chains.json)");

        BatchExecutorLib.Call[] memory exec = new BatchExecutorLib.Call[](2);
        exec[0] = BatchExecutorLib.Call({
            target: USDC, data: abi.encodeCall(IERC20.transfer, (strategy, principal)), value: 0
        });
        exec[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});

        BatchExecutorLib.Call[] memory settle = new BatchExecutorLib.Call[](1);
        settle[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});

        ISyndicateGovernor.CoProposer[] memory none = new ISyndicateGovernor.CoProposer[](0);

        // Permissive envelope: vault-level metering lands in Task 4; the e2e
        // proposal declares the widest legal bounds.
        ISyndicateGovernor.RiskEnvelope memory envelope =
            ISyndicateGovernor.RiskEnvelope({maxCapital: type(uint256).max, maxDrawdownBps: 10_000});

        vm.startBroadcast();
        uint256 proposalId = ISyndicateGovernor(governor)
            .propose(vault, strategy, "ipfs://e2e", durationDays * 1 days, envelope, exec, settle, none);
        vm.stopBroadcast();

        console.log("PROPOSAL_ID", proposalId);
    }
}
