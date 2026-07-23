// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockProposalStatus} from "./mocks/MockProposalStatus.sol";

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

/// @notice Minimal concrete BaseStrategy that overrides nothing liquidity-related.
contract MockDefaultStrategy is BaseStrategy {
    function name() external pure returns (string memory) {
        return "Default";
    }

    function _initialize(bytes calldata) internal override {}
    function _execute() internal override {}
    function _settle() internal override {}
    function _updateParams(bytes calldata) internal override {}
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
    /// @dev The canonical seam adapter (IProposalStatus) — replaces the old
    ///      per-selector vm.mockCall wiring of a phantom governor address.
    MockProposalStatus governor;
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

        governor = new MockProposalStatus();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
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
        // One adapter call replaces 3 per-selector mockCalls (IProposalStatus seam).
        governor.set(locked ? PID : 0, locked ? 1 : 0, locked ? address(strat) : address(0));
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

    /// @dev Build a single-call batch that sends `amount` of vault float to `to`
    ///      (stands in for a strategy deployment pulling capital).
    function _deployBatch(address to, uint256 amount) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(usdc), data: abi.encodeCall(usdc.transfer, (to, amount)), value: 0});
    }

    // ── Task 2: buffer enforcement ──

    function test_governorBatch_respectsBuffer() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000); // 10% of 1_000e6 = 100e6 must stay

        vm.prank(address(governor));
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6), type(uint256).max);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
    }

    function test_governorBatch_revertsOnBufferBreach() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000);

        vm.prank(address(governor));
        vm.expectRevert(ISyndicateVault.BufferBreached.selector);
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6 + 1), type(uint256).max);
    }

    function test_governorBatch_bufferOff_allowsFullDeploy() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(address(governor));
        vault.executeGovernorBatch(_deployBatch(address(strat), 1_000e6), type(uint256).max);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_governorBatch_settleBatch_passesTrivially() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000);
        vm.prank(address(governor));
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6), type(uint256).max);

        strat.pushBack(900e6);
        vm.prank(address(governor));
        vault.executeGovernorBatch(new BatchExecutorLib.Call[](0), type(uint256).max);
    }

    // ── Task 3: BaseStrategy defaults ──

    function test_baseStrategy_defaults_noOnDemandExit() public {
        MockDefaultStrategy tmpl = new MockDefaultStrategy();
        MockDefaultStrategy s = MockDefaultStrategy(payable(Clones.clone(address(tmpl))));
        s.initialize(address(vault), alice, "");

        assertEq(s.availableLiquidity(), 0, "default: no on-demand liquidity");
        vm.prank(address(vault));
        vm.expectRevert(BaseStrategy.OnDemandExitUnsupported.selector);
        s.withdrawTo(1);
    }

    function test_baseStrategy_withdrawTo_onlyVault() public {
        MockDefaultStrategy tmpl = new MockDefaultStrategy();
        MockDefaultStrategy s = MockDefaultStrategy(payable(Clones.clone(address(tmpl))));
        s.initialize(address(vault), alice, "");

        vm.prank(alice);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        s.withdrawTo(1);
    }

    // ── Task 4: instant exit spanning float + strategy pull ──

    function _enterAndLock(uint256 depositAmt, uint256 deployAmt, uint256 liveVal) internal {
        vm.prank(alice);
        vault.deposit(depositAmt, alice);
        vm.prank(address(governor));
        vault.executeGovernorBatch(_deployBatch(address(strat), deployAmt), type(uint256).max);
        strat.setLiquidity(deployAmt);
        _setLocked(true);
        router.set(liveVal, true); // Lane A on
    }

    function test_maxWithdraw_includesStrategyLiquidity() public {
        _enterAndLock(1_000e6, 900e6, 900e6); // float 100e6, strategy 900e6
        // Alice owns 100% of shares → maxWithdraw = min(1_000e6, 100e6 + 900e6).
        assertApproxEqAbs(vault.maxWithdraw(alice), 1_000e6, 1, "capacity = float + strategy liquidity");
    }

    function test_withdraw_pullsShortfallFromStrategy() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(500e6, alice, alice); // float only covers 100e6
        assertEq(usdc.balanceOf(alice) - before, 500e6, "full amount paid");
        assertEq(usdc.balanceOf(address(strat)), 500e6, "400e6 pulled from strategy");
    }

    function test_withdraw_floatOnly_noStrategyCall() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        vm.prank(alice);
        vault.withdraw(50e6, alice, alice); // fits in the 100e6 float
        assertEq(usdc.balanceOf(address(strat)), 900e6, "strategy untouched");
    }

    function test_withdraw_revertsOnUnderDelivery() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        strat.setLie(true);
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.UnwindShortfall.selector);
        vault.withdraw(500e6, alice, alice);
    }

    function test_maxWithdraw_zeroStrategyCapacity_whenLaneAOff() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        router.set(0, false); // Lane A off → no instant exit at all (float-only NAV)
        assertEq(vault.maxWithdraw(alice), 0, "no pricing, no instant exit");
    }

    function test_maxWithdraw_floatOnly_whenStrategyHasNoLiquidity() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        strat.setLiquidity(0); // default-strategy behavior
        assertEq(vault.maxWithdraw(alice), 100e6, "capped at float");
    }

    // ── Task 5: interim net-flow tracking ──

    function test_interimNetFlow_tracksLaneADeposit() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        vm.prank(bob);
        vault.deposit(300e6, bob);
        assertEq(vault.interimNetFlow(), int256(300e6), "deposit tracked");
    }

    function test_interimNetFlow_tracksInstantExit() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        vm.prank(alice);
        vault.withdraw(500e6, alice, alice);
        assertEq(vault.interimNetFlow(), -int256(500e6), "exit tracked");
    }

    function test_interimNetFlow_notTrackedOutsideProposal() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(alice);
        vault.withdraw(400e6, alice, alice);
        assertEq(vault.interimNetFlow(), 0, "no proposal, no tracking");
    }

    function test_interimNetFlow_resetOnSettle() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        vm.prank(bob);
        vault.deposit(300e6, bob);
        _setLocked(false); // proposal cleared
        vm.prank(address(governor));
        vault.onProposalSettled(PID);
        assertEq(vault.interimNetFlow(), 0, "reset at settlement stamp");
    }

    /// @notice The governor-side formula: float delta minus netflow == true
    ///         strategy PnL. Break-even strategy + 300e6 mid-proposal deposit
    ///         + 200e6 instant exit → formula must yield exactly 0.
    function test_settlementPnl_excludesLaneAFlows() public {
        _enterAndLock(1_000e6, 900e6, 900e6);
        uint256 snapshot = 1_000e6; // governor's pre-execute capital snapshot

        vm.prank(bob);
        vault.deposit(300e6, bob); // principal in — not strategy performance

        vm.prank(alice);
        vault.withdraw(200e6, alice, alice); // principal out (float covers it)

        // Strategy breaks even: return everything it still holds.
        strat.pushBack(usdc.balanceOf(address(strat)));

        int256 pnl = int256(usdc.balanceOf(address(vault))) - int256(snapshot) - vault.interimNetFlow();
        assertEq(pnl, 0, "flows excluded: break-even strategy shows zero pnl");
    }
}
