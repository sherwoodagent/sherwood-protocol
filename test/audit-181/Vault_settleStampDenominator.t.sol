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

/// @title Vault_settleStampDenominator
/// @notice Audit issue #181.
///
///   FINDING #1 (CRITICAL): `onProposalSettled` stamped the withdrawal
///   queue's frozen settle price as `num = totalAssets() + 1` over
///   `den = totalSupply() + offset`. `totalAssets()` already SUBTRACTS
///   `reservedQueueAssets()` (assets owed to prior stamped-but-unclaimed
///   redeems), but raw `totalSupply()` does NOT subtract those redeems'
///   shares (`stampedUnclaimedShares()`) — the sole conversion in this
///   contract that didn't divide by `_pricingSupply()`. A stamp taken while
///   any earlier stamp sat unclaimed was deflated on the denominator side,
///   over-minting every deposit claimed against it (PoC: 5.00x over-mint) and
///   underpaying every redeem queued against the same proposal.
///
///   Fixed by `den = _pricingSupply() + offset`, matching every other
///   conversion (`_convertToShares` / `_convertToAssets` /
///   `aboveHighWaterMark`). Safe for the SETTLING proposal's own redeem
///   shares because `VaultWithdrawalQueue.stampSettlement` only adds them to
///   `stampedUnclaimedShares()` AFTER it receives `num`/`den` from this call
///   — so `_pricingSupply()` read here excludes only PRIOR stamps.
///
///   FINDING #13 (HIGH): instant deposits close on `_depositsLocked()`
///   (`openProposalCount() != 0`, set at PROPOSE), but the async fallback
///   `requestDeposit` only opened on `redemptionsLocked()`
///   (`getActiveProposal() != 0`, set at EXECUTE). For the whole
///   Pending/GuardianReview/Approved window BOTH reverted — no path to
///   deposit existed at all. Fixed by gating `requestDeposit` on
///   `openProposalCount() == 0`, the same predicate the instant path closes
///   on, and tagging the queued request with the currently open proposal's
///   id (`_openProposalPid()`) rather than `_activePid()`
///   (`getActiveProposal()`, still 0 pre-execute).
contract VaultSettleStampDenominatorTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;

    address owner = makeAddr("owner");
    address quitter = makeAddr("quitter"); // queues a full redeem in P1, never claims
    address incumbent = makeAddr("incumbent"); // stays in the vault
    address newcomer = makeAddr("newcomer"); // queues a deposit
    address constant MOCK_GOVERNOR = address(0xF00D);

    uint256 constant INCUMBENT_ASSETS = 800e6;
    uint256 constant QUITTER_ASSETS = 200e6;
    uint256 constant NEWCOMER_ASSETS = 500e6;

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
        // No open proposal at genesis.
        _setProposal(0, 0, 0);

        usdc.mint(quitter, QUITTER_ASSETS);
        usdc.mint(incumbent, INCUMBENT_ASSETS);
        usdc.mint(newcomer, NEWCOMER_ASSETS);
        vm.prank(quitter);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(incumbent);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(newcomer);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Drives the three `IProposalStatus` selectors the vault reads
    ///      through the mocked governor. `proposalCount_` backs the new
    ///      `_openProposalPid()` fallback used pre-execute (finding #13) —
    ///      harmless when a test never exercises that branch.
    function _setProposal(uint256 activePid, uint256 openCount, uint256 proposalCount_) internal {
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(activePid));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(openCount));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("proposalCount()"), abi.encode(proposalCount_));
    }

    /// @dev Mirrors the real governor's settlement commit: `_activeProposal`
    ///      resets to 0 and `openProposalCount()` decrements to 0 in the same
    ///      transaction `onProposalSettled` is called from.
    function _settle(uint256 pid) internal {
        _setProposal(0, 0, pid);
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalSettled(pid);
    }

    // ==================== FINDING #1 ====================

    /// @notice THE OVER-MINT. A deposit queued against proposal 2 and claimed
    ///         at its stamp must mint exactly what `vault.convertToShares`
    ///         reports at the instant of settlement — not more. Before the
    ///         fix, proposal 1's stamped-but-unclaimed redeem shares stayed in
    ///         a raw `totalSupply()` denominator while their assets were
    ///         already excluded from `totalAssets()`, deflating proposal 2's
    ///         stamp and over-minting the newcomer's claim.
    function test_depositClaim_mintsExactlyConvertToShares_notMoreFromStaleUnclaimedRedeem() public {
        // Two LPs in.
        vm.prank(incumbent);
        vault.deposit(INCUMBENT_ASSETS, incumbent);
        vm.prank(quitter);
        uint256 quitterShares = vault.deposit(QUITTER_ASSETS, quitter);

        // Proposal 1: the quitter queues its whole position and P1 settles —
        // the payout is now stamped and reserved, but the quitter never
        // claims. That stamped-unclaimed balance is what leaks into P2's
        // stamp pre-fix.
        _setProposal(1, 1, 1);
        vm.prank(quitter);
        vault.requestRedeem(quitterShares, quitter);
        _settle(1);
        assertEq(queue.stampedUnclaimedShares(), quitterShares, "quitter's shares are stamped-unclaimed going into P2");

        // Proposal 2 opens; the newcomer queues a deposit tagged to it.
        _setProposal(2, 1, 2);
        vm.prank(newcomer);
        uint256 requestId = vault.requestDeposit(NEWCOMER_ASSETS, newcomer);

        // P2 settles FLAT — no gain/loss injected. The newcomer's assets are
        // still in queue custody (never swept into the vault pre-claim), so
        // they do not move totalAssets()/totalSupply() at settle time.
        _settle(2);

        // The correct price AT THAT INSTANT. `_convertToShares` was never the
        // buggy function — issue #92 already made it divide by
        // `_pricingSupply()`; only `onProposalSettled`'s own stamp was the
        // outlier this fix closes.
        uint256 expectedShares = vault.convertToShares(NEWCOMER_ASSETS);
        assertGt(expectedShares, 0, "sanity: nonzero expected mint");

        uint256 minted = queue.claim(requestId);

        assertEq(
            minted,
            expectedShares,
            "deposit claim must mint exactly what convertToShares reports at settle, not strictly more"
        );
    }

    // ==================== FINDING #13 ====================

    /// @notice THE DEAD WINDOW IS CLOSED. While a proposal is Pending
    ///         (`openProposalCount() != 0`, `getActiveProposal() == 0` — not
    ///         yet executed), instant deposit is already closed
    ///         (`_depositsLocked`), and pre-fix `requestDeposit` gated on
    ///         `redemptionsLocked()` (`getActiveProposal() != 0`) was ALSO
    ///         closed — leaving no way to deposit at all. `requestDeposit`
    ///         must now succeed here, and must tag the request with the
    ///         Pending proposal's id (via `_openProposalPid()`'s
    ///         `proposalCount()` fallback, since `getActiveProposal()` is
    ///         still 0) so `stampSettlement` covers it once that proposal
    ///         executes and settles.
    function test_requestDeposit_succeedsWhileProposalPending_andTagsTheOpenPid() public {
        // Instant deposit is closed in this state — confirms the window is
        // real, not just a mock artifact.
        _setProposal(0, 1, 1);
        vm.prank(newcomer);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(NEWCOMER_ASSETS, newcomer);

        // The async path must be open instead.
        vm.prank(newcomer);
        uint256 requestId = vault.requestDeposit(NEWCOMER_ASSETS, newcomer);
        assertGt(requestId, 0, "requestDeposit must succeed while Pending, not revert");

        IVaultWithdrawalQueue.Request memory r = queue.getRequest(requestId);
        assertEq(r.amount, NEWCOMER_ASSETS, "assets escrowed in full");
        assertEq(uint256(r.kind), uint256(IVaultWithdrawalQueue.RequestKind.Deposit));
        assertEq(r.pid, 1, "tagged to the open (Pending) proposal, not pid 0");
        assertFalse(r.claimed);
        assertFalse(r.cancelled);
    }
}
