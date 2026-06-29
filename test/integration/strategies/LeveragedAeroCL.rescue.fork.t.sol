// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "../../../src/strategies/BaseStrategy.sol";
import {ICLGauge} from "../../../src/interfaces/ISlipstream.sol";

// ─── Minimal mock ERC-20 ───────────────────────────────────────────────────────

/// @dev Bare-minimum ERC-20 for rescue tests: mint + transfer + balanceOf.
contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─── Test contract ─────────────────────────────────────────────────────────────

/// @title  LeveragedAeroCLRescueFork
/// @notice Task 3.11 TDD: rescueToVault — sweeps foreign ERC-20s to vault,
///         reverts for every position/accounting token, and gate-checks onlyProposer.
///
///         Run locally:
///           forge test --match-path '*LeveragedAeroCL.rescue.fork.t.sol' -vvv
///         Without TENDERLY_FORK_RPC_URL every test returns a vm.skip pass.
contract LeveragedAeroCLRescueFork is LeveragedAeroForkBase {
    // ── Test actors ──
    address internal fakeVault;
    address internal fakeProposer;
    address internal feeRecipient;

    // ── Strategy under test ──
    LeveragedAerodromeCLStrategy internal strategy;

    // ── Risk / fee params (mirroring deploy test) ──
    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint16 internal constant MAX_LTV_BPS = 6500;
    uint16 internal constant MIN_HEALTH_BPS = 12000;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint16 internal constant MGMT_FEE_BPS = 100;
    uint16 internal constant PERF_FEE_BPS = 1000;

    function setUp() public override {
        super.setUp();
        if (_skip) return;

        fakeVault = makeAddr("vault");
        fakeProposer = address(this); // test contract is the proposer
        feeRecipient = makeAddr("feeRecipient");

        // Deploy template + clone (mirrors deploy fork test pattern).
        address template = address(new LeveragedAerodromeCLStrategy());
        address clone = Clones.clone(template);
        strategy = LeveragedAerodromeCLStrategy(payable(clone));
        strategy.initialize(fakeVault, fakeProposer, abi.encode(_buildInitParams()));
    }

    function _buildInitParams() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        p = LeveragedAerodromeCLStrategy.InitParams({
            usdc: BaseAddresses.USDC,
            mUsdc: BaseAddresses.MOONWELL_MUSDC,
            mCbBTC: BaseAddresses.MOONWELL_MCBBTC,
            mWeth: BaseAddresses.MOONWELL_MWETH,
            comptroller: BaseAddresses.MOONWELL_COMPTROLLER,
            cbBTC: BaseAddresses.CBBTC,
            weth: BaseAddresses.WETH,
            pool: BaseAddresses.CBBTC_WETH_POOL,
            npm: BaseAddresses.SLIPSTREAM_NPM,
            gauge: BaseAddresses.CBBTC_WETH_GAUGE,
            swapRouter: BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER,
            cbBTCFeed: BaseAddresses.CHAINLINK_BTC_USD,
            wethFeed: BaseAddresses.CHAINLINK_ETH_USD,
            usdcFeed: BaseAddresses.CHAINLINK_USDC_USD,
            sequencerFeed: BaseAddresses.SEQUENCER_UPTIME_FEED,
            maxDelay: 48 hours,
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: BaseAddresses.CBBTC_WETH_TICK_SPACING,
            targetLtvBps: TARGET_LTV_BPS,
            maxLtvBps: MAX_LTV_BPS,
            minHealthBps: MIN_HEALTH_BPS,
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            managementFeeBps: MGMT_FEE_BPS,
            performanceFeeBps: PERF_FEE_BPS,
            feeRecipient: feeRecipient
        });
    }

    // ─────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────

    /// @notice A foreign ERC-20 accidentally sent to the strategy is swept in full to the vault.
    function test_rescue_sweepsForeignToken() public {
        if (_skip) return;

        MockERC20 mock = new MockERC20();
        uint256 amount = 1_000e18;
        mock.mint(address(strategy), amount);

        assertEq(mock.balanceOf(address(strategy)), amount, "setup: strategy balance wrong");
        assertEq(mock.balanceOf(fakeVault), 0, "setup: vault balance not zero");

        // fakeProposer == address(this), so call is direct (no prank needed).
        strategy.rescueToVault(address(mock));

        assertEq(mock.balanceOf(address(strategy)), 0, "strategy balance not zero after rescue");
        assertEq(mock.balanceOf(fakeVault), amount, "vault did not receive rescued tokens");
    }

    /// @notice rescueToVault reverts CannotRescuePositionToken for each of the 7 blocked tokens.
    function test_rescue_revertsForEachPositionToken() public {
        if (_skip) return;

        address aero = ICLGauge(BaseAddresses.CBBTC_WETH_GAUGE).rewardToken();

        address[7] memory blocked = [
            BaseAddresses.USDC,
            BaseAddresses.CBBTC,
            BaseAddresses.WETH,
            BaseAddresses.MOONWELL_MUSDC,
            BaseAddresses.MOONWELL_MCBBTC,
            BaseAddresses.MOONWELL_MWETH,
            aero
        ];

        for (uint256 i = 0; i < blocked.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(LeveragedAerodromeCLStrategy.CannotRescuePositionToken.selector));
            strategy.rescueToVault(blocked[i]);
        }
    }

    /// @notice A non-proposer cannot call rescueToVault.
    function test_rescue_onlyProposer() public {
        if (_skip) return;

        MockERC20 mock = new MockERC20();
        mock.mint(address(strategy), 1e18);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BaseStrategy.NotProposer.selector));
        strategy.rescueToVault(address(mock));
    }
}
