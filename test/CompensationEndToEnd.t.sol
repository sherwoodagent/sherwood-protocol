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

/// @title CompensationEndToEndTest
/// @notice Task 5 — the whole v1b part-1 payout rail against REAL contracts:
///         a real UUPS `StakedWood` proxy with a real staked+matured guardian, a
///         real `CompensationEscrow`, and — the point of this suite — a REAL
///         `SyndicateVault` whose ERC20Votes checkpoints come from real LP
///         deposits.
///
/// @dev    Every other suite in this plan apportions against `MockVotesVault`,
///         which simply *declares* that `getPastVotes(h, t) == balanceOf(h)` at
///         `t`. That equality is decision D1's load-bearing assumption (the vault
///         auto-delegates on receipt, `src/SyndicateVault.sol:853`). Here it is
///         exercised rather than assumed: nobody calls `delegate`, the vault's
///         own `_deposit` hook does the auto-delegation, and the escrow reads the
///         checkpoints that hook produced.
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
    ///      the vault's `_deposit` hook auto-delegates the receiver to itself,
    ///      which is exactly the D1 behaviour under test.
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
        (total, caseId) =
            swood.slashToEscrow(bytes32("verdict-case"), openedAt, approvers, SLASH_BPS, address(vault), snapTs);
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

        (address v, uint256 ts, uint256 proceeds, uint256 redeemed,, bool swept) = escrow.caseOf(caseId);
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

        (,,, uint256 redeemedAfter,,) = escrow.caseOf(caseId);
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
}
