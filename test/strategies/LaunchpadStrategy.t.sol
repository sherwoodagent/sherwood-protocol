// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
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
import {
    MockLaunchAdapter,
    MockCreatorVenue,
    MockRevertingCreatorVenue,
    MockNoCreatorVenue
} from "../mocks/MockLaunchAdapter.sol";

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
            feeMode: LaunchpadStrategy.FeeMode.ToVault,
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

    /// @dev A clone configured to route the creator stream to the fund's own
    ///      depositors rather than to the vault.
    function _cloneToDepositors() internal returns (LaunchpadStrategy) {
        LaunchpadStrategy.InitParams memory p = _params();
        p.feeMode = LaunchpadStrategy.FeeMode.ToDepositors;
        return _clone(p);
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
        assertEq(uint256(s.feeMode()), uint256(LaunchpadStrategy.FeeMode.ToVault), "ToVault is the zero value");
    }

    /// @dev The zero value MUST be today's behaviour, so a params struct that
    ///      never mentions `feeMode` decodes to `ToVault`.
    function test_init_feeModeDefaultsToVault() public {
        LaunchpadStrategy.InitParams memory p = _params();
        assertEq(uint256(p.feeMode), 0, "ToVault is enum member 0");
        assertEq(uint256(_clone(p).feeMode()), uint256(LaunchpadStrategy.FeeMode.ToVault));
        assertEq(uint256(_cloneToDepositors().feeMode()), uint256(LaunchpadStrategy.FeeMode.ToDepositors));
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

    /// @dev UPDATED FOR THE ACCUMULATOR. A second claim against an UNCHANGED
    ///      reserve is not "already claimed" any more — it is an entitlement of
    ///      exactly zero, and reverts as one. The outcome a caller sees is
    ///      identical (revert, no tokens move); only the selector changed,
    ///      because `AlreadyClaimed` stopped being true in general once
    ///      `collectFees()` could enlarge the pot.
    function test_claim_revertsOnDoubleClaimWithUnchangedReserve() public {
        LaunchpadStrategy s = _executedWithHolders();
        vm.prank(alice);
        s.claim();
        uint256 balBefore = IERC20(s.launchToken()).balanceOf(alice);
        assertEq(s.claimedOf(alice), balBefore, "claimedOf records the cumulative amount, not a flag");
        assertEq(s.claimable(alice), 0, "nothing outstanding");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadStrategy.ZeroEntitlement.selector, alice));
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
    // collectFees — the in-window, permissionless fee lane
    //
    // THE TIMING IS THE MECHANISM. `settle()` cannot serve `ToDepositors`: it is
    // gated on the claim window having ALREADY closed, so anything it added to
    // `reserve` would be unclaimable by construction. Everything below is about
    // that window.
    // ─────────────────────────────────────────────────────────────────────────

    uint256 internal constant TOPUP = 10_000e18;

    function test_collectFees_toDepositors_growsTheReserve() public {
        LaunchpadStrategy s = _cloneToDepositors();
        _execute(s);
        launchAdapter.setFeeAccrual(0, TOPUP);

        vm.expectEmit(false, false, false, true, address(s));
        emit LaunchpadStrategy.ReserveToppedUp(TOPUP, RESERVE + TOPUP);
        (uint256 quoteOut, uint256 tokenOut) = s.collectFees();

        assertEq(tokenOut, TOPUP, "measured from the strategy's own balance delta");
        assertEq(quoteOut, 0);
        assertEq(s.reserve(), RESERVE + TOPUP, "the claim pot grew");
        assertEq(IERC20(s.launchToken()).balanceOf(address(s)), RESERVE + TOPUP, "custody matches the books");
    }

    /// @dev THE REASON THE CLAIM HAD TO BECOME AN ACCUMULATOR. Alice claims her
    ///      half of the original pot, the pot then grows, and she must be able
    ///      to come back for exactly the difference — no more, no less. Under
    ///      the old once-only rule her share of the top-up was unreachable
    ///      forever and would have settled to the vault as inventory.
    function test_collectFees_toDepositors_earlyClaimantClaimsExactlyTheDelta() public {
        vault.setVotes(alice, 500e18);
        vault.setVotes(bob, 500e18);
        LaunchpadStrategy s = _cloneToDepositors();
        _execute(s);
        vm.warp(block.timestamp + 1);
        IERC20 token = IERC20(s.launchToken());

        vm.prank(alice);
        s.claim();
        assertEq(token.balanceOf(alice), RESERVE / 2, "half of the ORIGINAL pot");

        launchAdapter.setFeeAccrual(0, TOPUP);
        s.collectFees();

        // Alice comes back for the difference only.
        assertEq(s.claimable(alice), TOPUP / 2, "the outstanding difference, not a stale zero");
        vm.prank(alice);
        uint256 second = s.claim();
        assertEq(second, TOPUP / 2, "exactly the delta");
        assertEq(token.balanceOf(alice), (RESERVE + TOPUP) / 2, "half of the ENLARGED pot, total");
        assertEq(s.claimedOf(alice), (RESERVE + TOPUP) / 2);

        // Bob, who never claimed early, takes his full enlarged share in one go.
        vm.prank(bob);
        uint256 bobAmount = s.claim();
        assertEq(bobAmount, (RESERVE + TOPUP) / 2, "a late claimant is not advantaged");
        assertEq(token.balanceOf(bob), (RESERVE + TOPUP) / 2, "and the two are paid identically");

        assertEq(s.totalClaimed(), RESERVE + TOPUP);
        assertLe(s.totalClaimed(), s.reserve(), "the invariant survives a growing pot");
        assertEq(token.balanceOf(address(s)), 0);
    }

    /// @dev The same collection under `ToVault` must change NOTHING about the
    ///      claim: `reserve` is untouched, the extra tokens are ordinary custody
    ///      and reach the vault at settle/sweep as unpriced inventory.
    function test_collectFees_toVault_leavesReserveUntouchedAndTokensReachTheVault() public {
        vault.setVotes(alice, 1_000e18);
        LaunchpadStrategy s = _cloneDefault();
        assertEq(uint256(s.feeMode()), uint256(LaunchpadStrategy.FeeMode.ToVault));
        _execute(s);
        vm.warp(block.timestamp + 1);

        launchAdapter.setFeeAccrual(0, TOPUP);
        (, uint256 tokenOut) = s.collectFees();
        assertEq(tokenOut, TOPUP, "the tokens still arrived");
        assertEq(s.reserve(), RESERVE, "but the claim pot did NOT move");

        // Alice's claim is still priced against the original reserve.
        vm.prank(alice);
        assertEq(s.claim(), RESERVE, "sole holder claims the original pot, not the fees");

        launchAdapter.setFeeAccrual(0, 0);
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        uint256 vaultBefore = IERC20(s.launchToken()).balanceOf(address(vault));
        _sweep(s);
        assertEq(
            IERC20(s.launchToken()).balanceOf(address(vault)) - vaultBefore,
            TOPUP,
            "the fee tokens reach the vault as unpriced inventory"
        );
        assertEq(IERC20(s.launchToken()).balanceOf(address(s)), 0);
    }

    /// @dev BOTH MODES leave the quote half alone, where `_settle`'s existing
    ///      conversion picks it up. This is the second reason to collect during
    ///      the window: quote pulled in here is converted, quote the venue pays
    ///      the vault post-settlement is not.
    function test_collectFees_quoteStaysOnTheStrategyAndIsConvertedAtSettle() public {
        LaunchpadStrategy s = _cloneToDepositors();
        _execute(s);
        launchAdapter.setPayVaultWhenOwnerSettled(true);
        launchAdapter.setFeeAccrual(100e18, 0);

        (uint256 quoteOut,) = s.collectFees();
        assertEq(quoteOut, 100e18);
        assertEq(quote.balanceOf(address(s)), 100e18, "quote is custody, not claim pot");
        assertEq(s.reserve(), RESERVE, "the quote half never enters the reserve");

        launchAdapter.setFeeAccrual(0, 0);
        uint256 vaultBefore = asset.balanceOf(address(vault));
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        assertEq(quote.balanceOf(address(s)), 0, "converted");
        assertEq(asset.balanceOf(address(vault)) - vaultBefore, 100e18, "and delivered in the vault asset");
    }

    function test_collectFees_revertsBeforeExecute() public {
        LaunchpadStrategy s = _cloneDefault();
        vm.expectRevert(LaunchpadStrategy.NotClaimable.selector);
        s.collectFees();
    }

    function test_collectFees_revertsAfterSettlement() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        vm.expectRevert(LaunchpadStrategy.NotClaimable.selector);
        s.collectFees();
    }

    /// @dev At `windowEnd` exactly it still works; one second later it does not
    ///      — the same boundary `claim()` uses, because a top-up that arrives
    ///      after the last claim could never be claimed.
    function test_collectFees_revertsAfterWindowEnd() public {
        LaunchpadStrategy s = _cloneToDepositors();
        _execute(s);
        launchAdapter.setFeeAccrual(0, TOPUP);

        vm.warp(s.windowEnd());
        s.collectFees();
        assertEq(s.reserve(), RESERVE + TOPUP, "the last block of the window still counts");

        vm.warp(s.windowEnd() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadStrategy.ClaimWindowClosed.selector, block.timestamp, s.windowEnd())
        );
        s.collectFees();
    }

    /// @dev PERMISSIONLESS AND CANNOT REVERT ON A VENUE HICCUP. This verb is
    ///      open to anyone, so an adapter that reverts must not brick it — a
    ///      keeper's automation is exactly what an adversary would point at.
    function test_collectFees_toleratesRevertingAdapter() public {
        LaunchpadStrategy s = _cloneToDepositors();
        _execute(s);
        launchAdapter.setCollectFeesReverts(true);

        vm.expectEmit(true, false, false, false, address(s));
        emit LaunchpadStrategy.SettlementLegSkipped("collectFees");
        (uint256 quoteOut, uint256 tokenOut) = s.collectFees();

        assertEq(quoteOut, 0);
        assertEq(tokenOut, 0);
        assertEq(s.reserve(), RESERVE, "a failed leg adds nothing");
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Executed), "and bricks nothing");
    }

    /// @dev An ARBITRARY caller can drive it, and receives nothing for doing so.
    function test_collectFees_permissionlessAndPaysTheCallerNothing() public {
        LaunchpadStrategy s = _cloneToDepositors();
        _execute(s);
        launchAdapter.setFeeAccrual(50e18, TOPUP);

        address stranger = address(0xFEED);
        vm.prank(stranger);
        s.collectFees();

        assertEq(s.reserve(), RESERVE + TOPUP, "the pot grew for the holders");
        assertEq(IERC20(s.launchToken()).balanceOf(stranger), 0, "the caller got no launch tokens");
        assertEq(quote.balanceOf(stranger), 0, "and no quote");
        assertEq(quote.balanceOf(address(s)), 50e18, "the quote stayed on the strategy");
    }

    /// @dev The adapter's SELF-REPORT is ignored: `reserve` grows by what
    ///      actually arrived. An adapter that claims to have paid 10x while
    ///      moving nothing would otherwise mint claim rights against tokens that
    ///      do not exist, and the first honest claimant would drain the pot the
    ///      rest were owed.
    function test_collectFees_ignoresTheAdapterSelfReport() public {
        LaunchpadStrategy s = _cloneToDepositors();
        _execute(s);
        // The adapter now SAYS it paid `TOPUP * 10` while moving nothing at all.
        vm.mockCall(
            address(launchAdapter),
            abi.encodeWithSelector(ILaunchAdapter.collectFees.selector, s.launchRef()),
            abi.encode(uint256(0), TOPUP * 10)
        );
        (, uint256 tokenOut) = s.collectFees();
        vm.clearMockedCalls();

        assertEq(tokenOut, 0, "the balance delta is zero, whatever the adapter returned");
        assertEq(s.reserve(), RESERVE, "the lie never reached the claim pot");
        assertEq(IERC20(s.launchToken()).balanceOf(address(s)), RESERVE, "and custody is unchanged");
    }

    /// @dev Σ(claims) SHALL never exceed the reserve EVEN WHEN THE RESERVE GROWS
    ///      between claims — the property the accumulator had to preserve.
    ///      Alice claims first, the pot then grows, and everyone (Alice
    ///      included) claims again.
    function testFuzz_growingReserveNeverLetsClaimsExceedReserve(uint128 wA, uint128 wB, uint128 wC, uint96 topUpRaw)
        public
    {
        vm.assume(uint256(wA) + uint256(wB) + uint256(wC) > 0);
        uint256 topUp = bound(uint256(topUpRaw), 0, LAUNCH_SUPPLY - RESERVE);

        vault.setVotes(alice, wA);
        vault.setVotes(bob, wB);
        vault.setVotes(carol, wC);

        LaunchpadStrategy s = _cloneToDepositors();
        _execute(s);
        vm.warp(block.timestamp + 1);

        // An EARLY claimant, before the pot grows.
        vm.prank(alice);
        try s.claim() {} catch {}

        launchAdapter.setFeeAccrual(0, topUp);
        s.collectFees();
        assertEq(s.reserve(), RESERVE + topUp, "the pot grew by exactly what arrived");

        address[3] memory holders = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.prank(holders[i]);
            try s.claim() {} catch {}
        }
        // Alice a third time: whatever is left for her is zero by now.
        vm.prank(alice);
        try s.claim() {} catch {}

        assertLe(s.totalClaimed(), s.reserve(), "claims never exceed the reserve");
        assertEq(
            IERC20(s.launchToken()).balanceOf(address(s)), s.reserve() - s.totalClaimed(), "custody matches the books"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // settle
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev PINS THE DOCUMENTED SETTLE-TIME BEHAVIOUR so nobody "fixes" it by
    ///      accident. `BaseStrategy.settle()` flips `_state` to `Settled` BEFORE
    ///      `_settle()` runs, so an adapter that switches destination on the
    ///      owner being settled — the Stonk lane, and `ILaunchAdapter` makes it
    ///      normative — pays the VAULT directly. The consequence, recorded in
    ///      `_settle`'s natspec: the fee quote never enters strategy custody, so
    ///      `_convertQuote` never sees it and it lands RAW rather than converted.
    ///
    ///      That destination is correct (paying a settled clone is the
    ///      deposit-lock lever the vault-direct routing removes). The in-window
    ///      `collectFees()` is what keeps the unconverted residue small, and the
    ///      companion test above proves that lane converts.
    function test_settle_postSettlementFeeLanePaysVaultInKindAndSkipsConversion() public {
        launchAdapter.setPayVaultWhenOwnerSettled(true);
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        launchAdapter.setFeeAccrual(100e18, 25e18);

        uint256 vaultQuoteBefore = quote.balanceOf(address(vault));
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        uint256 vaultTokenBefore = IERC20(s.launchToken()).balanceOf(address(vault));

        vm.warp(s.windowEnd() + 1);
        _settle(s);

        assertEq(
            quote.balanceOf(address(vault)) - vaultQuoteBefore,
            100e18,
            "the fee quote reached the vault RAW, in kind - never converted"
        );
        assertEq(asset.balanceOf(address(vault)) - vaultAssetBefore, 0, "nothing was converted at settle");
        assertEq(quote.balanceOf(address(s)), 0, "the quote never entered strategy custody at all");
        assertEq(
            IERC20(s.launchToken()).balanceOf(address(vault)) - vaultTokenBefore,
            25e18,
            "the fee tokens likewise went straight to the vault"
        );
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled));
    }

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

    function test_settle_toleratesRevertingCollectFees() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        launchAdapter.setCollectFeesReverts(true);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled));
    }

    function test_settle_toleratesRevertingCreatorHandoff() public {
        launchAdapter.setTarget(address(new MockRevertingCreatorVenue()));
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled));
    }

    function test_settle_toleratesVenueWithoutCreatorTransfer() public {
        launchAdapter.setTarget(address(new MockNoCreatorVenue()));
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled));
    }

    function test_settle_handsCreatorRoleToVault() public {
        MockCreatorVenue venue = new MockCreatorVenue();
        launchAdapter.setTarget(address(venue));
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        assertEq(venue.calls(), 1);
        assertEq(venue.lastToken(), s.launchToken());
        assertEq(venue.lastCreator(), address(vault), "the ONGOING fee stream goes to the vault, not the strategy");
    }

    function test_settle_convertsQuoteResidueToVaultAsset() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        launchAdapter.setFeeAccrual(100e18, 0); // creator quote accrues
        uint256 vaultBefore = asset.balanceOf(address(vault));
        vm.warp(s.windowEnd() + 1);
        _settle(s);

        assertEq(quote.balanceOf(address(s)), 0, "quote converted");
        assertEq(asset.balanceOf(address(vault)) - vaultBefore, 100e18);
    }

    function test_settle_leavesQuoteInCustodyWhenSwapFails() public {
        LaunchpadStrategy s = _cloneDefault();
        _execute(s);
        launchAdapter.setFeeAccrual(100e18, 0);
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
        launchAdapter.setFeeAccrual(50e18, 0);
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
        launchAdapter.setFeeAccrual(50e18, 0);
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
}
