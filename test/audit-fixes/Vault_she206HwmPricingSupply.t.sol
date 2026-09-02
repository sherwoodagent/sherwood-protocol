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

/// @title Vault_she206HwmPricingSupply
/// @notice SHE-206 (audit High) — the two high-water-mark controls were keyed
///         on raw `totalSupply()` while EVERY pricing path in this vault
///         divides by `_pricingSupply()` (= `totalSupply()` less the queue's
///         stamped-but-unclaimed redeem shares). The two disagree for the
///         whole window between `stampSettlement` and the last `claim`: an
///         async full exit leaves `_pricingSupply() == 0` while
///         `totalSupply() != 0`, so
///
///           * `_update`'s drain reset (`totalSupply() == 0`) never fires, and
///           * `_initHighWaterMarkIfUnset`'s seed never re-seeds,
///
///         and the stale pre-exit mark survives into the next epoch. The next
///         deposit is then priced against a `_pricingSupply()` of zero, its
///         price per share lands at `(r + 1)x` the stale mark for residual
///         assets `r`, and `aboveHighWaterMark()` — which DOES multiply by
///         `_pricingSupply()` — books `d·r/(r+1)` of brand-new principal as
///         performance-fee base on exactly zero P&L. One wei of residue
///         charges half the deposit; a whole unit charges essentially all of
///         it.
///
///         The same full exit taken through the INSTANT lane burns the shares,
///         drives `totalSupply()` to 0, fires the reset and charges nothing.
///         The exit lane was the only variable — which is what made this an
///         ordinary-user bug, not a privileged one.
///
/// @dev    Fix: both controls read `_pricingSupply()`, and the reset also runs
///         on the PRE-state of a mint (`from == address(0)`), because the
///         moment `_pricingSupply()` empties is `stampSettlement` on the
///         queue — not an ERC20 `_update` at all — so a post-state-only check
///         can never observe it. Reset and seed must move together: the reset
///         alone would zero a mark that the `totalSupply()`-keyed seed then
///         refuses to re-seed.
///
/// @dev    Every test below was written against the unpatched base branch and
///         FAILED there first; the pre-fix figures are recorded in each.
contract VaultShe206HwmPricingSupplyTest is Test {
    SyndicateVault internal vault;
    VaultWithdrawalQueue internal queue;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    MockAgentRegistry internal agentRegistry;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal donor = makeAddr("donor");
    address internal constant MOCK_GOVERNOR = address(0xF00D);

    /// @dev Epoch-1 principal, fully exited through the async queue.
    uint256 internal constant EPOCH1 = 1_000e6;
    /// @dev Epoch-2 principal — the re-seeding deposit the bug charged on.
    uint256 internal constant EPOCH2 = 10_000e6;
    /// @dev Residual assets left behind the emptied pricing supply. `1e6` is
    ///      one whole USDC; the defect is live from `r == 1` (one wei).
    uint256 internal constant RESIDUE = 1e6;

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

        // Test contract acts as factory; queue is deployed and bound by it.
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(0)));

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(donor, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setProposalActive(bool active) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(active ? uint256(1) : uint256(0))
        );
    }

    /// @dev The governor settling proposal 1: clear the execute lock, then
    ///      stamp the realized frozen price into the queue. This is the call
    ///      that moves `_pricingSupply()` to zero — and it is not an ERC20
    ///      `_update`, which is the whole reason the drain reset could not see
    ///      the state it was written to catch.
    function _settle() internal {
        _setProposalActive(false);
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalSettled(1);
    }

    /// @dev Epoch 1: alice deposits, then takes a plain FULL async exit —
    ///      `requestRedeem` for every share she holds, settled and stamped but
    ///      not yet claimed. No privileged position, no donation, no dust
    ///      engineering: this is the ordinary queue lane.
    /// @return mark1 the epoch-1 high-water mark, seeded at alice's entry.
    function _fullAsyncExit() internal returns (uint256 mark1) {
        vm.prank(alice);
        uint256 shares = vault.deposit(EPOCH1, alice);
        mark1 = vault.highWaterPricePerShare();
        assertGt(mark1, 0, "sanity: mark seeded on the first deposit");

        _setProposalActive(true);
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        vault.requestRedeem(shares, alice);
        vm.stopPrank();

        _settle();

        assertEq(vault.totalSupply(), shares, "sanity: the shares are escrowed, NOT burned");
        assertEq(queue.stampedUnclaimedShares(), shares, "sanity: every remaining share is a stamped queue share");
    }

    // =====================================================================
    // The audit scenario
    // =====================================================================

    /// @notice THE FINDING. A plain async full exit followed by a re-seeding
    ///         deposit must not be charged a performance fee — there is no
    ///         profit anywhere in this sequence.
    ///
    ///         PRE-FIX (base branch): `aboveHighWaterMark()` reads
    ///         `d·r/(r+1)` = `10_000e6 * 1e6 / (1e6 + 1)` ≈ `9_999.99e6` —
    ///         99.99% of bob's brand-new principal, booked as fee base on zero
    ///         P&L. POST-FIX: exactly zero.
    ///
    /// @dev    MUTATION-CHECKED: reverting EITHER half of the fix on its own
    ///         re-breaks this. Restoring `totalSupply()` in the `_update`
    ///         reset leaves the stale mark standing and the pre-fix figure
    ///         returns in full. Restoring `totalSupply()` in
    ///         `_initHighWaterMarkIfUnset` is worse than the bug in the other
    ///         direction: the reset zeroes the mark and the seed then declines
    ///         to re-seed it, so the mark stays 0 and EVERY later gain reads
    ///         as chargeable from dollar one.
    function test_hwm_asyncFullExitThenReseedDepositChargesNoPerformanceFee() public {
        uint256 mark1 = _fullAsyncExit();

        // Residual assets behind the emptied pricing supply. Any of the
        // sources `_update`'s own natspec lists reaches this state — redeem
        // flooring, the queue's dust release, `_unclaimedFees` escrow, a bare
        // transfer. A transfer is simply the one with no other moving parts.
        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);
        assertEq(vault.totalAssets(), RESIDUE, "sanity: residue sits behind a zero pricing supply");

        // Epoch 2. Zero P&L: bob's money has been in the vault for zero
        // seconds and has earned nothing.
        vm.prank(bob);
        vault.deposit(EPOCH2, bob);

        assertEq(
            vault.aboveHighWaterMark(), 0, "a zero-P&L re-seeding deposit must not be charged a phantom performance fee"
        );
        assertEq(
            vault.highWaterPricePerShare(),
            vault.pricePerShare(),
            "the mark must re-seed to the CURRENT price, not survive from epoch 1"
        );
        assertNotEq(vault.highWaterPricePerShare(), mark1, "the stale epoch-1 mark must not carry over");
    }

    /// @notice THE SAME EXIT, THE OTHER LANE — the control that proves the
    ///         exit path was the only variable. An instant full redeem burns
    ///         the shares, so `totalSupply()` and `_pricingSupply()` agree at
    ///         zero and the pre-fix code charged nothing. Post-fix the async
    ///         lane must reach the same answer, and this pins that the fix did
    ///         not move the lane that was already right.
    function test_hwm_instantFullExitThenReseedDepositIsUnchanged() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(EPOCH1, alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.totalSupply(), 0, "sanity: instant lane burns");
        assertEq(vault.highWaterPricePerShare(), 0, "the drain reset still fires on a real zero supply");

        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);

        vm.prank(bob);
        vault.deposit(EPOCH2, bob);

        assertEq(vault.aboveHighWaterMark(), 0, "unchanged: the instant lane never charged this");
        assertEq(vault.highWaterPricePerShare(), vault.pricePerShare(), "seeded at bob's entry price");
    }

    /// @notice THE RESET, ISOLATED FROM ANY RESIDUE. With `r == 0` the pre-fix
    ///         arithmetic charges nothing (`d·0/1`), so this test says nothing
    ///         about the fee — it pins the STATE the fee reads: after a full
    ///         async exit the next deposit's mark must be its own entry price,
    ///         not epoch 1's.
    function test_hwm_asyncFullExitReseedsTheMarkWithNoResidue() public {
        _fullAsyncExit();

        vm.prank(bob);
        vault.deposit(EPOCH2, bob);

        assertEq(vault.highWaterPricePerShare(), vault.pricePerShare(), "re-seeded at bob's own entry price");
        assertEq(vault.aboveHighWaterMark(), 0, "and nothing above it");
    }

    /// @notice THE MARK STILL RATCHETS AND STILL PROTECTS. Keying on
    ///         `_pricingSupply()` must not make the mark forgiving: real
    ///         profit earned by a live pricing supply is still chargeable, and
    ///         a recovery after a loss is still free.
    function test_hwm_realProfitAboveAReseededMarkIsStillChargeable() public {
        _fullAsyncExit();

        vm.prank(bob);
        vault.deposit(EPOCH2, bob);
        assertEq(vault.aboveHighWaterMark(), 0, "flat at entry");

        // A genuine 10% gain on bob's live position.
        vm.prank(donor);
        usdc.transfer(address(vault), EPOCH2 / 10);

        assertApproxEqRel(
            vault.aboveHighWaterMark(), EPOCH2 / 10, 1e12, "the whole real gain sits above the re-seeded mark"
        );
    }

    /// @notice THE RESET FIRES ON THE CLAIM PATH TOO. Draining the escrow by
    ///         claiming burns the stamped shares and decrements the queue's
    ///         counter in the same call, so `_pricingSupply()` and
    ///         `totalSupply()` fall together and the post-state reset in
    ///         `_update` still catches a genuine full drain. Pins the ORDERING
    ///         the `_pricingSupply()` read inside `_update` depends on
    ///         (`VaultWithdrawalQueue.claim` decrements
    ///         `_stampedUnclaimedShares` BEFORE calling `settleRedeem`) — swap
    ///         those two and this read would under-count by the burn.
    function test_hwm_resetStillFiresWhenTheEscrowIsClaimedOut() public {
        _fullAsyncExit();

        vm.prank(alice);
        queue.claim(1);

        assertEq(vault.totalSupply(), 0, "sanity: the escrow is burned out");
        assertEq(vault.highWaterPricePerShare(), 0, "the drain reset fires on the claim burn");
    }
}
