// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WoodToken} from "../../src/WoodToken.sol";

/// @dev Test-only subclass exposing the internal `_credit` and the protected
///      `_burn` hook. Lets us exercise the OFT inbound-credit path without
///      standing up a full LayerZero endpoint, and simulate bridge-out burns
///      via the same `_burn` that the production `_debit` path invokes.
contract WoodTokenForTest is WoodToken {
    constructor(address _lzEndpoint, address _delegate) WoodToken(_lzEndpoint, _delegate) {}

    function credit(address to, uint256 amount, uint32 srcEid) external returns (uint256) {
        return _credit(to, amount, srcEid);
    }

    function burnExternal(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Minimal LZ endpoint mock — only `setDelegate` is touched by the
///      `OApp` constructor.
contract MockEndpoint {
    mapping(address => address) public delegates;

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }
}

/// @notice Sherlock run #1 — finding #5
///         WoodToken OFT `_credit` must enforce the 1B `MAX_SUPPLY` cap so
///         cross-chain bridges cannot inflate beyond what was locally minted.
///         Pre-fix, `_credit` called `_mint` directly, bypassing the cap.
contract WoodTokenOftMintCapTest is Test {
    WoodTokenForTest public wood;
    MockEndpoint public endpoint;

    address public delegate_ = makeAddr("delegate");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        endpoint = new MockEndpoint();
        wood = new WoodTokenForTest(address(endpoint), delegate_);
    }

    // ── #5 fix: _credit enforces MAX_SUPPLY ──

    function test_credit_revertsAtMaxSupply() public {
        // Local-mint near the cap so the next inbound bridge tips over.
        uint256 maxSupply = wood.MAX_SUPPLY();
        vm.prank(delegate_);
        wood.mint(alice, maxSupply - 1e18); // 1B - 1 minted locally
        assertEq(wood.totalEverMinted(), maxSupply - 1e18);
        assertEq(wood.totalMintable(), 1e18);

        // Inbound credit of 2e18 would push HWM to MAX_SUPPLY + 1e18 — reject.
        vm.expectRevert(WoodToken.MaxSupplyExceeded.selector);
        wood.credit(
            bob,
            2e18,
            30101 /* arbitrary srcEid */
        );
    }

    function test_credit_succeedsUnderCap() public {
        uint256 maxSupply = wood.MAX_SUPPLY();
        vm.prank(delegate_);
        wood.mint(alice, maxSupply / 2);
        assertEq(wood.totalEverMinted(), maxSupply / 2);

        uint256 inbound = maxSupply / 4;
        wood.credit(bob, inbound, 30101);

        assertEq(wood.balanceOf(bob), inbound);
        assertEq(wood.totalEverMinted(), maxSupply / 2 + inbound, "credit accumulates into HWM");
        assertEq(wood.totalMintable(), maxSupply - (maxSupply / 2 + inbound));
    }

    function test_credit_exactlyAtCap_succeeds() public {
        uint256 maxSupply = wood.MAX_SUPPLY();
        vm.prank(delegate_);
        wood.mint(alice, maxSupply - 100e18);
        wood.credit(bob, 100e18, 30101);
        assertEq(wood.totalEverMinted(), maxSupply);
        assertEq(wood.balanceOf(bob), 100e18);
        // Now any further credit must revert.
        vm.expectRevert(WoodToken.MaxSupplyExceeded.selector);
        wood.credit(alice, 1, 30101);
    }

    function test_credit_atZero_succeeds() public {
        // Greenfield chain: no local mint, accepts inbound bridge.
        wood.credit(alice, 1000e18, 30101);
        assertEq(wood.balanceOf(alice), 1000e18);
        assertEq(wood.totalEverMinted(), 1000e18);
    }

    // ── HWM invariant — _burn / bridge-out does NOT decrement HWM ──

    function test_burnDoesNotDecrementHwm() public {
        uint256 maxSupply = wood.MAX_SUPPLY();
        vm.prank(delegate_);
        wood.mint(alice, maxSupply);
        assertEq(wood.totalEverMinted(), maxSupply);

        // Simulate OFT bridge-out: _debit ultimately calls _burn. _totalEverMinted
        // must NOT decrement — this is the load-bearing invariant that lets the
        // cap survive cross-chain round-trips and prevents the local-mint-then-
        // bridge-out-then-remint inflation attack from finding #5's attack path.
        wood.burnExternal(alice, 100_000_000e18);
        assertEq(wood.totalSupply(), maxSupply - 100_000_000e18, "supply decremented by burn");
        assertEq(wood.totalEverMinted(), maxSupply, "HWM unchanged by burn");
        assertEq(wood.totalMintable(), 0, "no headroom restored");

        // Re-mint attempt: must fail (no headroom).
        vm.prank(delegate_);
        uint256 minted = wood.mint(bob, 100_000_000e18);
        assertEq(minted, 0, "no-op mint after bridge-out");

        // Inbound credit attempt: must also fail (HWM is at cap).
        vm.expectRevert(WoodToken.MaxSupplyExceeded.selector);
        wood.credit(bob, 1, 30101);
    }

    function test_mintAndCreditTogether_shareCapBudget() public {
        // Cap is enforced jointly across local mint and inbound credit.
        uint256 maxSupply = wood.MAX_SUPPLY();

        wood.credit(alice, maxSupply / 4, 30101);
        vm.prank(delegate_);
        wood.mint(bob, maxSupply / 4);
        wood.credit(alice, maxSupply / 4, 30101);
        vm.prank(delegate_);
        wood.mint(bob, maxSupply / 4);

        assertEq(wood.totalEverMinted(), maxSupply);
        assertEq(wood.balanceOf(alice), maxSupply / 2);
        assertEq(wood.balanceOf(bob), maxSupply / 2);

        // Any more in either path reverts.
        vm.expectRevert(WoodToken.MaxSupplyExceeded.selector);
        wood.credit(alice, 1, 30101);
        vm.prank(delegate_);
        uint256 minted = wood.mint(bob, 1);
        assertEq(minted, 0);
    }

    function test_totalEverMinted_tracksAllMintsAndCredits() public {
        vm.startPrank(delegate_);
        wood.mint(alice, 1e18);
        wood.mint(bob, 2e18);
        vm.stopPrank();
        wood.credit(alice, 3e18, 30101);
        assertEq(wood.totalEverMinted(), 6e18);

        wood.burnExternal(alice, 1e18);
        assertEq(wood.totalEverMinted(), 6e18, "burn does not decrement HWM");
        assertEq(wood.totalSupply(), 5e18);
    }
}
