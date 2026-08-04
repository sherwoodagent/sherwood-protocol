// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

/// @title Strategy_init_frontrun — MS-C3 regression
/// @notice Verifies that every concrete strategy template is *uninitializable*
///         once deployed via `new`, while ERC-1167 minimal-proxy clones spawned
///         from the template remain initializable. The constructor on
///         `BaseStrategy` flips `_initialized = true` so a separate-tx
///         `initialize` call on the template (e.g. an attacker front-running
///         a clone deployment that is split across two transactions) reverts
///         with `AlreadyInitialized`. Clones don't run constructors, so the
///         atomic `cloneAndInit` flow is unaffected.
contract StrategyInitFrontrunTest is Test {
    address public vault = makeAddr("vault");
    address public proposer = makeAddr("proposer");
    address public attacker = makeAddr("attacker");

    // Stub addresses — only need to be non-zero for init validation. The
    // tests assert revert on AlreadyInitialized *before* protocol-specific
    // checks ever run, so we don't need real protocol mocks here.
    address public stubToken = makeAddr("stubToken");
    address public stubProtocol = makeAddr("stubProtocol");

    // ── MockStrategy — the property in isolation ──
    //
    // MS-C3 is a `BaseStrategy` property, not a per-protocol one, so it is
    // worth exercising once against a subclass that adds nothing. This case
    // replaces the former `MoonwellSupplyStrategy` one, which carried the
    // same trivial init payload but dragged a Base-chain integration with it.

    function test_mock_template_is_locked() public {
        MockStrategy template = new MockStrategy();
        bytes memory initData = abi.encode(stubToken, stubProtocol, uint256(1), uint256(0), false);

        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        template.initialize(vault, proposer, initData);
    }

    function test_mock_clone_initializes() public {
        MockStrategy template = new MockStrategy();
        address payable clone = payable(Clones.clone(address(template)));
        bytes memory initData = abi.encode(stubToken, stubProtocol, uint256(1), uint256(0), false);

        MockStrategy(clone).initialize(vault, proposer, initData);

        assertEq(MockStrategy(clone).vault(), vault);
        assertEq(MockStrategy(clone).proposer(), proposer);
    }

    // ── PortfolioStrategy ──

    function test_portfolio_template_is_locked() public {
        PortfolioStrategy template = new PortfolioStrategy();
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("tokenA");
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        extra[0] = "";
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 18;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = keccak256("test.feed.tokenA");
        bytes memory initData = abi.encode(
            stubToken,
            makeAddr("adapter"),
            address(0),
            tokens,
            weights,
            uint256(1e6),
            uint256(100),
            extra,
            priceDecs,
            feedIds
        );

        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        template.initialize(vault, proposer, initData);
    }

    function test_portfolio_clone_initializes() public {
        PortfolioStrategy template = new PortfolioStrategy();
        address payable clone = payable(Clones.clone(address(template)));
        address tokenA = makeAddr("tokenA");
        // Mock decimals() so init can cache _assetDecimals + _tokenDecimals
        vm.mockCall(stubToken, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.mockCall(tokenA, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        address[] memory tokens = new address[](1);
        tokens[0] = tokenA;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        extra[0] = "";
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 18;
        // chainlinkVerifier == address(0) selects push-feed mode, so the feedId
        // must encode an AggregatorV3 whose live decimals() matches priceDecs.
        // Reuse the mocked tokenA address (decimals() = 18).
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(uint160(tokenA)));
        bytes memory initData = abi.encode(
            stubToken,
            makeAddr("adapter"),
            address(0),
            tokens,
            weights,
            uint256(1e6),
            uint256(100),
            extra,
            priceDecs,
            feedIds
        );

        PortfolioStrategy(clone).initialize(vault, proposer, initData);
        assertEq(PortfolioStrategy(clone).vault(), vault);
    }
}
