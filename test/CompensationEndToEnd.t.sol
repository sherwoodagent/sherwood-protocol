// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {CompensationEscrow} from "../src/CompensationEscrow.sol";
import {ICompensationEscrow} from "../src/interfaces/ICompensationEscrow.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

import {VaultWithdrawalQueue} from "../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../src/interfaces/IVaultWithdrawalQueue.sol";

/// @title CompensationEndToEndTest
/// @notice Task 5 — the whole v1b part-1 payout rail against REAL contracts:
///         a real UUPS `StakedWood` proxy with a real staked+matured guardian, a
///         real `CompensationEscrow`, and — the point of this suite — a REAL
///         `SyndicateVault` whose ERC20Votes checkpoints come from real LP
///         deposits.
///
/// @dev    Every other suite in this plan apportions against `MockVotesVault`,
///         which simply *declares* that `getPastVotes(h, t) == balanceOf(h)` at
///         `t`. That equality is decision D1's load-bearing assumption (the
///         vault's `_update` auto-delegates EVERY receipt — mint and plain
///         transfer, PR #24 review 🔴1). Here it is exercised rather than
///         assumed: nobody calls `delegate`, the `_update` override does the
///         auto-delegation, and the escrow reads the checkpoints it produced.
///
/// @dev    Fixture arithmetic (all exact, no rounding slack — see below):
///           - USDG is 6-dec and `_decimalsOffset()` returns the ASSET's decimals
///             (`src/SyndicateVault.sol:212`), so the first deposit into an empty
///             vault mints `assets * 1e6` shares. Every later deposit converts at
///             `(S + 10^d) / (A + 1)`, which for `S == A * 10^d` is exactly
///             `10^d` — so the 70/30 asset split is a 70/30 SHARE split with no
///             dust anywhere.
///           - LP1 70,000 USDG → 70,000e12 shares; LP2 30,000 USDG → 30,000e12;
///             snapshot supply 100,000e12.
///           - guardian stakes 20,000 WOOD, slashed at 10,000 bps → 20,000 WOOD
///             of proceeds → LP1 14,000 WOOD, LP2 6,000 WOOD.
contract CompensationEndToEndTest is Test {
    // ── Real stack ──
    ERC20Mock public usdg; // vault asset, 6-dec
    ERC20Mock public wood; // stake token, 18-dec
    BatchExecutorLib public executorLib;
    MockAgentRegistry public agentRegistry;
    ProtocolConfig public protocolConfig;
    StakedWood public swood;
    GuardianRegistry public registry;
    SyndicateVault public vault;
    SyndicateGovernor public gov;
    CompensationEscrow public escrow;

    address public owner = makeAddr("owner");
    address public backstop = makeAddr("backstop");
    address public g1 = makeAddr("guardian1");

    address public lp1 = makeAddr("lp1"); // pre-drain holder, 70%
    address public lp2 = makeAddr("lp2"); // pre-drain holder, 30%
    address public buyer = makeAddr("postDrainBuyer"); // deposits AFTER the snapshot

    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 45 days;
    uint256 constant MATURATION = 30 days;

    uint256 constant GUARDIAN_STAKE = 20_000e18;
    uint256 constant SLASH_BPS = 10_000; // full verdict slash

    uint256 constant LP1_ASSETS = 70_000e6;
    uint256 constant LP2_ASSETS = 30_000e6;
    uint256 constant BUYER_ASSETS = 20_000e6;

    /// @dev `assets * 10^assetDecimals` — see the fixture-arithmetic note above.
    uint256 constant LP1_SHARES = 70_000e12;
    uint256 constant LP2_SHARES = 30_000e12;
    uint256 constant BUYER_SHARES = 20_000e12;
    uint256 constant SNAP_SUPPLY = LP1_SHARES + LP2_SHARES;

    uint256 constant PROCEEDS = GUARDIAN_STAKE; // 10,000 bps of the own stake
    uint256 constant LP1_CLAIM = 14_000e18; // 70% of PROCEEDS
    uint256 constant LP2_CLAIM = 6_000e18; // 30% of PROCEEDS

    /// @dev The verdict's open timestamp — the at-open anchor `_slashOne` sizes
    ///      the guardian's legs against.
    uint256 public openedAt;
    /// @dev The pre-drain snapshot the escrow apportions against (§3.8 / D2).
    ///      Both LP deposits are already checkpointed at this timestamp; the
    ///      post-drain buyer's is not.
    uint256 public snapTs;
    /// @dev A timestamp AFTER the buyer's deposit — used to prove the buyer's
    ///      checkpoints really moved, they just moved too late to matter.
    uint256 public postBuyTs;

    /// @dev This test contract stands in for the factory, so it also answers
    ///      the factory's `compensationEscrow()` view — that is how a
    ///      withdrawal queue resolves the escrow now that it is no longer a
    ///      `claimCompensation` argument (PR #24 review 🔴N1).
    address public compensationEscrow;

    function setUp() public {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        protocolConfig = new ProtocolConfig(owner);

        // ── sWOOD (sole WOOD custodian). The test contract is the factory.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: COOL_DOWN,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 10_000,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: MATURATION,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        // ── Real guardian registry (the review path's home — untouched here,
        //    but wired so sWOOD is in its production shape while the VERDICT
        //    path runs through the separate `authorizedSlasher` role (D4)).
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, address(this), address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(owner);
        swood.setRegistry(address(registry));

        // ── Real vault + real governor. The test contract is the factory, so
        //    the vault resolves its governor through `governorOf`.
        _deploySyndicate();
        vm.mockCall(
            address(this), abi.encodeWithSignature("governorOf(address)", address(vault)), abi.encode(address(gov))
        );

        // ── Compensation escrow: sWOOD is the ONLY authorized funder, and this
        //    test contract stands in for Plan D's challenge game as the
        //    authorized slasher (until Plan D lands, a verdict is governance).
        escrow = new CompensationEscrow(owner, address(wood));
        compensationEscrow = address(escrow); // factory stand-in wiring (🔴N1)
        vm.startPrank(owner);
        escrow.setAuthorizedFunder(address(swood));
        escrow.setBackstop(backstop);
        swood.setAuthorizedSlasher(address(this));
        swood.setCompensationEscrow(address(escrow));
        vm.stopPrank();

        // ── Guardian stakes and matures to par.
        wood.mint(g1, GUARDIAN_STAKE);
        vm.startPrank(g1);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(GUARDIAN_STAKE, 1);
        vm.stopPrank();
        skip(MATURATION);
        vm.warp(vm.getBlockTimestamp() + 1);

        // ── PRE-drain LPs, one per timestamp so the ERC20Votes checkpoints
        //    genuinely separate (they are timestamp-keyed: `clock()` is
        //    `block.timestamp`, `src/SyndicateVault.sol:641`).
        _deposit(lp1, LP1_ASSETS);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _deposit(lp2, LP2_ASSETS);
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        // The pre-drain snapshot: both LP deposits are in, nothing else happens
        // at this timestamp.
        snapTs = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        // ── POST-drain buyer. A REAL deposit — the vault's supply and the
        //    buyer's own vote checkpoints both move, they just move after the
        //    snapshot the case is pinned to.
        _deposit(buyer, BUYER_ASSETS);
        postBuyTs = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        // ── The verdict opens AFTER the drain it convicts, which is why
        //    `slashToEscrow` can require `snapshotTimestamp <= openedAt`: a
        //    pre-drain snapshot necessarily precedes the verdict.
        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    // ── Fixture helpers ───────────────────────────────────────────────────

    function _deploySyndicate() internal {
        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdg),
                    name: "Sherwood Vault",
                    symbol: "swUSDG",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(registry),
                address(protocolConfig),
                address(this), // factory
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: 1 days,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        gov = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
    }

    /// @dev A real ERC4626 deposit. Nobody ever calls `delegate` in this suite —
    ///      the vault's `_update` override auto-delegates the receiver to
    ///      itself, which is exactly the D1 behaviour under test.
    function _deposit(address who, uint256 assets) internal {
        usdg.mint(who, assets);
        vm.startPrank(who);
        usdg.approve(address(vault), assets);
        vault.deposit(assets, who);
        vm.stopPrank();
    }

    /// @dev The verdict: slash the guardian to the escrow, pinned to `snapTs`.
    function _verdictSlash() internal returns (uint256 caseId, uint256 total) {
        address[] memory approvers = new address[](1);
        approvers[0] = g1;
        (total, caseId) = swood.slashToEscrow(
            bytes32("verdict-case"), openedAt, approvers, _bpsArr(approvers.length, SLASH_BPS), address(vault), snapTs
        );
        assertEq(caseId, escrow.caseCount(), "the returned case id is the escrow's newest case");
    }

    /// @dev Assert the fixture BEFORE asserting the behaviour: the vault's own
    ///      checkpoints must carry a clean 70/30 at `snapTs`, and — the D1
    ///      claim — each holder's votes must equal the shares it holds.
    function _assertSnapshotSplit() internal view {
        assertEq(vault.getPastTotalSupply(snapTs), SNAP_SUPPLY, "snapshot supply is the two pre-drain LPs");
        assertEq(vault.getPastVotes(lp1, snapTs), LP1_SHARES, "LP1 holds 70% at the snapshot");
        assertEq(vault.getPastVotes(lp2, snapTs), LP2_SHARES, "LP2 holds 30% at the snapshot");
        // D1 in the flesh: auto-delegation makes votes == balance, with nobody
        // having called `delegate`.
        assertEq(vault.delegates(lp1), lp1, "vault auto-delegated LP1 to itself");
        assertEq(vault.delegates(lp2), lp2, "vault auto-delegated LP2 to itself");
        assertEq(vault.getPastVotes(lp1, snapTs), vault.balanceOf(lp1), "votes == balance (D1)");
        assertEq(vault.getPastVotes(lp2, snapTs), vault.balanceOf(lp2), "votes == balance (D1)");
        // 70/30 stated as a ratio too, so the constants above cannot drift into
        // agreeing with each other while disagreeing with the intent.
        assertEq(vault.getPastVotes(lp1, snapTs) * 3, vault.getPastVotes(lp2, snapTs) * 7, "the split is exactly 70/30");
    }

    // ── 1. The happy path: pre-drain holders are made whole ───────────────

    /// @notice Spec §3.8. A verdict slash funds a case pinned to the pre-drain
    ///         snapshot; the escrow holds exactly the slashed WOOD, the claim
    ///         splits with the snapshot shares, and the two pre-drain LPs
    ///         between them redeem the case down to zero.
    function test_verdictSlash_compensatesPreDrainHolders() public {
        _assertSnapshotSplit();

        uint256 escrowBefore = wood.balanceOf(address(escrow));
        (uint256 caseId, uint256 total) = _verdictSlash();

        // ── The slash landed in the escrow, whole, and nowhere else.
        assertEq(total, PROCEEDS, "full slash of the guardian's own stake");
        assertEq(wood.balanceOf(address(escrow)), escrowBefore + PROCEEDS, "escrow holds exactly the slashed WOOD");
        assertEq(escrow.totalEscrowed(), PROCEEDS, "and books it as outstanding");
        assertEq(swood.guardianStake(g1), 0, "the guardian paid it");

        (address v, uint256 ts, uint256 proceeds, uint256 redeemed,,, bool swept) = escrow.caseOf(caseId);
        assertEq(v, address(vault), "case is pinned to the real vault");
        assertEq(ts, snapTs, "and to the pre-drain snapshot");
        assertEq(proceeds, PROCEEDS);
        assertEq(redeemed, 0);
        assertFalse(swept, "a fresh case is not swept");

        // ── Claims split with the snapshot, exactly.
        assertEq(escrow.claimable(caseId, lp1), LP1_CLAIM, "LP1 claims 70%");
        assertEq(escrow.claimable(caseId, lp2), LP2_CLAIM, "LP2 claims 30%");
        assertEq(LP1_CLAIM + LP2_CLAIM, PROCEEDS, "the two claims exhaust the case");

        // ── Both redeem. Hoisted balances: a cheatcode in argument position
        //    would be consumed by the inner call.
        uint256 lp1Before = wood.balanceOf(lp1);
        uint256 lp2Before = wood.balanceOf(lp2);

        vm.prank(lp1);
        uint256 got1 = escrow.redeem(caseId);
        vm.prank(lp2);
        uint256 got2 = escrow.redeem(caseId);

        assertEq(got1, LP1_CLAIM, "LP1 redeemed its 70%");
        assertEq(got2, LP2_CLAIM, "LP2 redeemed its 30%");
        assertEq(wood.balanceOf(lp1), lp1Before + LP1_CLAIM, "LP1 actually received the WOOD");
        assertEq(wood.balanceOf(lp2), lp2Before + LP2_CLAIM, "LP2 actually received the WOOD");
        assertEq(wood.balanceOf(address(escrow)), escrowBefore, "escrow paid out the full proceeds");
        assertEq(escrow.totalEscrowed(), 0, "nothing outstanding");

        (,,, uint256 redeemedAfter,,,) = escrow.caseOf(caseId);
        assertEq(redeemedAfter, PROCEEDS, "case fully redeemed");

        // Re-redeeming is closed for both.
        assertEq(escrow.claimable(caseId, lp1), 0, "LP1's claim is spent");
        vm.prank(lp1);
        vm.expectRevert(ICompensationEscrow.AlreadyRedeemed.selector);
        escrow.redeem(caseId);
    }

    // ── 2. F1: the post-drain buyer recoups nothing ───────────────────────

    /// @notice Finding F1, against the REAL vault. Paying slash proceeds into the
    ///         live NAV would let a coalition drain, buy the depressed shares of
    ///         exiting honest holders and recoup its own slash. The snapshot
    ///         closes it: shares bought AFTER the pinned block carry no claim,
    ///         however real the purchase, and the pre-drain LPs' entitlements do
    ///         not move an atom to accommodate the newcomer.
    function test_verdictSlash_postDrainBuyerGetsNothing() public {
        // The buyer's deposit was REAL: it holds shares, it is auto-delegated,
        // and its votes are live — the checkpoints simply moved too late.
        assertEq(vault.balanceOf(buyer), BUYER_SHARES, "the post-drain buyer really holds shares");
        assertEq(vault.delegates(buyer), buyer, "and is auto-delegated like everyone else");
        assertEq(vault.getPastVotes(buyer, postBuyTs), BUYER_SHARES, "its votes exist AFTER the snapshot");
        assertEq(vault.getPastTotalSupply(postBuyTs), SNAP_SUPPLY + BUYER_SHARES, "supply really grew");
        // ...but the snapshot the case is pinned to predates all of it.
        assertEq(vault.getPastVotes(buyer, snapTs), 0, "zero votes at the pre-drain snapshot");
        _assertSnapshotSplit();

        (uint256 caseId,) = _verdictSlash();

        // ── The F1 property.
        assertEq(escrow.claimable(caseId, buyer), 0, "post-drain shares carry no claim");
        vm.prank(buyer);
        vm.expectRevert(ICompensationEscrow.NoClaim.selector);
        escrow.redeem(caseId);

        // ── And the pre-drain LPs are entirely unaffected by the newcomer: the
        //    claim basis is the snapshot supply, not the (larger) live supply.
        assertEq(escrow.claimable(caseId, lp1), LP1_CLAIM, "LP1 undiluted by the post-drain deposit");
        assertEq(escrow.claimable(caseId, lp2), LP2_CLAIM, "LP2 undiluted by the post-drain deposit");
        assertEq(LP1_CLAIM + LP2_CLAIM, PROCEEDS, "the pre-drain cohort still owns the whole case");

        // Paying pro-rata on the LIVE supply is the channel that was closed:
        // the buyer would have taken this much of the slash.
        uint256 liveShare = (PROCEEDS * BUYER_SHARES) / (SNAP_SUPPLY + BUYER_SHARES);
        assertGt(liveShare, 0, "a live-NAV payout would have handed the buyer real WOOD");

        // The two honest LPs still drain the case between them.
        vm.prank(lp1);
        escrow.redeem(caseId);
        vm.prank(lp2);
        escrow.redeem(caseId);
        assertEq(escrow.totalEscrowed(), 0, "the whole slash reached pre-drain holders only");
        assertEq(wood.balanceOf(buyer), 0, "the post-drain buyer got nothing at all");
    }

    // ── 3. Compensation never touches live NAV ────────────────────────────

    /// @notice Spec §3.8's structural boundary: slash proceeds are WOOD held in a
    ///         separate escrow, never assets credited to the vault. `totalAssets`
    ///         — and therefore the share price every remaining LP redeems at — is
    ///         identical before the slash and after both victims have been paid.
    ///         Were it otherwise, compensation would itself be the recoupment
    ///         channel test 2 closes.
    function test_verdictSlash_doesNotTouchLiveNav() public {
        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        uint256 vaultWoodBefore = wood.balanceOf(address(vault));
        assertEq(navBefore, LP1_ASSETS + LP2_ASSETS + BUYER_ASSETS, "NAV is the deposited float");

        (uint256 caseId, uint256 total) = _verdictSlash();
        assertEq(total, PROCEEDS);
        assertEq(vault.totalAssets(), navBefore, "the slash itself does not credit the vault");

        vm.prank(lp1);
        escrow.redeem(caseId);
        vm.prank(lp2);
        escrow.redeem(caseId);
        assertEq(escrow.totalEscrowed(), 0, "both victims paid");

        // The compensation moved WOOD to the victims directly; nothing about the
        // vault's assets, supply or share price changed.
        assertEq(vault.totalAssets(), navBefore, "live NAV unchanged after compensation");
        assertEq(vault.totalSupply(), supplyBefore, "no shares minted or burned");
        assertEq(wood.balanceOf(address(vault)), vaultWoodBefore, "no WOOD ever reached the vault");
        assertEq(
            vault.convertToAssets(LP1_SHARES),
            (navBefore * LP1_SHARES) / supplyBefore,
            "share price undisturbed by the payout"
        );
    }

    // ── 4. PR #24 review 🔴1: transferred shares carry a claim ────────────

    /// @notice Regression for review PoC `test_poc_transferredSharesCarryNoClaim`
    ///         (now inverted): shares that arrive by plain ERC20 `transfer` are
    ///         auto-delegated by `_update`, so a pre-drain secondary buyer is a
    ///         holder of record at the snapshot and redeems its full share —
    ///         nothing strands to the backstop.
    function test_transferredSharesCarryClaim() public {
        address sec = makeAddr("secondaryBuyer");
        vm.prank(lp2);
        vault.transfer(sec, LP2_SHARES); // pre-drain secondary sale

        // Auto-delegated ON TRANSFER — the fix under test.
        assertEq(vault.delegates(sec), sec, "transfer recipient is auto-delegated");

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        snapTs = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        assertEq(vault.getPastVotes(sec, snapTs), LP2_SHARES, "full weight at the snapshot");
        assertEq(vault.getPastVotes(lp2, snapTs), 0, "the seller's weight moved with the shares");

        (uint256 caseId,) = _verdictSlash();

        // This timeline's snapshot includes the buyer's deposit too.
        uint256 supply = SNAP_SUPPLY + BUYER_SHARES;
        uint256 secClaim = (PROCEEDS * LP2_SHARES) / supply;
        assertEq(escrow.claimable(caseId, sec), secClaim, "secondary buyer holds LP2's claim");
        assertEq(escrow.claimable(caseId, lp2), 0, "the seller transferred the entitlement away");

        vm.prank(sec);
        uint256 got = escrow.redeem(caseId);
        assertEq(got, secClaim);
        assertEq(wood.balanceOf(sec), secClaim, "the WOOD actually arrived");

        // Everyone with snapshot weight can drain the case — only sub-wei
        // rounding dust remains for the residue sweep.
        vm.prank(lp1);
        escrow.redeem(caseId);
        vm.prank(buyer);
        escrow.redeem(caseId);
        assertLt(escrow.totalEscrowed(), 3, "no victim's money strands (dust only)");
    }

    // ── 5. PR #24 review 🔴1: the queue pays its claim through ────────────

    /// @dev Builds real queue custody exactly the way `requestRedeem` does —
    ///      `_transfer(owner, queue, shares)` + `queueRedeem(owner, ...)` —
    ///      without needing a live proposal (requestRedeem is lock-gated).
    function _queueCustody(VaultWithdrawalQueue q, address owner_, uint256 shares, uint256 pid)
        internal
        returns (uint256 reqId)
    {
        vm.prank(owner_);
        vault.transfer(address(q), shares);
        vm.prank(address(vault));
        reqId = q.queueRedeem(owner_, shares, pid);
    }

    /// @notice The modal victim of the review: an LP whose exit sat in the
    ///         withdrawal queue when the drain landed. The queue's custody
    ///         balance is auto-delegated (so the escrow counts it), and
    ///         `claimCompensation` pays the claim through to the request owner.
    function test_queuedRedeemerIsCompensatedViaQueuePayThrough() public {
        VaultWithdrawalQueue q = new VaultWithdrawalQueue(address(vault));
        uint256 reqId = _queueCustody(q, lp2, LP2_SHARES, 1);

        assertEq(vault.delegates(address(q)), address(q), "queue custody is auto-delegated");

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        snapTs = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        assertEq(vault.getPastVotes(address(q), snapTs), LP2_SHARES, "queue holds the exiter's weight");

        (uint256 caseId,) = _verdictSlash();

        // The exiter personally has no claim — the QUEUE is the holder of
        // record the escrow sees...
        assertEq(escrow.claimable(caseId, lp2), 0, "personal claim moved into custody");
        uint256 queueClaim = escrow.claimable(caseId, address(q));
        assertGt(queueClaim, 0, "the custody balance carries the claim");

        // ...and the pay-through hands it to the request owner.
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        (uint256 paid, uint256 processed, uint256 skipped) = q.claimCompensation(caseId, ids);
        assertEq(paid, queueClaim, "single request == the queue's whole claim");
        assertEq(processed, 1, "the request was credited");
        assertEq(skipped, 0, "nothing passed over");
        assertEq(wood.balanceOf(lp2), queueClaim, "the queued exiter got the WOOD");

        // Idempotent per request: a second pass pays nothing and now SKIPS
        // rather than reverting the batch (PR #24 review 🟡N7).
        (uint256 paid2, uint256 processed2, uint256 skipped2) = q.claimCompensation(caseId, ids);
        assertEq(paid2, 0, "no second payout");
        assertEq(processed2, 0, "nothing credited twice");
        assertEq(skipped2, 1, "the already-paid id was skipped");
        assertEq(wood.balanceOf(lp2), queueClaim, "balance unchanged by the replay");
    }

    /// @notice A request queued AFTER the snapshot was not in custody at the
    ///         drain and gets nothing through the queue.
    function test_queueCompensation_postSnapshotRequestIneligible() public {
        VaultWithdrawalQueue q = new VaultWithdrawalQueue(address(vault));
        uint256 preId = _queueCustody(q, lp2, LP2_SHARES, 1);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        snapTs = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        // Queued after the snapshot: in custody NOW, but not at the drain.
        uint256 postId = _queueCustody(q, buyer, BUYER_SHARES, 2);

        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        (uint256 caseId,) = _verdictSlash();

        // The post-snapshot request is passed over, not reverted (🟡N7) — but
        // the pull still happens, so the case is now funded and undistributed
        // to exactly the extent the caller failed to name eligible requests.
        uint256[] memory ids = new uint256[](1);
        ids[0] = postId;
        (uint256 nothing, uint256 credited, uint256 passedOver) = q.claimCompensation(caseId, ids);
        assertEq(nothing, 0, "an ineligible request is paid nothing");
        assertEq(credited, 0, "and is not credited");
        assertEq(passedOver, 1, "it is reported as skipped");
        assertEq(wood.balanceOf(buyer), 0, "the post-snapshot owner got nothing");

        // The pre-snapshot request still collects.
        ids[0] = preId;
        (uint256 paid,,) = q.claimCompensation(caseId, ids);
        assertGt(paid, 0);
        assertEq(wood.balanceOf(lp2), paid);
    }

    // ── 6. PR #24 review 🟠2 / 🟠4: slashToEscrow input hardening ─────────

    /// @notice `openedAt` must be a real past instant.
    function test_slashToEscrow_futureOpenedAtReverts() public {
        address[] memory approvers = new address[](1);
        approvers[0] = g1;
        uint256[] memory bps = _bpsArr(1, SLASH_BPS);
        uint256 future = vm.getBlockTimestamp() + 1;
        vm.expectRevert(StakedWood.VerdictNotPast.selector);
        swood.slashToEscrow(bytes32("verdict-case"), future, approvers, bps, address(vault), snapTs);
    }

    /// @notice Regression for the review's clamp-bypass PoC: N repeats of one
    ///         approver compounded to `1-(1-bps)^N`, blowing through the
    ///         `maxSlashBps` ceiling. Any duplicate reverts; order stays free
    ///         because the production feed (`ExposureLedger.slashBpsFor`) is
    ///         vote-ordered, not sorted.
    function test_slashToEscrow_duplicateApproversRevert() public {
        address[] memory dup = new address[](8);
        for (uint256 i = 0; i < 8; i++) {
            dup[i] = g1;
        }
        vm.expectRevert(StakedWood.DuplicateApprover.selector);
        swood.slashToEscrow(bytes32("case"), openedAt, dup, _bpsArr(8, SLASH_BPS), address(vault), snapTs);

        // A zero-rate entry is not a free slot for smuggling a duplicate.
        address[] memory zeroDup = new address[](2);
        zeroDup[0] = g1;
        zeroDup[1] = g1;
        uint256[] memory rates = new uint256[](2);
        rates[0] = SLASH_BPS;
        rates[1] = 0;
        vm.expectRevert(StakedWood.DuplicateApprover.selector);
        swood.slashToEscrow(bytes32("case"), openedAt, zeroDup, rates, address(vault), snapTs);
    }

    // ── 7. PR #24 review 🟡5: a bad vault burns instead of bricking ───────

    event VerdictSlashUncompensated(bytes32 indexed caseKey, address indexed vault, uint256 total);

    /// @notice If `openCase` reverts (here: a codeless `vault` address), the
    ///         slash still lands — proceeds burn to the dead address and the
    ///         uncompensated marker fires. The guilty guardian must never keep
    ///         its stake because a vault is unpriceable.
    function test_slashToEscrow_badVaultBurnsInsteadOfBricking() public {
        address deadVault = makeAddr("notAVault"); // no code: escrow's votes read reverts
        address burnAddr = 0x000000000000000000000000000000000000dEaD;
        uint256 burnBefore = wood.balanceOf(burnAddr);

        address[] memory approvers = new address[](1);
        approvers[0] = g1;
        vm.expectEmit(true, true, false, true, address(swood));
        emit VerdictSlashUncompensated(bytes32("verdict-case"), deadVault, PROCEEDS);
        (uint256 total, uint256 caseId) =
            swood.slashToEscrow(bytes32("verdict-case"), openedAt, approvers, _bpsArr(1, SLASH_BPS), deadVault, snapTs);

        assertEq(total, PROCEEDS, "the slash landed in full");
        assertEq(caseId, 0, "no case was opened");
        assertEq(swood.guardianStake(g1), 0, "the guardian paid");
        assertEq(wood.balanceOf(burnAddr), burnBefore + PROCEEDS, "proceeds burned, review-path style");
        assertEq(escrow.totalEscrowed(), 0, "nothing reached the escrow");
        assertEq(wood.balanceOf(address(escrow)), 0, "not even unbooked WOOD");
    }

    /// @notice Review F-A regression: `EmptySnapshot` means the escrow's votes
    ///         read SUCCEEDED and returned zero supply — the vault implements
    ///         the ERC20Votes surface and the TIMESTAMP is wrong (here it
    ///         predates the first LP deposit). That is a resubmittable caller
    ///         error, so it must BUBBLE rather than burn the victims'
    ///         compensation: the whole transaction rolls back — stake and the
    ///         per-(caseKey, approver) `_verdictSlashed` mark — and the
    ///         corrected call runs clean.
    function test_slashToEscrow_emptySnapshotBubblesAndRetrySucceeds() public {
        uint256 emptyTs = snapTs - 2 hours - 1; // vault live for 30+ days, pre-first-deposit
        assertEq(vault.getPastTotalSupply(emptyTs), 0, "fixture: nobody held the vault yet");

        address[] memory approvers = new address[](1);
        approvers[0] = g1;
        uint256[] memory bps = _bpsArr(1, SLASH_BPS);
        vm.expectRevert(ICompensationEscrow.EmptySnapshot.selector);
        swood.slashToEscrow(bytes32("verdict-case"), openedAt, approvers, bps, address(vault), emptyTs);

        // Nothing moved and nothing burned: the slash rolled back with the revert.
        assertEq(swood.guardianStake(g1), GUARDIAN_STAKE, "stake untouched");
        assertFalse(swood.verdictSlashed(bytes32("verdict-case"), g1), "the one slash was not consumed");

        // The resubmission with the corrected snapshot lands in full.
        (uint256 total, uint256 caseId) =
            swood.slashToEscrow(bytes32("verdict-case"), openedAt, approvers, bps, address(vault), snapTs);
        assertEq(total, PROCEEDS, "the corrected verdict slashed in full");
        assertGt(caseId, 0, "a case was opened");
        assertEq(escrow.totalEscrowed(), PROCEEDS, "proceeds escrowed, not burned");
    }

    // ── 8. PR #24 review 🟡6 + minors: frozen window reads, backstop guard ─

    /// @notice A holder can compute its sweep deadline on-chain: `caseOf` now
    ///         returns the FROZEN per-case window and `deadlineOf` the exact
    ///         instant sweeping opens; later owner changes do not move either.
    function test_caseExposesFrozenResidueWindow() public {
        (uint256 caseId,) = _verdictSlash();
        (,,,, uint256 caseOpenedAt, uint256 frozenWindow,) = escrow.caseOf(caseId);
        assertEq(frozenWindow, 180 days, "the window in force at open");
        assertEq(escrow.deadlineOf(caseId), caseOpenedAt + 180 days);

        vm.prank(owner);
        escrow.setResidueWindow(30 days);
        (,,,,, uint256 stillFrozen,) = escrow.caseOf(caseId);
        assertEq(stillFrozen, 180 days, "owner changes do not reach open cases");
        assertEq(escrow.deadlineOf(caseId), caseOpenedAt + 180 days, "deadline did not move");

        vm.expectRevert(ICompensationEscrow.CaseNotFound.selector);
        escrow.deadlineOf(caseId + 1);
    }

    /// @notice "Residue never to live NAV" is code-enforced: a backstop pointed
    ///         at the case's own vault cannot sweep.
    function test_sweepResidue_backstopCannotBeCaseVault() public {
        (uint256 caseId,) = _verdictSlash();
        vm.prank(owner);
        escrow.setBackstop(address(vault));
        vm.warp(vm.getBlockTimestamp() + 181 days);
        vm.expectRevert(ICompensationEscrow.BackstopIsVault.selector);
        escrow.sweepResidue(caseId);

        // Re-pointing at a real backstop unblocks the sweep.
        vm.prank(owner);
        escrow.setBackstop(backstop);
        uint256 swept = escrow.sweepResidue(caseId);
        assertEq(swept, PROCEEDS);
        assertEq(wood.balanceOf(backstop), PROCEEDS);
    }

    // ── 9. PR #24 review minor: verdict keys are namespaced ───────────────

    event GuardianSlashed(
        bytes32 indexed reviewKey, address indexed approver, uint256 ownSlash, uint256 delegatedSlash
    );

    /// @notice The verdict path's `GuardianSlashed` topic can never collide
    ///         with a review path `reviewKey`: the key is namespaced before it
    ///         feeds the shared event, while `VerdictSlashRouted` carries the
    ///         raw key for deterministic joins.
    function test_verdictSlashKeyIsNamespaced() public {
        bytes32 raw = bytes32("verdict-case");
        bytes32 namespaced = keccak256(abi.encodePacked("sherwood.verdict", raw));
        address[] memory approvers = new address[](1);
        approvers[0] = g1;

        vm.expectEmit(true, true, false, false, address(swood));
        emit GuardianSlashed(namespaced, g1, 0, 0);
        swood.slashToEscrow(raw, openedAt, approvers, _bpsArr(1, SLASH_BPS), address(vault), snapTs);
    }

    // ── 10. PR #24 review round 2: N1 / N2 / N7 / N8 regressions ──────────

    /// @notice 🔴N1. The escrow is no longer a caller argument, so the token
    ///         substitution drain has no entry point: the queue resolves the
    ///         escrow from the factory, and a caller who has not been granted
    ///         that slot cannot make the queue pull from anything.
    ///
    ///         The PoC needed two capabilities — name a hostile escrow, and
    ///         have the payout unit re-read from it after the amount was fixed.
    ///         This asserts both are gone: the wiring is governance-owned, and
    ///         the case pins its token at pull time.
    function test_carlos_N1_escrowIsGovernanceWiredAndTokenIsPinned() public {
        VaultWithdrawalQueue q = new VaultWithdrawalQueue(address(vault));
        uint256 reqId = _queueCustody(q, lp2, LP2_SHARES, 1);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        snapTs = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (uint256 caseId,) = _verdictSlash();

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        // Unwired factory ⇒ no pull at all, rather than a pull from wherever
        // the caller pointed.
        compensationEscrow = address(0);
        vm.expectRevert(IVaultWithdrawalQueue.CompensationEscrowNotSet.selector);
        q.claimCompensation(caseId, ids);

        // A hostile escrow deployed by anyone is inert: only governance's slot
        // is read, and this contract IS the factory stand-in, so the attacker's
        // address never enters the path.
        compensationEscrow = address(escrow);

        (uint256 paid,,) = q.claimCompensation(caseId, ids);
        assertGt(paid, 0, "the honest case pays");

        // The unit is pinned to what was actually received, recorded per case.
        (uint256 total,,, address pinned, bool pulled) = q.compensationCase(address(escrow), caseId);
        assertTrue(pulled, "case pulled");
        assertEq(pinned, address(wood), "payout token pinned to the token measured at pull time");
        assertEq(paid, total, "the single eligible request took the whole measured total");
        assertEq(wood.balanceOf(lp2), paid, "paid in real WOOD to the request owner");
        assertEq(wood.balanceOf(address(q)), 0, "nothing idles in the queue for a later caller to take");
    }

    /// @notice 🔴N1 (fix 3). Pulling a case while naming nobody is refused, so
    ///         proceeds cannot be parked in the queue by a front-runner ahead
    ///         of the honest pay-through.
    function test_carlos_N1_pullWithoutDistributionIsRefused() public {
        VaultWithdrawalQueue q = new VaultWithdrawalQueue(address(vault));
        _queueCustody(q, lp2, LP2_SHARES, 1);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        snapTs = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (uint256 caseId,) = _verdictSlash();

        vm.expectRevert(IVaultWithdrawalQueue.NoRequestsSupplied.selector);
        q.claimCompensation(caseId, new uint256[](0));

        (,,,, bool pulled) = q.compensationCase(address(escrow), caseId);
        assertFalse(pulled, "an empty batch does not pull the case");
        assertEq(wood.balanceOf(address(q)), 0, "and leaves no WOOD sitting in the queue");
    }

    /// @notice 🟡N7. One already-paid id no longer reverts a keeper's batch.
    ///         A griefer claims one request out of two; the honest sweep still
    ///         pays the other and reports the skip.
    function test_carlos_N7_frontRunClaimDoesNotGriefTheBatch() public {
        VaultWithdrawalQueue q = new VaultWithdrawalQueue(address(vault));
        uint256 idA = _queueCustody(q, lp2, LP2_SHARES / 2, 1);
        uint256 idB = _queueCustody(q, lp1, LP2_SHARES / 2, 1);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        snapTs = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (uint256 caseId,) = _verdictSlash();

        // The griefer front-runs with just one of the two ids.
        uint256[] memory one = new uint256[](1);
        one[0] = idA;
        vm.prank(makeAddr("griefer"));
        (uint256 griefPaid,,) = q.claimCompensation(caseId, one);
        assertGt(griefPaid, 0, "the front-run still pays its owner, not the griefer");

        // The keeper's full batch survives.
        uint256[] memory both = new uint256[](2);
        both[0] = idA;
        both[1] = idB;
        (uint256 paid, uint256 processed, uint256 skipped) = q.claimCompensation(caseId, both);
        assertEq(processed, 1, "only the unpaid id is credited");
        assertEq(skipped, 1, "the front-run id is skipped, not fatal");
        assertGt(paid, 0, "and the honest exiter is paid");
    }

    /// @notice 🟠N2. The severity ceiling binds per VERDICT, not per call: a
    ///         second `slashToEscrow` naming the same approver under the same
    ///         `caseKey` is refused, so splitting one verdict across
    ///         transactions cannot compound past `maxSlashBps`.
    function test_carlos_N2_repeatedCallsCannotCompoundPastTheCeiling() public {
        // A ceiling well below 100% so compounding would be visible.
        vm.startPrank(owner);
        swood.setMinSlashBps(0);
        swood.setMaxDelegatedSlashBps(2_500);
        swood.setMaxSlashBps(5_000);
        vm.stopPrank();

        address[] memory approvers = new address[](1);
        approvers[0] = g1;
        uint256[] memory bps = _bpsArr(1, 5_000);
        uint256 stakeAtOpen = swood.guardianStake(g1);

        swood.slashToEscrow(bytes32("split-verdict"), openedAt, approvers, bps, address(vault), snapTs);
        uint256 afterFirst = swood.guardianStake(g1);
        assertEq(afterFirst, stakeAtOpen / 2, "one call takes exactly the ceiling");

        assertTrue(swood.verdictSlashed(bytes32("split-verdict"), g1), "the pair is recorded");

        vm.expectRevert(StakedWood.ApproverAlreadySlashed.selector);
        swood.slashToEscrow(bytes32("split-verdict"), openedAt, approvers, bps, address(vault), snapTs);
        vm.expectRevert(StakedWood.ApproverAlreadySlashed.selector);
        swood.slashToEscrow(bytes32("split-verdict"), openedAt, approvers, bps, address(vault), snapTs);

        assertEq(swood.guardianStake(g1), afterFirst, "the ceiling held across the retries");

        // A DIFFERENT verdict is a different liability and still lands — the
        // guard is per case, not a lifetime immunity. It takes 5,000 bps of
        // what is LEFT (`_slashOne` sizes off `min(atOpenCheckpoint, live)`),
        // which is the geometric compounding 🟠N2 exists to stop: two calls
        // reach 75% of the original bond. Legitimate across two convictions,
        // a ceiling bypass within one.
        assertFalse(swood.verdictSlashed(bytes32("other-verdict"), g1), "unrelated case unaffected");
        swood.slashToEscrow(bytes32("other-verdict"), openedAt, approvers, bps, address(vault), snapTs);
        assertEq(swood.guardianStake(g1), afterFirst / 2, "a separate verdict slashes separately");
        assertEq(swood.guardianStake(g1), stakeAtOpen / 4, "two convictions compound to 75%; one may not");
    }

    /// @notice 🟡N8. A recoverable caller mistake surfaces instead of burning
    ///         the victims' compensation. `snapshotTimestamp == block.timestamp`
    ///         passes sWOOD's bound but fails the escrow's strictly-past one:
    ///         it must bubble, and the guardian's stake must be untouched so the
    ///         corrected call can still land.
    function test_carlos_N8_recoverableOpenCaseFailureBubblesInsteadOfBurning() public {
        address burnAddr = 0x000000000000000000000000000000000000dEaD;
        uint256 burnBefore = wood.balanceOf(burnAddr);
        uint256 stakeBefore = swood.guardianStake(g1);

        address[] memory approvers = new address[](1);
        approvers[0] = g1;
        uint256 now_ = vm.getBlockTimestamp();

        vm.expectRevert(ICompensationEscrow.SnapshotNotPast.selector);
        swood.slashToEscrow(bytes32("oops"), now_, approvers, _bpsArr(1, SLASH_BPS), address(vault), now_);

        assertEq(wood.balanceOf(burnAddr), burnBefore, "nothing burned on a fixable mistake");
        assertEq(swood.guardianStake(g1), stakeBefore, "the whole transaction rolled back");
        assertFalse(swood.verdictSlashed(bytes32("oops"), g1), "the dedup rolled back too, so the retry is clean");

        // The corrected call lands.
        (uint256 total, uint256 caseId) =
            swood.slashToEscrow(bytes32("oops"), openedAt, approvers, _bpsArr(1, SLASH_BPS), address(vault), snapTs);
        assertEq(total, PROCEEDS, "the retry recovered in full");
        assertGt(caseId, 0, "and opened a real case");
    }

    /// @dev `slashToEscrow` now takes one rate per approver. These suites all
    ///      exercise the uniform case, so this fills an aligned array with a
    ///      single rate — the per-approver spread is covered in
    ///      `SlashToEscrowProportional.t.sol`.
    function _bpsArr(uint256 n, uint256 bps) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = bps;
        }
    }
}
