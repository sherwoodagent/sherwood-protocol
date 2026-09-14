// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @title Vault_hwmDecimalQuantization
/// @notice Issue #97 — `PPS_SHARES = 1e18` was documented as *"Fixed at 1e18
///         so the mark's unit is independent of the asset's decimals"*. It was
///         not: share decimals are `assetDecimals + _decimalsOffset()`, and
///         this vault sets `_decimalsOffset()` to the asset's own decimals, so
///         share decimals are `2 * assetDecimals`. `1e18` is "one whole share"
///         only at `assetDecimals == 9`; at 18 (WETH-like) it was `1e-18` of a
///         share, and the high-water mark quantized at 100%-NAV steps. Fixed
///         by quoting the mark against `10 ** decimals()` — one whole share,
///         in the vault's OWN decimals — computed via `_pricePerShareUnit()`.
///         Every test below was written against unpatched `main` and passed
///         there first.
///
/// @dev    `SyndicateFactory.createSyndicate` accepts any asset with no
///         decimals restriction — the existing `test/fees/HighWaterMark.t.sol`
///         suite is exclusively USDC (6 decimals, share decimals = 12), which
///         is exactly the class of asset where this defect is invisible: at
///         d=6, `pps` carries 12 decimals of precision against an 18-decimal
///         unit, so it never quantizes in any test that suite could reach.
contract VaultHwmDecimalQuantizationTest is Test {
    SyndicateVault internal vault;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal weth;
    MockAgentRegistry internal agentRegistry;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal sink = makeAddr("sink");
    address internal constant MOCK_GOVERNOR = address(0xF00D);

    uint256 internal constant DEPOSIT = 100e18;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(weth),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));

        weth.mint(alice, 10_000e18);
        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);
    }

    function _gain(uint256 amount) internal {
        weth.mint(address(vault), amount);
    }

    /// @notice NO MORE QUANTIZATION: with an 18-decimal asset,
    ///         `pricePerShare()` now moves continuously with NAV, at full
    ///         `10 ** decimals()` precision, exactly as it always did for a
    ///         6-decimal asset.
    function test_pricePerShare_movesContinuouslyFor18DecimalAsset() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        assertEq(vault.pricePerShare(), 1e18, "seeded at one whole share, at full precision");

        _gain(25e18); // +25%
        assertApproxEqRel(vault.pricePerShare(), 1.25e18, 1e12, "25% gain reads as +25%");

        _gain(25e18); // total +50%
        assertApproxEqRel(vault.pricePerShare(), 1.5e18, 1e12, "50% gain reads as +50%");

        _gain(49e18); // total +99% (100 + 25 + 25 + 49 = 199e18)
        assertApproxEqRel(vault.pricePerShare(), 1.99e18, 1e12, "99% gain reads as +99%, not as flat");
    }

    /// @notice THE CONSEQUENCE, RESOLVED: a 99% gain now charges a
    ///         performance-fee base proportional to the actual gain, not zero.
    function test_aboveHighWaterMark_isProportionalAt99PercentGain() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        _gain(99e18); // +99%, a real and substantial gain

        // Above the mark by ~99% of the deposit — the mark seeds at the FIRST
        // deposit's price (1e18), so the base is `(pps - mark) * supply /
        // unit`, materially close to the 99e18 raw gain.
        assertApproxEqRel(vault.aboveHighWaterMark(), 99e18, 1e12, "the fee base tracks the real 99% gain");
    }

    /// @notice NO MORE DISCONTINUITY: the fee base rises smoothly across the
    ///         doubling boundary rather than jumping from zero to the whole
    ///         accumulated gain in one step.
    function test_aboveHighWaterMark_risesSmoothlyAcrossTheDoublingBoundary() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        _gain(99e18);
        uint256 at99Pct = vault.aboveHighWaterMark();
        assertGt(at99Pct, 0, "99%: already chargeable, not zero");

        _gain(1e18 + 1); // crosses the doubling
        uint256 atDoubling = vault.aboveHighWaterMark();
        // The increase across this last ~1% of gain is proportional to that
        // gain, not the whole ~99e18 the pre-fix jump would have added.
        assertLt(atDoubling - at99Pct, 2e18, "the increase matches the marginal gain, not the whole prior base");
    }
}
