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
/// @dev    PARTIAL. This closes the `_pricingSupply() == 0` case and NOT the
///         general one. Holding back a single share-wei keeps the pricing
///         supply at 1, every guard below asks `== 0`, and the original
///         finding returns at full magnitude — byte-identically to the base
///         commit. That residual is asserted, with figures, in
///         `Vault_she206ResidualDustBypass.t.sol`, and SHE-206 stays open.
///         Read the two files together; this one on its own overstates what
///         was fixed.
///
/// @dev    WHAT FAILS ON THE UNPATCHED BASE BRANCH, precisely — the earlier
///         blanket claim that "every test below" did was wrong, and the
///         distinction matters because the controls are the half that must
///         pass in both worlds:
///
///           FAILS on base (the fix is what makes them pass):
///             * `test_hwm_asyncFullExitThenReseedDepositChargesNoPerformanceFee`
///             * `test_hwm_aZeroValueDepositIntoAnAllStampedFundBanksNoMark`
///             * `test_hwm_resetFiresOnAPartialClaimWhileTheRawSupplyIsStillNonZero`
///             * `test_hwm_ratchetBanksNothingAgainstAnEmptyPricingSupply`
///
///           PASSES on base, BY DESIGN — these are controls. They pin the
///           behaviour the fix must not disturb (the instant lane, a
///           ratcheting mark, the claim-path drain), so a base-branch pass is
///           the point, not a gap:
///             * `test_hwm_instantFullExitThenReseedDepositIsUnchanged`
///             * `test_hwm_asyncFullExitReseedsTheMarkWithNoResidue`
///             * `test_hwm_realProfitAboveAReseededMarkIsStillChargeable`
///             * `test_hwm_resetStillFiresWhenTheEscrowIsClaimedOut`
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
    /// @dev    MUTATION-CHECKED, and NARROWLY. This test kills exactly ONE of
    ///         the fix's four guards: the PRE-STATE mint reset in `_update`.
    ///         Key that one on `totalSupply()` instead and the stale mark
    ///         stands, `aboveHighWaterMark()` returns `9_999_990_000`, and
    ///         this assertion fails.
    ///
    ///         An earlier version of this note claimed it also killed the
    ///         `_initHighWaterMarkIfUnset` gate. IT DOES NOT, and neither does
    ///         anything else in the end-to-end set. All three of the remaining
    ///         guards survive this test — verified by reverting each in turn:
    ///
    ///           * `_initHighWaterMarkIfUnset`'s `_pricingSupply() != 0` gate
    ///             can never be the deciding read HERE, because it runs
    ///             immediately after a mint that has already made both
    ///             candidate supplies nonzero. It is only distinguishable on a
    ///             mint that adds no shares — see
    ///             `test_hwm_aZeroValueDepositIntoAnAllStampedFundBanksNoMark`.
    ///           * The POST-STATE reset's key is invisible here too: this
    ///             sequence never runs an `_update` in the split state (raw
    ///             supply nonzero, pricing supply empty). Pinned by
    ///             `test_hwm_resetFiresOnAPartialClaimWhileTheRawSupplyIsStillNonZero`.
    ///           * `ratchetHighWaterMark`'s early return is never reached —
    ///             nothing in this scenario calls it. Pinned by
    ///             `test_hwm_ratchetBanksNothingAgainstAnEmptyPricingSupply`.
    ///
    ///         With those three tests added, each of the four guards has a
    ///         test that fails when and only when that guard is reverted.
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

    // =====================================================================
    // Pinning the individual guards
    //
    // The four tests above are all end-to-end: they drive the fee figure and
    // the mark through a whole epoch. That is the right shape for the finding
    // and the wrong shape for the FIX, which is four separate guards. An
    // end-to-end assertion is satisfied by whichever guard happens to fire
    // first, so three of the four could be reverted without any of it going
    // red -- see the corrected note on
    // `test_hwm_asyncFullExitThenReseedDepositChargesNoPerformanceFee`.
    //
    // Each test below is built so that ONE guard is the deciding read and the
    // others cannot mask it.
    // =====================================================================

    /// @notice THE SEED GATE, MADE THE DECIDING READ. A zero-value deposit into
    ///         an all-stamped fund must not bank a mark.
    ///
    /// @dev The seed gate (`_initHighWaterMarkIfUnset`) is the hardest of the
    ///      four to pin, and the reason is structural: it runs immediately
    ///      AFTER a mint, so by the time it reads the supply the mint has
    ///      already made both `totalSupply()` and `_pricingSupply()` nonzero
    ///      and the two candidate reads agree. Every ordinary deposit is like
    ///      that, which is why every end-to-end test in this file leaves the
    ///      gate's mutation alive.
    ///
    ///      A ZERO-VALUE deposit is the one mint that separates them.
    ///      `_deposit` refuses `shares == 0 && assets != 0` but permits
    ///      `deposit(0)`, so this mints nothing: the pre-state reset fires and
    ///      zeroes the mark, and then `_pricingSupply()` is STILL 0 while
    ///      `totalSupply()` is the whole stamped escrow. Keyed on the pricing
    ///      supply the gate correctly declines to seed. Keyed on
    ///      `totalSupply()` it seeds at `pricePerShare()` -- which here is
    ///      residual assets divided by the virtual offset alone, a number
    ///      describing no holder's position, a million times the real mark --
    ///      and banks it as the peak. The next real depositor would then be
    ///      measured against a mark no fund can ever clear.
    ///
    ///      Permissionless and free: `deposit(0)` costs the caller nothing but
    ///      gas, so this is not a theoretical mint.
    function test_hwm_aZeroValueDepositIntoAnAllStampedFundBanksNoMark() public {
        _fullAsyncExit();

        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);

        // What the mutated gate would bank: assets over the virtual offset.
        uint256 garbagePrice = vault.pricePerShare();
        assertGt(garbagePrice, 0, "sanity: there IS a nonzero price here to mis-bank");

        vm.prank(bob);
        uint256 minted = vault.deposit(0, bob);
        assertEq(minted, 0, "sanity: a zero-value deposit mints nothing");
        assertEq(vault.totalSupply(), queue.stampedUnclaimedShares(), "sanity: still every share stamped");

        assertEq(
            vault.highWaterPricePerShare(),
            0,
            "the seed gate must read the PRICING supply: there is no live position to price"
        );
    }

    /// @notice THE POST-STATE RESET, MADE THE DECIDING READ. A PARTIAL claim
    ///         out of an all-stamped escrow: the pricing supply is empty, the
    ///         raw supply is not.
    ///
    /// @dev `test_hwm_resetStillFiresWhenTheEscrowIsClaimedOut` above claims the
    ///      escrow out completely, so `totalSupply()` and `_pricingSupply()`
    ///      hit zero in the same call and it cannot tell the two keys apart --
    ///      it passes either way. This one splits alice's exit across TWO
    ///      requests and claims only the first, so after the burn the second
    ///      batch is still escrowed: `totalSupply() != 0`, `_pricingSupply()
    ///      == 0`. Exactly one of the two candidate reads fires the reset.
    ///
    ///      Also still pins the ordering the post-state read depends on
    ///      (`VaultWithdrawalQueue.claim` decrements `_stampedUnclaimedShares`
    ///      BEFORE calling `settleRedeem`) -- swap those and the read
    ///      under-counts by the burn and the reset misses here too.
    function test_hwm_resetFiresOnAPartialClaimWhileTheRawSupplyIsStillNonZero() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(EPOCH1, alice);
        assertGt(vault.highWaterPricePerShare(), 0, "sanity: mark seeded at alice's entry");

        _setProposalActive(true);
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        // Two requests, one exit. Nothing here is unusual -- a holder leaving
        // in two tranches is an ordinary use of the queue.
        vault.requestRedeem(shares / 2, alice);
        vault.requestRedeem(shares - shares / 2, alice);
        vm.stopPrank();

        _settle();
        assertEq(queue.stampedUnclaimedShares(), shares, "sanity: both tranches stamped");

        vm.prank(alice);
        queue.claim(1);

        assertGt(vault.totalSupply(), 0, "the RAW supply is still nonzero: tranche two is still escrowed");
        assertEq(vault.totalSupply(), queue.stampedUnclaimedShares(), "...and every share of it is a stamped share");
        assertEq(
            vault.highWaterPricePerShare(),
            0,
            "the post-state reset must key on the PRICING supply, which IS empty here"
        );
    }

    /// @notice THE RATCHET EARLY-RETURN, MADE THE DECIDING READ. Settling with
    ///         no live equity must leave the previous peak alone, not bank the
    ///         meaningless price.
    ///
    /// @dev Nothing else in this file calls `ratchetHighWaterMark` at all, so
    ///      its guard was pure unexercised code. The scenario is the governor
    ///      settling a proposal in exactly the state the async exit produces:
    ///      every share stamped, some residue in the contract. `pricePerShare()`
    ///      there divides that residue by the virtual offset alone and comes
    ///      back astronomically above the real mark, so a ratchet that ran
    ///      would bank it as the new peak -- permanently, since the mark is
    ///      monotonic and the reset path only ever LOWERS it to zero on a
    ///      genuine drain. Every subsequent epoch would then be fee-free
    ///      forever, which is the mirror-image loss to the finding this branch
    ///      is about: the depositors get overcharged, the manager gets
    ///      zeroed.
    ///
    ///      Asserts against `mark1` rather than merely "unchanged", so the test
    ///      still fails if the guard is replaced by something that zeroes the
    ///      mark instead of leaving it standing.
    function test_hwm_ratchetBanksNothingAgainstAnEmptyPricingSupply() public {
        uint256 mark1 = _fullAsyncExit();

        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);

        uint256 garbagePrice = vault.pricePerShare();
        assertGt(garbagePrice, mark1, "sanity: an unguarded ratchet WOULD move the mark, and upward");

        vm.prank(MOCK_GOVERNOR);
        vault.ratchetHighWaterMark();

        assertEq(vault.highWaterPricePerShare(), mark1, "the previous peak stands; the meaningless price is not banked");
    }
}
