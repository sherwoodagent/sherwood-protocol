// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {VaultWithdrawalQueue} from "../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

/// @notice Mock PriceRouter returning a configurable strategy valuation.
contract MockRouter {
    uint256 public v;
    bool public ok;

    function set(uint256 v_, bool ok_) external {
        v = v_;
        ok = ok_;
    }

    function valueStrategy(address) external view returns (uint256, bool) {
        return (v, ok);
    }
}

/// @notice Strategy mock holding real USDC it can return on demand (Task 4+).
contract MockLiquidStrategy {
    ERC20Mock immutable usdc;
    address immutable vaultAddr;
    uint256 public liq;
    bool public lie; // report liquidity but under-deliver

    constructor(ERC20Mock usdc_, address vault_) {
        usdc = usdc_;
        vaultAddr = vault_;
    }

    function setLiquidity(uint256 l) external {
        liq = l;
    }

    function setLie(bool l) external {
        lie = l;
    }

    function pushBack(uint256 amt) external {
        usdc.transfer(vaultAddr, amt);
    }

    function availableLiquidity() external view returns (uint256) {
        return liq;
    }

    function withdrawTo(uint256 assets) external {
        require(msg.sender == vaultAddr, "not vault");
        usdc.transfer(vaultAddr, lie ? assets / 2 : assets);
    }
}

contract VaultInstantLiquidityTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockRouter router;
    MockLiquidStrategy strat;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address constant MOCK_GOVERNOR = address(0xF00D);
    uint256 constant PID = 1;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MockRouter();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        strat = new MockLiquidStrategy(usdc, address(vault));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        _setLocked(false);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setLocked(bool locked) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(locked ? PID : uint256(0))
        );
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(locked ? uint256(1) : 0));
        if (locked) {
            ISyndicateGovernor.StrategyProposal memory p;
            p.id = PID;
            p.vault = address(vault);
            p.strategy = address(strat);
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, PID), abi.encode(p)
            );
        }
    }

    // ── Task 1: minBufferBps setter ──

    function test_minBufferBps_defaultZero() public view {
        assertEq(vault.minBufferBps(), 0, "buffer off by default");
    }

    function test_setMinBufferBps_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        vault.setMinBufferBps(1_000);
    }

    function test_setMinBufferBps_setsAndEmits() public {
        vm.prank(owner);
        vm.expectEmit();
        emit ISyndicateVault.MinBufferUpdated(1_000);
        vault.setMinBufferBps(1_000);
        assertEq(vault.minBufferBps(), 1_000);
    }

    function test_setMinBufferBps_revertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.BufferTooHigh.selector);
        vault.setMinBufferBps(5_001);
    }

    function test_setMinBufferBps_acceptsExactCap() public {
        vm.prank(owner);
        vault.setMinBufferBps(5_000);
        assertEq(vault.minBufferBps(), 5_000);
    }

    function test_setMinBufferBps_resetToZero() public {
        vm.prank(owner);
        vault.setMinBufferBps(1_000);
        vm.prank(owner);
        vault.setMinBufferBps(0);
        assertEq(vault.minBufferBps(), 0);
    }
}
