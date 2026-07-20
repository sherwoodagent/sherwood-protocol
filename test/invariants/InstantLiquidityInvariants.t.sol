// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {InstantLiquidityHandler, MockRouterH, MockLiquidStrategyH} from "./handlers/InstantLiquidityHandler.sol";

/// @title InstantLiquidityInvariantsTest
/// @notice Fuzz harness for the instant-withdrawal feature's novel properties:
///         INV-IL1 (settlement PnL isolates strategy performance from
///         mid-proposal LP flows via `interimNetFlow`) and INV-IL2 (no instant
///         exit is ever priced against float-only NAV). Reserve-seniority is
///         covered by AsyncRedeemInvariants.
contract InstantLiquidityInvariantsTest is StdInvariant, Test {
    SyndicateVault vault;
    ERC20Mock usdc;
    BatchExecutorLib executorLib;
    MockAgentRegistry agentRegistry;
    MockRouterH router;
    MockLiquidStrategyH strat;
    InstantLiquidityHandler handler;

    address constant MOCK_GOVERNOR = address(0xF00D);
    address owner = makeAddr("owner");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MockRouterH();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        strat = new MockLiquidStrategyH(usdc, address(vault));

        // The test contract is the factory: expose governorOf + priceRouter.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));

        handler = new InstantLiquidityHandler(vault, usdc, router, strat, MOCK_GOVERNOR);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = InstantLiquidityHandler.instantDeposit.selector;
        selectors[1] = InstantLiquidityHandler.instantWithdraw.selector;
        selectors[2] = InstantLiquidityHandler.execute.selector;
        selectors[3] = InstantLiquidityHandler.strategyYield.selector;
        selectors[4] = InstantLiquidityHandler.toggleLaneA.selector;
        selectors[5] = InstantLiquidityHandler.settle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INV-IL2 — while a proposal is live without Lane A live-NAV
    ///         (float-only `totalAssets`), no holder may instant-exit: mispricing
    ///         against float-only NAV would be theft. `maxWithdraw`/`maxRedeem`
    ///         must both report 0 so OZ's public withdraw/redeem revert.
    function invariant_noExitWithoutPricing() public view {
        if (!handler.lockedWithoutLaneA()) return;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            address a = handler.actorAt(i);
            assertEq(vault.maxWithdraw(a), 0, "INV-IL2: instant withdraw open without Lane A pricing");
            assertEq(vault.maxRedeem(a), 0, "INV-IL2: instant redeem open without Lane A pricing");
        }
    }

    /// @notice INV-IL1 (settlement PnL integrity) is asserted inside the
    ///         handler's `settle()` on every settlement. Guard against a
    ///         vacuous run: by the end of the sequence at least one full
    ///         execute→settle cycle must have exercised the PnL assertion.
    function afterInvariant() public view {
        assertGt(handler.settleAsserts(), 0, "INV-IL1 never exercised (no settlement occurred)");
    }
}
