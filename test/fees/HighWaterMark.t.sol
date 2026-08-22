// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice Covers `specs/performance-fee/spec.md`: the mark bounds the fee, it
///         ratchets upward only, and a fund that falls and recovers is not
///         charged twice on the same dollars.
///
/// @dev Profit and loss are simulated by moving the asset balance directly
///      (mint into / transfer out of the vault) rather than by running a real
///      strategy. That is exactly what a settlement observes — the vault's
///      float — so the mark sees the same prices it would in production.
contract HighWaterMarkTest is Test {
    SyndicateVault internal vault;
    VaultWithdrawalQueue internal queue;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    MockAgentRegistry internal agentRegistry;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal sink = makeAddr("sink");
    address internal constant MOCK_GOVERNOR = address(0xF00D);

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();

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

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));

        usdc.mint(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Move the fund's value without touching share count — a pure gain.
    function _gain(uint256 amount) internal {
        usdc.mint(address(vault), amount);
    }

    /// @dev A pure loss: value leaves, shares stay.
    function _loss(uint256 amount) internal {
        vm.prank(address(vault));
        usdc.transfer(sink, amount);
    }

    function _ratchet() internal {
        vm.prank(MOCK_GOVERNOR);
        vault.ratchetHighWaterMark();
    }

    // ── Seeding ──

    function test_theMarkIsUnsetBeforeAnyDeposit() public view {
        assertEq(vault.highWaterPricePerShare(), 0, "no shares, no price");
    }

    function test_theMarkIsSeededAtTheFirstDeposit() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        assertGt(vault.highWaterPricePerShare(), 0, "the first deposit must establish the mark");
        assertEq(vault.highWaterPricePerShare(), vault.pricePerShare(), "seeded at the entry price");
    }

    function test_aSecondDepositDoesNotReseedTheMark() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        uint256 seeded = vault.highWaterPricePerShare();

        _gain(200_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        assertEq(vault.highWaterPricePerShare(), seeded, "only the FIRST deposit seeds");
    }

    // ── The base ──

    function test_gainsAboveTheMarkAreChargeable() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _gain(200_000e6);

        assertApproxEqRel(vault.aboveHighWaterMark(), 200_000e6, 1e12, "the whole 20% gain sits above the mark");
    }

    function test_atTheMarkThereIsNothingToCharge() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        assertEq(vault.aboveHighWaterMark(), 0, "a flat fund owes no performance fee");
    }

    function test_belowTheMarkThereIsNothingToCharge() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _loss(50_000e6);

        assertEq(vault.aboveHighWaterMark(), 0, "a losing fund owes no performance fee");
    }

    // ── The property the mark exists for ──

    /// @notice 100 -> 120 (charged) -> 95 -> 120: the recovery is free, because
    ///         that ground was already paid for.
    function test_aRecoveryToAPreviousPeakIsNotChargedAgain() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        // 1.0M -> 1.2M, charged and ratcheted.
        _gain(200_000e6);
        assertApproxEqRel(vault.aboveHighWaterMark(), 200_000e6, 1e12);
        _ratchet();

        // 1.2M -> 0.95M.
        _loss(250_000e6);
        assertEq(vault.aboveHighWaterMark(), 0, "under water, nothing to charge");

        // 0.95M -> 1.2M: back to the peak, not past it.
        _gain(250_000e6);
        assertEq(vault.aboveHighWaterMark(), 0, "the recovery must be free");
    }

    /// @notice Only the portion above the peak is charged, not the whole gain
    ///         since the last settlement.
    function test_onlyThePortionAboveThePeakIsCharged() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _gain(200_000e6); // peak at 1.2M
        _ratchet();
        _loss(250_000e6); // down to 0.95M
        _gain(300_000e6); // up to 1.25M — only 50k is new ground

        assertApproxEqRel(vault.aboveHighWaterMark(), 50_000e6, 1e12, "only the 1.2M->1.25M portion is chargeable");
    }

    // ── The ratchet ──

    function test_theMarkAdvancesAfterAChargedFee() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        uint256 before = vault.highWaterPricePerShare();

        _gain(200_000e6);
        _ratchet();

        assertGt(vault.highWaterPricePerShare(), before, "the mark must advance");
        assertEq(vault.highWaterPricePerShare(), vault.pricePerShare(), "to the current price");
    }

    function test_aLossDoesNotLowerTheMark() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _gain(200_000e6);
        _ratchet();
        uint256 peak = vault.highWaterPricePerShare();

        _loss(400_000e6);
        _ratchet(); // ratcheting under water must be a no-op

        assertEq(vault.highWaterPricePerShare(), peak, "the mark ratchets upward only");
    }

    function test_theMarkIsMonotonicAcrossManyCycles() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        uint256 previous = vault.highWaterPricePerShare();
        for (uint256 i = 0; i < 5; ++i) {
            _gain(100_000e6);
            _ratchet();
            uint256 current = vault.highWaterPricePerShare();
            assertGe(current, previous, "never decreases");
            previous = current;

            _loss(60_000e6);
            _ratchet(); // a down leg must leave it alone
            assertEq(vault.highWaterPricePerShare(), previous, "a down leg leaves it alone");
        }
    }

    // ── Access control ──

    function test_onlyGovernorMayRatchet() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _gain(200_000e6);

        vm.prank(alice);
        vm.expectRevert();
        vault.ratchetHighWaterMark();
    }

    // ── Interaction with the management fee ──

    /// @notice The management fee lowers assets and therefore the price per
    ///         share, so a gain that only just clears the mark can be wiped out
    ///         by it. This is why management must be charged FIRST — reading
    ///         the base before it would charge performance on assets the
    ///         management fee already took.
    function test_aChargeAgainstAssetsCanMoveTheFundBackBelowTheMark() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _gain(1_000e6); // barely above the mark
        assertGt(vault.aboveHighWaterMark(), 0, "above the mark before the management fee");

        _loss(1_000e6); // the management fee taking its cut
        assertEq(vault.aboveHighWaterMark(), 0, "and back below it afterwards");
    }

    // ── Share-count independence ──

    /// @notice The mark is a PRICE, so it must survive share-count changes. A
    ///         new depositor buying in at the current price must not dilute the
    ///         mark and hand existing holders a free performance-fee window.
    function test_aNewDepositorDoesNotMoveTheMark() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _gain(200_000e6);
        _ratchet();
        uint256 peak = vault.highWaterPricePerShare();

        address bob = makeAddr("bob");
        usdc.mint(bob, 5_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(5_000_000e6, bob);
        vm.stopPrank();

        assertEq(vault.highWaterPricePerShare(), peak, "entry at the current price must not move the mark");
        assertEq(vault.aboveHighWaterMark(), 0, "and must not create chargeable ground");
    }
}
