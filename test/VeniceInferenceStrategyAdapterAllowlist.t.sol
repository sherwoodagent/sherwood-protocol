// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {VeniceInferenceStrategy} from "../src/strategies/VeniceInferenceStrategy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @notice Minimal vault stand-in exposing only `governor()`, mirroring the
///         one hop `_requireAllowedAdapter` reads off `vault()`. Has code
///         (unlike `makeAddr`) so the walk's first hop can resolve.
contract MockVaultWithGovernor {
    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }
}

/// @notice Minimal governor stand-in exposing only `tierRegistry()`.
contract MockGovernorWithRegistry {
    address public tierRegistry;

    constructor(address registry_) {
        tierRegistry = registry_;
    }
}

/// @notice A governor with code but no `tierRegistry()` selector — the walk's
///         staticcall reverts (no matching function, no fallback), which
///         `_readAddress` must treat as unresolved rather than propagating.
contract MockGovernorNoRegistryGetter {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Minimal registry stand-in: owner-settable per-adapter allowlist.
contract MockTierRegistry {
    mapping(address => bool) public allowed;

    function setAllowed(address adapter, bool value) external {
        allowed[adapter] = value;
    }

    function isAdapterAllowed(address adapter) external view returns (bool) {
        return allowed[adapter];
    }
}

/// @notice A registry whose `isAdapterAllowed` always reverts — models a
///         wrong address wired as the registry.
contract RevertingRegistry {
    function isAdapterAllowed(address) external pure returns (bool) {
        revert("registry broken");
    }
}

contract VeniceInferenceStrategyAdapterAllowlistTest is Test {
    VeniceInferenceStrategy public template;

    ERC20Mock public usdc;
    ERC20Mock public vvvToken;
    ERC20Mock public sVVVToken; // stand-in address only — never actually staked to in these tests
    address public aeroRouterAddr = makeAddr("aeroRouter");

    address public proposer = makeAddr("proposer");
    address public agentWallet = makeAddr("agentWallet");
    address public aeroFactoryAddr = makeAddr("aeroFactory");

    uint256 constant SWAP_AMOUNT = 1000e6;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        vvvToken = new ERC20Mock("VVV", "VVV", 18);
        sVVVToken = new ERC20Mock("Staked VVV", "sVVV", 18);
        template = new VeniceInferenceStrategy();
    }

    function _swapInitData() internal view returns (bytes memory) {
        return abi.encode(
            VeniceInferenceStrategy.InitParams({
                asset: address(usdc),
                weth: address(0),
                vvv: address(vvvToken),
                sVVV: address(sVVVToken),
                aeroRouter: aeroRouterAddr,
                aeroFactory: aeroFactoryAddr,
                agent: agentWallet,
                assetAmount: SWAP_AMOUNT,
                minVVV: 1,
                deadlineOffset: 0,
                singleHop: true
            })
        );
    }

    function _directInitData() internal view returns (bytes memory) {
        return abi.encode(
            VeniceInferenceStrategy.InitParams({
                asset: address(vvvToken),
                weth: address(0),
                vvv: address(vvvToken),
                sVVV: address(sVVVToken),
                aeroRouter: address(0),
                aeroFactory: address(0),
                agent: agentWallet,
                assetAmount: SWAP_AMOUNT,
                minVVV: 0,
                deadlineOffset: 0,
                singleHop: false
            })
        );
    }

    function _wiredVault(address registry) internal returns (MockVaultWithGovernor vault) {
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(registry);
        vault = new MockVaultWithGovernor(address(governor));
    }

    function _clone() internal returns (VeniceInferenceStrategy) {
        return VeniceInferenceStrategy(Clones.clone(address(template)));
    }

    // ── Non-allowlisted refused ──

    function test_aeroRouterNotAllowlisted_swapPathReverts() public {
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(sVVVToken), true); // sVVV allowed, aeroRouter is not
        MockVaultWithGovernor vault = _wiredVault(address(registry));

        VeniceInferenceStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(
                VeniceInferenceStrategy.AdapterNotAllowed.selector, aeroRouterAddr, address(registry)
            )
        );
        strategy.initialize(address(vault), proposer, _swapInitData());
    }

    function test_sVVVNotAllowlisted_directPathReverts() public {
        MockTierRegistry registry = new MockTierRegistry();
        // sVVV deliberately left un-allowlisted; direct path never touches aeroRouter at all
        MockVaultWithGovernor vault = _wiredVault(address(registry));

        VeniceInferenceStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(
                VeniceInferenceStrategy.AdapterNotAllowed.selector, address(sVVVToken), address(registry)
            )
        );
        strategy.initialize(address(vault), proposer, _directInitData());
    }

    function test_sVVVNotAllowlisted_swapPathReverts_evenWithAeroRouterAllowed() public {
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(aeroRouterAddr, true); // aeroRouter allowed, sVVV is not
        MockVaultWithGovernor vault = _wiredVault(address(registry));

        VeniceInferenceStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(
                VeniceInferenceStrategy.AdapterNotAllowed.selector, address(sVVVToken), address(registry)
            )
        );
        strategy.initialize(address(vault), proposer, _swapInitData());
    }

    // ── Allowlisted passes ──

    function test_bothAllowlisted_swapPathInitializesUnchanged() public {
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(aeroRouterAddr, true);
        registry.setAllowed(address(sVVVToken), true);
        MockVaultWithGovernor vault = _wiredVault(address(registry));

        VeniceInferenceStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _swapInitData());
        assertEq(strategy.aeroRouter(), aeroRouterAddr);
        assertEq(strategy.sVVV(), address(sVVVToken));
    }

    function test_sVVVAllowlisted_directPathInitializesWithoutCheckingAeroRouter() public {
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(sVVVToken), true);
        // aeroRouter is address(0) on the direct path and never allowlisted here —
        // if the check spuriously ran on address(0) it would revert.
        MockVaultWithGovernor vault = _wiredVault(address(registry));

        VeniceInferenceStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _directInitData());
        assertEq(strategy.aeroRouter(), address(0));
        assertFalse(strategy.needsSwap());
    }

    // ── Unresolved walk skips ──

    function test_codelessVault_skipsCheck() public {
        VeniceInferenceStrategy strategy = _clone();
        address codelessVault = makeAddr("codelessVault");
        strategy.initialize(codelessVault, proposer, _swapInitData()); // no allowlist wired anywhere; must not revert
        assertEq(strategy.aeroRouter(), aeroRouterAddr);
    }

    function test_vaultGovernorZero_skipsCheck() public {
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(0));
        VeniceInferenceStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _swapInitData());
        assertEq(strategy.sVVV(), address(sVVVToken));
    }

    function test_governorWithoutRegistryGetter_skipsCheck() public {
        MockGovernorNoRegistryGetter governor = new MockGovernorNoRegistryGetter();
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        VeniceInferenceStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _swapInitData());
        assertEq(strategy.aeroRouter(), aeroRouterAddr);
    }

    function test_tierRegistryZero_skipsCheck() public {
        MockVaultWithGovernor vault = _wiredVault(address(0));
        VeniceInferenceStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _directInitData());
        assertEq(strategy.sVVV(), address(sVVVToken));
    }

    // ── Resolved-but-unreadable registry fails closed ──

    function test_revertingRegistry_failsClosed() public {
        RevertingRegistry registry = new RevertingRegistry();
        MockVaultWithGovernor vault = _wiredVault(address(registry));
        VeniceInferenceStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(
                VeniceInferenceStrategy.AdapterNotAllowed.selector, aeroRouterAddr, address(registry)
            )
        );
        strategy.initialize(address(vault), proposer, _swapInitData());
    }
}
