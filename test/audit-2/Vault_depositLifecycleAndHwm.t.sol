// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @title Vault_depositLifecycleAndHwm
/// @notice Second-pass audit (audit-181-2), two findings owned by this agent.
///
///   FINDING A (CRITICAL, introduced by the FIRST remediation): the prior fix
///   opened `requestDeposit` on `openProposalCount() != 0` (Draft+Pending, not
///   just Executed). But a proposal in Draft/Pending can terminate WITHOUT
///   ever settling — cancelled, vetoed, rejected, expired all call
///   `_decOpen()` directly and never `onProposalSettled` — so a deposit
///   tagged to one of those pids had `_settlePrice[pid].stamped` permanently
///   false. `claim()` gated on THAT pid's stamp, so the claim reverted
///   `NotSettled` forever, with no symmetric recovery for a pay-on-behalf
///   depositor (`cancel` is receiver-gated; `requestDeposit` pulled from
///   `msg.sender`). Fixed by gating the deposit branch on
///   `_settlePrice[_lastStampedPid].stamped` — the price it actually uses —
///   so the claim unlocks at the next REAL settlement, whichever proposal
///   that turns out to be.
///
///   FINDING B (pre-existing): `_highWaterPricePerShare` was seeded once and
///   never reset when `totalSupply()` returns to zero, while the share/asset
///   conversion SCALE is independently re-derived from `(residualAssets + 1)`
///   on the next deposit. A re-seeding deposit's price-per-share can land at
///   up to `(donation+1)x` the STALE mark, so `aboveHighWaterMark` reads
///   nearly the entire new (zero-P&L) principal as performance-fee base.
///   Fixed by zeroing the mark on every 0-supply transition (`_update`) and
///   by having `settleDeposit` (the queue's mint entrypoint, which bypasses
///   `_deposit` entirely) also call `_initHighWaterMarkIfUnset()`.
contract VaultDepositLifecycleAndHwmTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;

    address owner = makeAddr("owner");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address payer = makeAddr("payer"); // pays on behalf of `receiver`
    address receiver = makeAddr("receiver");
    address constant MOCK_GOVERNOR = address(0xF00D);

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

        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        _setProposal(0, 0, 0);

        usdc.mint(lp1, 10_000e6);
        usdc.mint(lp2, 10_000e6);
        usdc.mint(payer, 10_000e6);
        vm.prank(lp1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(lp2);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(payer);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Drives the three `IProposalStatus` selectors read through the
    ///      mocked governor, matching `Vault_settleStampDenominator.t.sol`'s
    ///      helper exactly.
    function _setProposal(uint256 activePid, uint256 openCount, uint256 proposalCount_) internal {
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(activePid));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(openCount));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("proposalCount()"), abi.encode(proposalCount_));
    }

    function _settle(uint256 pid) internal {
        _setProposal(0, 0, pid);
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalSettled(pid);
    }

    // =====================================================================
    // FINDING A — deposit tagged to a proposal that dies without settling
    // =====================================================================

    /// @notice THE FAILURE MODE: a deposit queued against a Pending proposal
    ///         that is then rejected/cancelled/expired (terminal via
    ///         `_decOpen()` alone, never `onProposalSettled`) must NOT be
    ///         permanently stuck. Before this fix, `claim()` gated on
    ///         `_settlePrice[r.pid].stamped` — a pid that can never stamp —
    ///         so the claim reverted `NotSettled` forever, even after a LATER,
    ///         unrelated proposal genuinely settled. This is also a
    ///         pay-on-behalf deposit: `payer` funds it, `receiver` gets the
    ///         claim, and `cancel` (receiver-gated) is deliberately left
    ///         unexercised so the ONLY tested recovery is the claim path
    ///         itself unlocking at the next real settlement.
    function test_depositClaim_recoversAfterTaggedProposalDiesWithoutSettling_viaNextRealSettlement() public {
        // LP1 seeds the pool outside any proposal (Lane A).
        vm.prank(lp1);
        vault.deposit(1_000e6, lp1);

        // Proposal 1 opens (Pending: openCount=1, activePid still 0 pre-execute).
        _setProposal(0, 1, 1);
        vm.prank(payer);
        uint256 requestId = vault.requestDeposit(500e6, receiver);
        IVaultWithdrawalQueue.Request memory r = queue.getRequest(requestId);
        assertEq(r.pid, 1, "tagged to the open (Pending) proposal");

        // Proposal 1 dies WITHOUT ever settling — mirrors the governor's
        // Rejected/Expired/vetoed/cancelled paths, which call `_decOpen()`
        // directly and never `onProposalSettled`. Simulated here by simply
        // never calling `onProposalSettled(1)` and releasing the open-proposal
        // gate, exactly as `_decOpen()` does.
        _setProposal(0, 0, 1);

        // Boundary check: with NO settlement having EVER occurred, the claim
        // must still revert (nothing to price against yet) — this is the
        // honest "not claimable yet" case, not the bug.
        vm.expectRevert(IVaultWithdrawalQueue.NotSettled.selector);
        queue.claim(requestId);

        // A LATER, UNRELATED proposal (pid 2) opens, executes, and genuinely
        // settles. `requestId`'s own pid (1) is still, and will forever be,
        // unstamped.
        _setProposal(2, 1, 2);
        _settle(2);
        assertFalse(queue.getSettlePrice(1).stamped, "pid 1 never settles - confirms the dead-proposal premise");
        assertTrue(queue.getSettlePrice(2).stamped, "pid 2 is the real, later settlement");

        // THE FIX: the claim must now succeed, priced at pid 2's stamp (the
        // latest real settlement), not revert forever against dead pid 1.
        uint256 expectedShares = vault.convertToShares(500e6);
        uint256 minted = queue.claim(requestId);
        assertEq(minted, expectedShares, "claims at the next real settlement's price");

        r = queue.getRequest(requestId);
        assertTrue(r.claimed, "request is now claimed");
        assertEq(vault.balanceOf(receiver), minted, "receiver got the shares, not the payer");
        assertEq(vault.balanceOf(payer), 0, "payer funded the deposit but holds no shares (pay-on-behalf)");
    }

    /// @notice SIBLING CHECK: the REDEEM branch has no equivalent hole.
    ///         `requestRedeem` only opens while `redemptionsLocked()` is true
    ///         (`getActiveProposal() != 0`), i.e. the tagged proposal is
    ///         already Executed — and every Executed proposal reaches Settled
    ///         through exactly one of `settleProposal` / `unstick` /
    ///         `finalizeEmergencySettle`, all of which call
    ///         `onProposalSettled` before `_decOpen()`. So a redeem's own pid
    ///         is always eventually stamped; gating on `r.pid` (unchanged by
    ///         this fix) is therefore safe and MUST stay pid-scoped, not
    ///         `_lastStampedPid`-scoped (a redeem's payout is fixed at ITS
    ///         OWN settlement, not diluted forward to a later one).
    function test_redeemClaim_staysGatedOnOwnPid_noEquivalentHole() public {
        vm.prank(lp1);
        uint256 lp1Shares = vault.deposit(1_000e6, lp1);

        // Proposal 1 executes (the ONLY state `requestRedeem` opens in).
        _setProposal(1, 1, 1);
        vm.prank(lp1);
        uint256 requestId = vault.requestRedeem(lp1Shares, lp1);
        IVaultWithdrawalQueue.Request memory r = queue.getRequest(requestId);
        assertEq(r.pid, 1);

        // Cannot claim before settlement.
        vm.expectRevert(IVaultWithdrawalQueue.NotSettled.selector);
        queue.claim(requestId);

        // Its own proposal settles.
        _settle(1);
        assertTrue(queue.getSettlePrice(1).stamped);

        uint256 balanceBefore = usdc.balanceOf(lp1);
        uint256 outAmount = queue.claim(requestId);
        assertEq(usdc.balanceOf(lp1), balanceBefore + outAmount, "redeemer paid at its own proposal's stamp");
    }

    // =====================================================================
    // FINDING B — high-water mark re-seeds on 0 -> nonzero supply
    // =====================================================================

    /// @notice THE FAILURE MODE (Lane A path): a fund that fully drains to
    ///         `totalSupply() == 0` and is later re-seeded by a fresh deposit
    ///         must NOT inherit the stale pre-drain mark. Reproduces the
    ///         audit's worked example: epoch 1 establishes a mark, epoch 1
    ///         fully redeems, a bare donation leaves residual dust assets
    ///         behind zero supply, and epoch 2 deposits fresh, zero-P&L
    ///         principal. Before the fix, `aboveHighWaterMark()` would read
    ///         almost the entire epoch-2 principal as fee base; after the
    ///         fix it must read exactly zero.
    function test_highWaterMark_resetsOnFullDrain_andReseedsCleanOnNextDeposit() public {
        // Epoch 1: LP1 deposits, mark seeds to epoch 1's price per share.
        vm.prank(lp1);
        uint256 lp1Shares = vault.deposit(1_000e6, lp1);
        uint256 mark1 = vault.highWaterPricePerShare();
        assertGt(mark1, 0, "sanity: mark seeded on first deposit");

        // LP1 fully exits via Lane A (no proposal active, instant redeem).
        vm.prank(lp1);
        vault.redeem(lp1Shares, lp1, lp1);
        assertEq(vault.totalSupply(), 0, "sanity: supply fully drained");

        // THE RESET FIRES exactly at the 0-supply transition, independent of
        // any later deposit — pinning the `_update` half of the fix in
        // isolation from the reseed-on-mint half.
        assertEq(vault.highWaterPricePerShare(), 0, "mark must reset to 0 on full drain, not stay stale");

        // A bare donation leaves residual assets behind zero supply — the
        // audit's dust vector (redeem flooring / queue dust release /
        // unclaimed-fee escrow / plain transfer all reach the same state).
        vm.prank(payer);
        usdc.transfer(address(vault), 1e6);
        assertGt(vault.totalAssets(), 0, "sanity: residual assets sit behind zero supply");

        // Epoch 2: LP2 deposits fresh, zero-P&L principal. This re-seeding
        // deposit is the exact instant the bug charged up to the ENTIRE
        // principal as a phantom performance fee.
        vm.prank(lp2);
        vault.deposit(1_000e6, lp2);

        assertEq(
            vault.highWaterPricePerShare(),
            vault.pricePerShare(),
            "mark must reseed to the CURRENT price, not the stale epoch-1 mark"
        );
        assertEq(
            vault.aboveHighWaterMark(), 0, "a zero-P&L re-seeding deposit must not be charged a phantom performance fee"
        );
    }

    /// @notice THE FAILURE MODE (queue path): `settleDeposit` — the ONLY mint
    ///         entrypoint for a queue-originated claim — bypasses `_deposit`
    ///         entirely and, pre-fix, never called the seeder at all. A vault
    ///         whose very first mint happens through the async queue (no Lane
    ///         A deposit ever occurred) must still get its mark seeded, or
    ///         its high-water mark stays 0 forever and every future gain
    ///         reads as "above the mark" from dollar one — the opposite
    ///         failure (double charging), not the same one, but proof the
    ///         seeder must run on this path too.
    function test_highWaterMark_seedsOnQueueOnlyFirstMint_viaSettleDeposit() public {
        assertEq(vault.highWaterPricePerShare(), 0, "sanity: never seeded, no Lane A deposit ever happened");

        // Proposal 1 opens (Pending) so the async deposit path is open.
        _setProposal(0, 1, 1);
        vm.prank(payer);
        uint256 requestId = vault.requestDeposit(1_000e6, receiver);

        // It executes and settles — the queue-only mint happens inside
        // `claim()`, which calls `vault.settleDeposit`.
        _setProposal(1, 1, 1);
        _settle(1);

        assertEq(vault.totalSupply(), 0, "sanity: no shares exist yet - the claim below is the first mint ever");
        queue.claim(requestId);

        assertGt(vault.highWaterPricePerShare(), 0, "settleDeposit's mint must seed the mark, not leave it at 0");
        assertEq(
            vault.highWaterPricePerShare(),
            vault.pricePerShare(),
            "seeded mark must equal the price at the instant of this first-ever mint"
        );
        assertEq(vault.aboveHighWaterMark(), 0, "freshly seeded mark starts exactly at the current price");
    }
}
