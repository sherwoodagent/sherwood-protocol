// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LaunchpadStrategy} from "../../src/strategies/LaunchpadStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ILaunchAdapter} from "../../src/interfaces/ILaunchAdapter.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {MockLaunchAdapter, MockCreatorVenue} from "../mocks/MockLaunchAdapter.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Stand-ins
//
// Declared LOCALLY (the `PortfolioStrategyAdapterAllowlist.t.sol` precedent)
// rather than added to the shared mocks, because every selector below is one
// THIS template newly calls: `asset()`, `clock()`, `getPastVotes`,
// `getPastTotalSupply` on the vault, and `getProposal` on the governor. A typed
// call against a stand-in missing a selector reverts undecodably, so the
// stand-ins have to grow with the template — and growing them here keeps every
// other suite's fixtures meaning exactly what they meant before.
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Vault stand-in: ERC-4626 `asset()`, the `governor()` hop the
///         allowlist walk reads, `isAgent` for `onlyProposer`, and the ERC-5805
///         surface the claim is priced against.
contract MockFundVault {
    /// @dev Mirrors OZ's `Votes` error so a test can prove the template's own
    ///      error fires FIRST and this one never surfaces.
    error ERC5805FutureLookup(uint256 timepoint, uint48 clock);

    address public asset;
    address public governor;

    mapping(address => uint256) public votesOf;
    uint256 public totalVotes;

    constructor(address asset_, address governor_) {
        asset = asset_;
        governor = governor_;
    }

    function setGovernor(address governor_) external {
        governor = governor_;
    }

    function isAgent(address) external pure returns (bool) {
        return true;
    }

    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    function setVotes(address holder, uint256 amount) external {
        totalVotes = totalVotes + amount - votesOf[holder];
        votesOf[holder] = amount;
    }

    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        if (timepoint >= block.timestamp) revert ERC5805FutureLookup(timepoint, uint48(block.timestamp));
        return votesOf[account];
    }

    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        if (timepoint >= block.timestamp) revert ERC5805FutureLookup(timepoint, uint48(block.timestamp));
        return totalVotes;
    }

    // ── acting as the vault ──

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    /// @dev Drives a strategy call under an explicit gas cap, the way
    ///      `SyndicateVault._recoverResidueVia` drives `sweep()` under
    ///      `_SWEEP_GAS`. Returns success rather than bubbling, because the
    ///      vault ignores the result too.
    function callStrategyWithGas(address strategy, bytes calldata data, uint256 gasCap) external returns (bool ok) {
        // solhint-disable-next-line avoid-low-level-calls
        (ok,) = strategy.call{gas: gasCap}(data);
    }

    function callStrategy(address strategy, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = strategy.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

/// @notice A vault stand-in with NO `governor()` selector — the walk resolves
///         to nothing, which `_initialize` must treat as fail-closed.
contract MockVaultNoGovernor {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }

    function isAgent(address) external pure returns (bool) {
        return true;
    }
}

/// @notice Governor stand-in: the allowlist hop, the active-proposal binding
///         `BaseStrategy.execute()` enforces, and the `getProposal` struct the
///         claim-window clamp decodes.
contract MockFundGovernor {
    address public tierRegistry;
    uint256 public activeProposal = 1;
    uint256 public executedAt;
    uint256 public strategyDuration = 30 days;

    constructor(address registry_) {
        tierRegistry = registry_;
    }

    function setTierRegistry(address registry_) external {
        tierRegistry = registry_;
    }

    function getActiveProposal() external view returns (uint256) {
        return activeProposal;
    }

    /// @dev DELIBERATELY PERMISSIVE, mirroring `MockGovernorWithRegistry`: any
    ///      clone that resolves to this governor passes the binding check
    ///      without per-test proposal wiring. This suite is about the template,
    ///      not about the binding property (see
    ///      `test/audit-fixes/Strategy_cloneRatchetBinding.t.sol`).
    function strategyOf(uint256) external view returns (address) {
        return msg.sender;
    }

    function setProposal(uint256 executedAt_, uint256 duration_) external {
        executedAt = executedAt_;
        strategyDuration = duration_;
    }

    function getProposal(uint256) external view returns (ISyndicateGovernor.StrategyProposal memory p) {
        p.executedAt = executedAt;
        p.strategyDuration = strategyDuration;
    }
}

/// @notice `ISwapAdapter` stand-in that COUNTS and RECORDS its calls.
/// @dev    Local to this suite rather than folded into the shared
///         `MockSwapAdapter`, so no other suite's fixtures change meaning. It
///         exists for one question the shared mock cannot answer: HOW MANY
///         TIMES did `_execute` cross the pair? The fee hold-back is a
///         slippage optimisation, and the only observable difference between
///         "held the fee back" and "swapped it away and bought it back" is the
///         call count and the amount that went in.
contract RecordingSwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    mapping(bytes32 => uint256) public rates;
    uint256 public constant RATE_PRECISION = 1e18;

    uint256 public swapCalls;
    address[] public inToken;
    address[] public outToken;
    uint256[] public amountsIn;

    error RateNotSet();
    error SlippageExceeded();

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rates[keccak256(abi.encodePacked(tokenIn, tokenOut))] = rate;
    }

    function swapAt(uint256 i) external view returns (address, address, uint256) {
        return (inToken[i], outToken[i], amountsIn[i]);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata)
        external
        returns (uint256 amountOut)
    {
        uint256 rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        if (rate == 0) revert RateNotSet();
        amountOut = (amountIn * rate) / RATE_PRECISION;
        if (amountOut < amountOutMin) revert SlippageExceeded();

        swapCalls++;
        inToken.push(tokenIn);
        outToken.push(tokenOut);
        amountsIn.push(amountIn);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata)
        external
        view
        returns (uint256 amountOut)
    {
        uint256 rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        if (rate == 0) revert RateNotSet();
        amountOut = (amountIn * rate) / RATE_PRECISION;
    }
}

/// @notice Registry stand-in: owner-settable per-adapter allowlist.
contract MockFundRegistry {
    mapping(address => bool) public allowed;

    function setAllowed(address adapter, bool value) external {
        allowed[adapter] = value;
    }

    function isAdapterAllowed(address adapter) external view returns (bool) {
        return allowed[adapter];
    }
}

// ─────────────────────────────────────────────────────────────────────────────

contract LaunchpadStrategyTest is Test {
    using stdStorage for StdStorage;

    LaunchpadStrategy internal template;
    MockFundVault internal vault;
    MockFundGovernor internal governor;
    MockFundRegistry internal registry;
    MockLaunchAdapter internal launchAdapter;
    MockSwapAdapter internal swapAdapter;

    ERC20Mock internal asset;
    ERC20Mock internal quote;
    ERC20Mock internal feeToken;

    address internal proposer = address(0xA6E7);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint256 internal constant ASSET_IN = 1_000e18;
    uint256 internal constant LAUNCH_SUPPLY = 1_000_000e18;
    uint256 internal constant RESERVE = 100_000e18; // 10% — inside MAX_RESERVE_BPS
    uint256 internal constant CLAIM_WINDOW = 7 days;
    uint256 internal constant DURATION = 30 days;
    /// @dev Mirrors `BaseStrategy.RESIDUE_DUST`, which is `internal`.
    uint256 internal constant RESIDUE_DUST = 1e3;

    function setUp() public {
        vm.warp(1_800_000_000);

        asset = new ERC20Mock("Vault Asset", "VA", 18);
        quote = new ERC20Mock("Quote", "QT", 18);
        feeToken = new ERC20Mock("Fee", "FEE", 18);

        registry = new MockFundRegistry();
        governor = new MockFundGovernor(address(registry));
        vault = new MockFundVault(address(asset), address(governor));

        launchAdapter = new MockLaunchAdapter();
        swapAdapter = new MockSwapAdapter();

        registry.setAllowed(address(launchAdapter), true);
        registry.setAllowed(address(swapAdapter), true);

        launchAdapter.setQuoteSupported(address(quote), true);
        launchAdapter.setQuoteSupported(address(asset), true);
        launchAdapter.setMint(LAUNCH_SUPPLY, 0, false);
        launchAdapter.setTarget(address(new MockCreatorVenue()));

        // 1:1 both ways, and asset<->fee for the native-fee leg.
        swapAdapter.setRate(address(asset), address(quote), 1e18);
        swapAdapter.setRate(address(quote), address(asset), 1e18);
        swapAdapter.setRate(address(quote), address(feeToken), 1e18);
        quote.mint(address(swapAdapter), 10_000_000e18);
        asset.mint(address(swapAdapter), 10_000_000e18);
        feeToken.mint(address(swapAdapter), 10_000_000e18);

        asset.mint(address(vault), 10_000e18);

        template = new LaunchpadStrategy();
    }

    // ── helpers ──

    function _params() internal view returns (LaunchpadStrategy.InitParams memory p) {
        p = LaunchpadStrategy.InitParams({
            launchAdapter: address(launchAdapter),
            swapAdapter: address(swapAdapter),
            assetIn: ASSET_IN,
            quoteToken: address(quote),
            minQuoteOut: 900e18,
            quoteSwapData: "",
            feeSwapData: "",
            launchSupply: LAUNCH_SUPPLY,
            reserveAmount: RESERVE,
            minTokensOut: RESERVE,
            claimWindow: CLAIM_WINDOW,
            deadline: uint64(block.timestamp + 1 days),
            settleSlippageBps: 500,
            name: "Fund Token",
            symbol: "FUND",
            venueData: ""
        });
    }

    function _clone(LaunchpadStrategy.InitParams memory p) internal returns (LaunchpadStrategy s) {
        s = LaunchpadStrategy(Clones.clone(address(template)));
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    /// @dev An UNINITIALIZED clone. Init-failure tests need the deploy to
    ///      happen before `vm.expectRevert`, which otherwise consumes the
    ///      `CREATE` of the proxy rather than the `initialize` call.
    function _rawClone() internal returns (LaunchpadStrategy) {
        return LaunchpadStrategy(Clones.clone(address(template)));
    }

    function _cloneDefault() internal returns (LaunchpadStrategy) {
        return _clone(_params());
    }

    /// @dev A funded, allowlisted `RecordingSwapAdapter` wired for every pair
    ///      this suite's fee-routing tests need.
    function _recorder() internal returns (RecordingSwapAdapter rec) {
        rec = new RecordingSwapAdapter();
        rec.setRate(address(asset), address(quote), 1e18);
        rec.setRate(address(quote), address(asset), 1e18);
        rec.setRate(address(quote), address(feeToken), 1e18);
        rec.setRate(address(asset), address(feeToken), 1e18);
        asset.mint(address(rec), 10_000_000e18);
        quote.mint(address(rec), 10_000_000e18);
        feeToken.mint(address(rec), 10_000_000e18);
        registry.setAllowed(address(rec), true);
    }

    function _execute(LaunchpadStrategy s) internal {
        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));
    }

    function _settle(LaunchpadStrategy s) internal {
        vault.callStrategy(address(s), abi.encodeWithSignature("settle()"));
    }

    function _sweep(LaunchpadStrategy s) internal {
        vault.callStrategy(address(s), abi.encodeWithSignature("sweep()"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // init
    // ─────────────────────────────────────────────────────────────────────────

    function test_init_storesConfigAndVaultAsset() public {
        LaunchpadStrategy s = _cloneDefault();
        assertEq(s.name(), "Launchpad");
        assertEq(s.asset(), address(asset), "vault asset read once at init");
        assertEq(address(s.launchAdapter()), address(launchAdapter));
        assertEq(address(s.swapAdapter()), address(swapAdapter));
        assertEq(s.reserveAmount(), RESERVE);
        assertEq(s.claimWindow(), CLAIM_WINDOW);
        assertEq(s.tokenSymbol(), "FUND");
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending));
    }

    function test_init_revertsOnUnsupportedQuote() public {
        launchAdapter.setQuoteSupported(address(quote), false);
        LaunchpadStrategy.InitParams memory p = _params();
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(abi.encodeWithSelector(LaunchpadStrategy.QuoteNotSupported.selector, address(quote)));
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_revertsWhenRegistryUnresolved() public {
        MockVaultNoGovernor bare = new MockVaultNoGovernor(address(asset));
        LaunchpadStrategy s = LaunchpadStrategy(Clones.clone(address(template)));
        vm.expectRevert(LaunchpadStrategy.TierRegistryUnresolved.selector);
        s.initialize(address(bare), proposer, abi.encode(_params()));
    }

    function test_init_revertsWhenLaunchAdapterNotAllowed() public {
        registry.setAllowed(address(launchAdapter), false);
        LaunchpadStrategy.InitParams memory p = _params();
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchpadStrategy.LaunchAdapterNotAllowed.selector, address(launchAdapter), address(registry)
            )
        );
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_revertsWhenSwapAdapterNotAllowed() public {
        registry.setAllowed(address(swapAdapter), false);
        LaunchpadStrategy.InitParams memory p = _params();
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchpadStrategy.SwapAdapterNotAllowed.selector, address(swapAdapter), address(registry)
            )
        );
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_revertsOnZeroReserve() public {
        LaunchpadStrategy.InitParams memory p = _params();
        p.reserveAmount = 0;
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(LaunchpadStrategy.ZeroReserve.selector);
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_revertsWhenReserveAboveCap() public {
        LaunchpadStrategy.InitParams memory p = _params();
        uint256 maxReserve = (LAUNCH_SUPPLY * template.MAX_RESERVE_BPS()) / 10_000;
        p.reserveAmount = maxReserve + 1;
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(abi.encodeWithSelector(LaunchpadStrategy.ReserveTooLarge.selector, maxReserve + 1, maxReserve));
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_acceptsReserveExactlyAtCap() public {
        LaunchpadStrategy.InitParams memory p = _params();
        p.reserveAmount = (LAUNCH_SUPPLY * template.MAX_RESERVE_BPS()) / 10_000;
        LaunchpadStrategy s = _clone(p);
        assertEq(s.reserveAmount(), p.reserveAmount);
    }

    function test_init_revertsWhenWindowAboveMax() public {
        LaunchpadStrategy.InitParams memory p = _params();
        p.claimWindow = template.MAX_CLAIM_WINDOW() + 1;
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchpadStrategy.InvalidClaimWindow.selector, p.claimWindow, template.MAX_CLAIM_WINDOW()
            )
        );
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_revertsOnZeroWindow() public {
        LaunchpadStrategy.InitParams memory p = _params();
        p.claimWindow = 0;
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadStrategy.InvalidClaimWindow.selector, 0, template.MAX_CLAIM_WINDOW())
        );
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_revertsOnSlippageOutOfBounds() public {
        LaunchpadStrategy.InitParams memory p = _params();
        p.settleSlippageBps = template.MAX_SLIPPAGE_BPS() + 1;
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(abi.encodeWithSelector(LaunchpadStrategy.InvalidSlippage.selector, p.settleSlippageBps));
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    function test_init_revertsOnZeroAssetIn() public {
        LaunchpadStrategy.InitParams memory p = _params();
        p.assetIn = 0;
        LaunchpadStrategy s = _rawClone();
        vm.expectRevert(LaunchpadStrategy.InvalidAmount.selector);
        s.initialize(address(vault), proposer, abi.encode(p));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // updateParams — pre-execute only, tightening only
    // ─────────────────────────────────────────────────────────────────────────

    function test_updateParams_raisesMinTokensOut() public {
        LaunchpadStrategy s = _cloneDefault();
        vm.prank(proposer);
        s.updateParams(
            abi.encode(
                LaunchpadStrategy.UpdateParams({
                    minTokensOut: RESERVE + 1,
                    minQuoteOut: 950e18,
                    settleSlippageBps: 300,
                    deadline: uint64(block.timestamp + 3 days)
                })
            )
        );
        assertEq(s.minTokensOut(), RESERVE + 1);
        assertEq(s.minQuoteOut(), 950e18);
        assertEq(s.settleSlippageBps(), 300);
        assertEq(s.deadline(), uint64(block.timestamp + 3 days));
    }

    function test_updateParams_revertsWhenLoweringMinTokensOut() public {
        LaunchpadStrategy s = _cloneDefault();
        vm.prank(proposer);
        vm.expectRevert(LaunchpadStrategy.NotTightening.selector);
        s.updateParams(
            abi.encode(
                LaunchpadStrategy.UpdateParams({
                    minTokensOut: RESERVE - 1,
                    minQuoteOut: 900e18,
                    settleSlippageBps: 500,
                    deadline: uint64(block.timestamp + 1 days)
                })
            )
        );
    }

    function test_updateParams_revertsWhenWideningSlippage() public {
        LaunchpadStrategy s = _cloneDefault();
        vm.prank(proposer);
        vm.expectRevert(LaunchpadStrategy.NotTightening.selector);
        s.updateParams(
            abi.encode(
                LaunchpadStrategy.UpdateParams({
                    minTokensOut: RESERVE,
                    minQuoteOut: 900e18,
                    settleSlippageBps: 501,
                    deadline: uint64(block.timestamp + 1 days)
                })
            )
        );
    }

    function test_updateParams_revertsAfterExecute() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.prank(proposer);
        vm.expectRevert(LaunchpadStrategy.NotPending.selector);
        s.updateParams(
            abi.encode(
                LaunchpadStrategy.UpdateParams({
                    minTokensOut: RESERVE + 1,
                    minQuoteOut: 900e18,
                    settleSlippageBps: 500,
                    deadline: uint64(block.timestamp + 1 days)
                })
            )
        );
    }

    function test_updateParams_revertsForNonProposer() public {
        LaunchpadStrategy s = _cloneDefault();
        vm.prank(alice);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        s.updateParams(
            abi.encode(
                LaunchpadStrategy.UpdateParams({
                    minTokensOut: RESERVE + 1,
                    minQuoteOut: 900e18,
                    settleSlippageBps: 500,
                    deadline: uint64(block.timestamp + 1 days)
                })
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // execute
    // ─────────────────────────────────────────────────────────────────────────

    function test_execute_happyPath_quoteDiffersFromAsset() public {
        LaunchpadStrategy s = _cloneDefault();
        uint256 vaultBefore = asset.balanceOf(address(vault));
        _execute(s);

        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Executed));
        assertTrue(s.launchToken() != address(0), "launch token recorded");
        assertEq(s.reserve(), RESERVE);
        assertEq(IERC20(s.launchToken()).balanceOf(address(s)), RESERVE, "reserve in strategy custody");
        assertEq(IERC20(s.launchToken()).totalSupply(), LAUNCH_SUPPLY);
        assertEq(s.snap(), block.timestamp, "snapshot is the vault clock at execute");
        assertEq(asset.balanceOf(address(vault)), vaultBefore - ASSET_IN);
        // the whole budget routed through the quote leg
        assertEq(launchAdapter.lastQuoteIn(), ASSET_IN);
        assertEq(launchAdapter.lastQuoteToken(), address(quote));
        // no standing approvals
        assertEq(quote.allowance(address(s), address(launchAdapter)), 0);
        assertEq(asset.allowance(address(s), address(swapAdapter)), 0);
    }

    function test_execute_happyPath_quoteEqualsAsset() public {
        LaunchpadStrategy.InitParams memory p = _params();
        p.quoteToken = address(asset);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);
        _execute(s);

        assertEq(launchAdapter.lastQuoteToken(), address(asset));
        assertEq(launchAdapter.lastQuoteIn(), ASSET_IN, "no swap leg when the quote IS the vault asset");
        assertEq(IERC20(s.launchToken()).balanceOf(address(s)), RESERVE);
    }

    function test_execute_acquiresNamedNativeFeeToken() public {
        launchAdapter.setNativeFee(address(feeToken), 1e18);
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);

        assertEq(feeToken.balanceOf(address(launchAdapter)), 1e18, "venue fee pulled in the token it named");
        assertLt(launchAdapter.lastQuoteIn(), ASSET_IN, "fee was sourced from the quote, not assumed to be WETH");
        assertEq(feeToken.allowance(address(s), address(launchAdapter)), 0, "fee approval zeroed");
    }

    // ── native-fee routing: the hold-back that avoids a round trip ──

    /// @dev quote != asset AND the venue's fee is denominated in the VAULT
    ///      ASSET — the ordinary WETH-vault / Sushi-ETH-fee case. The strategy
    ///      must hold `feeAmount` of the asset back and cross the pair ONCE.
    ///      Swapping the whole budget and buying the fee back would pay
    ///      slippage twice, which on a thin lane is the difference between a
    ///      launch and a failed one.
    function test_execute_feeInVaultAsset_holdsBackAndSwapsOnce() public {
        RecordingSwapAdapter rec = _recorder();
        uint256 fee = 5e18;
        launchAdapter.setNativeFee(address(asset), fee);

        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);
        _execute(s);

        assertEq(rec.swapCalls(), 1, "the pair is crossed exactly once");
        (address tIn, address tOut, uint256 amtIn) = rec.swapAt(0);
        assertEq(tIn, address(asset));
        assertEq(tOut, address(quote));
        assertEq(amtIn, ASSET_IN - fee, "only the budget MINUS the held-back fee is swapped");

        assertEq(asset.balanceOf(address(launchAdapter)), fee, "the venue got its fee in the asset");
        assertEq(launchAdapter.lastQuoteIn(), ASSET_IN - fee);
        assertEq(asset.balanceOf(address(s)), 0, "no asset stranded");
        assertEq(asset.allowance(address(s), address(launchAdapter)), 0, "fee approval zeroed");
    }

    /// @dev The budget must cover the fee AND leave something to launch with.
    ///      Fails closed BEFORE any swap and before the launch.
    function test_execute_feeInVaultAsset_revertsWhenBudgetCannotCoverFee() public {
        RecordingSwapAdapter rec = _recorder();
        launchAdapter.setNativeFee(address(asset), ASSET_IN);

        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);

        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadStrategy.FeeAcquisitionFailed.selector, address(asset), ASSET_IN, ASSET_IN)
        );
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));

        assertEq(rec.swapCalls(), 0, "no swap happened");
        assertEq(s.launchToken(), address(0), "no launch happened");
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending));
    }

    /// @dev The fallback path must stay unbroken: a fee token that is NEITHER
    ///      the vault asset NOR the quote is still acquired by swapping the
    ///      quote, so the hold-back optimisation did not narrow the template to
    ///      the one venue shape it was written for.
    function test_execute_feeInThirdToken_stillSwapsFromQuote() public {
        RecordingSwapAdapter rec = _recorder();
        uint256 fee = 1e18;
        launchAdapter.setNativeFee(address(feeToken), fee);

        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);
        _execute(s);

        assertEq(rec.swapCalls(), 2, "quote leg plus the fee leg");
        (address t0In, address t0Out, uint256 amt0) = rec.swapAt(0);
        assertEq(t0In, address(asset));
        assertEq(t0Out, address(quote));
        assertEq(amt0, ASSET_IN, "nothing is held back when the fee is not the asset");
        (address t1In, address t1Out,) = rec.swapAt(1);
        assertEq(t1In, address(quote), "the fee is sourced from the quote");
        assertEq(t1Out, address(feeToken));

        assertEq(feeToken.balanceOf(address(launchAdapter)), fee);
        assertTrue(s.launchToken() != address(0));
    }

    /// @dev The fee token IS the quote: already held after the quote leg, so no
    ///      second swap, and the approval covers `quoteIn + feeAmount`.
    function test_execute_feeInQuoteToken_needsNoSecondSwap() public {
        RecordingSwapAdapter rec = _recorder();
        uint256 fee = 10e18;
        launchAdapter.setNativeFee(address(quote), fee);

        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);
        _execute(s);

        assertEq(rec.swapCalls(), 1, "the quote leg already bought the fee");
        (,, uint256 amt0) = rec.swapAt(0);
        assertEq(amt0, ASSET_IN, "nothing held back: the fee is not the asset");
        assertEq(launchAdapter.lastQuoteIn(), ASSET_IN - fee, "quoteIn excludes the fee");
        assertEq(quote.balanceOf(address(launchAdapter)), ASSET_IN, "venue pulled quoteIn AND the fee");
    }

    // ── the fee-swap overshoot: an exact-INPUT swap cannot hit an exact output ──

    /// @dev DEFECT A, the regression. `_acquireFeeToken` sizes an exact-INPUT
    ///      swap from a forward quote and adds `settleSlippageBps` of headroom,
    ///      so it ALWAYS buys more fee token than the venue pulls. When the fee
    ///      token is neither the vault asset nor the launch quote, that
    ///      overshoot used to rest on the clone FOREVER: `sweep()` moves only
    ///      `asset`, `launchToken` and the quote, `undeliveredValue()` counts
    ///      vault-asset only, and `hasUnvaluedResidue()` counts launch-token and
    ///      quote only — so it was unrecoverable AND undeclared.
    ///
    ///      Measured on the Robinhood fork: clone 0x6Cb8…511C bought
    ///      515,002,662,640,967 wei of WETH for a 500,000,000,000,000 wei fee
    ///      and 15,002,662,640,967 wei survived two `collectResidue` calls.
    ///
    ///      Asserted as an EXACT figure, not "small": at a 1:1 rate the
    ///      overshoot is `fee * settleSlippageBps / BPS` to the wei.
    function test_execute_feeInThirdToken_overshootIsDeliveredToTheVault() public {
        RecordingSwapAdapter rec = _recorder();
        uint256 fee = 1e18;
        launchAdapter.setNativeFee(address(feeToken), fee);

        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);

        // What the sizing formula buys at a 1:1 rate, to the wei.
        uint256 bought = (fee * (10_000 + p.settleSlippageBps)) / 10_000;
        uint256 overshoot = bought - fee;
        assertGt(overshoot, 0, "the fixture must actually overshoot, or it proves nothing");

        uint256 vaultBefore = feeToken.balanceOf(address(vault));
        _execute(s);

        assertEq(feeToken.balanceOf(address(launchAdapter)), fee, "the venue pulled exactly its fee");
        assertEq(feeToken.balanceOf(address(s)), 0, "NOTHING is stranded on the clone, not even transiently");
        assertEq(
            feeToken.balanceOf(address(vault)) - vaultBefore, overshoot, "the exact overshoot reached the vault in kind"
        );
    }

    /// @dev The same overshoot, announced. A silent delivery is only half the
    ///      fix: the vault warehouses this token unpriced, so the arrival has to
    ///      be readable off-chain.
    function test_execute_feeInThirdToken_overshootIsAnnounced() public {
        RecordingSwapAdapter rec = _recorder();
        uint256 fee = 2e18;
        launchAdapter.setNativeFee(address(feeToken), fee);

        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);

        uint256 overshoot = (fee * (10_000 + p.settleSlippageBps)) / 10_000 - fee;

        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.expectEmit(true, true, false, true, address(s));
        emit LaunchpadStrategy.FeeTokenResidueDelivered(address(feeToken), address(vault), overshoot);
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));
    }

    /// @dev THE FEE TOKEN IS THE QUOTE — unchanged. There is no second swap, so
    ///      there is no overshoot, and the residual push must NOT fire: the
    ///      quote is the launch's own lane, declared by `hasUnvaluedResidue()`
    ///      and converted at settlement. Hijacking it to the vault here would
    ///      move settlement's job into execute.
    function test_execute_feeInQuoteToken_noResidualPushFires() public {
        RecordingSwapAdapter rec = _recorder();
        uint256 fee = 10e18;
        launchAdapter.setNativeFee(address(quote), fee);

        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);

        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.recordLogs();
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));

        assertEq(_residueDeliveries(vm.getRecordedLogs()), 0, "the quote lane is never the residual lane");
        assertEq(rec.swapCalls(), 1, "still one swap");
        assertEq(launchAdapter.lastQuoteIn(), ASSET_IN - fee, "quoteIn still excludes the fee");
        assertEq(quote.balanceOf(address(launchAdapter)), ASSET_IN, "the venue still pulled quoteIn AND the fee");
        assertEq(quote.balanceOf(address(vault)), 0, "no quote was pushed to the vault at execute");
    }

    /// @dev THE FEE TOKEN IS THE VAULT ASSET — unchanged. The hold-back means
    ///      no fee swap and therefore no overshoot at all; anything left is
    ///      asset, which `_pushAllToVault(asset)` already returns, so the
    ///      residual push must not fire a second, redundant transfer.
    function test_execute_feeInVaultAsset_noResidualPushFires() public {
        RecordingSwapAdapter rec = _recorder();
        uint256 fee = 5e18;
        launchAdapter.setNativeFee(address(asset), fee);

        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);

        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.recordLogs();
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));

        assertEq(_residueDeliveries(vm.getRecordedLogs()), 0, "the asset lane is never the residual lane");
        assertEq(rec.swapCalls(), 1, "the pair is still crossed exactly once");
        assertEq(asset.balanceOf(address(s)), 0, "no asset stranded");
        assertEq(asset.balanceOf(address(launchAdapter)), fee, "the venue still got its fee in the asset");
    }

    /// @dev Counts `FeeTokenResidueDelivered` logs in a recorded trace.
    function _residueDeliveries(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        bytes32 topic = LaunchpadStrategy.FeeTokenResidueDelivered.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    /// @dev The zero-fee path is untouched by the reordering: one swap, the
    ///      whole budget.
    function test_execute_noNativeFee_swapsWholeBudgetOnce() public {
        RecordingSwapAdapter rec = _recorder();
        LaunchpadStrategy.InitParams memory p = _params();
        p.swapAdapter = address(rec);
        p.minQuoteOut = 0;
        LaunchpadStrategy s = _clone(p);
        _execute(s);

        assertEq(rec.swapCalls(), 1);
        (,, uint256 amt0) = rec.swapAt(0);
        assertEq(amt0, ASSET_IN);
        assertEq(launchAdapter.lastQuoteIn(), ASSET_IN);
    }

    function test_execute_revertsWhenLaunchAdapterDemotedAfterInit() public {
        LaunchpadStrategy s = _cloneDefault();
        registry.setAllowed(address(launchAdapter), false);
        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchpadStrategy.LaunchAdapterNotAllowed.selector, address(launchAdapter), address(registry)
            )
        );
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));
        assertEq(asset.balanceOf(address(s)), 0, "no capital left the vault");
    }

    function test_execute_revertsWhenSwapAdapterDemotedAfterInit() public {
        LaunchpadStrategy s = _cloneDefault();
        registry.setAllowed(address(swapAdapter), false);
        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchpadStrategy.SwapAdapterNotAllowed.selector, address(swapAdapter), address(registry)
            )
        );
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));
    }

    function test_execute_revertsWhenLaunchUnderDeliversReserve() public {
        launchAdapter.setMint(LAUNCH_SUPPLY, RESERVE - 1, true);
        LaunchpadStrategy s = _cloneDefault();
        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadStrategy.ReserveNotDelivered.selector, RESERVE - 1, RESERVE - 1, RESERVE)
        );
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));
    }

    function test_execute_revertsWhenDeclaredSupplyMismatches() public {
        // The proposer declared LAUNCH_SUPPLY at init; the venue mints double.
        launchAdapter.setMint(LAUNCH_SUPPLY * 2, 0, false);
        LaunchpadStrategy s = _cloneDefault();
        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadStrategy.SupplyMismatch.selector, LAUNCH_SUPPLY * 2, LAUNCH_SUPPLY)
        );
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));
    }

    /// @dev Branch A of the `min`: the configured window is the tighter arm.
    function test_execute_windowFromConfigWhenProposalIsLong() public {
        LaunchpadStrategy s = _cloneDefault();
        uint256 t0 = block.timestamp;
        _execute(s);
        assertEq(s.windowEnd(), t0 + CLAIM_WINDOW);
        assertEq(s.anyoneSettleAt(), t0 + DURATION);
    }

    /// @dev Branch B of the `min`: the proposal truncates the window.
    function test_execute_windowTruncatedByProposal() public {
        LaunchpadStrategy s = _cloneDefault();
        uint256 t0 = block.timestamp;
        uint256 shortDuration = 2 days;
        governor.setProposal(t0, shortDuration);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));

        assertEq(s.windowEnd(), t0 + shortDuration - s.CLAIM_SETTLE_BUFFER());
        assertLt(s.windowEnd(), t0 + CLAIM_WINDOW, "truncated below the configured window");
        assertEq(s.anyoneSettleAt(), t0 + shortDuration);
    }

    /// @dev Exactly on the boundary: both arms of the `min` are equal.
    function test_execute_windowBoundaryExact() public {
        LaunchpadStrategy s = _cloneDefault();
        uint256 t0 = block.timestamp;
        uint256 exact = CLAIM_WINDOW + s.CLAIM_SETTLE_BUFFER();
        governor.setProposal(t0, exact);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));

        assertEq(s.windowEnd(), t0 + CLAIM_WINDOW);
        assertEq(s.windowEnd(), t0 + exact - s.CLAIM_SETTLE_BUFFER(), "both arms agree on the boundary");
    }

    function test_execute_revertsWhenDurationAtBuffer() public {
        LaunchpadStrategy s = _cloneDefault();
        uint256 buffer = s.CLAIM_SETTLE_BUFFER();
        governor.setProposal(block.timestamp, buffer);
        vault.approveToken(address(asset), address(s), ASSET_IN);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadStrategy.StrategyDurationTooShort.selector, buffer, buffer));
        vault.callStrategy(address(s), abi.encodeWithSignature("execute()"));

        // Fail-closed BEFORE any capital is committed: the launch never ran.
        assertEq(s.launchToken(), address(0));
        assertEq(asset.balanceOf(address(s)), 0);
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // claim
    // ─────────────────────────────────────────────────────────────────────────

    function _executedWithHolders() internal returns (LaunchpadStrategy s) {
        vault.setVotes(alice, 500e18);
        vault.setVotes(bob, 300e18);
        vault.setVotes(carol, 200e18);
        s = _cloneDefault();
        _execute(s);
        vm.warp(block.timestamp + 1);
    }

    function test_claim_proRataAcrossHolders() public {
        LaunchpadStrategy s = _executedWithHolders();
        IERC20 token = IERC20(s.launchToken());

        vm.prank(alice);
        s.claim();
        vm.prank(bob);
        s.claim();
        vm.prank(carol);
        s.claim();

        assertEq(token.balanceOf(alice), RESERVE / 2);
        assertEq(token.balanceOf(bob), (RESERVE * 3) / 10);
        assertEq(token.balanceOf(carol), RESERVE / 5);
        assertEq(s.totalClaimed(), RESERVE);
        assertEq(token.balanceOf(address(s)), 0);
    }

    function test_claimFor_paysTheHolderNotTheCaller() public {
        LaunchpadStrategy s = _executedWithHolders();
        vm.prank(alice); // any caller
        s.claimFor(bob);
        assertEq(IERC20(s.launchToken()).balanceOf(bob), (RESERVE * 3) / 10);
        assertEq(IERC20(s.launchToken()).balanceOf(alice), 0);
    }

    /// @dev ONE SHOT PER HOLDER. `reserve` is immutable after execute — nothing
    ///      can grow it — so a second claim is `AlreadyClaimed`, not a
    ///      zero-value top-up.
    function test_claim_revertsOnDoubleClaim() public {
        LaunchpadStrategy s = _executedWithHolders();
        vm.prank(alice);
        s.claim();
        uint256 balBefore = IERC20(s.launchToken()).balanceOf(alice);
        assertTrue(s.claimed(alice), "the flag is set");
        assertEq(s.claimable(alice), 0, "nothing outstanding");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadStrategy.AlreadyClaimed.selector, alice));
        s.claim();
        assertEq(IERC20(s.launchToken()).balanceOf(alice), balBefore, "no tokens moved");
    }

    function test_claim_revertsOnZeroEntitlement() public {
        LaunchpadStrategy s = _executedWithHolders();
        address latecomer = address(0xDEAD);
        vm.prank(latecomer);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadStrategy.ZeroEntitlement.selector, latecomer));
        s.claim();
    }

    /// @dev The template's OWN error, never OZ's `ERC5805FutureLookup`.
    function test_claim_atSnapshotBlockRevertsWithTemplateError() public {
        vault.setVotes(alice, 1e18);
        LaunchpadStrategy s = _cloneDefault();
        _execute(s); // no warp: clock() == snap

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadStrategy.SnapshotNotFinal.selector, block.timestamp, block.timestamp)
        );
        s.claim();

        // …and provably NOT the OZ error the vault would have thrown.
        vm.prank(alice);
        try s.claim() {
            revert("claim should have reverted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), LaunchpadStrategy.SnapshotNotFinal.selector);
            assertTrue(bytes4(err) != MockFundVault.ERC5805FutureLookup.selector, "OZ error must not bubble");
        }
    }

    function test_claim_revertsAfterWindow() public {
        LaunchpadStrategy s = _executedWithHolders();
        vm.warp(s.windowEnd() + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadStrategy.ClaimWindowClosed.selector, block.timestamp, s.windowEnd())
        );
        s.claim();
    }

    function test_claim_revertsBeforeExecute() public {
        LaunchpadStrategy s = _cloneDefault();
        vm.prank(alice);
        vm.expectRevert(LaunchpadStrategy.NotClaimable.selector);
        s.claim();
    }

    /// @dev Σ(claims) SHALL never exceed the recorded reserve, whatever the
    ///      weight distribution — the floor division is what guarantees it.
    function testFuzz_claimSumNeverExceedsReserve(uint128 wA, uint128 wB, uint128 wC) public {
        vm.assume(uint256(wA) + uint256(wB) + uint256(wC) > 0);
        vault.setVotes(alice, wA);
        vault.setVotes(bob, wB);
        vault.setVotes(carol, wC);

        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(block.timestamp + 1);

        address[3] memory holders = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.prank(holders[i]);
            try s.claim() {} catch {}
        }

        assertLe(s.totalClaimed(), s.reserve(), "claims never exceed the reserve");
        assertEq(
            IERC20(s.launchToken()).balanceOf(address(s)), s.reserve() - s.totalClaimed(), "custody matches the books"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // creator fees — named at launch, paid to the vault, never in clone custody
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev THE ONE THING THE STRATEGY DOES ABOUT FEES. `feeRecipient` is not an
    ///      `InitParams` member at all, so no proposer can steer it: `_execute`
    ///      reads `vault()` and puts that in the `LaunchParams` it builds.
    function test_feeRouting_executeNamesTheVaultAsFeeRecipient() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);

        assertEq(launchAdapter.lastFeeRecipient(), address(vault), "the launch named the FUND'S vault");
        assertTrue(launchAdapter.lastFeeRecipient() != address(s), "and never the strategy");
    }

    /// @dev FEES NEVER ENTER CLONE CUSTODY, so there is nothing for the strategy
    ///      to hold, convert, hand over or re-point — which is why `collectFees`
    ///      is gone from this contract entirely. Anyone drives the ADAPTER's
    ///      permissionless verb; the strategy's balances and its claim pot are
    ///      untouched by the payout.
    function test_feeRouting_payoutNeverTouchesTheStrategy() public {
        vault.setVotes(alice, 1_000e18);
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        IERC20 token = IERC20(s.launchToken());

        uint256 strategyTokenBefore = token.balanceOf(address(s));
        uint256 strategyQuoteBefore = quote.balanceOf(address(s));
        uint256 reserveBefore = s.reserve();
        uint256 vaultTokenBefore = token.balanceOf(address(vault));
        uint256 vaultQuoteBefore = quote.balanceOf(address(vault));

        launchAdapter.setFeeAccrual(100e18, 25e18);
        vm.prank(address(0xFEED)); // an arbitrary keeper, no strategy hop
        launchAdapter.collectFees(s.launchRef());

        assertEq(token.balanceOf(address(vault)) - vaultTokenBefore, 25e18, "fee tokens landed at the vault");
        assertEq(quote.balanceOf(address(vault)) - vaultQuoteBefore, 100e18, "fee quote landed at the vault");
        assertEq(token.balanceOf(address(s)), strategyTokenBefore, "strategy launch-token balance untouched");
        assertEq(quote.balanceOf(address(s)), strategyQuoteBefore, "strategy quote balance untouched");
        assertEq(s.reserve(), reserveBefore, "and a fee payout cannot move the claim pot");

        // The claim is still exactly the execute-time reserve, fees or no fees.
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        assertEq(s.claim(), RESERVE, "sole holder claims the reserve, never the fees");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // settle
    // ─────────────────────────────────────────────────────────────────────────

    function test_settle_revertsWhileClaimWindowOpen() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchpadStrategy.ClaimWindowStillOpen.selector, block.timestamp, s.windowEnd(), s.anyoneSettleAt()
            )
        );
        _settle(s);
    }

    function test_settle_succeedsAfterWindow() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled));
    }

    /// @dev THE WEDGE-PROOFING TEST. With a coherent governor decode the clamp
    ///      guarantees `windowEnd < anyoneSettleAt`, so this branch is
    ///      unreachable by construction — which is exactly why it is tested by
    ///      POISONING `windowEnd` directly: that models the corrupt-decode case
    ///      the disjunction exists for (a governor that reorders
    ///      `StrategyProposal` writes garbage into the clamp). Settlement must
    ///      still open at `anyoneSettleAt`, or the clone pins
    ///      `openProposalCount() != 0` with no permissionless exit.
    function test_settle_backstopOpensAtAnyoneSettleAt() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        uint256 anyoneAt = s.anyoneSettleAt();

        stdstore.target(address(s)).sig("windowEnd()").checked_write(type(uint256).max);
        assertEq(s.windowEnd(), type(uint256).max, "window poisoned past the proposal");

        vm.warp(anyoneAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchpadStrategy.ClaimWindowStillOpen.selector, block.timestamp, type(uint256).max, anyoneAt
            )
        );
        _settle(s);

        vm.warp(anyoneAt);
        _settle(s);
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled), "backstop opened settlement");
    }

    /// @dev The quote residue is what the LAUNCH left behind (a venue that
    ///      spent less than `quoteIn`), never a fee arrival: fees are the
    ///      vault's from the launch block and never reach this clone.
    function test_settle_convertsQuoteResidueToVaultAsset() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        quote.mint(address(s), 100e18); // unspent launch quote
        uint256 vaultBefore = asset.balanceOf(address(vault));
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        assertEq(quote.balanceOf(address(s)), 0, "quote converted");
        assertEq(asset.balanceOf(address(vault)) - vaultBefore, 100e18);
    }

    function test_settle_leavesQuoteInCustodyWhenSwapFails() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        quote.mint(address(s), 100e18);
        swapAdapter.setRate(address(quote), address(asset), 0); // unquotable
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled), "settlement still completes");
        assertEq(quote.balanceOf(address(s)), 100e18, "quote left as declared residue");
        assertTrue(s.hasUnvaluedResidue(), "the residue is DECLARED, not hidden");
    }

    function test_settle_neverSellsTheFundToken() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        // The whole unclaimed reserve is still here — no route existed for it
        // and none was invented.
        assertEq(IERC20(s.launchToken()).balanceOf(address(s)), RESERVE);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // residue: the split latch
    // ─────────────────────────────────────────────────────────────────────────

    function test_residue_flagTrueAtSettlementWithUnclaimedReserve() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        assertTrue(s.hasUnvaluedResidue(), "custody is at its maximum at settlement");
        assertFalse(s.residueLatched(), "the latch is NOT armed at settlement itself");
    }

    /// @dev The spec's donation scenario, plus the SPLIT the spec insists on:
    ///      the launch-token predicate latches, the vault-asset figure does not.
    function test_residue_splitLatch_donationCannotReMark() public {
        // A clone that settles ALREADY CLEAR of fund tokens: one holder owns
        // 100% of the snapshot and claims the whole reserve, so no clearing
        // sweep ever runs.
        vault.setVotes(alice, 1_000e18);
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        s.claim();
        address token = s.launchToken();
        assertEq(IERC20(token).balanceOf(address(s)), 0);

        vm.warp(s.windowEnd() + 1);
        _settle(s);

        // Vault-asset residue arrives (benign donation), and the latch is armed
        // by the permissionless poke — no sweep involved.
        asset.mint(address(s), 42e18);
        assertFalse(s.hasUnvaluedResidue(), "nothing unvaluable in custody");
        vm.prank(address(0xBEEF));
        assertTrue(s.pokeResidueLatch(), "first post-settlement false observation latches");

        // Now the griefer donates fund tokens above the dust floor.
        ERC20Mock(token).mint(address(s), RESIDUE_DUST + 1);
        assertGt(IERC20(token).balanceOf(address(s)), RESIDUE_DUST);
        assertFalse(s.hasUnvaluedResidue(), "latched false forever: cannot re-mark, cannot re-stamp the lock");

        // …WHILE the vault-asset figure stays honest. The two are NOT latched
        // together: latching this on a fund-token observation IS the finding-#3
        // skim.
        assertEq(s.undeliveredValue(), 42e18, "vault-asset custody still reported");
        assertTrue(s.hasUndeliveredValue(), "tracks the amount, not the unvalued flag");
    }

    function test_residue_latchArmedBySweep() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        assertTrue(s.hasUnvaluedResidue());

        _sweep(s);
        assertTrue(s.residueLatched(), "a clearing sweep arms the latch");
        assertFalse(s.hasUnvaluedResidue());

        ERC20Mock(s.launchToken()).mint(address(s), RESIDUE_DUST + 1);
        assertFalse(s.hasUnvaluedResidue(), "re-donation cannot flip it back");
    }

    function test_residue_pokeIsNoOpBeforeSettlement() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        assertFalse(s.pokeResidueLatch(), "no latch before Settled");
        assertFalse(s.hasUnvaluedResidue(), "views answer only for Settled");
        assertEq(s.undeliveredValue(), 0);
    }

    function test_residue_viewsNeverRevertWithHostileToken() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        // A launch token whose `balanceOf` reverts — the probe must resolve it
        // to 0, not propagate, since the vault reads these under a gas cap and
        // treats a failure as "no residue".
        vm.mockCallRevert(
            s.launchToken(), abi.encodeWithSelector(IERC20.balanceOf.selector, address(s)), "hostile token"
        );
        assertFalse(s.hasUnvaluedResidue());
        assertEq(s.undeliveredValue(), 0);
        assertFalse(s.hasUndeliveredValue());
        vm.clearMockedCalls();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // sweep
    // ─────────────────────────────────────────────────────────────────────────

    function test_sweep_movesAllThreeBalancesAndMakesNoVenueCall() public {
        MockCreatorVenue venue = new MockCreatorVenue();
        launchAdapter.setTarget(address(venue));
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        quote.mint(address(s), 50e18);
        swapAdapter.setRate(address(quote), address(asset), 0); // leave quote behind
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        uint256 venueCallsBefore = venue.calls();
        asset.mint(address(s), 7e18);

        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        uint256 vaultQuoteBefore = quote.balanceOf(address(vault));
        uint256 vaultTokenBefore = IERC20(s.launchToken()).balanceOf(address(vault));

        _sweep(s);

        assertEq(asset.balanceOf(address(vault)) - vaultAssetBefore, 7e18, "vault asset pushed");
        assertEq(quote.balanceOf(address(vault)) - vaultQuoteBefore, 50e18, "leftover quote warehoused");
        assertEq(
            IERC20(s.launchToken()).balanceOf(address(vault)) - vaultTokenBefore,
            RESERVE,
            "fund tokens warehoused unpriced"
        );
        assertEq(asset.balanceOf(address(s)), 0);
        assertEq(quote.balanceOf(address(s)), 0);
        assertEq(IERC20(s.launchToken()).balanceOf(address(s)), 0);

        assertEq(venue.calls(), venueCallsBefore, "sweep makes NO venue call");
        assertEq(s.undeliveredValue(), 0);
        assertFalse(s.hasUnvaluedResidue());
    }

    /// @dev The vault drives `sweep()` under a hard `_SWEEP_GAS = 1_500_000`
    ///      cap and IGNORES the result, so an out-of-gas sweep silently
    ///      recovers nothing. Balance-only is what keeps it inside the cap.
    function test_sweep_fitsTheVaultSweepGasCap() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        quote.mint(address(s), 50e18);
        swapAdapter.setRate(address(quote), address(asset), 0);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        asset.mint(address(s), 7e18);

        bool ok = vault.callStrategyWithGas(address(s), abi.encodeWithSignature("sweep()"), 1_500_000);
        assertTrue(ok, "sweep must fit the vault's _SWEEP_GAS cap");
        assertEq(IERC20(s.launchToken()).balanceOf(address(s)), 0);
    }

    /// @dev The vault probes the three delivery views under
    ///      `_PROBE_GAS = 150_000`; a probe that runs out of gas reads as "no
    ///      residue", which is finding #3 restored.
    function test_deliveryViews_fitTheVaultProbeGasCap() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        (bool a,) = address(s).staticcall{gas: 150_000}(abi.encodeWithSignature("hasUnvaluedResidue()"));
        (bool b,) = address(s).staticcall{gas: 150_000}(abi.encodeWithSignature("undeliveredValue()"));
        (bool c,) = address(s).staticcall{gas: 150_000}(abi.encodeWithSignature("hasUndeliveredValue()"));
        assertTrue(a && b && c, "all three probes fit _PROBE_GAS");
    }

    function test_sweep_revertsBeforeSettlement() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.expectRevert(LaunchpadStrategy.NotSettled.selector);
        _sweep(s);
    }

    function test_sweep_revertsForNonVault() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        vm.prank(alice);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        s.sweep();
    }
    // ─────────────────────────────────────────────────────────────────────────
    // Unpriced cost basis
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The template announces up front that it converts capital.
    /// @dev    Read by the governor at PROPOSE time and snapshotted onto the
    ///         proposal, so a guardian reviewing a launch sees the intent before
    ///         execution instead of meeting it at settlement.
    function test_unpricedCostBasis_templateDeclaresConversion() public {
        LaunchpadStrategy s = _cloneDefault();
        assertTrue(s.expectsUnpricedResidue(), "a launch always converts capital it cannot price");
    }

    /// @notice Nothing is reported until the strategy has actually settled.
    /// @dev    Before settlement the difference between what was taken and what
    ///         was given back is capital IN FLIGHT, not capital converted.
    function test_unpricedCostBasis_zeroBeforeSettle() public {
        LaunchpadStrategy s = _cloneDefault();
        assertEq(s.unpricedCostBasis(), 0, "nothing deployed yet");
        _execute(s);
        assertEq(s.unpricedCostBasis(), 0, "mid-strategy is not converted");
    }

    /// @notice The basis is exactly what the strategy took and did not return.
    /// @dev    No price is consulted to reach it — that is the point. It is what
    ///         the fund PAID for the inventory it still holds, which is the one
    ///         honest number available for something the template refuses to
    ///         value.
    function test_unpricedCostBasis_isDeployedLessReturned() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);

        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        uint256 vaultBefore = asset.balanceOf(address(vault));
        _settle(s);
        uint256 returned = asset.balanceOf(address(vault)) - vaultBefore;

        assertEq(s.unpricedCostBasis(), ASSET_IN - returned, "cost of what is still held");
        assertGt(s.unpricedCostBasis(), 0, "a live launch has converted something");
        assertTrue(s.hasUnvaluedResidue(), "and the predicate agrees there IS unpriced inventory");
    }

    /// @notice Sweeping the launch token to the vault does not change the basis.
    /// @dev    THE REASON THE FIGURE IS RECORDED RATHER THAN MEASURED. A
    ///         balance-derived answer would collapse to zero the moment `sweep()`
    ///         moved the inventory — and the vault does not price it either, so
    ///         the false loss would come straight back. Moving inventory between
    ///         two holders that both decline to price it realizes nothing.
    function test_unpricedCostBasis_survivesSweep() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        _settle(s);

        uint256 basisBefore = s.unpricedCostBasis();
        assertGt(basisBefore, 0, "precondition: something was converted");

        _sweep(s);

        assertEq(s.unpricedCostBasis(), basisBefore, "inventory changed hands; nothing was realized");
    }

}
