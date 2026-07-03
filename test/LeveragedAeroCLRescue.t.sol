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
}
