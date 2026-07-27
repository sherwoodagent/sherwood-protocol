# Guardian Economic Security — Plan C: Slash Rails + Compensation Escrow (v1b, part 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the retroactive-liability *payout* rails of the spec's v1b phase (`docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md` §3.8 + §4 "Authorized-slasher entrypoint"): a new authorized-slasher entrypoint on `StakedWood` that routes slash proceeds to a `CompensationEscrow` instead of the burn address, and snapshot-gated, non-transferable compensation claims that pay **pre-drain** shareholders.

**Architecture:** A new standalone `CompensationEscrow` (Ownable2Step, like `TierRegistry`/`ProposerBondEscrow`) holds WOOD slash proceeds per *case*. A case is `(vault, snapshotTimestamp, proceeds)`; holders redeem pro-rata against `SyndicateVault.getPastVotes(holder, snapshotTimestamp) / getPastTotalSupply(snapshotTimestamp)` — the ERC20Votes checkpoint the vault already maintains. Claims are a mapping, never a token, so they are non-transferable by construction. `StakedWood` gains an owner-settable `authorizedSlasher` role and a `slashToEscrow` entrypoint that reuses the existing per-approver slash legs (own stake, delegated at the `maxDelegatedSlashBps` cap, first-loss spill) but sends the total to the escrow rather than `_burnWood`.

**Tech Stack:** Solidity 0.8.28, Foundry (forge test/fmt), OpenZeppelin Ownable2Step / UUPS / SafeERC20. Repo conventions: custom errors, natspec with spec-section tags, tests in `test/*.t.sol`, storage goldens via `script/check-layout-goldens.sh`.

**Sequencing:** Plan A (PR #13) shipped execution-side bounds; Plan B (PR #22) completed v1a (coverage ledger, approve quorum, bonds). This is **v1b part 1**. Two follow-on plans complete v1b:
- **Plan D — challenge game (§3.4):** the five predicates, bonded filing, per-proposal coverage freeze, undisputed auto-slash after delay, disputed → parked for the court. It *calls* this plan's `slashToEscrow`. Split out because it is the largest single subsystem in the spec and is independently testable once the sink exists.
- **Plan E — approver premium (§3.10) + watchtower funding:** fee-economics, and gated on the §4 **blocking** ROE validation regardless of implementation order.

**Why this slice first:** it contains the F1 regression fix — the highest-value security property in v1b — and every other v1b component terminates in it. Building the sink before the trigger means Plan D has a real, tested target instead of a stub.

---

## Design decisions pinned before any code

**D1 — Claim basis is `getPastVotes`, not raw balance.** `SyndicateVault` is `ERC20VotesUpgradeable` and **auto-delegates on receipt** (`_delegate(to, to)` at `src/SyndicateVault.sol:852,1054,1082`), so for the overwhelming majority of holders `getPastVotes(h, t) == balanceOf(h)` at `t`. Solidity keeps no historical *balance* checkpoint to use instead, and adding one means a new checkpoint array on a live upgradeable vault.

**Accepted edge, must be documented in natspec:** a holder who *explicitly* delegated to a third party has its compensation credited to that delegate, not to itself. This is a real deviation from "pro-rata to shares held then." Accepted for v1b because (a) auto-delegation makes explicit delegation rare, (b) the delegate relationship is holder-chosen, and (c) the alternative is a storage addition to a live vault. **Revisit if vault-share delegation becomes common.**

**D2 — Snapshot timestamp is supplied by the slasher, not derived.** Per §3.8 the correct block differs by predicate: for predicates 1–4 (and predicate 5 on a short strategy) it is the block before the drain proposal executed; for a per-epoch drawdown conviction it is the epoch-N opening checkpoint block. The escrow cannot know which, so `openCase` takes it as a parameter and the *caller* (Plan D's challenge game) chooses it. The escrow enforces only that it is in the past.

**D3 — Payout is WOOD** (§3.8 "WOOD-only payout boundary"). Victims are made whole in WOOD valued at slash time, which is exactly why §3.7's covered-TVL cap must bind. No conversion is attempted here.

**D4 — `refundSlash` must NOT reach this path** (§4). The registry's existing 20%/epoch appeal reserve stays bound to the *block-quorum review* slash. A verdict slash is proven malice and is not refundable. This plan adds no refund path and must not touch `GuardianRegistry.refundSlash`.

**D5 — Escrow is not upgradeable.** Like `TierRegistry`/`ProposerBondEscrow`, it is a plain `Ownable2Step` deploy, so its storage layout is unconstrained. `StakedWood` **is** UUPS and live: its additions are append-only, carved from `uint256[9] private __gap` (`src/StakedWood.sol:326`).

**Invariant (spec §4 requires one per new accounting path, with a fuzz test):** the escrow's WOOD balance is always at least the sum over open cases of `(proceeds − redeemed)`.

---

### Task 1: CompensationEscrow — case funding

**Files:**
- Create: `src/CompensationEscrow.sol`
- Create: `src/interfaces/ICompensationEscrow.sol`
- Create: `test/CompensationEscrow.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CompensationEscrow} from "src/CompensationEscrow.sol";
import {ICompensationEscrow} from "src/interfaces/ICompensationEscrow.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @dev Vault stand-in exposing the ERC20Votes reads the escrow apportions
///      against. Mirrors SyndicateVault's auto-delegated behaviour, where
///      `getPastVotes(h, t)` equals that holder's share balance at `t`.
contract MockVotesVault {
    mapping(address => mapping(uint256 => uint256)) public votesAt;
    mapping(uint256 => uint256) public totalAt;

    function setVotes(address holder, uint256 ts, uint256 v) external {
        votesAt[holder][ts] = v;
    }

    function setTotal(uint256 ts, uint256 v) external {
        totalAt[ts] = v;
    }

    function getPastVotes(address holder, uint256 ts) external view returns (uint256) {
        return votesAt[holder][ts];
    }

    function getPastTotalSupply(uint256 ts) external view returns (uint256) {
        return totalAt[ts];
    }
}

contract CompensationEscrowTest is Test {
    CompensationEscrow internal escrow;
    ERC20Mock internal wood;
    MockVotesVault internal vault;

    address internal owner = makeAddr("owner");
    address internal slasher = makeAddr("slasher");
    address internal backstop = makeAddr("backstop");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal snapTs;

    function setUp() public {
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        vault = new MockVotesVault();
        escrow = new CompensationEscrow(owner, address(wood));
        vm.startPrank(owner);
        escrow.setAuthorizedFunder(slasher);
        escrow.setBackstop(backstop);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 30 days);
        snapTs = vm.getBlockTimestamp() - 1 days; // a past block

        // Alice 70%, Bob 30% of a 1,000-share supply at the snapshot.
        vault.setTotal(snapTs, 1_000e18);
        vault.setVotes(alice, snapTs, 700e18);
        vault.setVotes(bob, snapTs, 300e18);

        wood.mint(slasher, 1_000_000e18);
        vm.prank(slasher);
        wood.approve(address(escrow), type(uint256).max);
    }

    function test_openCase_pullsProceedsAndRecords() public {
        vm.prank(slasher);
        uint256 caseId = escrow.openCase(address(vault), snapTs, 10_000e18);

        assertEq(wood.balanceOf(address(escrow)), 10_000e18);
        (address v, uint256 ts, uint256 proceeds, uint256 redeemed,) = escrow.caseOf(caseId);
        assertEq(v, address(vault));
        assertEq(ts, snapTs);
        assertEq(proceeds, 10_000e18);
        assertEq(redeemed, 0);
    }

    function test_openCase_onlyAuthorizedFunder() public {
        vm.expectRevert(ICompensationEscrow.NotAuthorizedFunder.selector);
        escrow.openCase(address(vault), snapTs, 10_000e18);
    }

    function test_openCase_rejectsFutureSnapshot() public {
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.SnapshotNotPast.selector);
        escrow.openCase(address(vault), vm.getBlockTimestamp(), 10_000e18);
    }

    function test_openCase_rejectsZeroProceeds() public {
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.NothingToCompensate.selector);
        escrow.openCase(address(vault), snapTs, 0);
    }

    /// @notice A snapshot with no supply can apportion nothing — reject it at
    ///         open rather than stranding WOOD in a case nobody can redeem.
    function test_openCase_rejectsEmptySnapshotSupply() public {
        uint256 emptyTs = snapTs - 1; // never populated
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.EmptySnapshot.selector);
        escrow.openCase(address(vault), emptyTs, 10_000e18);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract CompensationEscrowTest -vv`
Expected: compilation failure — `src/CompensationEscrow.sol` not found.

- [ ] **Step 3: Write the interface**

`src/interfaces/ICompensationEscrow.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICompensationEscrow
/// @notice Snapshot-gated victim compensation for the guardian
///         economic-security model (spec 2026-07-22 §3.8). Slash proceeds fund
///         per-case claims payable ONLY to holders of record at a pre-drain
///         snapshot, so a coalition that drains and then accumulates shares
///         from exiting holders recoups nothing (finding F1).
interface ICompensationEscrow {
    error NotAuthorizedFunder();
    error SnapshotNotPast();
    error NothingToCompensate();
    error EmptySnapshot();
    error NoClaim();
    error AlreadyRedeemed();
    error ResidueWindowOpen();
    error CaseNotFound();
    error InvalidWindow();
    error ZeroAddress();

    event CaseOpened(
        uint256 indexed caseId, address indexed vault, uint256 indexed snapshotTimestamp, uint256 proceeds
    );
    event ClaimRedeemed(uint256 indexed caseId, address indexed holder, uint256 amount);
    event ResidueSwept(uint256 indexed caseId, address indexed backstop, uint256 amount);
    event AuthorizedFunderSet(address indexed oldFunder, address indexed newFunder);
    event BackstopSet(address indexed oldBackstop, address indexed newBackstop);
    event ResidueWindowSet(uint256 oldWindow, uint256 newWindow);

    function openCase(address vault, uint256 snapshotTimestamp, uint256 proceeds) external returns (uint256 caseId);
    function redeem(uint256 caseId) external returns (uint256 amount);
    function sweepResidue(uint256 caseId) external returns (uint256 amount);

    function claimable(uint256 caseId, address holder) external view returns (uint256);
    function caseOf(uint256 caseId)
        external
        view
        returns (address vault, uint256 snapshotTimestamp, uint256 proceeds, uint256 redeemed, uint256 openedAt);
    function totalEscrowed() external view returns (uint256);

    function setAuthorizedFunder(address funder) external;
    function setBackstop(address backstop) external;
    function setResidueWindow(uint256 window) external;
}
```

- [ ] **Step 4: Write the minimal implementation**

`src/CompensationEscrow.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICompensationEscrow} from "./interfaces/ICompensationEscrow.sol";

/// @dev The ERC20Votes read surface the escrow apportions against. Narrow by
///      design (mirrors the IGovernorMinimal pattern) — the escrow never needs
///      the full vault ABI.
interface IVaultVotesMinimal {
    function getPastVotes(address holder, uint256 timestamp) external view returns (uint256);
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256);
}

/**
 * @title CompensationEscrow
 * @notice Victim compensation for a passed challenge (spec 2026-07-22 §3.8).
 *
 *         Slash proceeds do NOT go to the vault's live ERC4626 balance.
 *         `totalAssets` is pro-rata and share transfers are ungated, so paying
 *         the live NAV would let a coalition drain, buy the depressed shares of
 *         exiting honest holders, and recoup its own slash — a recoupment
 *         channel the burn sink never had (finding F1). Instead each conviction
 *         opens a CASE pinned to a pre-drain snapshot, and only holders of
 *         record AT THAT SNAPSHOT can redeem.
 *
 *         Claims are entries in a mapping, never a token: there is no transfer
 *         surface, so a claim cannot be bought from an exiting honest holder.
 *
 * @dev    PAYOUT IS WOOD (§3.8 "WOOD-only payout boundary"): a victim is made
 *         whole in WOOD valued at slash time, which is exactly why §3.7's
 *         covered-TVL cap must bind — it keeps recoverable dollars
 *         proportionate to dollars at risk. v2 multi-collateral pays partly in
 *         stable legs.
 *
 * @dev    CLAIM BASIS (accepted edge, decision D1): apportionment uses the
 *         vault's ERC20Votes checkpoints, not raw balances — Solidity keeps no
 *         historical balance. `SyndicateVault` auto-delegates on receipt, so
 *         `getPastVotes(h, t)` equals h's balance for any holder that never
 *         delegated away. A holder that DID explicitly delegate has its
 *         compensation credited to the delegate instead. Accepted for v1b;
 *         revisit if vault-share delegation becomes common.
 *
 * @dev    Not upgradeable, and not refundable: the registry's `refundSlash`
 *         appeal reserve stays bound to the block-quorum review slash, because
 *         a verdict slash is proven malice (spec §4).
 */
contract CompensationEscrow is Ownable2Step, ICompensationEscrow {
    using SafeERC20 for IERC20;

    struct Case {
        address vault;
        uint256 snapshotTimestamp;
        uint256 proceeds;
        uint256 redeemed;
        uint256 openedAt;
        uint256 snapshotSupply; // cached: a past snapshot cannot change
        bool swept; // residue returned to the backstop; claims are closed
    }

    IERC20 public immutable wood;

    /// @notice The only address permitted to fund cases. In v1b this is
    ///         `StakedWood` (whose `slashToEscrow` opens the case); Plan D's
    ///         challenge game drives that entrypoint.
    address public authorizedFunder;

    /// @notice Where unredeemed residue goes once the window closes — the
    ///         protocol insurance backstop, NEVER the live vault NAV (§3.8).
    address public backstop;

    /// @notice How long holders have to redeem before residue may be swept.
    uint256 public residueWindow = 180 days;

    /// @notice Sum over cases of (proceeds - redeemed - swept). The escrow's
    ///         WOOD balance must never fall below this (fuzz invariant, Task 2).
    uint256 public totalEscrowed;

    uint256 public caseCount;
    mapping(uint256 caseId => Case) internal _cases;
    mapping(uint256 caseId => mapping(address holder => bool)) internal _redeemed;

    constructor(address initialOwner, address wood_) Ownable(initialOwner) {
        if (wood_ == address(0)) revert ZeroAddress();
        wood = IERC20(wood_);
    }

    modifier onlyFunder() {
        if (msg.sender != authorizedFunder) revert NotAuthorizedFunder();
        _;
    }

    /// @inheritdoc ICompensationEscrow
    /// @dev The snapshot timestamp is chosen by the CALLER, not derived here
    ///      (decision D2): §3.8 uses the block before the drain proposal
    ///      executed for predicates 1-4, but the epoch-N opening checkpoint for
    ///      a per-epoch drawdown conviction. Only "is it in the past" is
    ///      enforceable at this layer.
    function openCase(address vault, uint256 snapshotTimestamp, uint256 proceeds)
        external
        onlyFunder
        returns (uint256 caseId)
    {
        if (vault == address(0)) revert ZeroAddress();
        if (snapshotTimestamp >= block.timestamp) revert SnapshotNotPast();
        if (proceeds == 0) revert NothingToCompensate();
        uint256 supply = IVaultVotesMinimal(vault).getPastTotalSupply(snapshotTimestamp);
        // A zero-supply snapshot apportions nothing: reject at open rather than
        // accept WOOD into a case no one can ever redeem.
        if (supply == 0) revert EmptySnapshot();

        caseId = ++caseCount;
        _cases[caseId] = Case({
            vault: vault,
            snapshotTimestamp: snapshotTimestamp,
            proceeds: proceeds,
            redeemed: 0,
            openedAt: block.timestamp,
            snapshotSupply: supply,
            swept: false
        });
        totalEscrowed += proceeds;
        wood.safeTransferFrom(msg.sender, address(this), proceeds);
        emit CaseOpened(caseId, vault, snapshotTimestamp, proceeds);
    }

    /// @inheritdoc ICompensationEscrow
    function caseOf(uint256 caseId)
        external
        view
        returns (address vault, uint256 snapshotTimestamp, uint256 proceeds, uint256 redeemed, uint256 openedAt)
    {
        Case storage c = _cases[caseId];
        return (c.vault, c.snapshotTimestamp, c.proceeds, c.redeemed, c.openedAt);
    }

    // `claimable`, `redeem` and `sweepResidue` land in Tasks 2 and 3. Reverting
    // stubs so this task compiles and its tests go green first.

    function claimable(uint256, address) public view virtual returns (uint256) {
        revert NoClaim();
    }

    function redeem(uint256) external virtual returns (uint256) {
        revert NoClaim();
    }

    function sweepResidue(uint256) external virtual returns (uint256) {
        revert ResidueWindowOpen();
    }

    // ── Owner setters ──

    function setAuthorizedFunder(address funder) external onlyOwner {
        if (funder == address(0)) revert ZeroAddress();
        emit AuthorizedFunderSet(authorizedFunder, funder);
        authorizedFunder = funder;
    }

    function setBackstop(address backstop_) external onlyOwner {
        if (backstop_ == address(0)) revert ZeroAddress();
        emit BackstopSet(backstop, backstop_);
        backstop = backstop_;
    }

    function setResidueWindow(uint256 window) external onlyOwner {
        // Bounded: a zero window would let residue be swept before holders can
        // realistically redeem; beyond a year the backstop never recovers dust.
        if (window < 30 days || window > 365 days) revert InvalidWindow();
        emit ResidueWindowSet(residueWindow, window);
        residueWindow = window;
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `forge test --match-contract CompensationEscrowTest -vv`
Expected: 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add src/CompensationEscrow.sol src/interfaces/ICompensationEscrow.sol test/CompensationEscrow.t.sol
git commit -m "feat(escrow): CompensationEscrow case funding — snapshot-gated victim payout (spec 3.8)"
```

---

### Task 2: Pro-rata claims and redemption

**Files:**
- Modify: `src/CompensationEscrow.sol`
- Test: `test/CompensationEscrow.t.sol` (append)

- [ ] **Step 1: Write the failing tests**

```solidity
// ── append inside CompensationEscrowTest ──

function _open(uint256 proceeds) internal returns (uint256) {
    vm.prank(slasher);
    return escrow.openCase(address(vault), snapTs, proceeds);
}

function test_claimable_isProRataAtSnapshot() public {
    uint256 caseId = _open(10_000e18);
    assertEq(escrow.claimable(caseId, alice), 7_000e18); // 70%
    assertEq(escrow.claimable(caseId, bob), 3_000e18); // 30%
}

function test_redeem_paysHolderAndMarksRedeemed() public {
    uint256 caseId = _open(10_000e18);
    vm.prank(alice);
    uint256 got = escrow.redeem(caseId);
    assertEq(got, 7_000e18);
    assertEq(wood.balanceOf(alice), 7_000e18);
    assertEq(escrow.claimable(caseId, alice), 0, "claim consumed");
    assertEq(escrow.totalEscrowed(), 3_000e18, "only bob's share still owed");
}

function test_redeem_twiceReverts() public {
    uint256 caseId = _open(10_000e18);
    vm.prank(alice);
    escrow.redeem(caseId);
    vm.prank(alice);
    vm.expectRevert(ICompensationEscrow.AlreadyRedeemed.selector);
    escrow.redeem(caseId);
}

function test_redeem_nonHolderReverts() public {
    uint256 caseId = _open(10_000e18);
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(ICompensationEscrow.NoClaim.selector);
    escrow.redeem(caseId);
}

/// @notice THE F1 PROPERTY. A coalition that drains, lets honest holders exit
///         at the depressed NAV, and accumulates their shares AFTERWARDS gets
///         nothing: the claim is pinned to the pre-drain snapshot, where the
///         coalition held zero. Paying the live NAV instead would have refunded
///         the attacker its own slash.
function test_postDrainAccumulatorGetsNothing() public {
    address coalition = makeAddr("coalition");
    // Coalition held NOTHING at the snapshot...
    vault.setVotes(coalition, snapTs, 0);
    uint256 caseId = _open(10_000e18);

    // ...and buys up the whole supply afterwards (a LATER timestamp).
    uint256 nowTs = vm.getBlockTimestamp();
    vault.setTotal(nowTs, 1_000e18);
    vault.setVotes(coalition, nowTs, 1_000e18);

    assertEq(escrow.claimable(caseId, coalition), 0, "no pre-drain claim");
    vm.prank(coalition);
    vm.expectRevert(ICompensationEscrow.NoClaim.selector);
    escrow.redeem(caseId);

    // The pre-drain holders still hold the entire entitlement.
    assertEq(escrow.claimable(caseId, alice) + escrow.claimable(caseId, bob), 10_000e18);
}

/// @notice Claims are a mapping, not a token — there is no transfer surface, so
///         a claim cannot be bought from an exiting honest holder.
function test_claimsHaveNoTransferSurface() public {
    uint256 caseId = _open(10_000e18);
    (bool ok,) =
        address(escrow).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, caseId));
    assertFalse(ok, "escrow must expose no claim-transfer surface");
}

/// Fuzz the stated invariant: escrow WOOD balance >= sum of unredeemed claims.
function testFuzz_balanceCoversOutstanding(uint96 p, bool aliceRedeems, bool bobRedeems) public {
    uint256 proceeds = uint256(p) % 1_000_000e18 + 1e18;
    uint256 caseId = _open(proceeds);
    if (aliceRedeems) {
        vm.prank(alice);
        escrow.redeem(caseId);
    }
    if (bobRedeems) {
        vm.prank(bob);
        escrow.redeem(caseId);
    }
    assertGe(wood.balanceOf(address(escrow)), escrow.totalEscrowed());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract CompensationEscrowTest -vv`
Expected: the new tests FAIL — `claimable`/`redeem` are reverting stubs.

- [ ] **Step 3: Implement** — replace the `claimable` and `redeem` stubs in `src/CompensationEscrow.sol` (drop their `virtual`):

```solidity
    /// @inheritdoc ICompensationEscrow
    /// @dev Pro-rata against the snapshot: `proceeds * votes(h, snap) / supply(snap)`.
    ///      Returns 0 once redeemed or swept, so one call serves both
    ///      "what am I owed" and "what is left". Rounds DOWN, so the sum of
    ///      claims can never exceed `proceeds`; the dust stays in the case and
    ///      leaves with the residue.
    function claimable(uint256 caseId, address holder) public view returns (uint256) {
        Case storage c = _cases[caseId];
        if (c.proceeds == 0) return 0;
        if (c.swept) return 0; // residue returned to the backstop; claims closed
        if (_redeemed[caseId][holder]) return 0;
        uint256 votes = IVaultVotesMinimal(c.vault).getPastVotes(holder, c.snapshotTimestamp);
        if (votes == 0) return 0;
        return (c.proceeds * votes) / c.snapshotSupply;
    }

    /// @inheritdoc ICompensationEscrow
    /// @dev Pull-based: each holder redeems its own claim. Effects before
    ///      interaction — the per-holder flag is set BEFORE the transfer, so a
    ///      hooked WOOD cannot re-enter for a second payout.
    function redeem(uint256 caseId) external returns (uint256 amount) {
        Case storage c = _cases[caseId];
        if (c.proceeds == 0) revert CaseNotFound();
        if (_redeemed[caseId][msg.sender]) revert AlreadyRedeemed();
        amount = claimable(caseId, msg.sender);
        if (amount == 0) revert NoClaim();

        _redeemed[caseId][msg.sender] = true;
        c.redeemed += amount;
        totalEscrowed -= amount;
        wood.safeTransfer(msg.sender, amount);
        emit ClaimRedeemed(caseId, msg.sender, amount);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CompensationEscrowTest -vv`
Expected: all PASS, including the fuzz.

- [ ] **Step 5: Commit**

```bash
git add src/CompensationEscrow.sol test/CompensationEscrow.t.sol
git commit -m "feat(escrow): pro-rata snapshot claims + pull redemption (closes the F1 recoupment channel)"
```

---

### Task 3: Residue sweep to the backstop

**Files:**
- Modify: `src/CompensationEscrow.sol`
- Test: `test/CompensationEscrow.t.sol` (append)

- [ ] **Step 1: Write the failing tests**

```solidity
// ── append inside CompensationEscrowTest ──

function test_sweepResidue_beforeWindowReverts() public {
    uint256 caseId = _open(10_000e18);
    vm.expectRevert(ICompensationEscrow.ResidueWindowOpen.selector);
    escrow.sweepResidue(caseId);
}

function test_sweepResidue_afterWindowPaysBackstop() public {
    uint256 caseId = _open(10_000e18);
    vm.prank(alice);
    escrow.redeem(caseId); // 7,000 claimed; 3,000 left unredeemed

    vm.warp(vm.getBlockTimestamp() + 180 days + 1);
    uint256 swept = escrow.sweepResidue(caseId);

    assertEq(swept, 3_000e18);
    assertEq(wood.balanceOf(backstop), 3_000e18, "residue goes to the backstop, never live NAV");
    assertEq(escrow.totalEscrowed(), 0);
}

function test_sweepResidue_isPermissionlessAndOnce() public {
    uint256 caseId = _open(10_000e18);
    vm.warp(vm.getBlockTimestamp() + 180 days + 1);
    vm.prank(makeAddr("keeper")); // anyone may trigger it; funds go to the backstop
    escrow.sweepResidue(caseId);
    vm.expectRevert(ICompensationEscrow.NothingToCompensate.selector);
    escrow.sweepResidue(caseId);
}

/// @notice A holder that sat on its claim past the window loses it — the sweep
///         is what bounds the escrow's liability, so redemption must fail after.
function test_redeem_afterSweepReverts() public {
    uint256 caseId = _open(10_000e18);
    vm.warp(vm.getBlockTimestamp() + 180 days + 1);
    escrow.sweepResidue(caseId);
    vm.prank(alice);
    vm.expectRevert(ICompensationEscrow.NoClaim.selector);
    escrow.redeem(caseId);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract CompensationEscrowTest -vv`
Expected: the new tests FAIL — `sweepResidue` is a reverting stub.

- [ ] **Step 3: Implement** — replace the `sweepResidue` stub (drop `virtual`):

```solidity
    /// @inheritdoc ICompensationEscrow
    /// @dev Permissionless: the destination is the owner-set backstop, so an
    ///      arbitrary caller can only accelerate a fixed transfer, never
    ///      redirect it. Residue goes to the protocol insurance backstop and
    ///      NEVER to the vault's live NAV — paying live NAV is precisely the F1
    ///      recoupment channel this contract exists to close (§3.8).
    function sweepResidue(uint256 caseId) external returns (uint256 amount) {
        Case storage c = _cases[caseId];
        if (c.proceeds == 0) revert CaseNotFound();
        if (block.timestamp < c.openedAt + residueWindow) revert ResidueWindowOpen();
        if (c.swept) revert NothingToCompensate();
        amount = c.proceeds - c.redeemed;
        if (amount == 0) revert NothingToCompensate();

        c.swept = true;
        totalEscrowed -= amount;
        wood.safeTransfer(backstop, amount);
        emit ResidueSwept(caseId, backstop, amount);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract CompensationEscrowTest -vv`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/CompensationEscrow.sol test/CompensationEscrow.t.sol
git commit -m "feat(escrow): residue sweep to protocol backstop after the redemption window"
```

---

### Task 4: StakedWood — authorized-slasher entrypoint

**Files:**
- Modify: `src/StakedWood.sol`
- Modify: `src/interfaces/IStakedWood.sol`
- Create: `test/StakedWoodSlashToEscrow.t.sol`

**STORAGE (critical):** `StakedWood` is UUPS and live. Append `authorizedSlasher` immediately BEFORE `uint256[9] private __gap;` (`src/StakedWood.sol:326`) and decrement the gap `9 → 8`. Do not reorder any existing field. The golden check in Task 6 verifies this.

**Signature note (read before writing):** the escrow needs the VAULT whose holders are compensated, and a `caseKey` alone cannot yield it. Do **not** invent a lookup — `slashToEscrow` takes an explicit `vault` parameter, supplied by the caller (Plan D's challenge game knows the challenged proposal's vault).

- [ ] **Step 1: Write the failing tests**

Model the fixture on the existing StakedWood suite — locate it with `ls test/ | grep -i staked` and copy its setUp (real sWOOD proxy, WOOD token, a staked and matured guardian `g1`, the registry address it authorizes). Add a real `CompensationEscrow` with sWOOD as its `authorizedFunder`, and a `MockVotesVault`-style vault with a populated snapshot (copy `MockVotesVault` from `test/CompensationEscrow.t.sol`). The assertions:

```solidity
function test_setAuthorizedSlasher_onlyOwner() public {
    vm.expectRevert(); // Ownable: caller is not the owner
    swood.setAuthorizedSlasher(makeAddr("rogue"));
}

function test_slashToEscrow_onlySlasher() public {
    address[] memory gs = new address[](1);
    gs[0] = g1;
    vm.expectRevert(IStakedWood.NotAuthorizedSlasher.selector);
    swood.slashToEscrow(bytes32("case"), openedAt, gs, 10_000, address(escrow), address(vault), snapTs);
}

function test_slashToEscrow_routesProceedsToEscrowNotBurn() public {
    vm.prank(owner);
    swood.setAuthorizedSlasher(slasher);

    uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
    address[] memory gs = new address[](1);
    gs[0] = g1;

    vm.prank(slasher);
    uint256 total = swood.slashToEscrow(bytes32("case"), openedAt, gs, 10_000, address(escrow), address(vault), snapTs);

    assertGt(total, 0, "something was actually slashed");
    assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore, "verdict slash must NOT burn");
    assertEq(wood.balanceOf(address(escrow)), total, "proceeds land in the escrow");
    (address v, uint256 ts, uint256 proceeds,,) = escrow.caseOf(1);
    assertEq(v, address(vault));
    assertEq(ts, snapTs);
    assertEq(proceeds, total, "the whole slash funds the case");
}

/// @notice The review path is untouched: it still burns and still runs through
///         `onlyRegistry`. The two slash paths stay distinct so the registry's
///         refund reserve can never refund a verdict (spec §4, decision D4).
function test_reviewPathStillBurns() public {
    uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
    address[] memory gs = new address[](1);
    gs[0] = g1;
    vm.prank(address(registry));
    uint256 total = swood.slashGuardians(bytes32("review"), openedAt, gs, 10_000);
    assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + total, "review slash still burns");
}

/// @notice A verdict against approvers with nothing left to slash is a no-op,
///         not a zero-proceeds case the escrow would reject.
function test_slashToEscrow_zeroTotalOpensNoCase() public {
    vm.prank(owner);
    swood.setAuthorizedSlasher(slasher);
    address[] memory gs = new address[](1);
    gs[0] = makeAddr("neverStaked");
    vm.prank(slasher);
    uint256 total = swood.slashToEscrow(bytes32("c"), openedAt, gs, 10_000, address(escrow), address(vault), snapTs);
    assertEq(total, 0);
    assertEq(escrow.caseCount(), 0, "no empty case opened");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract StakedWoodSlashToEscrowTest -vv`
Expected: compilation failure — `setAuthorizedSlasher` / `slashToEscrow` / `NotAuthorizedSlasher` missing.

- [ ] **Step 3: Implement**

In `src/interfaces/IStakedWood.sol` add:

```solidity
    /// @notice Reverts when a non-slasher calls the verdict slash path.
    error NotAuthorizedSlasher();

    event AuthorizedSlasherSet(address indexed slasher);

    /// @notice Verdict-driven slash whose proceeds fund victim compensation
    ///         instead of burning (spec §3.8 + §4 authorized-slasher entrypoint).
    function slashToEscrow(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256 slashBps,
        address escrow,
        address vault,
        uint256 snapshotTimestamp
    ) external returns (uint256 total);

    function setAuthorizedSlasher(address slasher) external;
    function authorizedSlasher() external view returns (address);
```

In `src/StakedWood.sol`, import the escrow interface and replace the gap declaration:

```solidity
import {ICompensationEscrow} from "./interfaces/ICompensationEscrow.sol";
```

```solidity
    /// @notice The one address permitted to drive the VERDICT slash path
    ///         (`slashToEscrow`). Deliberately distinct from `onlyRegistry`,
    ///         which drives the block-quorum review slash: the paths must stay
    ///         separate so the registry's `refundSlash` reserve can never refund
    ///         a proven-malice verdict (spec §4). Set to Plan D's challenge game
    ///         once it exists; owner-set meanwhile, which means a verdict is a
    ///         governance action until then — state that in the PR.
    address public authorizedSlasher;

    /// @dev Reserved storage for future upgrades (was 9; -1 authorizedSlasher).
    uint256[8] private __gap;
```

Add the modifier beside `onlyRegistry`:

```solidity
    modifier onlyAuthorizedSlasher() {
        if (msg.sender != authorizedSlasher) revert NotAuthorizedSlasher();
        _;
    }
```

Add the setter beside the other owner setters:

```solidity
    /// @inheritdoc IStakedWood
    function setAuthorizedSlasher(address slasher) external onlyOwner {
        authorizedSlasher = slasher;
        emit AuthorizedSlasherSet(slasher);
    }
```

Add the entrypoint beside `slashGuardians`:

```solidity
    /// @inheritdoc IStakedWood
    /// @dev Reuses the SAME per-approver legs as the review path (`_slashOne`:
    ///      own stake at `slashBps`, delegated pools at
    ///      `min(slashBps, maxDelegatedSlashBps)`, uncovered remainder spilling
    ///      onto own stake as first loss) — only the SINK differs. Proceeds are
    ///      approved to the escrow and booked as a compensation case pinned to
    ///      `snapshotTimestamp`, so pre-drain holders redeem them (§3.8) instead
    ///      of the WOOD burning.
    /// @param vault The vault whose pre-drain holders are compensated. Supplied
    ///        by the caller because a `caseKey` cannot yield it.
    /// @param snapshotTimestamp The pre-drain snapshot the escrow apportions
    ///        against. Chosen by the CALLER (§3.8): the block before the drain
    ///        proposal executed for predicates 1-4, the epoch-N opening
    ///        checkpoint for a per-epoch drawdown conviction.
    function slashToEscrow(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256 slashBps,
        address escrow,
        address vault,
        uint256 snapshotTimestamp
    ) external onlyAuthorizedSlasher returns (uint256 total) {
        for (uint256 i = 0; i < approvers.length; i++) {
            total += _slashOne(caseKey, openedAt, approvers[i], slashBps);
        }
        // Nothing recovered: no case to open (the escrow rejects zero proceeds).
        if (total == 0) return 0;
        _totalStakeCheckpoint.push(uint32(block.timestamp), uint224(totalGuardianStake));
        // Effects are complete; hand the proceeds over and open the case.
        IERC20(wood).approve(escrow, total);
        ICompensationEscrow(escrow).openCase(vault, snapshotTimestamp, total);
    }
```

- [ ] **Step 4: Run tests**

Run: `forge test --match-contract "StakedWoodSlashToEscrow|StakedWood" -vv`
Expected: new suite PASS; every pre-existing StakedWood suite still PASS (the review path is untouched).

- [ ] **Step 5: Commit**

```bash
git add src/StakedWood.sol src/interfaces/IStakedWood.sol test/StakedWoodSlashToEscrow.t.sol
git commit -m "feat(swood): authorized-slasher entrypoint routing proceeds to the compensation escrow (spec 4/3.8)"
```

---

### Task 5: End-to-end — real slash, real vault, victim redeems

**Files:**
- Create: `test/CompensationEndToEnd.t.sol`

- [ ] **Step 1: Write the tests**

Build a REAL fixture — model it on `test/CoverageEndToEnd.t.sol`, which already wires a real `StakedWood` proxy, real `GuardianRegistry`, real `SyndicateVault` and real LP deposits. Add a real `CompensationEscrow` with sWOOD set as `authorizedFunder`, and set the test contract as sWOOD's `authorizedSlasher`. Two LPs deposit BEFORE the snapshot so the vault's own ERC20Votes checkpoints carry the 70/30 split; a third address deposits AFTER.

Three tests, all substantive — no mock vault, so the D1 auto-delegation assumption is exercised for real:

1. `test_verdictSlash_compensatesPreDrainHolders` — record `snapTs` with LP1 at 70% / LP2 at 30% (assert the split via `vault.getPastVotes` first, so the fixture is proven before the behaviour); warp; `slashToEscrow` against the staked guardian; assert the escrow holds exactly the slashed WOOD, `claimable` splits 70/30, and both LPs redeem for the full proceeds.
2. `test_verdictSlash_postDrainBuyerGetsNothing` — the third address deposits AFTER `snapTs` (a real deposit, so real checkpoints move); assert its `claimable` is 0 and `redeem` reverts `NoClaim`, while the pre-drain LPs' entitlements are unchanged. This is the F1 property against the REAL vault, not a mock.
3. `test_verdictSlash_doesNotTouchLiveNav` — record `vault.totalAssets()` before the slash and after both redemptions; assert it is unchanged. Compensation must never inflate live NAV, which is the exact channel §3.8 closes.

- [ ] **Step 2: Run**

Run: `forge test --match-contract CompensationEndToEnd -vv`
Expected: 3 PASS.

- [ ] **Step 3: Commit**

```bash
git add test/CompensationEndToEnd.t.sol
git commit -m "test: end-to-end verdict slash -> snapshot compensation against a real vault"
```

---

### Task 6: Goldens, full suite, docs, PR

- [ ] **Step 1: Pin StakedWood's layout and regenerate**

`StakedWood` gained a slot and is UUPS + live — exactly the class this guard exists for, but it is not yet pinned. Add to `script/check-layout-goldens.sh`, beside the other three:

```bash
check_contract StakedWood script/staked-wood-layout.golden.json
```

Update the script's header comment to name four contracts and the final "OK" echo to match. Then run `./script/check-layout-goldens.sh --update-golden`.

**Before committing, inspect `git diff` on every golden and confirm each pre-existing slot is unchanged** — only `authorizedSlasher` and a shrunken `__gap` may appear in the StakedWood golden. If any existing slot moved, STOP and surface it rather than regenerating over it.

- [ ] **Step 2: Full suite**

Run: `forge test`
Expected: no NEW failures. The known pre-existing baseline is 22 — 21 fork tests needing `--fork-url` (`SimulateExecution.t.sol` documents this in its own header) and 1 in `test/audit-fixes/SetGuardianRegistry.t.sol` (`MockRegistryMinimal.factory()` reverts `NotImplemented`, read by the factory's alignment check as `RegistryFactoryMismatch`).

- [ ] **Step 3: Format**

Run: `forge fmt && forge fmt --check`
(This repo has no CI workflows, so local forge is the only reference.)

- [ ] **Step 4: Update the spec status header**

In `docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md`, extend the implementation-status paragraph: **v1b part 1** (authorized-slasher entrypoint + compensation escrow) complete; the challenge game (§3.4) and approver premium (§3.10) still outstanding, and until the challenge game lands `authorizedSlasher` is an owner-set address, so a verdict is a governance action rather than an adjudicated one.

- [ ] **Step 5: Commit, push, PR**

```bash
git add -A && git commit -m "docs: v1b part 1 status; pin StakedWood layout"
git push -u origin feat/guardian-econ-security-c
```

PR body must state: what landed (escrow + slasher entrypoint), the F1 property it closes, decisions D1–D5 (especially D1's delegation edge and the fact that a verdict is governance-driven until Plan D), and what is explicitly NOT here (challenge game → Plan D; approver premium + watchtower → Plan E; two-layer court → v1c).

---

## Self-review checklist

1. **Spec coverage:** §3.8 compensation escrow → Tasks 1–3, 5. §3.8 snapshot-block rule → decision D2 + the `snapshotTimestamp` parameter. §3.8 WOOD-only payout boundary → D3, in natspec. §4 authorized-slasher entrypoint → Task 4. §4 "every new accounting path carries an invariant + fuzz test" → Task 2's `testFuzz_balanceCoversOutstanding`. §4 `refundSlash` stays on the review path → D4 + Task 4's `test_reviewPathStillBurns`.
2. **Deliberately NOT in this plan (state in the PR):** the challenge game (§3.4) that will *call* `slashToEscrow` — Plan D; the approver premium (§3.10) and watchtower funding — Plan E; the two-layer court (§3.5) — v1c. Until Plan D lands, `authorizedSlasher` is owner-set, so a verdict is a governance action, not an adjudicated one. Say it plainly rather than implying the court exists.
3. **Known gaps carried forward:** D1's delegation edge (compensation follows delegated votes, not raw balances); residue is lost to holders after `residueWindow` by design; a case whose vault had zero supply at the snapshot is rejected rather than parked.
4. **Type consistency:** `openCase(address vault, uint256 snapshotTimestamp, uint256 proceeds) returns (uint256 caseId)` is identical in Tasks 1, 2, 4, 5. `slashToEscrow(bytes32, uint256, address[], uint256, address escrow, address vault, uint256 snapshotTimestamp)` carries the explicit `vault` parameter in the interface, the implementation AND every test. `claimable(uint256, address)` and `redeem(uint256)` agree across Tasks 2, 3, 5.

---

## Post-implementation amendments (2026-07-25, from code review)

The shipped code intentionally diverges from the task snippets above. Review found a **critical fund-mixing bug** and several hardening gaps; the fixes landed in `e7fcc24` and this section is the record of record where they disagree with the tasks:

1. **Per-case fund isolation (critical).** `claimable` caps at the case's own remaining balance: `min(proceeds * votes / snapshotSupply, proceeds - redeemed)`. Without the cap a `vault` reporting votes > its own supply let one case pay out of a sibling case's funds — demonstrated as a 1-WOOD case paying 50 WOOD — and larger skews underflowed `totalEscrowed`, bricking redemption.
2. **`slashBps` is clamped** in `slashToEscrow` to `[minSlashBps, maxSlashBps]`, the same envelope `GuardianRegistry._severityBps` applies on the review path. Note `slashBps = 0` now floors to `minSlashBps` rather than being a no-op.
3. **`escrow` is owner-set state, not a call parameter.** `StakedWood` gained `compensationEscrow` (slot 46, gap `8 → 7`) + `setCompensationEscrow`. **`slashToEscrow`'s real arity is `(bytes32 caseKey, uint256 openedAt, address[] approvers, uint256 slashBps, address vault, uint256 snapshotTimestamp)`** — the Task 4 snippets above show the older 7-arg form. Uses `forceApprove` and zeroes the allowance after `openCase`.
4. **The residue window is frozen per case** (`Case.residueWindowAtOpen`), so the owner cannot lower it and sweep funds from cases opened under longer terms.
5. **`snapshotTimestamp <= openedAt`** is enforced in `slashToEscrow` (`SnapshotAfterVerdict`). This shrinks what a compromised `authorizedSlasher` can do before Plan D: it cannot pick a POST-drain snapshot at which the coalition holds everything and hand the attacker back its own slash.
6. **`caseOf` returns `swept`**, and `slashToEscrow` returns `(total, caseId)` and emits `VerdictSlashRouted`.

Two observations worth carrying into Plan D:

- **The golden layout guard cannot see gap length.** Its canonicalizer strips the digits after `)`, so `t_array(t_uint256)7_storage` and `...)8_storage` compare equal. A wrong-sized `__gap` alone would pass the guard; only a *shifted* field is caught. Gap arithmetic still needs a human check on every append.
- **FIX 5 exposed a fixture bug rather than just adding a constraint:** the e2e suite had been setting `openedAt` BEFORE the LP deposits — i.e. the verdict opened before the drain it convicts. The ordering is now realistic.
