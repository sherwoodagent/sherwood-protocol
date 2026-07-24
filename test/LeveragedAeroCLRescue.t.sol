// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mocks (fork-free): a vault exposing owner() + asset(), a mintable ERC-20,
// and a gauge exposing rewardToken().
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Vault stand-in: only the surface `rescueToVault` / `_initialize` read — `owner()`
///      (Ownable) and `asset()` (ERC-4626 L7 wiring check).
contract MockOwnedVault {
    address public owner;
    address public asset;

    constructor(address owner_, address asset_) {
        owner = owner_;
        asset = asset_;
    }
}

/// @dev Bare mintable ERC-20 (mint + transfer + balanceOf + decimals).
contract MockToken {
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Gauge stub returning a fixed reward token (AERO) for the rescue blocklist.
contract MockGauge {
    address public rewardToken;

    constructor(address rewardToken_) {
        rewardToken = rewardToken_;
    }
}

/// @title  LeveragedAeroCLRescueUnit
/// @notice Fork-free unit tests for `rescueToVault` (D5): proposer OR vault owner may sweep a
///         stray ERC-20 to the vault; a stranger reverts; the position/asset-token blocklist
///         reverts for both authorised callers. The initializer's external reads (comptroller
///         collateral factor, asset/decimals wiring) are mocked so no fork is needed.
contract LeveragedAeroCLRescueUnit is Test {
    LeveragedAerodromeCLStrategy internal strategy;

    // ── Actors ──
    address internal proposer;
    address internal vaultOwner;
    MockOwnedVault internal vault;

    // ── Position / accounting tokens (blocklisted) ──
    MockToken internal usdc; // 6dp asset (L7)
    address internal mUsdc = makeAddr("mUsdc");
    address internal mCbBTC = makeAddr("mCbBTC");
    address internal mWeth = makeAddr("mWeth");
    address internal cbBTC = makeAddr("cbBTC");
    address internal weth = makeAddr("weth");
    address internal comptroller = makeAddr("comptroller");
    address internal aero = makeAddr("aero");
    address internal aeroUsdFeed = makeAddr("aeroUsdFeed");
    MockGauge internal gauge;

    function setUp() public {
        proposer = makeAddr("proposer");
        vaultOwner = makeAddr("vaultOwner");

        usdc = new MockToken(6);
        vault = new MockOwnedVault(vaultOwner, address(usdc));
        gauge = new MockGauge(aero);

        // Mock the comptroller collateral-factor read (`markets(address)` → (isListed, cfMantissa,...)).
        vm.mockCall(
            comptroller, abi.encodeWithSignature("markets(address)", mUsdc), abi.encode(true, uint256(0.88e18), false)
        );
        // L9: init asserts the AERO/USD aggregator is 8dp — mock the one `decimals()` read.
        vm.mockCall(aeroUsdFeed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

        address template = address(new LeveragedAerodromeCLStrategy());
        strategy = LeveragedAerodromeCLStrategy(payable(Clones.clone(template)));
        strategy.initialize(address(vault), proposer, abi.encode(_initParams()));
    }

    function _initParams() internal returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        p = LeveragedAerodromeCLStrategy.InitParams({
            usdc: address(usdc),
            mUsdc: mUsdc,
            mCbBTC: mCbBTC,
            mWeth: mWeth,
            comptroller: comptroller,
            cbBTC: cbBTC,
            weth: weth,
            pool: makeAddr("pool"),
            npm: makeAddr("npm"),
            gauge: address(gauge),
            swapRouter: makeAddr("swapRouter"),
            cbBTCFeed: makeAddr("cbBTCFeed"),
            wethFeed: makeAddr("wethFeed"),
            usdcFeed: makeAddr("usdcFeed"),
            sequencerFeed: makeAddr("sequencerFeed"),
            aeroUsdFeed: aeroUsdFeed,
            maxDelay: 48 hours,
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: 100,
            width: 4000, // full width (raw ticks) = 40·tickSpacing (preserves the pre-param 20-spacing/side range)
            minWidth: 200, // 2·tickSpacing
            maxWidth: 20000,
            targetLtvBps: 5000,
            maxLtvBps: 6500,
            minHealthBps: 12000,
            maxSlippageBps: 100,
            managementFeeBps: 100,
            performanceFeeBps: 1000,
            feeRecipient: makeAddr("feeRecipient")
        });
    }

    function _strayToken() internal returns (MockToken t) {
        t = new MockToken(18);
        t.mint(address(strategy), 1_000e18);
    }

    // ── D5: proposer path (unchanged behaviour) ──

    function test_rescue_proposerCanSweep() public {
        MockToken stray = _strayToken();
        vm.prank(proposer);
        strategy.rescueToVault(address(stray));
        assertEq(stray.balanceOf(address(strategy)), 0, "strategy not drained");
        assertEq(stray.balanceOf(address(vault)), 1_000e18, "vault did not receive stray");
    }

    // ── D5: vault-owner path (the fix — previously reverted NotProposer) ──

    function test_rescue_vaultOwnerCanSweep() public {
        MockToken stray = _strayToken();
        vm.prank(vaultOwner);
        strategy.rescueToVault(address(stray));
        assertEq(stray.balanceOf(address(strategy)), 0, "strategy not drained");
        assertEq(stray.balanceOf(address(vault)), 1_000e18, "vault did not receive stray");
    }

    // ── D5: stranger still blocked ──

    function test_rescue_strangerReverts() public {
        MockToken stray = _strayToken();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotProposerOrOwner.selector);
        strategy.rescueToVault(address(stray));
    }

    // ── Blocklist still enforced for BOTH authorised callers ──

    function test_rescue_blocklistReverts_forProposerAndOwner() public {
        address[7] memory blocked = [address(usdc), cbBTC, weth, mUsdc, mCbBTC, mWeth, aero];
        for (uint256 i = 0; i < blocked.length; i++) {
            vm.prank(proposer);
            vm.expectRevert(LeveragedAerodromeCLStrategy.CannotRescuePositionToken.selector);
            strategy.rescueToVault(blocked[i]);

            vm.prank(vaultOwner);
            vm.expectRevert(LeveragedAerodromeCLStrategy.CannotRescuePositionToken.selector);
            strategy.rescueToVault(blocked[i]);
        }
    }

    // ── Width band validation in _initialize (Mamo rerange param; tickSpacing = 100) ──

    /// @dev Fresh clone + initialize with an overridden width band; expects `WidthOutOfBounds`.
    function _expectInitWidthRevert(uint24 width, uint24 minWidth, uint24 maxWidth) internal {
        LeveragedAerodromeCLStrategy.InitParams memory p = _initParams();
        p.width = width;
        p.minWidth = minWidth;
        p.maxWidth = maxWidth;
        LeveragedAerodromeCLStrategy s =
            LeveragedAerodromeCLStrategy(payable(Clones.clone(address(new LeveragedAerodromeCLStrategy()))));
        vm.expectRevert(LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_storesWidthBand() public view {
        LeveragedAerodromeCLStrategy.LayoutView memory v = strategy.layout();
        assertEq(uint256(v.width), 4000, "width not stored");
        assertEq(uint256(v.minWidth), 200, "minWidth not stored");
        assertEq(uint256(v.maxWidth), 20000, "maxWidth not stored");
    }

    function test_init_revertsWidth_aboveMax() public {
        _expectInitWidthRevert(20100, 200, 20000); // width (aligned) > maxWidth
    }

    function test_init_revertsWidth_belowMin() public {
        _expectInitWidthRevert(100, 200, 20000); // width (aligned) < minWidth
    }

    function test_init_revertsWidth_misaligned() public {
        _expectInitWidthRevert(4050, 200, 20000); // width % tickSpacing(100) != 0, in band
    }

    function test_init_revertsWidth_minBelowTwoSpacings() public {
        _expectInitWidthRevert(4000, 100, 20000); // minWidth = 1·tickSpacing < 2·tickSpacing
    }

    function test_init_revertsWidth_bandBoundMisaligned() public {
        _expectInitWidthRevert(4000, 250, 20000); // minWidth not a multiple of tickSpacing
    }

    // ── rerange width-band validation (Mamo per-cycle width; strategy-side, pre-delegatecall) ──
    //
    // `rerange` (onlyProposer nonReentrant) validates `width` with the same pure `_requireWidthInBand`
    // as init, BEFORE the manager delegatecall — so the guard is fork-free. Its entrypoint gates on
    // `State.Executed` FIRST, though, and a freshly-initialized clone is `State.Pending`; flip the
    // packed `_state` byte to Executed (leaving tokenId == 0, a flat book) so the guard is reachable
    // without opening a venue position. The revert cases mirror the RPC-gated
    // `test_rerange_revertsWidth*` fork tests in-gate; the flat-book persist test is new (the fork
    // suite only exercises rerange on a live position).

    /// @dev `_state` lives in BaseStrategy slot 1, byte 20, packed alongside `_proposer` (bytes 0-19)
    ///      and `_initialized` (byte 21). Set it to `State.Executed` (== 1) without clobbering the
    ///      neighbours; tokenId stays 0 so the book is flat and no venue call is made.
    function _forceExecutedState() internal {
        bytes32 slot = bytes32(uint256(1));
        uint256 raw = uint256(vm.load(address(strategy), slot));
        raw &= ~(uint256(0xff) << 160); // clear the _state byte
        raw |= uint256(1) << 160; // State.Executed
        vm.store(address(strategy), slot, bytes32(raw));
    }

    function test_rerange_revertsWidth_belowMin() public {
        _forceExecutedState();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
        strategy.rerange(100, 0, 0); // < minWidth 200 (aligned)
    }

    function test_rerange_revertsWidth_aboveMax() public {
        _forceExecutedState();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
        strategy.rerange(20100, 0, 0); // > maxWidth 20000 (aligned)
    }

    function test_rerange_revertsWidth_misaligned() public {
        _forceExecutedState();
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.WidthOutOfBounds.selector);
        strategy.rerange(4050, 0, 0); // in band but not a multiple of tickSpacing 100
    }

    /// @notice Flat book (tokenId == 0): a valid in-band width persists (the rebalancer reads
    ///         `layout().width` back) and the recenter is skipped (no venue touch). The persist must
    ///         happen even on the flat-book bail so the Mamo rebalancer's choice is not silently
    ///         dropped.
    function test_rerange_flatBook_persistsWidthNoVenue() public {
        _forceExecutedState();
        assertEq(uint256(strategy.layout().width), 4000, "precondition: init width");
        assertEq(uint256(strategy.layout().tokenId), 0, "precondition: flat book (tokenId == 0)");

        uint24 newWidth = 8000; // in [minWidth 200, maxWidth 20000], multiple of tickSpacing 100
        vm.prank(proposer);
        strategy.rerange(newWidth, 0, 0);

        // Persisted — layout().width reflects the accepted choice.
        assertEq(uint256(strategy.layout().width), newWidth, "flat-book rerange did not persist width");
        // Venue untouched: still a flat book, no NFT minted.
        assertEq(uint256(strategy.layout().tokenId), 0, "flat-book rerange must not open a position");
    }
}
