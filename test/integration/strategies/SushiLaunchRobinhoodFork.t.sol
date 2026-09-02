// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {SushiLaunchAdapter} from "../../../src/adapters/SushiLaunchAdapter.sol";
import {ILaunchAdapter} from "../../../src/interfaces/ILaunchAdapter.sol";
import {ISushiLaunchpad, IWETH} from "../../../src/vendor/sushi/ISushiLaunchpad.sol";
import {LaunchpadStrategy} from "../../../src/strategies/LaunchpadStrategy.sol";
import {BaseStrategy} from "../../../src/strategies/BaseStrategy.sol";

import {MockSwapAdapter} from "../../mocks/MockSwapAdapter.sol";
// The vault/governor/registry stand-ins are IMPORTED, not re-declared: they are
// the same shapes the unit suite maintains, and `tasks.md` 4.6 requires them to
// grow with the template in one place. Cross-suite fixture imports are the
// house pattern (see `test/pashov-final/*` and
// `test/strategies/ConcentratedLiquidityStrategySettle.t.sol`).
import {MockFundVault, MockFundGovernor, MockFundRegistry} from "../../strategies/LaunchpadStrategy.t.sol";

/// @dev The two members `IUniswapV3Pool` in `src/vendor/uniswap` does not
///      vendor. Declared here rather than widened there: nothing in `src/`
///      swaps a pool directly, and this is only used to MAKE FEES ACCRUE so
///      `distributeFees` has something to pay out.
interface ISushiV3PoolSwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
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
 *         adapter makes about sourcing the launch fee — pull WETH, unwrap,
 *         forward as `msg.value`, attach nothing of the caller's — is only
 *         load-bearing against a caller shaped like this one. A stub with a
 *         `receive()` would let a broken adapter pass by accident.
 */
contract NoReceiveStrategyStub {
    // Deliberately no receive(), no fallback(). Do not add one.

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    /// @dev Wraps its OWN native into WETH so the fee lane is funded with
    ///      genuinely ETH-backed WETH rather than a `deal`-written balance the
    ///      wrapper cannot honour on `withdraw`.
    function wrapNative(address weth, uint256 amount) external {
        IWETH(weth).deposit{value: amount}();
    }

    /// @dev No `value:` — the whole point. The adapter is `payable`; the
    ///      strategy pays it nothing.
    function callLaunch(SushiLaunchAdapter adapter, ILaunchAdapter.LaunchParams calldata p)
        external
        returns (ILaunchAdapter.LaunchResult memory)
    {
        return adapter.launch(p);
    }
}

/// @notice Drives real trades through the launch's V3 pool so the creator's LP
///         fee share is nonzero when `distributeFees` is called. Pays inside the
///         callback; holds nothing afterwards that the assertions read.
contract PoolSwapper {
    function swapExactIn(address pool, address tokenIn, uint256 amountIn) external {
        bool zeroForOne = tokenIn == ISushiV3PoolSwap(pool).token0();
        ISushiV3PoolSwap(pool)
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

    /// @dev SushiSwap V3 is a Uniswap V3 fork and uses the Uniswap callback
    ///      name; the alias is here so a renamed fork does not silently turn a
    ///      fee assertion into a skipped one.
    function sushiSwapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }
}

/**
 * @title SushiLaunchRobinhoodForkTest
 * @notice End-to-end Sushi Launchpad V1 accounting for `SushiLaunchAdapter`,
 *         driven against the LIVE venue on Robinhood Chain mainnet (4663). The
 *         unit suite stands the venue in; this suite does not, because every
 *         claim under test is a claim about the venue's behaviour: that the fee
 *         really comes out of `msg.value`, that the buy is really all-or-nothing,
 *         that `transferCreator` really lands in the same transaction, and that
 *         `distributeFees` really pays the creator rather than the caller.
 *
 *         Addresses were resolved ON-CHAIN (see `addresses/4663.json`), not
 *         taken from a vendor list. The canonical mainnet DEX addresses hold
 *         UNRELATED bytecode on this chain, so `setUp` asserts venue IDENTITY —
 *         `WETH()`, `v3Factory()`, `positionManager()` round-tripped against the
 *         address book — rather than mere code presence.
 *
 * @dev Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention);
 *      excluded from default CI by the `test/integration/**` path filter and run
 *      by `.github/workflows/fork-tests.yml`.
 *
 *      NO HARDCODED BLOCK PIN, on purpose. The public RPC is pruned to a short
 *      sliding window (a few thousand blocks, and 4663 produces them fast), so a
 *      constant in this file is unreachable within minutes of being written and
 *      every state read returns `-32000`. The pin therefore lives in the
 *      environment, exactly as `UniswapAdapterRobinhoodForkTest` and
 *      `RobinhoodMainnetIntegrationTest` do it — 0 means fork at latest.
 *
 *      Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        ROBINHOOD_FORK_BLOCK=<recent block, or unset for latest> \
 *        forge test --match-path "test/integration/strategies/SushiLaunchRobinhoodFork.t.sol" -vv
 */
contract SushiLaunchRobinhoodForkTest is Test {
    // ── addresses resolved on-chain (chains/4663.json, addresses/4663.json) ──
    address constant SUSHI_LAUNCHPAD_V1 = 0x104F1Ab42674565EC3DF0BFEbCcC4186f72fA7ED;
    address constant SUSHI_V3_FACTORY = 0xE51960f1B45f1C9FB6D166E6a884F866fC70433B;
    address constant SUSHI_V3_POSITION_MANAGER = 0x51d0e5188afe12d502e29D982d20C190e7816107;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WOOD = 0xF8BC08092C06dB6148114DCf82AF881F1085f92b;

    /// @dev The venue's fixed float, and the figure `LaunchpadStrategy`'s
    ///      `SupplyMismatch` check compares an executed launch's `totalSupply()`
    ///      against. Asserted against the REAL token below.
    uint256 constant SUSHI_FIXED_SUPPLY = 1e9 * 1e18;

    ISushiLaunchpad pad = ISushiLaunchpad(SUSHI_LAUNCHPAD_V1);
    SushiLaunchAdapter adapter;
    NoReceiveStrategyStub strategy;

    address vault = makeAddr("vault"); // p.feeRecipient — the fund's vault
    address keeper = makeAddr("keeper"); // permissionless distributeFees caller

    // ── stand-ins for the parts of Sherwood that are NOT deployed on 4663 ──
    //
    // Only the launch VENUES live on this chain. A real `SyndicateVault` /
    // `SyndicateGovernor` pair cannot be forked here, so the clamp test below
    // stands them in and says so in its own natspec rather than pretending
    // otherwise. Everything the clamp actually reads — `asset()`, `governor()`,
    // `clock()`, the ERC-5805 vote surface, `getActiveProposal()` and the
    // `StrategyProposal` carrying `executedAt`/`strategyDuration` — is present.
    LaunchpadStrategy launchpadTemplate;
    MockFundVault fundVault;
    MockFundGovernor fundGovernor;
    MockFundRegistry fundRegistry;
    MockSwapAdapter swapAdapter;

    address proposer = makeAddr("proposer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    /// @dev 7 days, and it MUST be <= `MAX_CLAIM_WINDOW` (14 days) or init
    ///      rejects it with `InvalidClaimWindow` — a different, already-tested
    ///      failure that would never reach the clamp.
    uint256 constant CONFIGURED_CLAIM_WINDOW = 7 days;
    /// @dev The proposal the window is clamped against: 168x shorter.
    uint256 constant STRATEGY_DURATION = 1 hours;

    /// @dev 1005 USDG: `QUOTE_IN` worth of launch budget plus headroom for the
    ///      fee leg, which is charged in WETH and therefore has to be bought.
    uint256 constant ASSET_IN = 1005e6;

    /// @dev Mock rate for the FEE LEG ONLY, and deliberately not a venue fact:
    ///      1 USDG (1e6 units) -> 2.5e14 wei of WETH, i.e. ~$4k/ETH. The venue
    ///      does not price this pair, `ISwapAdapter` is the fund's own routing
    ///      surface, and nothing in this test asserts anything about the rate —
    ///      it exists so `_acquireFeeToken` can fund a REAL launch fee out of a
    ///      USDG-denominated budget, which is the `_deliverFeeTokenResidue`
    ///      lane the template documents.
    uint256 constant USDG_TO_WETH_RATE = 25e25;

    uint256 constant QUOTE_IN = 1000e6; // 1000 USDG (6 dec)

    /// @dev A REAL floor, not a token one. 1000 USDG buys ~164.6M of the 1e9
    ///      float at the venue's fixed start price, so 100M is a floor with
    ///      genuine headroom that would still bite on a sandwiched buy. A
    ///      `minTokensOut` of 1 wei would let every assertion below pass while
    ///      proving nothing about the slippage guard the reserve depends on.
    uint256 constant MIN_OUT = 100_000_000e18;

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
        assertEq(pad.WETH(), WETH, "launchpad disowns the address book's WETH");
        assertEq(pad.v3Factory(), SUSHI_V3_FACTORY, "launchpad disowns SUSHI_V3_FACTORY");
        assertEq(pad.positionManager(), SUSHI_V3_POSITION_MANAGER, "launchpad disowns SUSHI_V3_POSITION_MANAGER");

        adapter = new SushiLaunchAdapter(SUSHI_LAUNCHPAD_V1);
        strategy = new NoReceiveStrategyStub();

        // ── the stand-in fund the clamp test drives ──
        fundRegistry = new MockFundRegistry();
        fundGovernor = new MockFundGovernor(address(fundRegistry));
        fundVault = new MockFundVault(USDG, address(fundGovernor));
        swapAdapter = new MockSwapAdapter();
        fundRegistry.setAllowed(address(adapter), true);
        fundRegistry.setAllowed(address(swapAdapter), true);
        swapAdapter.setRate(USDG, WETH, USDG_TO_WETH_RATE);
        _fundSwapAdapterWithRealWeth(0.01 ether);

        // Two equal holders, so a claim inside the window pays an exact half of
        // the reserve rather than a rounded-down number that proves less.
        fundVault.setVotes(alice, 50e18);
        fundVault.setVotes(bob, 50e18);

        launchpadTemplate = new LaunchpadStrategy();
    }

    // ── venue facts the adapter and the template are written against ──

    /// @notice The three figures the vendored interface's header asserts, read
    ///         from the live venue. A change in any of them is a change in the
    ///         economics `LaunchpadStrategy` prices its reserve against.
    function test_venue_economicsAreWhatWeVendored() public view {
        assertEq(pad.launchFee(), 5e14, "launchFee");
        assertEq(_readUint("protocolReserveBps()"), 300, "protocolReserveBps");
        assertEq(_readUint("defaultSushiFeeBps()"), 3000, "defaultSushiFeeBps");
    }

    /// @notice The WOOD dependency is STILL LIVE at this block: the venue has no
    ///         WOOD aggregator, so a WOOD-quoted proposal is refused before any
    ///         capital moves. The adapter mirrors the venue's own gate rather
    ///         than keeping an allowlist, so this flips to `true` with no
    ///         redeploy the moment the venue owner registers the feed.
    function test_venue_woodHasNoQuoteFeed() public view {
        assertEq(pad.quoteTokenPriceFeed(WOOD), address(0), "WOOD feed appeared - the spec's caveat is now stale");
        assertFalse(adapter.quoteSupported(WOOD), "adapter must mirror the venue's refusal");
        assertTrue(pad.quoteTokenPriceFeed(WETH) != address(0), "WETH feed");
        assertTrue(pad.quoteTokenPriceFeed(USDG) != address(0), "USDG feed");
        assertTrue(adapter.quoteSupported(USDG), "adapter must mirror the venue's acceptance");
    }

    /// @notice The fee is quoted in WETH and read LIVE, so a venue reprice
    ///         between propose and execute cannot under-fund the launch.
    function test_venue_nativeFeeSourceIsWethAtTheLiveFee() public view {
        (address token, uint256 amount) = adapter.nativeFeeSource();
        assertEq(token, WETH, "fee source token");
        assertEq(amount, pad.launchFee(), "fee source amount tracks the live fee");
        assertEq(adapter.weth(), WETH, "adapter read WETH off the venue");
        assertEq(adapter.launchTarget(), SUSHI_LAUNCHPAD_V1, "launchTarget names the venue");
    }

    // ── the launch, end to end ──

    function test_launch_accountingAgainstTheRealVenue() public {
        if (!forked) return;

        uint256 fee = pad.launchFee();
        _fundStrategy(fee);

        uint256 stratQuoteBefore = IERC20(USDG).balanceOf(address(strategy));
        uint256 stratWethBefore = IERC20(WETH).balanceOf(address(strategy));
        uint256 wethEthBefore = WETH.balance;
        uint256 wethSupplyBefore = IERC20(WETH).totalSupply();
        assertEq(address(strategy).balance, 0, "the strategy holds no native - it cannot even receive any");

        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);

        // 1 ── the native fee came from unwrapped WETH pulled from the CALLER,
        //      and the caller attached no value of its own.
        assertEq(stratWethBefore - IERC20(WETH).balanceOf(address(strategy)), fee, "exactly the fee was pulled in WETH");
        assertEq(wethSupplyBefore - IERC20(WETH).totalSupply(), fee, "the adapter unwrapped exactly the fee");
        assertEq(wethEthBefore - WETH.balance, fee, "the unwrapped native left the wrapper");
        assertEq(address(strategy).balance, 0, "the caller sent no value and received none back");
        assertEq(address(adapter).balance, 0, "the adapter forwarded the whole unwrap as msg.value");

        // 2 ── the dev buy landed on the CALLER, in full.
        assertGe(res.reserveHeld, MIN_OUT, "delivered below minTokensOut");
        assertEq(IERC20(res.token).balanceOf(address(strategy)), res.reserveHeld, "reserve is held by the STRATEGY");
        assertEq(res.quoteSpent, QUOTE_IN, "quoteSpent must equal quoteIn - the venue rejects a partial buy");
        assertEq(stratQuoteBefore - IERC20(USDG).balanceOf(address(strategy)), QUOTE_IN, "quote actually spent");
        assertEq(res.launchRef, bytes32(uint256(uint160(res.token))), "the ref IS the token");
        assertTrue(adapter.phase(res.launchRef) == ILaunchAdapter.LaunchPhase.Live, "issued launches are Live at once");

        // 3 ── the creator role is the VAULT, in this same transaction.
        ISushiLaunchpad.LaunchInfo memory info = pad.launchInfo(res.token);
        assertEq(info.creator, vault, "creator must be p.feeRecipient");
        assertTrue(info.creator != address(strategy), "creator must not be the strategy");
        assertTrue(info.creator != address(adapter), "creator must not be the adapter");
        assertEq(info.quoteToken, USDG, "venue recorded the quote");

        // 4 ── the adapter ends empty, with no standing allowance.
        assertEq(IERC20(res.token).balanceOf(address(adapter)), 0, "adapter holds no launch token");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "adapter holds no quote");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "adapter holds no WETH");
        assertEq(address(adapter).balance, 0, "adapter holds no native");
        assertEq(IERC20(USDG).allowance(address(adapter), SUSHI_LAUNCHPAD_V1), 0, "no standing quote allowance");

        // 5 ── the float is the one `LaunchpadStrategy.SupplyMismatch` expects.
        assertEq(IERC20(res.token).totalSupply(), SUSHI_FIXED_SUPPLY, "fixed supply");

        console2.log("launch token:      ", res.token);
        console2.log("reserve delivered: ", res.reserveHeld);
        console2.log("quote spent:       ", res.quoteSpent);
        console2.log("pool:              ", info.pool);
        console2.log("pool fee tier:     ", ISushiV3PoolSwap(info.pool).fee());
        console2.log("protocol reserve:  ", info.reserveAmount);
    }

    /// @notice THE PERMISSIONLESS FEE PATH. `distributeFees` pays the CURRENT
    ///         CREATOR — the vault — no matter who calls it, and pays the
    ///         strategy and the caller nothing. Fees are made real first by
    ///         trading through the launch's own pool, so this is not the vacuous
    ///         zero case.
    function test_distributeFees_paysTheVaultAndNotTheStrategy() public {
        if (!forked) return;

        _fundStrategy(pad.launchFee());
        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);
        ISushiLaunchpad.LaunchInfo memory info = pad.launchInfo(res.token);
        address pool = info.pool;
        assertTrue(pool != address(0), "venue seeded no pool");

        // Make fees accrue: two round-trip trades through the launch pool.
        PoolSwapper swapper = new PoolSwapper();
        deal(USDG, address(swapper), 2000e6);
        swapper.swapExactIn(pool, USDG, 1000e6);
        uint256 got = IERC20(res.token).balanceOf(address(swapper));
        assertGt(got, 0, "buy through the pool returned nothing");
        swapper.swapExactIn(pool, res.token, got / 2);

        uint256 vaultQuoteBefore = IERC20(USDG).balanceOf(vault);
        uint256 vaultTokenBefore = IERC20(res.token).balanceOf(vault);
        uint256 stratQuoteBefore = IERC20(USDG).balanceOf(address(strategy));
        uint256 stratTokenBefore = IERC20(res.token).balanceOf(address(strategy));
        uint256 keeperQuoteBefore = IERC20(USDG).balanceOf(keeper);
        uint256 keeperTokenBefore = IERC20(res.token).balanceOf(keeper);

        vm.prank(keeper);
        (uint256 quoteCollected, uint256 tokenCollected, uint256 quoteToSushi, uint256 tokenToSushi) =
            pad.distributeFees(res.token);

        uint256 vaultQuoteOut = IERC20(USDG).balanceOf(vault) - vaultQuoteBefore;
        uint256 vaultTokenOut = IERC20(res.token).balanceOf(vault) - vaultTokenBefore;
        console2.log("vault quote fees:  ", vaultQuoteOut);
        console2.log("vault token fees:  ", vaultTokenOut);

        assertTrue(vaultQuoteOut > 0 || vaultTokenOut > 0, "the vault received no creator fees at all");
        // The 70/30 split the vendored header records, measured on the live
        // venue rather than assumed: the creator leg IS collected minus Sushi's.
        assertEq(vaultQuoteOut, quoteCollected - quoteToSushi, "creator quote leg");
        assertEq(vaultTokenOut, tokenCollected - tokenToSushi, "creator token leg");
        // Within 1 bps: the venue floors the split, so an exact 3000 is only
        // ever coincidence of the amounts.
        assertApproxEqAbs(
            quoteToSushi * 10_000 / quoteCollected, 3000, 1, "defaultSushiFeeBps applied to the quote leg"
        );
        assertEq(IERC20(USDG).balanceOf(address(strategy)), stratQuoteBefore, "strategy must receive no quote fee");
        assertEq(IERC20(res.token).balanceOf(address(strategy)), stratTokenBefore, "strategy must receive no token fee");
        assertEq(IERC20(USDG).balanceOf(keeper), keeperQuoteBefore, "the caller is not paid");
        assertEq(IERC20(res.token).balanceOf(keeper), keeperTokenBefore, "the caller is not paid");
    }

    /// @notice `collectFees` reports the CREATOR's deltas, not the caller's — so
    ///         a permissionless keeper driving fees to the vault reports what
    ///         actually moved instead of its own zero.
    function test_collectFees_reportsTheCreatorsDeltas() public {
        if (!forked) return;

        _fundStrategy(pad.launchFee());
        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);
        address pool = pad.launchInfo(res.token).pool;

        PoolSwapper swapper = new PoolSwapper();
        deal(USDG, address(swapper), 2000e6);
        swapper.swapExactIn(pool, USDG, 1000e6);
        swapper.swapExactIn(pool, res.token, IERC20(res.token).balanceOf(address(swapper)) / 2);

        uint256 vaultQuoteBefore = IERC20(USDG).balanceOf(vault);
        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);

        assertEq(IERC20(USDG).balanceOf(vault) - vaultQuoteBefore, quoteOut, "reported quote delta is the vault's");
        assertTrue(quoteOut > 0 || tokenOut > 0, "nothing reported despite accrued fees");
    }

    /// @notice A FORCE-SENT WEI MUST NOT BRICK THE SINGLETON. `_sweepNative` is
    ///         best-effort precisely because the caller cannot receive native,
    ///         so a reverting sweep would disable `launch` for every fund
    ///         forever. `vm.deal` reproduces a `selfdestruct` force-send: the
    ///         balance appears without `receive()` ever running.
    function test_launch_survivesAForceSentNativeBalance() public {
        if (!forked) return;

        _fundStrategy(pad.launchFee());
        vm.deal(address(adapter), 1 wei);

        ILaunchAdapter.LaunchResult memory res = _launch(MIN_OUT);

        assertTrue(res.token != address(0), "launch must still succeed");
        // The sweep to a receive-less caller fails, so the wei stays put — and
        // that is the documented, non-reverting outcome.
        assertEq(address(adapter).balance, 1 wei, "the force-sent wei is left in place, not reverted on");
    }

    /// @notice The venue itself enforces the slippage floor the adapter insists
    ///         on, so a sandwiched buy cannot deliver less than the fund promised.
    function test_launch_venueRejectsAnUnreachableFloor() public {
        if (!forked) return;

        _fundStrategy(pad.launchFee());
        vm.expectRevert(); // venue: InsufficientInitialBuyOutput
        _launch(SUSHI_FIXED_SUPPLY);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The clamp, against a REAL launch
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice A CONFIGURED CLAIM WINDOW LONGER THAN THE PROPOSAL CANNOT OUTLIVE
     *         IT. `claimWindow` is 7 days; the proposal it runs under lasts 1
     *         hour. `_clampWindow` must throw the configured figure away, land
     *         `windowEnd` at `executedAt + strategyDuration - CLAIM_SETTLE_BUFFER`,
     *         and leave `settle()` reachable at `anyoneSettleAt` — so a proposer
     *         cannot pick a window that holds settlement hostage.
     *
     * @dev    WHAT THIS TEST OWNS, AND WHAT IT DOES NOT. Task 4.7 names three
     *         consequences; only the first is a 4663 fact:
     *
     *           OWNED HERE — the clamp itself and settlement's reachability,
     *           measured against the LIVE Sushi Launchpad. The launch, the
     *           WETH-denominated native fee, the fixed float and the creator
     *           binding are all the real venue; the clone is a real
     *           `LaunchpadStrategy` and the adapter a real `SushiLaunchAdapter`.
     *
     *           NOT OWNED HERE — `openProposalCount()` returning to 0 and vault
     *           deposits unlocking. THE SHERWOOD STACK IS NOT DEPLOYED ON 4663;
     *           only the launch venues are. The vault and governor below are
     *           therefore stand-ins (the unit suite's `MockFundVault` /
     *           `MockFundGovernor`), which can report an `executedAt` and a
     *           `strategyDuration` for the clamp to read but cannot answer for a
     *           real `SyndicateGovernor`'s bookkeeping. Asserting those two here
     *           would be asserting the mock.
     *
     *         Where the other half WAS proven: the Robinhood-fork vnet, chain
     *         9994663, which carries the full stack, driven by
     *         `script/fork/launchpad-e2e.sh`. That run configured
     *         `claimWindow = 604800` against `strategyDuration = 3600`, saw
     *         `windowEnd` clamped to `executedAt + 3600 - 300`, a claim past it
     *         revert `ClaimWindowClosed`, `settleProposal` succeed,
     *         `openProposalCount()` return to 0 and `depositsLocked()` go false.
     *
     *         `settle()` IS `onlyVault` — see `BaseStrategy.settle`. Task 4.7's
     *         "arbitrary caller" is the GOVERNOR-level permissionless
     *         `settleProposal(pid)` after `executedAt + strategyDuration`, which
     *         is the vnet's half. What this test can show is the half that would
     *         wedge it: that the strategy's own gate is open by then.
     */
    function test_fork_longClaimWindowCannotWedgeSettlement() public {
        if (!forked) return;

        LaunchpadStrategy s = _cloneAgainstStandIns();

        // ── execute against the REAL venue, under a 1-hour proposal ──
        uint256 executedAt = block.timestamp;
        fundGovernor.setProposal(executedAt, STRATEGY_DURATION);
        deal(USDG, address(fundVault), ASSET_IN);
        fundVault.approveToken(USDG, address(s), ASSET_IN);
        fundVault.callStrategy(address(s), abi.encodeWithSignature("execute()"));

        // the launch is real: the venue recorded the VAULT as creator.
        address token = s.launchToken();
        assertTrue(token != address(0), "no launch token");
        assertEq(pad.launchInfo(token).creator, address(fundVault), "venue creator must be the vault");
        assertEq(IERC20(token).totalSupply(), SUSHI_FIXED_SUPPLY, "real venue float");

        uint256 buffer = launchpadTemplate.CLAIM_SETTLE_BUFFER();
        uint256 we = s.windowEnd();
        uint256 settleAt = s.anyoneSettleAt();

        console2.log("executedAt:        ", executedAt);
        console2.log("configured window: ", s.claimWindow());
        console2.log("windowEnd:         ", we);
        console2.log("anyoneSettleAt:    ", settleAt);
        console2.log("reserve:           ", s.reserve());

        // 1 ── THE CONFIGURED WINDOW LOST. `windowEnd` is the proposal's bound,
        //      not `executedAt + claimWindow`, and it sits strictly inside the
        //      anyone-settle instant by exactly `CLAIM_SETTLE_BUFFER`.
        assertEq(s.claimWindow(), CONFIGURED_CLAIM_WINDOW, "the long window really was configured");
        assertEq(settleAt, executedAt + STRATEGY_DURATION, "anyoneSettleAt is the proposal's own clock");
        assertEq(we, executedAt + STRATEGY_DURATION - buffer, "windowEnd must be clamped to the proposal");
        assertLt(we, settleAt, "the window must close BEFORE settlement opens");
        assertEq(settleAt - we, buffer, "the gap is exactly CLAIM_SETTLE_BUFFER");
        assertLt(we, executedAt + CONFIGURED_CLAIM_WINDOW, "the configured window must have been discarded");

        // 2 ── the gate is genuinely live: inside the window, settlement is
        //      refused. Without this the success in step 5 proves nothing.
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadStrategy.ClaimWindowStillOpen.selector, block.timestamp, we, settleAt)
        );
        fundVault.callStrategy(address(s), abi.encodeWithSignature("settle()"));

        // 3 ── a claim AT `windowEnd` is still good: the truncation is not a
        //      confiscation, and the reserve is really payable out of custody.
        vm.warp(we);
        vm.prank(alice);
        uint256 got = s.claim();
        assertEq(got, s.reserve() / 2, "alice's half of the reserve");
        assertEq(IERC20(token).balanceOf(alice), got, "reserve paid in the REAL launch token");

        // 4 ── one second later the window is shut — the 7-day figure buys
        //      nothing past the proposal.
        vm.warp(we + 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadStrategy.ClaimWindowClosed.selector, block.timestamp, we));
        vm.prank(bob);
        s.claim();

        // 5 ── AT THE BOUNDARY, not well past it: `settle()` succeeds at exactly
        //      `anyoneSettleAt`. This is the assertion the task is about — the
        //      long window cannot hold settlement hostage.
        vm.warp(settleAt);
        assertEq(block.timestamp, settleAt, "settling at the boundary instant, not after it");
        fundVault.callStrategy(address(s), abi.encodeWithSignature("settle()"));

        // 6 ── and the clone really reached `Settled`.
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled), "state must be Settled");
        assertFalse(s.executed(), "no longer Executed");
        assertEq(IERC20(USDG).balanceOf(address(s)), 0, "no vault asset left behind");
    }

    // ── helpers ──

    function _fundStrategy(uint256 fee) internal {
        deal(USDG, address(strategy), QUOTE_IN);
        vm.deal(address(strategy), fee);
        strategy.wrapNative(WETH, fee);
        strategy.approveToken(USDG, address(adapter), QUOTE_IN);
        strategy.approveToken(WETH, address(adapter), fee);
    }

    function _launch(uint256 minTokensOut) internal returns (ILaunchAdapter.LaunchResult memory) {
        return strategy.callLaunch(
            adapter,
            ILaunchAdapter.LaunchParams({
                name: "Sherwood Fund Token",
                symbol: "SHFT",
                quoteToken: USDG,
                quoteIn: QUOTE_IN,
                minTokensOut: minTokensOut,
                reserveAmount: minTokensOut,
                deadline: uint64(block.timestamp + 1 hours),
                feeRecipient: vault,
                venueData: ""
            })
        );
    }

    /// @dev The mock swap adapter must pay out WETH that is GENUINELY
    ///      ETH-backed: the launch adapter unwraps what it pulls, so a
    ///      `deal`-written balance would be a claim the wrapper cannot honour.
    ///      Wrapping real native here keeps the fee leg honest end to end.
    function _fundSwapAdapterWithRealWeth(uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        IWETH(WETH).deposit{value: amount}();
        IERC20(WETH).transfer(address(swapAdapter), amount);
    }

    /// @dev A real `LaunchpadStrategy` clone bound to the stand-in fund and the
    ///      REAL `SushiLaunchAdapter`. Quote == vault asset (USDG), so the quote
    ///      leg is a no-op and the only swap in the whole run is the WETH fee
    ///      leg — the launch itself is entirely the live venue.
    function _cloneAgainstStandIns() internal returns (LaunchpadStrategy s) {
        s = LaunchpadStrategy(Clones.clone(address(launchpadTemplate)));
        s.initialize(
            address(fundVault),
            proposer,
            abi.encode(
                LaunchpadStrategy.InitParams({
                    launchAdapter: address(adapter),
                    swapAdapter: address(swapAdapter),
                    assetIn: ASSET_IN,
                    quoteToken: USDG,
                    minQuoteOut: 0, // quote IS the vault asset - ignored
                    quoteSwapData: "",
                    feeSwapData: "",
                    launchSupply: SUSHI_FIXED_SUPPLY,
                    reserveAmount: MIN_OUT, // 10% of the float - inside MAX_RESERVE_BPS
                    minTokensOut: MIN_OUT,
                    claimWindow: CONFIGURED_CLAIM_WINDOW,
                    deadline: uint64(block.timestamp + 1 hours),
                    settleSlippageBps: 500,
                    name: "Sherwood Fund Token",
                    symbol: "SHFT",
                    venueData: ""
                })
            )
        );
    }

    /// @dev Two venue getters the adapter never calls and the interface
    ///      therefore does not vendor, read raw so the economics assertion does
    ///      not force a wider vendored surface than `src/` needs.
    function _readUint(string memory sig) internal view returns (uint256) {
        (bool ok, bytes memory ret) = SUSHI_LAUNCHPAD_V1.staticcall(abi.encodeWithSignature(sig));
        require(ok && ret.length >= 32, string.concat("venue read failed: ", sig));
        return abi.decode(ret, (uint256));
    }
}
