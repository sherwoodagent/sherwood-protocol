// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Minimal answering stub for `GuardianRegistry.setExposureLedger`'s
///         STRICT post-audit-#181-finding-#26 validation (see that function's
///         natspec in `src/GuardianRegistry.sol`). The setter now calls INTO
///         the ledger with no try/catch, so a codeless sentinel address
///         reverts the wiring outright — this test only cares about the
///         STORAGE SLOT the ledger address lands in, so any contract that
///         answers the two calls the setter makes is sufficient:
///           - `challengeWindow()` must be >= `reviewPeriod +
///             MAX_GOVERNOR_EXECUTION_WINDOW` (24h review + 7d window here,
///             so 30 days clears it with margin).
///           - `guardianRegistry()` must be `address(0)` (unset) or the
///             calling registry — `address(0)` is the legitimate
///             first-time-wiring reading this fixture exercises.
contract MockExposureLedgerMinimal {
    function challengeWindow() external pure returns (uint256) {
        return 30 days;
    }

    function guardianRegistry() external pure returns (address) {
        return address(0);
    }
}

/// @notice Raw-slot pins for `GuardianRegistry`'s UUPS-upgraded storage layout —
///         the in-`forge test` layer of the golden guard (the field-by-field JSON
///         diff lives in `script/check-layout-goldens.sh` against
///         `script/guardian-registry-layout.golden.json`), mirroring
///         `test/governor/GovernorLayoutPins.t.sol`.
///
///         WHY THIS EXISTS: the registry is upgradeable but had NO layout gate of
///         any kind until the proposal-lifecycle branch, which promptly shipped a
///         real collision — `vaultOf` was inserted ahead of `factory`/`swood`
///         with the `__gap` left at 50, silently shifting every field below it by
///         one word. A human reading the diff caught it; CI could not have. The
///         fix appended `vaultOf` after `swood` and shrank the gap 50 -> 49. This
///         file makes the next such mistake fail loudly.
///
///         New fields are APPEND-ONLY, carved from the FRONT of `__gap`: add a
///         pin, never edit one. That append has since happened — Plan B added
///         `exposureLedger` (gap 49 -> 48), landing at slot 21 and pushing
///         `__gap` to 22, leaving every pin below untouched. The gap pin was
///         RE-TARGETED 21 -> 22 to follow it, and a positive pin for
///         `exposureLedger` at 21 was added (PR #56 review M7): the old assert
///         passed only because this fixture never wired a ledger, so the real
///         `__gap[0]` was unguarded and the assert would have started failing
///         for the wrong reason the day one was wired. Pins that were still
///         correct (14, 15, 18, 19, 20) did not move.
///
///         Layout map (linear; OZ Ownable/UUPS are ERC-7201 namespaced and hold
///         no linear slot):
///           0..9  review + emergency mappings   14 reviewPeriod
///           10 epochGenesis                     15 blockQuorumBps
///           11 paused (bool) + pausedAt (u64)   16..17 _authorizedGovernors (Set)
///           12 slashAppealReserve               18 factory
///           13 refundedInEpoch                  19 swood
///                                               20 vaultOf
///                                               21 exposureLedger
///                                               22..69 __gap[48]
contract GuardianRegistryLayoutPinsTest is Test {
    GuardianRegistry registry;

    address constant OWNER_SENTINEL = address(0xA11CE);
    address constant FACTORY_SENTINEL = address(0xFAC10);
    address constant SWOOD_SENTINEL = address(0x5000D);
    address constant GOV_SENTINEL = address(0x60F);
    address constant VAULT_SENTINEL = address(0xFA017);
    /// @dev NOT a bare sentinel address — `setExposureLedger` now calls INTO
    ///      the ledger (`challengeWindow()`, `guardianRegistry()`), so this
    ///      must be a deployed, answering contract. See
    ///      `MockExposureLedgerMinimal` above.
    address LEDGER_SENTINEL;

    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;

    function setUp() public {
        GuardianRegistry impl = new GuardianRegistry(6 hours);
        bytes memory init = abi.encodeCall(
            GuardianRegistry.initialize,
            (OWNER_SENTINEL, FACTORY_SENTINEL, SWOOD_SENTINEL, REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(impl), init)));
        LEDGER_SENTINEL = address(new MockExposureLedgerMinimal());
    }

    function _slot(uint256 index) internal view returns (bytes32) {
        return vm.load(address(registry), bytes32(index));
    }

    /// @notice Parameters and privileged addresses land at their frozen words.
    function test_layout_paramsAndPrivilegedPinned() public view {
        assertEq(uint256(_slot(14)), REVIEW_PERIOD, "slot 14: reviewPeriod");
        assertEq(uint256(_slot(15)), BLOCK_QUORUM_BPS, "slot 15: blockQuorumBps");
        assertEq(_slot(18), bytes32(uint256(uint160(FACTORY_SENTINEL))), "slot 18: factory");
        assertEq(_slot(19), bytes32(uint256(uint160(SWOOD_SENTINEL))), "slot 19: swood");
    }

    /// @notice `vaultOf` must sit at slot 20 — AFTER `factory`/`swood`, not
    ///         inserted ahead of them. A mapping stores nothing at its base
    ///         slot, so pin it through the derived slot for a known key:
    ///         `keccak256(abi.encode(key, 20))`. If the base slot moved, this
    ///         read returns zero and the assert fires.
    function test_layout_vaultOfPinnedToSlot20() public {
        vm.prank(FACTORY_SENTINEL);
        registry.addGovernor(GOV_SENTINEL, VAULT_SENTINEL);

        bytes32 derived = keccak256(abi.encode(GOV_SENTINEL, uint256(20)));
        assertEq(
            vm.load(address(registry), derived),
            bytes32(uint256(uint160(VAULT_SENTINEL))),
            "vaultOf base slot moved off 20"
        );
        // Sanity: the getter agrees with the raw read.
        assertEq(registry.vaultOf(GOV_SENTINEL), VAULT_SENTINEL);
    }

    /// @notice `exposureLedger` must sit at slot 21 — the word Plan B carved off
    ///         the FRONT of `__gap` (49 -> 48). Pinned POSITIVELY, by writing a
    ///         sentinel and reading the raw word back: a zero-check would pass
    ///         for a field that had moved, which is exactly how the stale
    ///         `gapStartsAtSlot21` assert stayed green (PR #56 review M7).
    function test_layout_exposureLedgerPinnedToSlot21() public {
        vm.prank(OWNER_SENTINEL);
        registry.setExposureLedger(LEDGER_SENTINEL);

        assertEq(_slot(21), bytes32(uint256(uint160(LEDGER_SENTINEL))), "slot 21: exposureLedger moved");
        // Sanity: the getter agrees with the raw read.
        assertEq(address(registry.exposureLedger()), LEDGER_SENTINEL);
    }

    /// @notice The reserved gap starts immediately after `exposureLedger`. Slot
    ///         22 must be unwritten — if a field were appended without shrinking
    ///         the gap, or inserted above, this word would hold data. Asserted
    ///         with the ledger WIRED so the check cannot be satisfied by a
    ///         fixture that simply never populates the field above it.
    function test_layout_gapStartsAtSlot22() public {
        vm.prank(OWNER_SENTINEL);
        registry.setExposureLedger(LEDGER_SENTINEL);

        assertEq(_slot(22), bytes32(0), "slot 22: __gap[0] must be unused");
    }
}
