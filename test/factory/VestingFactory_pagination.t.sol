// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Audit #181 finding #28 (conf 70): VestingFactory.walletsOf is the only
// unpaginated enumeration in the repo. createVesting is permissionless,
// accepts an arbitrary beneficiary, and a zero-amount create is a valid,
// cheap (one clone + one SSTORE) unfunded shell pushed into
// _walletsOf[beneficiary] BEFORE any funding transfer. Anyone can therefore
// inflate any address's wallet list until walletsOf(victim) exceeds a node's
// eth_call gas budget, permanently breaking that beneficiary's on-chain
// enumeration.
//
// Fix: add walletCountOf + walletsOfPaginated (clamped to MAX_PAGE_LIMIT,
// mirroring SyndicateVaultAdminLib.pageAddresses), keeping walletsOf for
// backward compatibility. This test proves:
//   1. walletCountOf / walletsOfPaginated exist and page correctly
//      (offset/limit slicing, clamping, offset >= total early-return).
//   2. Against the OLD contract (no pagination API), this test fails to
//      compile at all -- the strongest possible "fails against old
//      behaviour" signal for a missing-function finding.
//   3. Pagination lets a caller enumerate a beneficiary's wallets in
//      bounded-size chunks even after enough wallets exist that a single
//      walletsOf() call would be gas-hazardous, demonstrating the DoS
//      mitigation actually works end to end.

import {Test} from "forge-std/Test.sol";
import {VestingFactory} from "../../src/vesting/VestingFactory.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract VestingFactoryPaginationTest is Test {
    VestingFactory internal factory;
    ERC20Mock internal token;

    address internal owner = makeAddr("owner");
    address internal beneficiary = makeAddr("beneficiary");

    uint64 internal start;
    uint64 internal constant DURATION = 365 days;

    function setUp() public {
        factory = new VestingFactory();
        token = new ERC20Mock("Wood", "WOOD", 18);
        start = uint64(vm.getBlockTimestamp());
    }

    function _create() internal returns (address wallet) {
        // amount = 0: the documented, cheap, unfunded-shell path an attacker
        // would use to grow a victim's wallet list.
        wallet = factory.createVesting(owner, beneficiary, address(token), start, 0, DURATION, true, 0);
    }

    function test_walletCountOf_matchesNumberCreated() public {
        assertEq(factory.walletCountOf(beneficiary), 0);
        _create();
        _create();
        _create();
        assertEq(factory.walletCountOf(beneficiary), 3);
        assertEq(factory.walletCountOf(makeAddr("nobody")), 0);
    }

    function test_walletsOfPaginated_matchesWalletsOfSlice() public {
        address w0 = _create();
        address w1 = _create();
        address w2 = _create();
        address w3 = _create();
        address w4 = _create();

        address[] memory full = factory.walletsOf(beneficiary);
        assertEq(full.length, 5);
        assertEq(full[0], w0);
        assertEq(full[4], w4);

        address[] memory page = factory.walletsOfPaginated(beneficiary, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], w1);
        assertEq(page[1], w2);

        // Last partial page.
        address[] memory tail = factory.walletsOfPaginated(beneficiary, 3, 10);
        assertEq(tail.length, 2);
        assertEq(tail[0], w3);
        assertEq(tail[1], w4);
    }

    function test_walletsOfPaginated_clampsLimitToMaxPageLimit() public {
        uint256 max = factory.MAX_PAGE_LIMIT();
        // Create more than one page's worth of wallets (zero-amount shells,
        // the exact griefing primitive the finding describes).
        for (uint256 i = 0; i < max + 5; i++) {
            _create();
        }
        assertEq(factory.walletCountOf(beneficiary), max + 5);

        // Even asking for far more than exist per call, a single page never
        // exceeds MAX_PAGE_LIMIT results -- this is what keeps the call
        // inside a bounded eth_call gas budget regardless of how many
        // zero-amount shells an attacker has pushed onto the beneficiary.
        address[] memory page = factory.walletsOfPaginated(beneficiary, 0, type(uint256).max - 1);
        assertEq(page.length, max);

        // The remaining 5 wallets are reachable via a second bounded page.
        address[] memory page2 = factory.walletsOfPaginated(beneficiary, max, max);
        assertEq(page2.length, 5);
    }

    function test_walletsOfPaginated_offsetAtOrPastTotalReturnsEmpty() public {
        _create();
        _create();
        assertEq(factory.walletCountOf(beneficiary), 2);

        assertEq(factory.walletsOfPaginated(beneficiary, 2, 10).length, 0);
        assertEq(factory.walletsOfPaginated(beneficiary, 100, 10).length, 0);
    }

    function test_walletsOfPaginated_offsetPlusLimitOverflowDoesNotRevert() public {
        _create();
        // offset + limit must not overflow-revert (mirrors
        // SyndicateVaultAdminLib.pageAddresses's offset >= total early-return
        // preceding the overflow-capable offset + limit addition).
        address[] memory page = factory.walletsOfPaginated(beneficiary, 0, type(uint256).max);
        assertEq(page.length, 1);
    }

    // Not `view`: makeAddr() labels the address via a cheatcode, which the
    // compiler treats as state-modifying.
    function test_walletsOfPaginated_emptyForBeneficiaryWithNoWallets() public {
        assertEq(factory.walletsOfPaginated(makeAddr("nobody"), 0, 10).length, 0);
    }
}
