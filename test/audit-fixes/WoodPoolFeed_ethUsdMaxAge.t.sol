// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChallengeEndToEndTest} from "../ChallengeEndToEnd.t.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IExposureLedger} from "../../src/interfaces/IExposureLedger.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {WoodPoolFeed} from "../../src/pricing/WoodPoolFeed.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";
import {MockUniswapV3PoolRing} from "../mocks/MockUniswapV3PoolRing.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {RobinhoodParams} from "../../script/robinhood-mainnet/RobinhoodParams.sol";

/// @title WoodPoolFeed_ethUsdMaxAge — audit 2026-10-01 V1-06 regression
/// @notice With the SHIPPED `ETH_USD_MAX_AGE`, an ETH/USD round published late (24h + 1s)
///         still prices WOOD end to end; only a reading older than the bound halts.
///         REAL: WoodPoolFeed, ExposureLedger, GuardianRegistry, SyndicateGovernor,
///         ChallengeGame, StakedWood. MOCKED: the V2 pair, the V3 pool, ETH/USD, ERC-20s.
contract WoodPoolFeedEthUsdMaxAgeTest is ChallengeEndToEndTest {
    ERC20Mock internal bWeth;
    MockUniswapV2Pair internal bPair;
    MockUniswapV3PoolRing internal bPool;
    MockAggregatorV3 internal bEthUsd;
    WoodPoolFeed internal bFeed;

    /// @dev ~2x the pair's price, so the pair ($0.05) is the `min` leg.
    int24 internal constant B_V3_TICK = -103_094;
    uint128 internal constant B_V3_LIQ = 2e22; // ~ the live pool's 2.128e22
    uint256 internal constant KEEP_STEP = 1 hours;

    // ── fixture ──────────────────────────────────────────────────────────

    /// @dev Production `WoodPoolFeed` with the SHIPPED constants, primed over one full
    ///      window, wired into the ledger with the shipped WOOD feed bound.
    function _bSeat() internal {
        bWeth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        bPair = new MockUniswapV2Pair(address(wood), address(bWeth), 1e26, 1_666_666_666_666_666_666_666);
        bPool = new MockUniswapV3PoolRing(address(wood), address(bWeth), B_V3_TICK, B_V3_LIQ);
        bEthUsd = new MockAggregatorV3(8, 3000e8);
        bEthUsd.setUpdatedAt(vm.getBlockTimestamp());
        bFeed = new WoodPoolFeed(
            address(bPair),
            address(bPool),
            address(wood),
            address(bWeth),
            address(bEthUsd),
            RobinhoodParams.ETH_USD_MAX_AGE,
            RobinhoodParams.TWAP_WINDOW,
            RobinhoodParams.MIN_WETH_RESERVE,
            uint128(RobinhoodParams.MIN_V3_LIQUIDITY)
        );
        assertEq(bFeed.ethUsdMaxAge(), 1 days + 2 hours, "shipped ETH_USD_MAX_AGE");
        bFeed.update();
        _bWarpKeep(vm.getBlockTimestamp() + RobinhoodParams.TWAP_WINDOW);

        vm.prank(ledgerOwner);
        ledger.setWoodFeed(address(bFeed), RobinhoodParams.WOOD_FEED_MAX_DELAY);

        wood.mint(challenger, 100 * _challengerBond());
    }

    /// @dev Keeper + healthy ETH feed: advance in 1h steps, publishing ETH/USD and
    ///      rolling the pool feed at every step.
    function _bWarpKeep(uint256 target) internal {
        uint256 t = vm.getBlockTimestamp();
        while (t < target) {
            t = t + KEEP_STEP < target ? t + KEEP_STEP : target;
            vm.warp(t);
            bEthUsd.setUpdatedAt(t);
            bFeed.update();
        }
    }

    function _bEthAge(uint256 age) internal {
        bEthUsd.setUpdatedAt(vm.getBlockTimestamp() - age);
    }

    function _bSel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) {
            assembly {
                s := mload(add(ret, 32))
            }
        }
    }

    function _bExpect(bool ok, bytes memory ret, bytes4 sel, string memory what) internal pure {
        assertFalse(ok, string.concat(what, ": must revert"));
        assertEq(_bSel(ret), sel, string.concat(what, ": selector"));
    }

    function _bProposeCall() internal returns (bool ok, bytes memory ret) {
        ISyndicateGovernor.RiskEnvelope memory env =
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000});
        BatchExecutorLib.Call[] memory ex = _execCalls();
        BatchExecutorLib.Call[] memory st = _settleCalls();
        bytes memory data = abi.encodeCall(
            gov.propose,
            (
                address(vault),
                address(0),
                "ipfs://b",
                7 days,
                env,
                ex,
                GovEnvelope.defaultCaps(MAX_CAPITAL, ex.length),
                st,
                GovEnvelope.defaultCaps(MAX_CAPITAL, st.length),
                new ISyndicateGovernor.CoProposer[](0)
            )
        );
        vm.prank(agent);
        (ok, ret) = address(gov).call(data);
    }

    function _bVoteCall(uint256 pid) internal returns (bool ok, bytes memory ret) {
        bytes memory data = abi.encodeCall(
            registry.voteOnProposal, (address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max)
        );
        vm.prank(g1);
        (ok, ret) = address(registry).call(data);
    }

    function _bExecCall(uint256 pid) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(gov).call(abi.encodeCall(gov.executeProposal, (pid)));
    }

    function _bFileCall(uint256 pid) internal returns (bool ok, bytes memory ret) {
        bytes memory data = abi.encodeCall(
            game.file,
            (
                address(gov),
                pid,
                IChallengeGame.Predicate.OutOfAdapterOutflow,
                address(adapter),
                adapter.poke.selector,
                "ipfs://b-evidence"
            )
        );
        vm.prank(challenger);
        (ok, ret) = address(game).call(data);
    }

    /// @dev Runs the whole lifecycle; at each entry point the ETH/USD answer is first aged
    ///      `ethAge`. If `halts`, asserts the revert + selector, then lets the (late)
    ///      heartbeat land and retries.
    function _run(uint256 ethAge, bool halts) internal {
        _bSeat();
        bool ok;
        bytes memory ret;

        // ── (1) the price read itself.
        _bEthAge(ethAge);
        (ok, ret) = address(bFeed).staticcall(abi.encodeCall(bFeed.latestRoundData, ()));
        if (halts) {
            _bExpect(ok, ret, WoodPoolFeed.PriceUnavailable.selector, "WoodPoolFeed.latestRoundData");
            (ok, ret) = address(ledger).staticcall(abi.encodeCall(ledger.woodPriceX8, ()));
            _bExpect(ok, ret, IExposureLedger.NoWoodPrice.selector, "ExposureLedger.woodPriceX8");
        } else {
            assertTrue(ok, "feed answers");
            assertGt(ledger.woodPriceX8(), 0, "ledger prices WOOD");
        }

        // ── (2) propose (proposerBondWood).
        (ok, ret) = _bProposeCall();
        if (halts) {
            _bExpect(ok, ret, IExposureLedger.NoWoodPrice.selector, "SyndicateGovernor.propose");
            _bEthAge(0);
            (ok, ret) = _bProposeCall();
        }
        assertTrue(ok, "propose lands");
        uint256 pid = abi.decode(ret, (uint256));

        // ── (3) guardian Approve vote with a lock.
        _bWarpKeep(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        _bEthAge(ethAge);
        (ok, ret) = _bVoteCall(pid);
        if (halts) {
            _bExpect(ok, ret, IExposureLedger.NoWoodPrice.selector, "GuardianRegistry.voteOnProposal(Approve)");
            _bEthAge(0);
            (ok, ret) = _bVoteCall(pid);
        }
        assertTrue(ok, "approve lands");
        assertEq(ledger.openExposure(g1), G1_STAKE, "lock booked");

        // ── (4) execute (requireApproveQuorum).
        _bWarpKeep(gov.getProposal(pid).reviewEnd + 1);
        _bEthAge(ethAge);
        (ok, ret) = _bExecCall(pid);
        if (halts) {
            _bExpect(ok, ret, IExposureLedger.NoWoodPrice.selector, "SyndicateGovernor.executeProposal");
            _bEthAge(0);
            (ok, ret) = _bExecCall(pid);
        }
        assertTrue(ok, "execute lands");

        // ── (5) ChallengeGame.file (unsharedLiabilityUsd).
        _bEthAge(ethAge);
        (ok, ret) = _bFileCall(pid);
        if (halts) {
            _bExpect(ok, ret, IChallengeGame.WoodPriceUnset.selector, "ChallengeGame.file");
            _bEthAge(0);
            (ok, ret) = _bFileCall(pid);
        }
        assertTrue(ok, "file lands");
        assertEq(abi.decode(ret, (uint256)), 1, "challenge 1 filed");
    }

    /// @notice A heartbeat round 1s late (24h + 1s) prices the read, propose, approve,
    ///         execute and file first time (the audit PoC halted all five).
    function test_ethUsdOneSecondPastHeartbeat_everythingLands() public {
        _run(RobinhoodParams.ETH_USD_HEARTBEAT + 1, false);
    }

    /// @notice A reading 1s past the shipped bound halts all five, and recovers on publish.
    function test_ethUsdPastTheShippedBound_haltsEveryPricedEntryPoint() public {
        _run(RobinhoodParams.ETH_USD_MAX_AGE + 1, true);
    }

    /// @notice Boundary: exactly the bound prices (`age > max` is strict), one second more fails.
    function test_boundaryIsStrictAtTheShippedBound() public {
        _bSeat();
        _bEthAge(RobinhoodParams.ETH_USD_MAX_AGE);
        assertGt(ledger.woodPriceX8(), 0, "age == ETH_USD_MAX_AGE still prices");
        _bEthAge(RobinhoodParams.ETH_USD_MAX_AGE + 1);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }
}
