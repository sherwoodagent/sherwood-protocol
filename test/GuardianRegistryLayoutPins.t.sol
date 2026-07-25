// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
///         pin, never edit one. A guardian-economic-security branch is expected
///         to append `exposureLedger` next (gap 49 -> 48); that lands at slot 21
///         and pushes `__gap` to 22, leaving every pin below untouched.
///
///         Layout map (linear; OZ Ownable/UUPS are ERC-7201 namespaced and hold
///         no linear slot):
///           0..9  review + emergency mappings   14 reviewPeriod
///           10 epochGenesis                     15 blockQuorumBps
///           11 paused (bool) + pausedAt (u64)   16..17 _authorizedGovernors (Set)
///           12 slashAppealReserve               18 factory
///           13 refundedInEpoch                  19 swood
///                                               20 vaultOf
///                                               21..69 __gap[49]
contract GuardianRegistryLayoutPinsTest is Test {
    GuardianRegistry registry;

    address constant OWNER_SENTINEL = address(0xA11CE);
    address constant FACTORY_SENTINEL = address(0xFAC10);
    address constant SWOOD_SENTINEL = address(0x5000D);
    address constant GOV_SENTINEL = address(0x60F);
    address constant VAULT_SENTINEL = address(0xFA017);

    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;

    function setUp() public {
        GuardianRegistry impl = new GuardianRegistry(6 hours);
        bytes memory init = abi.encodeCall(
            GuardianRegistry.initialize,
            (OWNER_SENTINEL, FACTORY_SENTINEL, SWOOD_SENTINEL, REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(impl), init)));
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

    /// @notice The reserved gap starts immediately after `vaultOf`. Slot 21 must
    ///         be unwritten — if a field were appended without shrinking the gap,
    ///         or inserted above, this word would hold data.
    function test_layout_gapStartsAtSlot21() public view {
        assertEq(_slot(21), bytes32(0), "slot 21: __gap[0] must be unused");
    }
}
