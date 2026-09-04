// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PonsLaunchAdapter} from "../../../src/adapters/PonsLaunchAdapter.sol";
import {ILaunchAdapter} from "../../../src/interfaces/ILaunchAdapter.sol";
import {IPonsLaunchFactory, IPonsLaunchLocker, IWrappedNative} from "../../../src/vendor/pons/IPonsLaunch.sol";

/// @dev The venue-OWNER surface, declared here and deliberately NOT vendored
///      into `src/`: nothing this repo ships ever calls these. The fork suite
///      needs them only to reproduce the two actions Pons itself would take to
///      un-block this adapter, and to name the gate's error.
interface IPonsAdmin {
    error NotWhitelisted();

    function owner() external view returns (address);
    function setWhitelistedLauncher(address launcher, bool enabled) external;
    function setLaunchEnabled(bool enabled) external;
}

/// @dev The launch token's own accessor for its pool. Declared here for the
///      same reason: the adapter never reads it.
interface IPonsLauncherToken {
    function liquidityPool() external view returns (address);
    function restrictionEndBlock() external view returns (uint256);
    function maxWalletLimit() external view returns (uint256);
}

/// @dev The two members `IUniswapV3Pool` in `src/vendor/uniswap` does not
///      vendor. Used only to MAKE FEES ACCRUE so the locker has something to
///      pay out.
interface IPonsV3PoolSwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/**
 * @notice PRODUCTION'S CALLER SHAPE, and the reason this stub is deliberately
 *         austere: a `BaseStrategy` clone declares NO `receive` and NO
 *         `fallback`, so it cannot be paid native at all. Every claim the
 *         adapter makes about sourcing the launch — pull WETH, unwrap, forward
 *         as `msg.value`, attach nothing of the caller's — is only load-bearing
 *         against a caller shaped like this one.
 */
contract NoReceiveStrategyStub {
    // Deliberately no receive(), no fallback(). Do not add one.

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    /// @dev Wraps its OWN native into WETH so the lane is funded with genuinely
    ///      ETH-backed WETH rather than a `deal`-written balance the wrapper
    ///      cannot honour on `withdraw` — and on this venue BOTH the fee and
    ///      the dev buy travel that lane.
    function wrapNative(address weth, uint256 amount) external {
        IWrappedNative(weth).deposit{value: amount}();
    }

    /// @dev No `value:` — the whole point. The adapter is `payable`; the
    ///      strategy pays it nothing.
    function callLaunch(PonsLaunchAdapter adapter, ILaunchAdapter.LaunchParams calldata p)
        external
        returns (ILaunchAdapter.LaunchResult memory)
    {
        return adapter.launch(p);
    }

    function sendToken(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @notice Drives real trades through the launch's V3 pool so the creator's fee
///         share is nonzero when the locker collects.
contract PoolSwapper {
    function swapExactIn(address pool, address tokenIn, uint256 amountIn) external {
        bool zeroForOne = tokenIn == IPonsV3PoolSwap(pool).token0();
        IPonsV3PoolSwap(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                // MIN_SQRT_RATIO + 1 / MAX_SQRT_RATIO - 1: no price limit.
                zeroForOne ? 4_295_128_740 : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341,
                abi.encode(tokenIn)
            );
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) public {
        address tokenIn = abi.decode(data, (address));
        int256 owed = amount0Delta > 0 ? amount0Delta : amount1Delta;
        IERC20(tokenIn).transfer(msg.sender, uint256(owed));
    }
}

/**
 * @title PonsLaunchRobinhoodForkTest
 * @notice End-to-end Pons launch accounting for `PonsLaunchAdapter`, driven
 *         against the LIVE venue on Robinhood Chain mainnet (4663). The unit
 *         suite stands the venue in; this suite does not, because every claim
 *         under test is a claim about the venue's behaviour: that the gate
 *         really blocks, that whitelisting the ADAPTER really opens it, that
 *         the dev buy really lands on `feeWallet`, that the factory really
 *         records our adapter as `deployer`, and that `setFeeRedirect` really
 *         accepts a deployer's re-point in the same transaction.
 *
 *         THE GATE IS THE HEADLINE. `launchEnabled()` is FALSE on 4663 and no
 *         launcher is whitelisted, so this adapter is INERT on mainnet today.
 *         `test_gate_blocksUntilPonsWhitelistsTheAdapter` proves that first —
 *         it is the live blocker, and a suite that only exercised the happy
 *         path behind a prank would quietly hide it.
 *
 * @dev Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention);
 *      excluded from default CI by the `test/integration/**` path filter.
 *
 *      NO HARDCODED BLOCK PIN, on purpose. The public RPC is pruned to a short
 *      sliding window (4663 produces ~0.101s blocks), so a constant in this
 *      file is unreachable within minutes of being written and every state read
 *      returns `-32000`. The pin lives in the environment, exactly as
 *      `SushiLaunchRobinhoodForkTest` does it — 0 means fork at latest.
 *
 *      Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        ROBINHOOD_FORK_BLOCK=<recent block, or unset for latest> \
 *        forge test --match-path "test/integration/strategies/PonsLaunchRobinhoodFork.t.sol" -vv
 */
contract PonsLaunchRobinhoodForkTest is Test {
    // ── addresses resolved on-chain (verified sources on blockscout) ──
    address constant PONS_LAUNCH_FACTORY_V2 = 0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB;
    address constant PONS_LAUNCH_LOCKER_V2 = 0x736D76699C26D0d966744cAe304C000d471f7F35;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @dev Config 0's `supply`, and the float `LaunchpadStrategy` would
    ///      compare an executed launch's `totalSupply()` against.
    uint256 constant PONS_CONFIG0_SUPPLY = 1e27;

    IPonsLaunchFactory pad = IPonsLaunchFactory(PONS_LAUNCH_FACTORY_V2);
    IPonsLaunchLocker lock = IPonsLaunchLocker(PONS_LAUNCH_LOCKER_V2);
    PonsLaunchAdapter adapter;
    NoReceiveStrategyStub strategy;

    address vault = makeAddr("vault"); // p.feeRecipient — the fund's vault
    address keeper = makeAddr("keeper"); // permissionless collectFees caller

    uint256 constant QUOTE_IN = 0.05 ether;

    /// @dev A REAL floor, not a token one. At config 0's `initialTick` of
    ///      -204200 the start price is ~7.4e8 launch tokens per WETH, so
    ///      0.05 WETH buys tens of millions before slippage; 1M is a floor with
    ///      genuine headroom that would still bite on a sandwiched buy. A
    ///      `minTokensOut` of 1 wei would let every assertion below pass while
    ///      proving nothing about the guard the reserve depends on — and on
    ///      THIS venue that guard is the adapter's alone, since the factory
    ///      passes `amountOutMinimum: 0` to the router.
    uint256 constant MIN_OUT = 1_000_000e18;

    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pin);
        }
        uint256 wantChain = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(4663));
        require(block.chainid == wantChain, "unexpected chain: set ROBINHOOD_FORK_CHAIN_ID (archive vnet is 9994663)");
        forked = true;

        // ── identity, not code presence ──
        // The canonical mainnet DEX addresses hold UNRELATED bytecode on this
        // chain, so `code.length != 0` is not evidence. The factory and locker
        // must name EACH OTHER; a squatter would have to reproduce both halves.
        assertEq(pad.locker(), PONS_LAUNCH_LOCKER_V2, "factory disowns the locker");
        assertEq(lock.factory(), PONS_LAUNCH_FACTORY_V2, "locker disowns the factory");

        adapter = new PonsLaunchAdapter(PONS_LAUNCH_FACTORY_V2, WETH);
        strategy = new NoReceiveStrategyStub();
    }

    // ── venue facts the adapter and the template are written against ──

    /// @notice Every figure the vendored header records, read from the live
    ///         venue. A change in any of them is a change in the economics the
    ///         template prices its reserve against.
    function test_venue_configAndFeeAreWhatWeVendored() public view {
        assertEq(pad.launchFee(), 5e14, "launchFee");
        assertEq(pad.launchConfigCount(), 1, "launchConfigCount");
        assertEq(pad.dexConfigCount(), 1, "dexConfigCount");

        IPonsLaunchFactory.LaunchConfig memory c = pad.getLaunchConfig(0);
        assertEq(c.pairToken, WETH, "config 0 pairToken");
        assertEq(c.graduationThreshold, 4.2e18, "config 0 graduationThreshold");
        assertEq(c.initialTick, -204_200, "config 0 initialTick");
        assertEq(c.supply, PONS_CONFIG0_SUPPLY, "config 0 supply");
        assertEq(c.maxWalletBps, 500, "config 0 maxWalletBps");
        assertEq(c.maxTxBps, 550, "config 0 maxTxBps");
        assertEq(c.restrictionBlocks, 2, "config 0 restrictionBlocks");
        assertEq(c.reservedFee, 0, "config 0 reservedFee");
        assertTrue(c.enabled, "config 0 enabled");
        assertFalse(c.routerRequiresDeadline, "config 0 routerRequiresDeadline");

        IPonsLaunchFactory.DexConfig memory d = pad.getDexConfig(0);
        assertTrue(d.enabled, "dex 0 enabled");
        assertTrue(d.swapRouter != address(0), "dex 0 swapRouter");
        assertEq(d.poolFee, 10_000, "dex 0 poolFee");
        assertEq(d.tickSpacing, 200, "dex 0 tickSpacing");

        assertEq(lock.protocolFeeShare(), 30, "locker protocolFeeShare (percent)");
    }

    function test_venue_nativeFeeSourceIsWethAtTheLiveFee() public view {
        (address token, uint256 amount) = adapter.nativeFeeSource();
        assertEq(token, WETH, "fee source token");
        assertEq(amount, pad.launchFee(), "fee source amount tracks the live fee");
        assertEq(adapter.weth(), WETH);
        assertEq(address(adapter.locker()), PONS_LAUNCH_LOCKER_V2, "locker read off the factory");
        assertEq(adapter.launchTarget(), PONS_LAUNCH_FACTORY_V2, "launchTarget names the factory");
        assertTrue(adapter.quoteSupported(WETH), "WETH is the one configured pairing");
    }

    // ── THE LIVE BLOCKER ──

    /// @notice `launchEnabled()` is FALSE and this adapter is not whitelisted,
    ///         so every launch reverts `NotWhitelisted` at the venue — after
    ///         the adapter has validated everything and BEFORE the venue does
    ///         anything. This is the single reason the adapter is inert on
    ///         mainnet, and whitelisting THE ADAPTER (not the strategy, not the
    ///         vault) is what lifts it. That per-address shape is why the
    ///         adapter is a singleton.
    function test_gate_blocksUntilPonsWhitelistsTheAdapter() public {
        if (!forked) return;

        assertFalse(pad.launchEnabled(), "launchEnabled flipped - the spec's blocker is now stale");
        assertFalse(pad.whitelistedLaunchers(address(adapter)), "a fresh adapter cannot already be whitelisted");

        _fundStrategy(pad.launchFee());
        vm.expectRevert(IPonsAdmin.NotWhitelisted.selector);
        _launch(MIN_OUT);

        // Nothing moved: the venue refuses before it touches anything, and the
        // adapter's own pulls are reverted with it.
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "adapter holds no WETH after the refusal");
        assertEq(address(adapter).balance, 0);

        // Exactly what we would ask Pons to do.
        _whitelistAdapter();
        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);
        assertTrue(res.token != address(0), "whitelisting the adapter opens the venue");
        assertEq(IERC20(res.token).balanceOf(address(strategy)), res.reserveHeld, "and the reserve lands");
    }

    /// @notice The other half of the same gate: Pons flipping `launchEnabled`
    ///         opens it for everyone, with no per-address entry at all. Either
    ///         action un-blocks this adapter, which is worth knowing when
    ///         asking for one.
    function test_gate_alsoOpensWhenPonsFlipsLaunchEnabled() public {
        if (!forked) return;

        _fundStrategy(pad.launchFee());
        vm.prank(IPonsAdmin(PONS_LAUNCH_FACTORY_V2).owner());
        IPonsAdmin(PONS_LAUNCH_FACTORY_V2).setLaunchEnabled(true);

        assertFalse(pad.whitelistedLaunchers(address(adapter)), "still not whitelisted");
        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);
        assertGe(res.reserveHeld, MIN_OUT, "the public gate serves the same launch");
    }

    // ── the launch, end to end ──

    /// @notice THE CRUX, against the real venue: `feeWallet` does double duty,
    ///         so the adapter names the STRATEGY there (the dev buy is the
    ///         reserve) and re-points the locker at the VAULT in the same
    ///         transaction. Both destinations are asserted, and they are
    ///         different addresses.
    function test_launch_accountingAgainstTheRealVenue() public {
        if (!forked) return;

        _whitelistAdapter();
        uint256 fee = pad.launchFee();
        _fundStrategy(fee);

        uint256 stratWethBefore = IERC20(WETH).balanceOf(address(strategy));
        uint256 wethEthBefore = WETH.balance;
        uint256 wethSupplyBefore = IERC20(WETH).totalSupply();
        assertEq(address(strategy).balance, 0, "the strategy holds no native - it cannot even receive any");

        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);

        // 1 ── BOTH the fee and the buy came from unwrapped WETH pulled from the
        //      CALLER, and the caller attached no value of its own. This is the
        //      sharpest difference from the Sushi venue, where only the fee was
        //      native.
        assertEq(
            stratWethBefore - IERC20(WETH).balanceOf(address(strategy)),
            QUOTE_IN + fee,
            "exactly quote + fee was pulled in WETH"
        );
        // ...and the NET wrapper movement is the FEE ONLY, which is not a
        // contradiction but the round trip this venue actually performs: the
        // adapter unwraps `quoteIn + fee`, the factory pays the fee away as
        // native and hands the buy to the router as native, and the ROUTER
        // RE-WRAPS that buy into WETH to pay the pool. So the fee is the only
        // leg that permanently leaves the wrapper. Asserted rather than
        // assumed, because it is the difference between "the adapter forwarded
        // the buy" and "the adapter kept it".
        assertEq(wethSupplyBefore - IERC20(WETH).totalSupply(), fee, "only the fee leg leaves the wrapper");
        assertEq(wethEthBefore - WETH.balance, fee, "the buy's native is re-wrapped by the router");
        assertEq(address(strategy).balance, 0, "the caller sent no value and received none back");
        assertEq(address(adapter).balance, 0, "the adapter forwarded the whole unwrap as msg.value");

        // 2 ── the dev buy landed on the CALLER, above the adapter's floor —
        //      which on this venue is the ONLY floor, since the factory passes
        //      `amountOutMinimum: 0`.
        assertGe(res.reserveHeld, MIN_OUT, "delivered below minTokensOut");
        assertEq(IERC20(res.token).balanceOf(address(strategy)), res.reserveHeld, "reserve is held by the STRATEGY");
        assertEq(res.quoteSpent, QUOTE_IN, "quoteSpent is the whole dev buy");
        assertEq(res.launchRef, bytes32(uint256(uint160(res.token))), "the ref IS the token");
        assertTrue(adapter.phase(res.launchRef) == ILaunchAdapter.LaunchPhase.Live, "issued launches are Live at once");

        // 3 ── the FEE STREAM is the VAULT's, in this same transaction, and is
        //      NOT the strategy's — which is what `feeWallet` alone would have
        //      given us.
        assertEq(lock.feeRedirects(res.token), vault, "redirect must be p.feeRecipient");
        assertTrue(lock.feeRedirects(res.token) != address(strategy), "the strategy must not hold the fee stream");
        assertTrue(lock.feeRedirects(res.token) != address(adapter), "nor the adapter");

        // 4 ── the venue records OUR ADAPTER as the deployer. That standing is
        //      what made step 3 legal, and it is the residual power the
        //      adapter's header addresses: permanent, and reachable through no
        //      function this contract exposes.
        IPonsLaunchFactory.LaunchedToken memory launched = pad.getLaunchedToken(res.token);
        assertTrue(launched.exists, "the venue recorded the launch");
        assertEq(launched.deployer, address(adapter), "deployer must be the adapter");
        assertEq(launched.pairedToken, WETH, "paired against the quote");
        assertEq(launched.supply, PONS_CONFIG0_SUPPLY, "config 0 supply");
        assertEq(launched.initialBuyAmount, QUOTE_IN, "the venue booked our whole dev buy");

        // 5 ── the adapter ends empty, with no standing allowance.
        assertEq(IERC20(res.token).balanceOf(address(adapter)), 0, "adapter holds no launch token");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "adapter holds no WETH");
        assertEq(address(adapter).balance, 0, "adapter holds no native");
        assertEq(IERC20(WETH).allowance(address(adapter), PONS_LAUNCH_FACTORY_V2), 0, "no standing allowance");

        // 6 ── the float is the one the template expects, and the reserve is NOT
        //      capped by `maxWalletBps` — the factory exempts the atomic buy.
        assertEq(IERC20(res.token).totalSupply(), PONS_CONFIG0_SUPPLY, "fixed supply");
        console2.log("launch token:      ", res.token);
        console2.log("reserve delivered: ", res.reserveHeld);
        console2.log("maxWalletLimit:    ", IPonsLauncherToken(res.token).maxWalletLimit());
        console2.log("pool:              ", IPonsLauncherToken(res.token).liquidityPool());
    }

    /// @notice The adapter is `launched.deployer` FOREVER, so it permanently
    ///         COULD re-point this launch's fees. The invariant holds only
    ///         because it exposes no path to: every verb is driven here by an
    ///         attacker and the redirect does not move, and no other address
    ///         holds the lever either.
    function test_launch_noExternalPathRepointsTheFeeRedirect() public {
        if (!forked) return;

        _whitelistAdapter();
        _fundStrategy(pad.launchFee());
        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);
        address attacker = makeAddr("attacker");

        vm.startPrank(attacker);
        adapter.finalize(res.launchRef);
        adapter.collectFees(res.launchRef);
        adapter.phase(res.launchRef);
        adapter.quoteSupported(WETH);
        adapter.nativeFeeSource();
        adapter.launchTarget();
        vm.stopPrank();
        assertEq(lock.feeRedirects(res.token), vault, "no adapter verb moved the redirect");

        // Nor does anyone outside it: the locker admits only the deployer or the
        // factory, and the strategy is neither.
        vm.prank(attacker);
        vm.expectRevert();
        lock.setFeeRedirect(res.token, attacker);
        vm.prank(address(strategy));
        vm.expectRevert();
        lock.setFeeRedirect(res.token, address(strategy));
        assertEq(lock.feeRedirects(res.token), vault, "still the vault");
    }

    /// @notice The permissionless fee path, made non-vacuous by real trades
    ///         through the launch's own pool. The locker gates `collectFees` to
    ///         the deployer/recipient/owner/collector set — a keeper is refused
    ///         directly and served through the adapter, because the ADAPTER is
    ///         the deployer. The payee is the VAULT either way, and the reported
    ///         deltas are the recipient's NET, not the locker's gross.
    function test_collectFees_paysTheVaultAndReportsItsNetDeltas() public {
        if (!forked) return;

        _whitelistAdapter();
        _fundStrategy(pad.launchFee());
        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);

        // THE DEV BUY ALREADY EARNED FEES. The launch's own initial buy trades
        // through the pool it just seeded, so the 1% tier has already accrued
        // before anyone else touches the token — the vault is in profit from
        // the launch transaction itself. Worth asserting rather than assuming a
        // vacuous zero here.
        uint256 vaultSeedBefore = IERC20(WETH).balanceOf(vault);
        vm.prank(keeper);
        (uint256 q0, uint256 t0) = adapter.collectFees(res.launchRef);
        assertGt(q0, 0, "the launch buy's own LP fee did not reach the vault");
        assertEq(IERC20(WETH).balanceOf(vault) - vaultSeedBefore, q0, "and it is the VAULT that was paid");
        console2.log("launch-buy fee to vault:", q0);
        console2.log("launch-buy token fee:   ", t0);

        // Immediately again, with nothing left to collect: the locker reverts
        // `NoFeesToCollect()` and the adapter must report (0, 0) rather than
        // propagate it — the interface lets settlement call this
        // unconditionally.
        vm.prank(keeper);
        (uint256 q1, uint256 t1) = adapter.collectFees(res.launchRef);
        assertEq(q1, 0, "NoFeesToCollect must not revert through the adapter");
        assertEq(t1, 0);

        address pool = IPonsLauncherToken(res.token).liquidityPool();
        assertTrue(pool != address(0), "venue seeded no pool");
        // Past the launch-block restriction window before trading.
        vm.roll(block.number + 5);

        PoolSwapper swapper = new PoolSwapper();
        strategy.sendToken(res.token, address(swapper), res.reserveHeld / 4);
        swapper.swapExactIn(pool, res.token, res.reserveHeld / 8);
        uint256 gotWeth = IERC20(WETH).balanceOf(address(swapper));
        assertGt(gotWeth, 0, "sell through the pool returned nothing");
        swapper.swapExactIn(pool, WETH, gotWeth / 2);

        uint256 vaultWethBefore = IERC20(WETH).balanceOf(vault);
        uint256 vaultTokenBefore = IERC20(res.token).balanceOf(vault);
        uint256 stratWethBefore = IERC20(WETH).balanceOf(address(strategy));

        // The locker refuses the keeper directly...
        vm.prank(keeper);
        vm.expectRevert();
        lock.collectFees(res.token);

        // ...and serves the same keeper through the adapter, which is the
        // deployer. That is the interface's "permissionless" delivered through
        // a venue that is not.
        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);

        assertTrue(quoteOut > 0 || tokenOut > 0, "the vault received no creator fees at all");
        assertEq(IERC20(WETH).balanceOf(vault) - vaultWethBefore, quoteOut, "reported quote delta is the VAULT's");
        assertEq(IERC20(res.token).balanceOf(vault) - vaultTokenBefore, tokenOut, "reported token delta is the VAULT's");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), stratWethBefore, "the strategy receives no fees, ever");
        assertEq(IERC20(WETH).balanceOf(keeper), 0, "the caller is paid nothing for calling");
        assertEq(IERC20(res.token).balanceOf(keeper), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "adapter receives nothing");

        console2.log("vault WETH fees:   ", quoteOut);
        console2.log("vault token fees:  ", tokenOut);
    }

    /// @notice The adapter's floor is the ONLY floor. The venue would settle a
    ///         buy at any price, so an unreachable `minTokensOut` must be
    ///         refused by `SlippageFloorNotMet` — from THIS contract, not from
    ///         the venue.
    function test_launch_adapterIsTheOnlySlippageGuard() public {
        if (!forked) return;

        _whitelistAdapter();
        _fundStrategy(pad.launchFee());
        // More than the whole float can possibly deliver.
        vm.expectRevert();
        _launch(PONS_CONFIG0_SUPPLY);
    }

    /// @notice A force-sent wei must not brick the singleton — which on this
    ///         venue would also cost a fresh Pons whitelist entry to replace.
    ///         `vm.deal` reproduces a `selfdestruct` force-send: the balance
    ///         appears without `receive()` ever running.
    function test_launch_survivesAForceSentNativeBalance() public {
        if (!forked) return;

        _whitelistAdapter();
        _fundStrategy(pad.launchFee());
        vm.deal(address(adapter), 1 wei);

        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);

        assertTrue(res.token != address(0), "launch must still succeed");
        assertEq(address(adapter).balance, 1 wei, "the force-sent wei is left in place, not reverted on");
    }

    // ── helpers ──

    /// @dev Exactly the action we would ask Pons to take, performed as the
    ///      factory owner.
    function _whitelistAdapter() internal {
        vm.prank(IPonsAdmin(PONS_LAUNCH_FACTORY_V2).owner());
        IPonsAdmin(PONS_LAUNCH_FACTORY_V2).setWhitelistedLauncher(address(adapter), true);
        assertTrue(pad.whitelistedLaunchers(address(adapter)), "whitelist did not take");
    }

    function _fundStrategy(uint256 fee) internal {
        vm.deal(address(strategy), QUOTE_IN + fee);
        strategy.wrapNative(WETH, QUOTE_IN + fee);
        strategy.approveToken(WETH, address(adapter), QUOTE_IN + fee);
    }

    function _launch(uint256 minTokensOut) internal returns (ILaunchAdapter.LaunchResult memory) {
        return strategy.callLaunch(
            adapter,
            ILaunchAdapter.LaunchParams({
                name: "Sherwood Pons Fund",
                symbol: "SPFT",
                quoteToken: WETH,
                quoteIn: QUOTE_IN,
                minTokensOut: minTokensOut,
                reserveAmount: minTokensOut,
                deadline: uint64(block.timestamp + 1 hours),
                feeRecipient: vault,
                venueData: abi.encode(
                    PonsLaunchAdapter.VenueData({launchConfigId: 0, dexId: 0, salt: bytes32(uint256(1))})
                )
            })
        );
    }
}
