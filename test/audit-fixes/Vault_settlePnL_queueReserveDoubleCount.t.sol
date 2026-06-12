// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Vault settle-PnL × queue-reserve double-count (campaign finding F1)
/// @notice Mainnet-readiness campaign 2026-06-12. Adjudicates the adversarial
///         recheck of ana-refuted item (a) "reserve-coverage double-count into
///         settle PnL".
///
///         Root cause: `_withdraw` pulls `needed = assets + reserve - float`
///         from the live adapter and `_pullFromLiveAdapter` credits the FULL
///         `needed` to `liveAdapterWithdrawn[pid]`. But only `assets` leaves the
///         vault — the `reserve - float` queue top-up stays as vault float. At
///         settle `balanceAdjusted = balanceOf(vault) + liveAdapterWithdrawn`
///         (SyndicateGovernor `_finishSettlement`) therefore counts that top-up
///         TWICE → phantom profit → over-paid performance/protocol/guardian fees
///         drawn from LP capital.
///
///         By conservation (adapter + float + paidOut = snapshot + principal)
///         the correct credit is `liveAdapterWithdrawn += assets` (the LP
///         payout), not `+= needed`. The existing
///         `test_pnlFormula_LPFlowOnly_netsToZero` only ever exercises
///         `reservedQueueAssets() == 0`, so it never caught this.
///
///         These assertions encode the CORRECT (post-fix) behaviour, so they are
///         RED on the buggy `+= needed` code and GREEN after the fix.
contract VaultSettlePnLQueueReserveTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockQueue queue;

    address owner = makeAddr("owner");
    address constant MOCK_GOVERNOR = address(0xF00D);
    uint256 constant PID = 7;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();

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

        // This test contract is `_factory` (set to msg.sender in initialize),
        // so it answers `governor()` and can bind the withdrawal queue.
        vm.mockCall(address(this), abi.encodeWithSignature("governor()"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal(address)"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount(address)"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(0)));

        queue = new MockQueue();
        vault.setWithdrawalQueue(address(queue));
    }

    function _attachAdapter(address adapter) internal {
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal(address)"), abi.encode(PID));
        ISyndicateGovernor.StrategyProposal memory p;
        p.id = PID;
        p.vault = address(vault);
        p.strategy = adapter;
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, PID), abi.encode(p));
    }

    /// @notice Pure LP-flow with a pending queue request must still net to zero
    ///         settle-PnL. Reserve top-up that stays as float must NOT be
    ///         credited to `liveAdapterWithdrawn`.
    function test_settlePnL_withQueueReserve_netsToZero() public {
        LiveAdapter adapter = new LiveAdapter(usdc, address(vault));
        adapter.setValue(1_000e6, true);

        // Attach BEFORE deposit so the deposit forwards to the adapter (float→0).
        _attachAdapter(address(adapter));

        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 0, "deposit forwarded to adapter");
        assertEq(vault.liveAdapterPrincipal(PID), 1_000e6, "principal tracked");
        adapter.setReturnable(1_000e6);

        // Alice escrows ~100e6-worth of shares into the queue → reserve > 0.
        uint256 escrowShares = vault.convertToShares(100e6);
        vm.prank(alice);
        vault.requestRedeem(escrowShares, alice);
        uint256 reserve = vault.reservedQueueAssets();
        assertGt(reserve, 0, "queue reserve is non-zero");

        // Standard live-NAV withdrawal of 400e6. float=0, so the vault pulls
        // `needed = 400e6 + reserve` from the adapter; only 400e6 leaves.
        vm.prank(alice);
        vault.withdraw(400e6, alice, alice);

        assertEq(usdc.balanceOf(alice), 400e6, "alice received exactly the withdrawal");
        // The reserve top-up stayed as vault float.
        assertEq(usdc.balanceOf(address(vault)), reserve, "reserve top-up remained as float");

        // CORE ASSERTION: credit must equal the LP payout (400e6), NOT
        // `needed` (400e6 + reserve). `+= needed` double-counts the reserve.
        assertEq(
            vault.liveAdapterWithdrawn(PID),
            400e6,
            "liveAdapterWithdrawn must credit the LP payout, not the reserve top-up"
        );

        // Simulate `_settle` full-unwind: adapter pushes its remaining balance.
        uint256 adapterRemaining = usdc.balanceOf(address(adapter));
        vm.prank(address(adapter));
        usdc.transfer(address(vault), adapterRemaining);

        // Governor `_finishSettlement` formula, replayed:
        //   pnl = (balanceOf(vault) + liveAdapterWithdrawn) − (snapshot + principal)
        // snapshot (capitalSnapshot) = 0 here (no pre-deposit), principal = 1000e6.
        int256 pnl = int256(usdc.balanceOf(address(vault)) + vault.liveAdapterWithdrawn(PID))
            - int256(uint256(0) + vault.liveAdapterPrincipal(PID));
        assertEq(pnl, int256(0), "pure LP flow + queue reserve must net to zero settle-PnL (no phantom profit)");
    }
}

/// @dev Minimal withdrawal-queue stub: records escrowed shares so
///      `vault.reservedQueueAssets()` (= convertToAssets(pendingShares())) is
///      non-zero. Only the two selectors the vault touches in this path.
contract MockQueue {
    uint256 public pendingShares;

    function queueRequest(address, uint256 shares) external returns (uint256) {
        pendingShares += shares;
        return pendingShares;
    }
}

/// @dev Live-NAV adapter mirroring test/SyndicateVault.LiveWithdraw.t.sol's
///      LiveWithdrawAdapter (onLiveWithdraw returns `min(returnable, needed)`,
///      no over-return), trimmed to what this PoC needs.
contract LiveAdapter {
    ERC20Mock public asset;
    address public boundVault;
    uint256 public mockValue;
    bool public mockValid;
    uint256 public returnable;

    constructor(ERC20Mock asset_, address vault_) {
        asset = asset_;
        boundVault = vault_;
    }

    function setValue(uint256 v, bool valid_) external {
        mockValue = v;
        mockValid = valid_;
    }

    function setReturnable(uint256 r) external {
        returnable = r;
    }

    function positionValue() external view returns (uint256, bool) {
        return (mockValue, mockValid);
    }

    function onLiveWithdraw(uint256 assetsNeeded) external returns (uint256) {
        uint256 amount = returnable < assetsNeeded ? returnable : assetsNeeded;
        if (amount > 0) {
            asset.transfer(boundVault, amount);
            returnable -= amount;
        }
        return amount;
    }

    function onLiveDeposit(uint256) external {}

    function supportsLiveWithdraw() external pure returns (bool) {
        return true;
    }
}
