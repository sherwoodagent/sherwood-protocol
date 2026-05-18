// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockStrategyAdapter} from "./mocks/MockStrategyAdapter.sol";

/// @notice Live-NAV LP-flow tests under the strategy-on-proposal model.
///         The vault no longer has a `setActiveStrategyAdapter` setter — the
///         strategy address is read from the governor's proposal struct
///         (`getProposal(activePid).strategy`), set immutably at propose time.
///         This test simulates that read with `vm.mockCall`.
contract VaultLiveNAVTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;

    address owner = makeAddr("owner");
    address constant MOCK_GOVERNOR = address(0xF00D);
    address constant MOCK_ADAPTER = address(0xADA9);
    uint256 constant MOCK_PID = 1;

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
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = SyndicateVault(payable(address(proxy)));

        // The vault reads governor via `factory.governor()`. The factory in
        // this isolated test is `address(this)`, so mock its `governor()`.
        vm.mockCall(address(this), abi.encodeWithSignature("governor()"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal(address)"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount(address)"), abi.encode(uint256(0)));
        // NAV-floor guard reads `getCapitalSnapshot(pid)` from the governor.
        // Mock to 0 — tests with non-zero principal override per-call.
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(0)));
    }

    /// @dev Lock the vault by mocking `getActiveProposal` to MOCK_PID, then
    ///      mock `getProposal(MOCK_PID)` to return a struct whose `.strategy`
    ///      field is the supplied adapter address. This is the new code path
    ///      the vault walks for live NAV — replaces the old
    ///      `vault.setActiveStrategyAdapter(adapter)` flow.
    function _mockStrategyOnActiveProposal(address strategy) internal {
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal(address)"), abi.encode(uint256(MOCK_PID)));

        ISyndicateGovernor.StrategyProposal memory p;
        p.id = MOCK_PID;
        p.vault = address(vault);
        p.strategy = strategy;
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, MOCK_PID), abi.encode(p)
        );
    }

    /// @dev Toggle the lock without setting a strategy (queue-only proposal,
    ///      `strategy=address(0)` at propose time).
    function _mockActiveProposal(bool active) internal {
        if (active) {
            _mockStrategyOnActiveProposal(address(0));
        } else {
            vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal(address)"), abi.encode(uint256(0)));
        }
    }

    function _mockActiveProposal() internal {
        _mockActiveProposal(true);
    }

    function test_activeStrategyAdapter_initiallyZero() public view {
        // No active proposal → resolves to address(0).
        assertEq(vault.activeStrategyAdapter(), address(0));
    }

    function test_activeStrategyAdapter_resolvesFromGovernor() public {
        MockStrategyAdapter adapter = new MockStrategyAdapter();
        _mockStrategyOnActiveProposal(address(adapter));
        assertEq(vault.activeStrategyAdapter(), address(adapter));
    }

    function test_activeStrategyAdapter_zeroWhenProposalQueueOnly() public {
        // Active proposal but proposer passed strategy=address(0).
        _mockStrategyOnActiveProposal(address(0));
        assertEq(vault.activeStrategyAdapter(), address(0));
    }

    function test_totalAssets_includesAdapterNAVWhenValid() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(2_000e6, true);

        // Simulate funds deployed: vault float drained
        vm.prank(address(vault));
        usdc.transfer(address(adapter), 1_000e6);

        // Adapter NAV is only included while a proposal is active.
        _mockStrategyOnActiveProposal(address(adapter));

        // float = 0; adapter NAV = 2000; totalAssets = 2000
        assertEq(vault.totalAssets(), 2_000e6);
    }

    function test_totalAssets_ignoresAdapterWhenInvalid() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, false);
        _mockStrategyOnActiveProposal(address(adapter));

        // Adapter is invalid, totalAssets falls back to float-only
        assertEq(vault.totalAssets(), 1_000e6);
    }

    function test_totalAssets_floatOnlyWhenAdapterUnbound() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        assertEq(vault.activeStrategyAdapter(), address(0));
        assertEq(vault.totalAssets(), 1_000e6);
    }

    function test_totalAssets_floatPlusAdapterValue() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(500e6, true); // half deployed, half float

        // Move only 500e6 to the adapter — vault keeps 500e6 float
        vm.prank(address(vault));
        usdc.transfer(address(adapter), 500e6);
        _mockStrategyOnActiveProposal(address(adapter));

        assertEq(vault.totalAssets(), 1_000e6); // 500 float + 500 adapter
    }

    // ──────────────────────── live-NAV LP-flow gating ────────────────────────

    function test_deposit_allowedWhenAdapterValidDuringLock() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, true); // value=0 + valid=true
        _mockStrategyOnActiveProposal(address(adapter));

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0);
    }

    function test_deposit_blockedWhenAdapterInvalidDuringLock() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, false);
        _mockStrategyOnActiveProposal(address(adapter));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    // ──────────────── NAV-floor guard (share-inflation defense) ────────────────

    /// @notice Deposit reverts when the strategy reports a NAV below
    ///         `principal / 2`. Closes the share-inflation attack: a new
    ///         depositor minting against fake-low totalAssets() would dilute
    ///         existing LPs. The gate falls through to queue-only.
    function test_deposit_blockedWhenAdapterReportsBelowNavFloor() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        // Strategy reports value=400 with valid=true while principal=1000:
        // 400 < 1000 / 2 (= 500) → floor blocks the deposit.
        adapter.setValue(400e6, true);
        _mockStrategyOnActiveProposal(address(adapter));
        // Mock principal at 1000 USDC via the governor's getCapitalSnapshot.
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(1_000e6)));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice Boundary: value at exactly `principal / 2` is still valid —
    ///         honest losses up to 50% don't strand LPs on the queue path.
    function test_deposit_allowedWhenAdapterReportsAtNavFloor() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        // value=500, principal=1000 → 500 == 500 (not strictly less than) → allowed.
        adapter.setValue(500e6, true);
        _mockStrategyOnActiveProposal(address(adapter));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(1_000e6)));

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0);
    }

    /// @notice I-3 fail-closed: when `getCapitalSnapshot` reverts (e.g. UUPS
    ///         upgrade dropped the selector) the gate blocks the live path
    ///         instead of silently zeroing the floor and re-enabling the
    ///         share-inflation attack. LPs route through the queue.
    function test_deposit_blockedWhenGovernorSnapshotReverts() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        // Honest report (above floor for any non-zero snapshot) — only the
        // snapshot read fails. Without the I-3 fail-closed branch, snapshot
        // defaults to 0 and the floor becomes 0, so this deposit succeeds
        // (the bug). With fail-closed, the gate returns blocked.
        adapter.setValue(800e6, true);
        _mockStrategyOnActiveProposal(address(adapter));
        vm.mockCallRevert(
            MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), "GovernorSnapshotMissing()"
        );

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    /// @notice `totalAssets()` and `_lpFlowGate` must agree byte-for-byte:
    ///         when the floor fires, `totalAssets()` falls back to float-only
    ///         so `previewDeposit`/`previewWithdraw` quote a NAV that the
    ///         on-chain entry/exit gate would actually honour.
    function test_totalAssets_dropsToFloatWhenFloorFires() public {
        // Seed float so we can observe the strategy slice being excluded.
        usdc.mint(address(vault), 200e6);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        // Sub-floor: value=100, principal=1000 → 100 < 500 → blocked.
        adapter.setValue(100e6, true);
        _mockStrategyOnActiveProposal(address(adapter));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(1_000e6)));

        // Float (200) only — the 100 from the under-reporting strategy must
        // be excluded so previews match the gate's block decision.
        assertEq(vault.totalAssets(), 200e6);
    }

    /// @notice Same fail-closed semantics on the view surface: a reverting
    ///         `getCapitalSnapshot` excludes the strategy slice from
    ///         `totalAssets()` rather than counting it under a zeroed floor.
    function test_totalAssets_dropsToFloatWhenGovernorSnapshotReverts() public {
        usdc.mint(address(vault), 200e6);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(800e6, true);
        _mockStrategyOnActiveProposal(address(adapter));
        vm.mockCallRevert(
            MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), "GovernorSnapshotMissing()"
        );

        assertEq(vault.totalAssets(), 200e6);
    }

    function test_deposit_blockedWhenAdapterUnboundDuringLock() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        _mockStrategyOnActiveProposal(address(0)); // queue-only proposal
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, alice);
    }

    function test_withdraw_allowedWhenAdapterValidDuringLock() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, true);
        _mockStrategyOnActiveProposal(address(adapter));

        // Should be able to withdraw via standard path
        vm.prank(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);
        assertGt(redeemed, 0);
    }

    function test_withdraw_blockedWhenAdapterInvalidDuringLock() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, false); // invalid
        _mockStrategyOnActiveProposal(address(adapter));

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(1, alice, alice);
    }

    function test_maxWithdraw_returnsNonZeroWhenAdapterValid() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, true);
        _mockStrategyOnActiveProposal(address(adapter));

        assertGt(vault.maxWithdraw(alice), 0);
    }

    // ──────────────────────── live-deposit forwarding ────────────────────────

    function test_deposit_forwardsAssetsToLiveAdapter() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, true);
        _mockStrategyOnActiveProposal(address(adapter));

        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        assertEq(adapter.lastLiveDeposit(), 1_000e6, "adapter received forwarded assets");
        assertEq(adapter.liveDepositCount(), 1, "hook called exactly once");
        assertEq(usdc.balanceOf(address(adapter)), 1_000e6, "assets pushed to adapter");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault float drained");
    }

    /// @notice Outside the lock window the forwarding hook must not fire.
    function test_deposit_doesNotForwardWhenUnlocked() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // No active proposal mocked — `redemptionsLocked()` is false. Even
        // though we attached a mock strategy via `_mockStrategyOnActiveProposal`
        // momentarily for setup, we explicitly clear the lock here.
        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, true);
        _mockActiveProposal(false);

        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        assertEq(adapter.liveDepositCount(), 0, "hook not called when unlocked");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "vault keeps float");
    }

    function test_deposit_doesNotForwardWhenAdapterUnbound() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // No active proposal, no adapter — plain deposit path.
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "vault keeps float");
    }

    /// @notice Implicit-clear behaviour: with no active proposal the strategy
    ///         is silently ignored. Under the new model `activeStrategyAdapter`
    ///         resolves through the governor — no proposal active means no
    ///         strategy regardless of any prior state.
    function test_totalAssets_ignoresStrategyWhenUnlocked() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        // No active proposal mock => `redemptionsLocked()` is false →
        // governor's `getActiveProposal` returns 0 → no strategy resolved.
        assertEq(vault.activeStrategyAdapter(), address(0));
        assertEq(vault.totalAssets(), 1_000e6);
    }

    // ──────────────────────── try/catch backstop on totalAssets ────────────────────────

    /// @notice A reverting strategy must NOT brick `totalAssets` (e.g. the
    ///         strategy self-destructs or upgrades to a reverting impl after
    ///         being set on the proposal). Vault falls back to float-only so
    ///         every ERC-4626 conversion path keeps working.
    function test_totalAssets_revertingAdapterFallsBackToFloat() public {
        RevertingAdapter ra = new RevertingAdapter();
        _mockStrategyOnActiveProposal(address(ra));

        // Synthetic float — bypass `_deposit` (which would also call into the
        // reverting adapter via `_lpFlowGate`) by funding the vault directly.
        deal(address(usdc), address(vault), 1_000e6);

        // Should not revert; should report float-only.
        uint256 ta = vault.totalAssets();
        assertEq(ta, 1_000e6);
    }

    // ──────────────────────── IMP-2: maxRedeem cap (EIP-4626 conformance) ────────────────────────

    /// @notice Under the live-NAV onLiveWithdraw model, `maxRedeem` is capped
    ///         by float + adapter `positionValue` (the assets the vault can
    ///         either pay directly or pull from the adapter via
    ///         `onLiveWithdraw`). Verifies the cap matches that backing.
    function test_maxRedeem_capsAtBackingAssetsUnderLiveNAV() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, true);
        _mockStrategyOnActiveProposal(address(adapter));

        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        // Vault has 100 float; adapter holds 900 worth.
        deal(address(usdc), address(vault), 100e6);
        adapter.setValue(900e6, true);

        uint256 mr = vault.maxRedeem(alice);
        uint256 mrAssets = vault.convertToAssets(mr);
        // Cap = float (100) + adapter NAV (900) = 1000; user holds 1000-equivalent.
        assertLe(mrAssets, 1_000e6, "maxRedeem exceeds float+adapter backing");
    }

    // Sherlock #37 — DEFERRED to #50 (Moonwell/WstETHMoonwell/Portfolio
    // _onLiveWithdraw implementations). Adding a `supportsLiveWithdraw`
    // capability flag at IStrategy + vault-side gate pushed SyndicateVault
    // over EIP-170. Reverted here; tracking in PR description.

    // ──────────────────────── Sherlock #24: onLiveDeposit failure reverts ────────────────────────

    /// @notice Sherlock run #1 finding #24 — an adapter that reverts on
    ///         `onLiveDeposit` must hard-revert the LP deposit. Pre-fix,
    ///         the vault caught the revert and bumped principal anyway,
    ///         leaving assets stranded on the adapter where `positionValue`
    ///         couldn't see them; the next depositor minted shares against
    ///         a deflated NAV (dilution).
    function test_deposit_revertsWhenAdapterLacksOnLiveDeposit() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        NoOnLiveDepositAdapter ad = new NoOnLiveDepositAdapter();
        ad.setValue(0, true);
        _mockStrategyOnActiveProposal(address(ad));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.LiveDepositRejected.selector);
        vault.deposit(1_000e6, alice);
        // Reverted atomically — no stranded assets, no principal bump, no shares.
        assertEq(usdc.balanceOf(address(ad)), 0, "no stranded assets on adapter");
        assertEq(vault.liveAdapterPrincipal(MOCK_PID), 0, "principal not bumped on failed hook");
        assertEq(vault.balanceOf(alice), 0, "no shares minted");
    }

    /// @notice Same hard-revert for a hook that reverts transiently
    ///         (paused upstream, max-cap, oracle staleness). The LP must
    ///         use the queue path or retry later instead of getting
    ///         silently diluted.
    function test_deposit_revertsWhenOnLiveDepositReverts() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        RevertingOnLiveDepositAdapter ad = new RevertingOnLiveDepositAdapter();
        ad.setValue(0, true);
        _mockStrategyOnActiveProposal(address(ad));

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.LiveDepositRejected.selector);
        vault.deposit(1_000e6, alice);
        assertEq(vault.liveAdapterPrincipal(MOCK_PID), 0, "no principal bump on failed hook");
    }

    /// @notice With float drained AND adapter reporting zero positionValue,
    ///         maxRedeem returns 0 (nothing redeemable).
    function test_maxRedeem_returnsZeroWhenNoBackingAvailable() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        MockStrategyAdapter adapter = new MockStrategyAdapter();
        adapter.setValue(0, true);
        _mockStrategyOnActiveProposal(address(adapter));

        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        // Float drained (forwarded to adapter) AND adapter reports 0 NAV
        // (e.g. position deeply impaired, awaiting settle).
        adapter.setValue(0, true);
        assertEq(usdc.balanceOf(address(vault)), 0, "float drained");

        assertEq(vault.maxRedeem(alice), 0, "maxRedeem 0 when no backing");
    }
}

/// @dev Adapter whose `positionValue()` reverts. Used to verify the
///      try/catch backstop in `totalAssets` and `_lpFlowGate`.
contract RevertingAdapter {
    function positionValue() external pure returns (uint256, bool) {
        revert("nope");
    }
}

/// @dev Adapter that reports valid NAV but has no `onLiveDeposit` selector.
///      Models a bespoke (non-BaseStrategy) adapter that ships with
///      `positionValue()` but forgets the live-deposit hook. Without the
///      try/catch wrapper in `_deposit`, this would revert every LP deposit
///      during the active proposal window.
contract NoOnLiveDepositAdapter {
    uint256 public mockValue;
    bool public mockValid;

    function setValue(uint256 v, bool valid_) external {
        mockValue = v;
        mockValid = valid_;
    }

    function positionValue() external view returns (uint256, bool) {
        return (mockValue, mockValid);
    }
    // No `onLiveDeposit` — calls revert with selector-not-found.
}

/// @dev Adapter whose `onLiveDeposit` reverts. Models a transient upstream
///      pause / max-deposit cap on a strategy that *does* implement the hook
///      but is unhealthy right now.
contract RevertingOnLiveDepositAdapter {
    uint256 public mockValue;
    bool public mockValid;

    function setValue(uint256 v, bool valid_) external {
        mockValue = v;
        mockValid = valid_;
    }

    function positionValue() external view returns (uint256, bool) {
        return (mockValue, mockValid);
    }

    function onLiveDeposit(uint256) external pure {
        revert("upstream paused");
    }
}
