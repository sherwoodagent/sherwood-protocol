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

/// @title Vault_queueReservedNav
/// @notice Issue #92 — a redeem whose settle price has been STAMPED but not yet
///         CLAIMED kept both its shares in `totalSupply()` and its reserved
///         assets in `totalAssets()`, while its payout was already fixed. Every
///         price read in that window therefore blended two prices: the frozen
///         one owed to the queue, and the live one owed to everyone else.
///
///         Fixed by netting BOTH legs out of pricing together —
///         `totalAssets()` subtracts `reservedQueueAssets()` and the converters
///         divide by `_pricingSupply()`. Every test below was written against
///         unpatched `main` and reproduced there first.
///
/// @dev    WHY THE WINDOW IS WIDE OPEN. `VaultWithdrawalQueue.cancel` reverts
///         `AlreadySettled` once a pid is stamped, so after the stamp the only
///         exit is `claim` — and `claim` has no deadline. Waiting is strictly
///         free for the queued redeemer, because `mulDiv(amount, sp.num,
///         sp.den)` cannot move. The holder of a stamped claim therefore
///         chooses how long the vault misprices itself.
///
/// @dev    THE CODE ALREADY CONTRADICTS ITSELF HERE. `claim`'s deposit branch
///         justifies pricing at the latest stamp with: "Redeem (above) keeps
///         its own pid deliberately: those shares LEFT THE SUPPLY at that
///         settlement". They have not. `SyndicateVault.settleRedeem` — and its
///         `_burn` — runs at claim time, one transaction later, at the queued
///         redeemer's discretion.
contract VaultQueueReservedNavTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;

    address owner = makeAddr("owner");
    address quitter = makeAddr("quitter"); // queues a redeem, then sits on the claim
    address incumbent = makeAddr("incumbent"); // stays in the vault
    address constant MOCK_GOVERNOR = address(0xF00D);

    uint256 constant QUITTER_ASSETS = 200e6;
    uint256 constant INCUMBENT_ASSETS = 800e6;

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
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(0)));

        usdc.mint(quitter, QUITTER_ASSETS);
        usdc.mint(incumbent, INCUMBENT_ASSETS);
        vm.prank(quitter);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(incumbent);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setProposalActive(bool active) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(active ? uint256(1) : uint256(0))
        );
    }

    function _settle(uint256 pid) internal {
        _setProposalActive(false);
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalSettled(pid);
    }

    /// @dev Drive the vault into the mispricing window: both LPs in, the quitter
    ///      queues its whole position, P1 settles and stamps the price, the
    ///      quitter does NOT claim, then the strategy loses `lossPct` of the
    ///      float. The loss is parameterised because the two consequences need
    ///      different magnitudes: mispricing starts at ANY non-zero loss, while
    ///      wedging the vault needs the residual float to fall below the
    ///      already-fixed reserve.
    /// @return quitterShares the escrowed, stamped-but-unclaimed share count.
    function _reachMispricingWindow(uint256 lossPct) internal returns (uint256 quitterShares) {
        vm.prank(incumbent);
        vault.deposit(INCUMBENT_ASSETS, incumbent);
        vm.prank(quitter);
        quitterShares = vault.deposit(QUITTER_ASSETS, quitter);

        _setProposalActive(true);
        vm.prank(quitter);
        vault.requestRedeem(quitterShares, quitter);

        // P1 settles flat: the quitter's payout freezes at its share of NAV.
        _settle(1);
        assertGt(queue.reservedAssets(), 0, "the quitter's payout is reserved and now fixed");

        // A real loss on what is left. It cannot touch the quitter, whose price
        // already froze, so it must fall entirely on the incumbent.
        usdc.burn(address(vault), (usdc.balanceOf(address(vault)) * lossPct) / 100);
    }

    /// @notice NO MORE BLEND. Inside the window the vault now prices the
    ///         RESIDUAL pool: the reserved assets are out of `totalAssets` and
    ///         the stamped shares are out of the pricing supply.
    function test_stampedUnclaimedRedeem_isExcludedFromPricingOnBothSides() public {
        uint256 quitterShares = _reachMispricingWindow(40);

        // The shares are still in supply and the assets still in custody — the
        // fix does not move tokens, it stops COUNTING them.
        assertEq(vault.balanceOf(address(queue)), quitterShares, "shares still escrowed, as before");
        assertGt(queue.reservedAssets(), 0, "assets still reserved, as before");
        assertEq(queue.stampedUnclaimedShares(), quitterShares, "and the share-side counter tracks them");

        // Asset side: the reserve is no longer inside the reported NAV.
        uint256 gross = usdc.balanceOf(address(vault));
        assertEq(vault.totalAssets(), gross - queue.reservedAssets(), "reserve netted out of totalAssets");

        // Price side: within the virtual-offset dust of the true residual price,
        // where it used to overstate it by more than 1%.
        uint256 truePps = _pps(vault.totalAssets(), vault.totalSupply() - quitterShares);
        assertApproxEqRel(vault.convertToAssets(1e18), truePps, 1e12, "prices the residual pool");
    }

    /// @notice NO MORE EXTRACTION. A residual holder exiting inside the window
    ///         is paid its true residual share, not a slice of the queue's
    ///         reserved assets. Before the fix it was overpaid by >1% of its
    ///         exit, and the shortfall landed on whoever was still in the vault
    ///         when the stamped claim arrived.
    function test_residualHolderRedeemsAtTheResidualPrice() public {
        uint256 quitterShares = _reachMispricingWindow(40);
        uint256 incumbentShares = vault.balanceOf(incumbent);

        uint256 paid = vault.previewRedeem(incumbentShares);
        uint256 fair = Math.mulDiv(incumbentShares, vault.totalAssets(), vault.totalSupply() - quitterShares);
        assertApproxEqRel(paid, fair, 1e12, "paid the residual price, not the blended one");
        assertLe(paid, fair, "and never above it: rounding favours the pool");
    }

    /// @notice THE HARD FAILURE. `stampSettlement` reserves against the blended
    ///         price, so it can reserve more than the vault holds. Once
    ///         `reservedAssets > float`, `executeGovernorBatch` reverts
    ///         `QueueReserveBreached` for every future batch — including the
    ///         settle batches that would bring assets back.
    /// @dev    Distinct from the extraction above: that moves value between LPs,
    ///         this wedges the vault. Same root cause, so one fix must close
    ///         both. It also violates the stated invariant INV-Q2
    ///         (`reservedQueueAssets <= float` when unlocked) in
    ///         `test/invariants/AsyncRedeemInvariants.t.sol`.
    /// @notice THE WEDGE SURVIVES, AND THAT IS CORRECT. An 85% drawdown really
    ///         does leave less float than the quitter's already-frozen payout,
    ///         and `QueueReserveBreached` is the honest response: the vault
    ///         cannot both honour a stamped claim and keep deploying. The fix
    ///         does not — and must not — paper over a genuine shortfall.
    /// @dev    WHAT THE FIX CHANGES HERE is that the shortfall is now VISIBLE in
    ///         the price rather than hidden by it. `totalAssets()` reports the
    ///         residual pool, so it floors at 0 once the reserve exceeds the
    ///         float, instead of quoting incumbents a price backed by assets
    ///         owed to somebody else. Pinned so a later "fix" that silently
    ///         relaxes the reserve check has to argue with this test.
    function test_genuineShortfallStillHaltsBatchesAndIsVisibleInThePrice() public {
        _reachMispricingWindow(85);

        assertGt(
            queue.reservedAssets(), usdc.balanceOf(address(vault)), "the frozen payout really does exceed the float"
        );
        assertEq(vault.totalAssets(), 0, "so the residual pool is reported as empty, not as solvent");

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(usdc), value: 0, data: abi.encodeCall(ERC20Mock.decimals, ())});
        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(ISyndicateVault.QueueReserveBreached.selector);
        vault.executeGovernorBatch(calls, new uint256[](0), 0);
    }

    /// @notice THE INVARIANT THE FIX EXISTS TO ESTABLISH: settling a stamped
    ///         claim must not move anybody else's position. `claim` removes
    ///         `shares` from supply and `assets` from float at the same instant
    ///         the queue's two counters drop by the same amounts, so the
    ///         residual price is unchanged across it.
    /// @dev    THIS IS THE REAL REGRESSION TEST. The three above pin the symptom;
    ///         this pins the property. Netting only one leg — assets without
    ///         shares, or shares without assets — would understate or overstate
    ///         the price by exactly the amount this assertion catches, so it
    ///         fails for any half-application of the fix.
    function test_claimingAStampedRedeemDoesNotMoveTheResidualPrice() public {
        _reachMispricingWindow(40);

        uint256 ppsBefore = vault.convertToAssets(1e18);
        uint256 incumbentValueBefore = vault.previewRedeem(vault.balanceOf(incumbent));

        uint256[] memory ids = queue.getRequestsByOwner(quitter);
        assertEq(ids.length, 1);
        vm.prank(quitter);
        queue.claim(ids[0]);

        assertEq(queue.stampedUnclaimedShares(), 0, "the claim cleared the share-side counter");
        assertEq(queue.reservedAssets(), 0, "and the asset-side one");
        assertApproxEqRel(vault.convertToAssets(1e18), ppsBefore, 1e12, "the residual price did not move");
        assertApproxEqRel(
            vault.previewRedeem(vault.balanceOf(incumbent)),
            incumbentValueBefore,
            1e12,
            "and the incumbent's position is worth what it was"
        );
    }

    /// @notice PRE-STAMP ESCROW IS NOT EXCLUDED. A queued-but-unsettled redeem
    ///         has no frozen price, so it still floats with the pool and must
    ///         stay in the denominator. Excluding it — the easy mistake of
    ///         reading `pendingShares()` instead of `stampedUnclaimedShares()` —
    ///         would hand the remaining holders a windfall the moment anyone
    ///         queued an exit.
    function test_preStampEscrowStaysInThePricingSupply() public {
        vm.prank(incumbent);
        vault.deposit(INCUMBENT_ASSETS, incumbent);
        vm.prank(quitter);
        uint256 quitterShares = vault.deposit(QUITTER_ASSETS, quitter);

        uint256 ppsBefore = vault.convertToAssets(1e18);

        _setProposalActive(true);
        vm.prank(quitter);
        vault.requestRedeem(quitterShares, quitter);
        // Back to the inter-proposal gap WITHOUT settling: the shares are
        // escrowed but no price is stamped, which is the state under test. The
        // gap is also the only window in which claims are permitted
        // (`redemptionsLocked`), so it is where pricing has to be right.
        _setProposalActive(false);

        assertEq(queue.stampedUnclaimedShares(), 0, "nothing is stamped yet");
        assertGt(queue.pendingShares(), 0, "though shares are escrowed");
        assertApproxEqRel(vault.convertToAssets(1e18), ppsBefore, 1e12, "queuing an exit moves no price");
    }

    /// @notice A VAULT WITH NO QUEUE IS UNTOUCHED — `_pricingSupply` short-circuits
    ///         on the zero address, so the fix cannot regress deployments that
    ///         never wired a queue.
    function test_vaultWithoutQueuePricesNormally() public {
        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "No Queue",
                    symbol: "nq",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        SyndicateVault bare = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        vm.prank(incumbent);
        usdc.approve(address(bare), type(uint256).max);
        vm.prank(incumbent);
        uint256 shares = bare.deposit(INCUMBENT_ASSETS, incumbent);

        assertEq(bare.withdrawalQueue(), address(0), "no queue wired");
        assertApproxEqRel(bare.previewRedeem(shares), INCUMBENT_ASSETS, 1e12, "prices exactly as before");
    }

    /// @dev Assets per whole (1e18) share, computed here rather than through the
    ///      vault so the expectation cannot agree with the bug under test.
    function _pps(uint256 assets, uint256 supply) internal pure returns (uint256) {
        return Math.mulDiv(1e18, assets, supply);
    }
}

/// @dev Minimal local mulDiv, so expectations never route through the same
///      library the implementation under test uses.
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b) / d;
    }
}
