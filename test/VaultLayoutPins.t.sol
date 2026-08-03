// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @notice Raw-slot pins for `SyndicateVault`'s UUPS-upgraded storage layout —
///         the in-`forge test` layer of the golden-layout guard (the full
///         field-by-field JSON diff lives in `script/check-layout-goldens.sh`
///         against `script/syndicate-vault-layout.golden.json`), mirroring
///         `test/GuardianRegistryLayoutPins.t.sol` and
///         `test/governor/GovernorLayoutPins.t.sol`.
///
///         WHY THIS EXISTS (issue #148): `SyndicateVault` is a UUPS proxy
///         (`_authorizeUpgrade` is factory-gated) and the ONE proxy in this
///         protocol that directly custodies user assets — a field
///         reorder/insert/retype here would compile clean, pass the full test
///         suite, and pass CI, then silently corrupt every live vault's
///         storage on the next upgrade. Nothing pinned this before now.
///
///         RE-BASELINED (issue #54, the SAME day #148 landed): Lane A retired
///         outright, deleting `_laneALockPid`, `instantExitFeeBps`,
///         `_interimNetFlow`, and `_crystallizedMgmt`/`_crystallizedPerf` from
///         the vault's OWN storage. Field deletion (not a same-slot
///         placeholder) is legal here ONLY because no `SyndicateVault` proxy
///         is deployed on any chain (design.md "Deployment reality") — the
///         exact condition #148's own NatSpec required for its "initial
///         baseline, not re-baseline" framing still held at the moment of
///         this second edit, so re-baselining rather than placeholder-padding
///         carries no live-proxy compatibility risk. `__gap` grew
///         28 -> 31 words to hold the freed slots, so the contract's total
///         reserved footprint (through slot 47) is unchanged.
///
///         Layout map (linear; every OZ upgradeable base this contract
///         inherits — `Initializable`, `ERC4626Upgradeable`,
///         `ERC20VotesUpgradeable`/`VotesUpgradeable`, `OwnableUpgradeable`,
///         `PausableUpgradeable`, `UUPSUpgradeable` — is ERC-7201 namespaced
///         and holds no linear slot; `ERC721Holder` and
///         `ReentrancyGuardTransient` contribute none either, so the vault's
///         OWN declared storage begins at slot 0, confirmed against
///         `forge inspect SyndicateVault storageLayout`):
///           0  _agents (mapping)             11 _agentFeeBpsPlusOne
///           1-2 _agentSet (AddressSet)        12 minBufferBps(u16)/
///           3  _executorImpl                      minHoldingPeriod(u32)
///           4-5 _approvedDepositors           13 lastDepositAt (mapping)
///           6  _openDeposits(bool)/           14 _mgmtAssetSeconds
///              _agentRegistry(address)        15 _mgmtBase(u192)/
///           7  _managementFeeBps                  _mgmtLastUpdate(u64)
///           8  _factory                       16 _highWaterPricePerShare
///           9  _expectedExecutorCodehash      17..47 __gap[31]
///           10 _cachedDecimalsOffset(u8)/
///              _withdrawalQueue(address)
///
///         FUTURE CONVENTION (issue #148): new fields are APPEND-ONLY, carved
///         from the FRONT of `__gap` — add a pin, never edit one. A REMOVED
///         field must become a same-slot placeholder (e.g.
///         `uint256[1] private __deprecated_x;`) or fold into `__gap`; it must
///         NEVER simply be deleted, since deleting a declared field shifts
///         every field below it down one slot and corrupts a live proxy's
///         storage on the next upgrade exactly as a reorder would. The
///         retire-lane-a re-baseline above is the sanctioned one-time
///         exception this convention itself anticipates, and only while the
///         "no live proxy" precondition holds — the moment a vault proxy is
///         deployed on any chain, EVERY future storage change (including
///         further deletions) must follow the append-only/placeholder rule,
///         no exceptions.
contract VaultLayoutPinsTest is Test {
    SyndicateVault vault;
    ERC20Mock asset;
    BatchExecutorLib executorLib;

    address constant OWNER_SENTINEL = address(0xA11CE);
    address constant AGENT_SENTINEL = address(0xACE47);
    address constant LP_SENTINEL = address(0x1F);
    address constant GOV_SENTINEL = address(0x60F);
    address constant QUEUE_SENTINEL = address(0xBEEF);

    uint256 constant DEPOSIT_ASSETS = 1_000e6; // USDC-like, 6 decimals
    uint256 constant MANAGEMENT_FEE_BPS = 250;
    uint256 constant AGENT_ID = 7;

    function setUp() public {
        asset = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();

        SyndicateVault impl = new SyndicateVault();
        bytes memory init = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(asset),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: OWNER_SENTINEL,
                    executorImpl: address(executorLib),
                    openDeposits: false,
                    agentRegistry: address(0), // no ERC-8004 registry wired
                    managementFeeBps: MANAGEMENT_FEE_BPS
                }))
        );
        // This test contract deploys the proxy, so it becomes `_factory`
        // (msg.sender at `initialize`) — same convention `GovernorLayoutPinsTest`
        // uses for `factory`.
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), init))));

        // `_getGovernor()` reads `ISyndicateFactory(_factory).governorOf(vault)`;
        // this test IS `_factory`, so it mocks its own call. Selector-only
        // mocks (no encoded args) match any argument, mirroring
        // `test/SyndicateVault.t.sol`'s setUp.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(GOV_SENTINEL));
        vm.mockCall(GOV_SENTINEL, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(GOV_SENTINEL, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));
    }

    function _slot(uint256 index) internal view returns (bytes32) {
        return vm.load(address(vault), bytes32(index));
    }

    // ==================== 0-2: _agents / _agentSet ====================

    /// @notice `_agents` (slot 0, mapping) and `_agentSet` (slots 1-2, an
    ///         `EnumerableSet.AddressSet` — `_inner._values` at its base slot,
    ///         `_inner._positions` one word after) pinned via the same
    ///         derived-slot technique `GuardianRegistryLayoutPinsTest` uses
    ///         for `vaultOf`: a mapping stores nothing at its own base slot,
    ///         so read through `keccak256(abi.encode(key, slot))`.
    function test_layout_agentsPinnedToSlot0() public {
        vm.prank(OWNER_SENTINEL);
        vault.registerAgent(AGENT_ID, AGENT_SENTINEL);

        // AgentConfig{ uint256 agentId; address agentAddress; bool active; }
        // packs as: derived+0 = agentId, derived+1 = agentAddress (bits 0..159)
        // | active (bit 160).
        bytes32 derived = keccak256(abi.encode(AGENT_SENTINEL, uint256(0)));
        assertEq(vm.load(address(vault), derived), bytes32(AGENT_ID), "_agents base slot moved off 0 (agentId)");
        bytes32 packed = vm.load(address(vault), bytes32(uint256(derived) + 1));
        assertEq(
            packed,
            bytes32(uint256(uint160(AGENT_SENTINEL)) | (uint256(1) << 160)),
            "_agents base slot moved off 0 (agentAddress/active)"
        );
        // Sanity: the getters agree with the raw read.
        assertTrue(vault.isAgent(AGENT_SENTINEL));
        assertEq(vault.getAgentCount(), 1);
    }

    /// @notice `_agentSet` occupies slots 1-2: `Set._values.length` at slot 1
    ///         (one agent registered ⇒ length 1), `Set._positions[key]` at the
    ///         derived slot off base 2 (1-indexed position).
    function test_layout_agentSetPinnedToSlot1() public {
        vm.prank(OWNER_SENTINEL);
        vault.registerAgent(AGENT_ID, AGENT_SENTINEL);

        assertEq(uint256(_slot(1)), 1, "slot 1: _agentSet._inner._values.length");
        bytes32 posDerived = keccak256(abi.encode(AGENT_SENTINEL, uint256(2)));
        assertEq(uint256(vm.load(address(vault), posDerived)), 1, "slot 2: _agentSet._inner._positions base slot moved");
    }

    // ==================== 3: _executorImpl ====================

    /// @notice Stamped once at `initialize`; no getter, so pinned directly
    ///         against the value this test's own `initialize` call supplied.
    function test_layout_executorImplPinnedToSlot3() public view {
        assertEq(_slot(3), bytes32(uint256(uint160(address(executorLib)))), "slot 3: _executorImpl");
    }

    // ==================== 4-5: _approvedDepositors ====================

    /// @notice Same derived-slot technique as `_agentSet`, one base slot later.
    function test_layout_approvedDepositorsPinnedToSlot4() public {
        vm.prank(OWNER_SENTINEL);
        vault.approveDepositor(LP_SENTINEL);

        assertEq(uint256(_slot(4)), 1, "slot 4: _approvedDepositors._inner._values.length");
        bytes32 posDerived = keccak256(abi.encode(LP_SENTINEL, uint256(5)));
        assertEq(
            uint256(vm.load(address(vault), posDerived)),
            1,
            "slot 5: _approvedDepositors._inner._positions base slot moved"
        );
        // Sanity: the getter agrees with the raw read.
        assertTrue(vault.isApprovedDepositor(LP_SENTINEL));
    }

    // ==================== 6: _openDeposits / _agentRegistry ====================

    /// @notice Packed slot: `_openDeposits` (bool, offset 0) then
    ///         `_agentRegistry` (address, offset 1). Init passed
    ///         `openDeposits: false` and `agentRegistry: address(0)`; flip the
    ///         bool via the real setter so the pin is positive, not a
    ///         double-zero-check.
    function test_layout_openDepositsPinnedToSlot6() public {
        assertEq(_slot(6), bytes32(0), "slot 6 starts unset (openDeposits=false, agentRegistry=0)");
        vm.prank(OWNER_SENTINEL);
        vault.setOpenDeposits(true);
        assertEq(_slot(6), bytes32(uint256(1)), "slot 6 offset 0: _openDeposits");
        assertTrue(vault.openDeposits());
    }

    // ==================== 7: _managementFeeBps ====================

    function test_layout_managementFeeBpsPinnedToSlot7() public view {
        assertEq(_slot(7), bytes32(MANAGEMENT_FEE_BPS), "slot 7: _managementFeeBps");
        assertEq(vault.managementFeeBps(), MANAGEMENT_FEE_BPS);
    }

    // ==================== 8: _factory ====================

    function test_layout_factoryPinnedToSlot8() public view {
        assertEq(_slot(8), bytes32(uint256(uint160(address(this)))), "slot 8: _factory");
        assertEq(vault.factory(), address(this));
    }

    // ==================== 9: _expectedExecutorCodehash ====================

    function test_layout_expectedExecutorCodehashPinnedToSlot9() public view {
        assertEq(_slot(9), address(executorLib).codehash, "slot 9: _expectedExecutorCodehash");
    }

    // ==================== 10: _cachedDecimalsOffset / _withdrawalQueue ====================

    /// @notice Packed slot: `_cachedDecimalsOffset` (uint8, offset 0), stamped
    ///         from `asset.decimals()` at init (6, for the mock USDC), then
    ///         `_withdrawalQueue` (address, offset 1), set once via the
    ///         factory-only setter (this test IS the factory).
    function test_layout_cachedDecimalsOffsetPinnedToSlot10() public {
        assertEq(_slot(10), bytes32(uint256(6)), "slot 10 offset 0: _cachedDecimalsOffset (pre-queue)");
        vault.setWithdrawalQueue(QUEUE_SENTINEL);
        assertEq(
            _slot(10),
            bytes32(uint256(6) | (uint256(uint160(QUEUE_SENTINEL)) << 8)),
            "slot 10: _cachedDecimalsOffset / _withdrawalQueue"
        );
        assertEq(vault.withdrawalQueue(), QUEUE_SENTINEL);
    }

    // ==================== 11: _agentFeeBpsPlusOne ====================

    /// @notice Stored offset-by-one (0 = unset ⇒ default 5%); pin the raw
    ///         `bps + 1` encoding, not just the getter's un-offset view.
    ///         Slot 11 (was 12 pre-retire-lane-a): `_laneALockPid`, the field
    ///         that used to occupy slot 11, was deleted whole (issue #54).
    function test_layout_agentFeeBpsPlusOnePinnedToSlot11() public {
        uint256 bps = 1_234;
        assertEq(_slot(11), bytes32(0), "slot 11 starts unset");
        vm.prank(OWNER_SENTINEL);
        vault.setAgentFeeBps(bps);
        assertEq(_slot(11), bytes32(bps + 1), "slot 11: _agentFeeBpsPlusOne (offset-by-one)");
        assertEq(vault.agentFeeBps(), bps);
    }

    // ==================== 12: minBufferBps / minHoldingPeriod ====================

    /// @notice Two-way packed slot: `minBufferBps` (uint16, offset 0) has a
    ///         real owner setter; `minHoldingPeriod` (uint32, offset 2) has
    ///         none — it is declared but "not yet exposed" (see its natspec)
    ///         — so it is pinned via `vm.store` at the compiler-reported
    ///         offset, checked alongside the other so a slot/offset mistake
    ///         on either would corrupt its sibling and fail this assert.
    ///         Slot 12 (was 13 pre-retire-lane-a, minus the third packed
    ///         field `instantExitFeeBps`, deleted whole with the rest of the
    ///         exit-fee crystallization system — issue #54).
    function test_layout_packedBufferHoldingSlot12() public {
        uint16 minBuffer = 1_234; // <= MAX_MIN_BUFFER_BPS (5_000)
        uint32 holdingPeriod = 777;

        vm.prank(OWNER_SENTINEL);
        vault.setMinBufferBps(minBuffer);

        bytes32 packed = bytes32(uint256(minBuffer) | (uint256(holdingPeriod) << 16));
        vm.store(address(vault), bytes32(uint256(12)), packed);

        assertEq(_slot(12), packed, "slot 12: minBufferBps / minHoldingPeriod");
        assertEq(vault.minBufferBps(), minBuffer, "minBufferBps getter disagrees with raw slot");
    }

    // ==================== 13: lastDepositAt ====================

    /// @notice No getter — like `minHoldingPeriod`, declared but reserved for
    ///         future instant-exit logic and read by nothing today. Pinned by
    ///         `vm.store`/`vm.load` self-consistency at the derived slot; the
    ///         ceiling of what is provable for a field nothing yet reads.
    ///         Slot 13 (was 15 pre-retire-lane-a; `_interimNetFlow`, the field
    ///         that used to occupy slot 14, was deleted whole — issue #54).
    function test_layout_lastDepositAtPinnedToSlot13() public {
        uint40 ts = 1_700_000_000;
        bytes32 derived = keccak256(abi.encode(LP_SENTINEL, uint256(13)));
        vm.store(address(vault), derived, bytes32(uint256(ts)));
        assertEq(vm.load(address(vault), derived), bytes32(uint256(ts)), "slot 13: lastDepositAt base slot moved");
    }

    // ==================== 14-16: management accrual + high-water mark ====================

    /// @notice Real values, not `vm.store`: an approved LP deposit seeds
    ///         `_highWaterPricePerShare` (slot 16) via `_initHighWaterMarkIfUnset`,
    ///         and the governor-only `startManagementAccrual` stamps
    ///         `_mgmtAssetSeconds` (slot 14, zeroed) and the packed
    ///         `_mgmtBase`/`_mgmtLastUpdate` (slot 15) from live `totalAssets()`.
    ///         Withdrawal queue is deliberately NOT set yet in this test — it
    ///         would make `totalAssets()`'s `reservedQueueAssets()` call
    ///         revert against a codeless sentinel, which `_stampMgmtBase`
    ///         would silently swallow into its balance-only fallback branch
    ///         and defeat the point of pinning the primary branch's value.
    ///         Slots 14-16 (were 16-18 pre-retire-lane-a; issue #54 deleted
    ///         two fields ahead of this trio: `_laneALockPid`,
    ///         `instantExitFeeBps`, `_interimNetFlow`).
    function test_layout_managementAccrualAndHighWaterMarkSlots() public {
        vm.prank(OWNER_SENTINEL);
        vault.approveDepositor(LP_SENTINEL);
        asset.mint(LP_SENTINEL, DEPOSIT_ASSETS);
        vm.startPrank(LP_SENTINEL);
        asset.approve(address(vault), DEPOSIT_ASSETS);
        vault.deposit(DEPOSIT_ASSETS, LP_SENTINEL);
        vm.stopPrank();

        // The first deposit seeds the high-water mark at the post-deposit price.
        uint256 pps = vault.pricePerShare();
        assertEq(_slot(16), bytes32(pps), "slot 16: _highWaterPricePerShare");
        assertEq(vault.highWaterPricePerShare(), pps);

        vm.prank(GOV_SENTINEL);
        vault.startManagementAccrual();

        assertEq(_slot(14), bytes32(0), "slot 14: _mgmtAssetSeconds (freshly zeroed)");
        assertEq(vault.managementAssetSeconds(), 0);

        uint256 base = vault.totalAssets();
        assertEq(base, DEPOSIT_ASSETS, "sanity: idle float equals the deposit with no fees/queue yet");
        bytes32 packed15 = bytes32(base | (block.timestamp << 192));
        assertEq(_slot(15), packed15, "slot 15: _mgmtBase / _mgmtLastUpdate");
        assertTrue(vault.isAccruingManagementFee(), "_mgmtLastUpdate getter disagrees with raw slot");
    }

    // ==================== 17-47: __gap ====================

    /// @notice The reserved gap starts immediately after `_highWaterPricePerShare`
    ///         (slot 16) and spans 31 words (grown from 28 — issue #54 — to
    ///         hold the three deleted-field slots, keeping the contract's
    ///         total reserved footprint through slot 47 unchanged). Both
    ///         boundary words must be unwritten in a fresh proxy — if a field
    ///         were appended without shrinking the gap, or inserted above,
    ///         one of these would hold data.
    function test_layout_gapStartsAtSlot17() public view {
        assertEq(_slot(17), bytes32(0), "slot 17: __gap[0] must be unused");
        assertEq(_slot(47), bytes32(0), "slot 47: __gap[30] (last word) must be unused");
    }
}
