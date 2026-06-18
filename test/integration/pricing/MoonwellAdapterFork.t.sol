// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PriceRouter} from "../../../src/pricing/PriceRouter.sol";
import {MoonwellSupplyAdapter} from "../../../src/pricing/adapters/MoonwellSupplyAdapter.sol";
import {Position} from "../../../src/interfaces/IPriceRouter.sol";
import {ICToken} from "../../../src/interfaces/ICToken.sol";
import {MoonwellSupplyStrategy} from "../../../src/strategies/MoonwellSupplyStrategy.sol";

/// @title  MoonwellAdapterForkTest
/// @notice Fork tests for the Phase-1 PriceRouter + MoonwellSupplyAdapter
///         against real Moonwell on Base mainnet. Validates that vault-side
///         pricing reads the venue (not the strategy), rejects non-canonical
///         venues, and lands on the same number a real strategy self-reports.
/// @dev    Run: forge test --fork-url $BASE_RPC_URL --match-contract MoonwellAdapterForkTest
contract MoonwellAdapterForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MOONWELL_MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address constant MOONWELL_COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;

    uint256 constant SUPPLY = 10_000e6;
    bytes32 constant KIND = keccak256("MOONWELL_SUPPLY");

    PriceRouter router;
    MoonwellSupplyAdapter adapter;
    address owner = makeAddr("owner");
    address holder = makeAddr("holder");

    function setUp() public {
        adapter = new MoonwellSupplyAdapter(MOONWELL_COMPTROLLER);
        PriceRouter impl = new PriceRouter();
        router = PriceRouter(address(new ERC1967Proxy(address(impl), abi.encodeCall(PriceRouter.initialize, (owner)))));
        vm.prank(owner);
        router.registerAdapter(KIND, address(adapter));
    }

    function _supplyAsHolder(uint256 amount) internal {
        deal(USDC, holder, amount);
        vm.startPrank(holder);
        IERC20(USDC).approve(MOONWELL_MUSDC, amount);
        require(ICToken(MOONWELL_MUSDC).mint(amount) == 0, "mint failed");
        vm.stopPrank();
    }

    function _pos() internal pure returns (Position memory) {
        return Position({venue: MOONWELL_MUSDC, kind: KIND, ref: ""});
    }

    /// @notice Adapter prices a real Moonwell position read from the venue.
    function test_fork_adapterPricesRealPosition() public {
        _supplyAsHolder(SUPPLY);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertTrue(ok, "priceable");
        uint256 expected =
            (ICToken(MOONWELL_MUSDC).balanceOf(holder) * ICToken(MOONWELL_MUSDC).exchangeRateStored()) / 1e18;
        assertEq(v, expected, "value == balanceOf*rate/1e18");
        assertApproxEqRel(v, SUPPLY, 0.01e18, "~10k USDC supplied");
    }

    /// @notice A non-listed venue (USDC itself) is rejected -> Lane B fallback.
    function test_fork_unlistedVenue_returnsZeroFalse() public view {
        Position memory p = Position({venue: USDC, kind: KIND, ref: ""});
        (uint256 v, bool ok) = adapter.value(p, holder);
        assertEq(v, 0);
        assertFalse(ok, "fake/foreign venue not priceable");
    }

    /// @notice Router applies the realizability haircut to the real value.
    function test_fork_routerAppliesHaircut() public {
        _supplyAsHolder(SUPPLY);
        vm.prank(owner);
        router.setHaircutBps(KIND, 100); // 1%
        (uint256 raw, bool okA) = adapter.value(_pos(), holder);
        (uint256 v, bool ok) = router.valuePosition(_pos(), holder);
        assertTrue(okA && ok);
        assertEq(v, (raw * 9900) / 10_000, "1% haircut on real value");
    }

    /// @notice End-to-end trust inversion: a real MoonwellSupplyStrategy holds
    ///         the position; the router prices it by reading the venue (mToken
    ///         balance × exchange rate) independently — the strategy is never
    ///         asked for a value.
    function test_fork_routerPricesRealStrategyPosition() public {
        address template = address(new MoonwellSupplyStrategy());
        bytes memory initData = abi.encode(USDC, MOONWELL_MUSDC, SUPPLY, uint256(9_900e6), false);
        address strategy = Clones.clone(template);
        MoonwellSupplyStrategy(payable(strategy)).initialize(address(this), makeAddr("proposer"), initData);

        // This test contract acts as the vault: fund + approve + execute.
        deal(USDC, address(this), SUPPLY);
        IERC20(USDC).approve(strategy, SUPPLY);
        MoonwellSupplyStrategy(payable(strategy)).execute();

        (uint256 routerVal, bool ok) = router.valuePosition(_pos(), strategy);
        // Same math the router performs, computed here independently from the venue.
        uint256 expected =
            (ICToken(MOONWELL_MUSDC).balanceOf(strategy) * ICToken(MOONWELL_MUSDC).exchangeRateStored()) / 1e18;

        assertTrue(ok, "strategy position instant-priceable");
        assertEq(routerVal, expected, "router prices the strategy's venue position");
        assertApproxEqRel(routerVal, SUPPLY, 0.01e18, "~10k USDC");
    }

    /// @notice Full Lane A pricing path on real Moonwell: strategy.positions()
    ///         -> router.valueStrategy -> adapter -> venue, gated by governance
    ///         eligibility (off by default, on after enable).
    function test_fork_valueStrategy_gatedByEligibility() public {
        address template = address(new MoonwellSupplyStrategy());
        bytes memory initData = abi.encode(USDC, MOONWELL_MUSDC, SUPPLY, uint256(9_900e6), false);
        address strategy = Clones.clone(template);
        MoonwellSupplyStrategy(payable(strategy)).initialize(address(this), makeAddr("proposer"), initData);
        deal(USDC, address(this), SUPPLY);
        IERC20(USDC).approve(strategy, SUPPLY);
        MoonwellSupplyStrategy(payable(strategy)).execute();

        // Lane A disabled by default → not instant-eligible (falls to Lane B).
        (, bool okBefore) = router.valueStrategy(strategy);
        assertFalse(okBefore, "Lane A disabled by default");

        // Governance enables the kind after audit.
        vm.prank(owner);
        router.setLaneAEnabled(KIND, true);
        (uint256 v, bool ok) = router.valueStrategy(strategy);
        assertTrue(ok, "enabled -> instant-eligible");
        assertApproxEqRel(v, SUPPLY, 0.01e18, "~10k USDC priced via positions()");
    }
}
