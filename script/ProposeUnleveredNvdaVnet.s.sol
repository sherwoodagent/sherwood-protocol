// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ConcentratedLiquidityStrategy} from "../src/strategies/ConcentratedLiquidityStrategy.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {MarketParams} from "../src/vendor/morpho/IMorpho.sol";
import {IUniswapV3Pool} from "../src/vendor/uniswap/IUniswapV3Pool.sol";

/// @notice Vnet ops (unlevered-cl-lp task 4.1/4.2): clone the unlevered CL
///         template and open the first economically real strategy proposal for
///         the guardian fleet — unlevered NVDA/USDG 0.05% LP.
///
///         Not a deployment script: every address is the LIVE vnet book, and
///         the run is expected exactly once per proposal. Params follow the
///         datanet momentum pod (±3% band ≈ ±300 ticks) and the measured
///         venue ($5.2M TVL, $33M/day, 2026-08-31; realized round-trip cost
///         ~50bps in the pinned fork test).
contract ProposeUnleveredNvdaVnet is Script {
    address constant FACTORY = 0xb3C009aECAeDd5ccC62Ec12eDAAA55F19C4A1eFb;
    address constant GOVERNOR = 0x88D2A4FC849da99088945dF05599075aC48cAdbc;
    address constant VAULT = 0x98ac52b9957c648887d70A06c93C6aB45d202A9a;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant SWAP_ADAPTER = 0xdBf12248c68d1FCb6083f431A1d6ab6d0ef84E49;

    uint256 constant LP_AMOUNT = 10_000e6;
    uint256 constant STRATEGY_DURATION = 3600;

    function run() external {
        address template = vm.envAddress("CL_TEMPLATE");

        IUniswapV3Pool pool = IUniswapV3Pool(NVDA_POOL);
        int24 spacing = pool.tickSpacing();
        (, int24 spot,,,,,) = pool.slot0();
        int24 lower = ((spot - 300) / spacing) * spacing;
        int24 upper = ((spot + 300) / spacing) * spacing;

        ConcentratedLiquidityStrategy.InitParams memory p = ConcentratedLiquidityStrategy.InitParams({
            pool: NVDA_POOL,
            positionManager: POSITION_MANAGER,
            uniswapFactory: UNISWAP_V3_FACTORY,
            swapAdapter: SWAP_ADAPTER,
            morpho: address(0),
            marketParams: MarketParams({
                loanToken: address(0), collateralToken: address(0), oracle: address(0), irm: address(0), lltv: 0
            }),
            collateralAmount: 0,
            borrowAmount: 0,
            lpAmount: LP_AMOUNT,
            tickLower: lower,
            tickUpper: upper,
            expectedLiquidity: uint128(pool.liquidity() / 100),
            swapFractionBps: 5_000,
            twapWindow: 1800,
            maxTwapDeviationBps: 1_000,
            mintSlippageBps: 1_000,
            rerange: ConcentratedLiquidityStrategy.RerangePolicy({
                halfWidthTicks: 300,
                triggerBps: 8_000,
                minInterval: 1 hours,
                maxReranges: 4,
                slippageBps: 1_000,
                swapFractionBps: 5_000
            }),
            settleSlippageBps: 1_000,
            settleDeadline: 0,
            swapExtraData: abi.encodePacked(bytes1(0x00), abi.encode(uint24(500)))
        });

        vm.startBroadcast();

        // Reuse an existing, never-executed clone (its Pending->Executed
        // ratchet only flips at execute, so a clone whose proposal was blocked
        // is still proposable) — or mint a fresh one.
        address clone = vm.envOr("EXISTING_CLONE", address(0));
        if (clone == address(0)) {
            clone = StrategyFactory(FACTORY).cloneAndInit(template, VAULT, msg.sender, abi.encode(p));
        }
        console2.log("clone", clone);

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] =
            BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.approve, (clone, LP_AMOUNT)), value: 0});
        execCalls[1] = BatchExecutorLib.Call({target: clone, data: abi.encodeWithSignature("execute()"), value: 0});
        // The MOVER is the last call — cap it, not the approve.
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = LP_AMOUNT;

        BatchExecutorLib.Call[] memory settleCalls = new BatchExecutorLib.Call[](1);
        settleCalls[0] = BatchExecutorLib.Call({target: clone, data: abi.encodeWithSignature("settle()"), value: 0});
        uint256[] memory settleCaps = new uint256[](1);
        settleCaps[0] = LP_AMOUNT;

        uint256 pid = ISyndicateGovernor(GOVERNOR)
            .propose(
                VAULT,
                clone,
                "ipfs://unlevered-nvda-cl-lp-v1",
                STRATEGY_DURATION,
                ISyndicateGovernor.RiskEnvelope({maxCapital: LP_AMOUNT, maxDrawdownBps: 5_000}),
                execCalls,
                execCaps,
                settleCalls,
                settleCaps,
                new ISyndicateGovernor.CoProposer[](0)
            );
        console2.log("proposalId", pid);

        vm.stopBroadcast();
    }
}
