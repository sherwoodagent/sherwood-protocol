// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SushiLaunchAdapter} from "../../src/adapters/SushiLaunchAdapter.sol";
import {ILaunchAdapter} from "../../src/interfaces/ILaunchAdapter.sol";
import {ISushiLaunchpad} from "../../src/vendor/sushi/ISushiLaunchpad.sol";
import {MockSushiLaunchpad} from "../mocks/MockSushiLaunchpad.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal WETH9: the adapter's declared native-fee source.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth: withdraw failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract SushiLaunchAdapterTest is Test {
    MockWETH internal weth;
    MockSushiLaunchpad internal pad;
    SushiLaunchAdapter internal adapter;
    ERC20Mock internal quote;
    ERC20Mock internal wood;

    /// @dev Stands in for `TokenizeFundStrategy`: the `launch` caller, and the
    ///      address the custody invariant says must end up holding everything.
    address internal strategy = makeAddr("strategy");
    address internal vault = makeAddr("vault");
    address internal keeper = makeAddr("keeper");
    address internal feed = makeAddr("priceFeed");

    uint256 internal constant FEE = 5e14; // the live venue's `launchFee()`
    uint256 internal constant QUOTE_IN = 10 ether;
    uint256 internal constant RESERVE = 5 ether; // at rate 1e18, 10 quote → 10 tokens

    function setUp() public {
        weth = new MockWETH();
        pad = new MockSushiLaunchpad(address(weth));
        adapter = new SushiLaunchAdapter(address(pad));

        quote = new ERC20Mock("Quote", "Q", 18);
        wood = new ERC20Mock("Wood", "WOOD", 18);

        pad.setQuoteTokenPriceFeed(address(quote), feed);
        pad.setLaunchFee(FEE);

        _fund(strategy, QUOTE_IN * 10, FEE * 10);
    }

    // ── helpers ──

    function _fund(address who, uint256 quoteAmount, uint256 wethAmount) internal {
        quote.mint(who, quoteAmount);
        wood.mint(who, quoteAmount);
        vm.deal(who, wethAmount);
        vm.prank(who);
        weth.deposit{value: wethAmount}();
    }

    function _params(address quoteToken, uint256 quoteIn, uint256 minOut, uint256 reserve)
        internal
        view
        returns (ILaunchAdapter.LaunchParams memory)
    {
        return ILaunchAdapter.LaunchParams({
            name: "Fund Token",
            symbol: "FUND",
            quoteToken: quoteToken,
            quoteIn: quoteIn,
            minTokensOut: minOut,
            reserveAmount: reserve,
            deadline: uint64(block.timestamp + 1 hours),
            venueData: ""
        });
    }

    function _approve(address who, address quoteToken, uint256 quoteIn, uint256 fee) internal {
        vm.startPrank(who);
        IERC20(quoteToken).approve(address(adapter), quoteIn);
        weth.approve(address(adapter), fee);
        vm.stopPrank();
    }

    function _launchAsStrategy() internal returns (ILaunchAdapter.LaunchResult memory res) {
        _approve(strategy, address(quote), QUOTE_IN, FEE);
        vm.prank(strategy);
        res = adapter.launch(_params(address(quote), QUOTE_IN, RESERVE, RESERVE));
    }

    // ── custody invariant ──

    function test_Launch_ReserveLandsOnCallerAndAdapterIsClean() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();

        assertEq(res.reserveHeld, QUOTE_IN, "reserve = dev buy output");
        assertGe(res.reserveHeld, RESERVE, "reserve floor honoured");
        assertEq(res.quoteSpent, QUOTE_IN, "venue consumes the buy in full");
        assertEq(res.launchRef, bytes32(uint256(uint160(res.token))), "ref is the token");
        assertEq(IERC20(res.token).balanceOf(strategy), res.reserveHeld, "strategy holds the reserve");

        // The adapter retains nothing.
        assertEq(IERC20(res.token).balanceOf(address(adapter)), 0, "no launch token on adapter");
        assertEq(quote.balanceOf(address(adapter)), 0, "no quote on adapter");
        assertEq(weth.balanceOf(address(adapter)), 0, "no weth on adapter");
        assertEq(address(adapter).balance, 0, "no native on adapter");
        assertEq(quote.allowance(address(adapter), address(pad)), 0, "no standing allowance");
    }

    function test_Launch_CreatorRoleIsTheCaller() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        assertEq(pad.launchInfo(res.token).creator, strategy, "creator handed to the caller in-tx");

        // And the adapter kept no path back to it.
        vm.prank(address(adapter));
        vm.expectRevert(MockSushiLaunchpad.NotCreator.selector);
        pad.transferCreator(res.token, address(adapter));
    }

    // ── reserve enforcement ──

    function test_RevertWhen_MinTokensOutBelowReserve() public {
        _approve(strategy, address(quote), QUOTE_IN, FEE);
        vm.prank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(SushiLaunchAdapter.ReserveFloorBelowReserve.selector, RESERVE - 1, RESERVE)
        );
        adapter.launch(_params(address(quote), QUOTE_IN, RESERVE - 1, RESERVE));
    }

    function test_RevertWhen_InitialBuyUnderDeliversAgainstVenueFloor() public {
        // 0.1 token per quote → 1 token out against a 5-token floor.
        pad.setRate(1e17);
        _approve(strategy, address(quote), QUOTE_IN, FEE);
        vm.prank(strategy);
        vm.expectRevert(MockSushiLaunchpad.InsufficientInitialBuyOutput.selector);
        adapter.launch(_params(address(quote), QUOTE_IN, RESERVE, RESERVE));
    }

    function test_RevertWhen_VenueUnderDeliversPastItsOwnFloor() public {
        // A venue that stopped enforcing its own `amountOutMinimum`: the
        // adapter's belt-and-braces assert is the only thing left.
        pad.setSkipOutputFloor(true);
        pad.setRate(1e17);
        _approve(strategy, address(quote), QUOTE_IN, FEE);
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.ReserveNotDelivered.selector, 1 ether, RESERVE));
        adapter.launch(_params(address(quote), QUOTE_IN, RESERVE, RESERVE));
    }

    function test_RevertWhen_ZeroQuoteIn() public {
        _approve(strategy, address(quote), QUOTE_IN, FEE);
        vm.prank(strategy);
        vm.expectRevert(SushiLaunchAdapter.ZeroQuoteIn.selector);
        adapter.launch(_params(address(quote), 0, RESERVE, RESERVE));
    }

    // ── quote gating: the WOOD path ──

    function test_RevertWhen_QuoteFeedUnregistered_NoFundsMove() public {
        assertFalse(adapter.quoteSupported(address(wood)), "WOOD unsupported before registration");

        uint256 woodBefore = wood.balanceOf(strategy);
        uint256 wethBefore = weth.balanceOf(strategy);
        _approve(strategy, address(wood), QUOTE_IN, FEE);

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.UnsupportedQuote.selector, address(wood)));
        adapter.launch(_params(address(wood), QUOTE_IN, RESERVE, RESERVE));

        assertEq(wood.balanceOf(strategy), woodBefore, "no quote pulled");
        assertEq(weth.balanceOf(strategy), wethBefore, "no fee pulled");
    }

    function test_Launch_WoodQuoteSucceedsOnceVenueRegistersFeed() public {
        // The venue owner whitelists WOOD. No adapter change, no redeploy.
        pad.setQuoteTokenPriceFeed(address(wood), feed);
        assertTrue(adapter.quoteSupported(address(wood)), "WOOD supported after registration");

        _approve(strategy, address(wood), QUOTE_IN, FEE);
        vm.prank(strategy);
        ILaunchAdapter.LaunchResult memory res = adapter.launch(_params(address(wood), QUOTE_IN, RESERVE, RESERVE));

        assertEq(IERC20(res.token).balanceOf(strategy), res.reserveHeld);
        assertEq(pad.launchInfo(res.token).quoteToken, address(wood), "paired against WOOD");
        assertEq(pad.launchInfo(res.token).creator, strategy);
        assertEq(wood.balanceOf(address(adapter)), 0, "no WOOD dust on adapter");
    }

    function test_QuoteSupported_NeverReverts() public {
        assertFalse(adapter.quoteSupported(address(0)), "zero quote");
        assertFalse(adapter.quoteSupported(makeAddr("notAContract")), "non-contract quote");
        assertFalse(adapter.quoteSupported(address(wood)), "unregistered");
        assertTrue(adapter.quoteSupported(address(quote)), "registered");
        // Registration is the only thing that flips it.
        pad.setQuoteTokenPriceFeed(address(quote), address(0));
        assertFalse(adapter.quoteSupported(address(quote)), "de-registered");
    }

    // ── phase / finalize ──

    function test_Phase_UnknownRefReturnsNoneWithoutReverting() public {
        assertEq(uint256(adapter.phase(bytes32(0))), uint256(ILaunchAdapter.LaunchPhase.None), "zero ref");
        assertEq(
            uint256(adapter.phase(bytes32(uint256(uint160(makeAddr("neverIssued")))))),
            uint256(ILaunchAdapter.LaunchPhase.None),
            "never issued"
        );
        // Dirty high bits: a ref this adapter could not have issued.
        assertEq(
            uint256(adapter.phase(bytes32(type(uint256).max))), uint256(ILaunchAdapter.LaunchPhase.None), "dirty ref"
        );
        // A codeful non-launch (the launchpad itself) must not revert either.
        assertEq(
            uint256(adapter.phase(bytes32(uint256(uint160(address(pad)))))),
            uint256(ILaunchAdapter.LaunchPhase.None),
            "codeful non-launch"
        );
    }

    function test_Phase_IssuedLaunchIsLive() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Live));
    }

    function test_Finalize_IsANoOpInEveryPhase() public {
        adapter.finalize(bytes32(0));
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        adapter.finalize(res.launchRef);
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Live));
    }

    // ── native fee source ──

    function test_NativeFeeSource_ReportsWethAndTheLiveFee() public {
        (address token, uint256 amount) = adapter.nativeFeeSource();
        assertEq(token, address(weth), "fee source is WETH, never the quote");
        assertEq(amount, FEE);

        // Repriced by the venue owner between propose and execute.
        pad.setLaunchFee(2e15);
        (, amount) = adapter.nativeFeeSource();
        assertEq(amount, 2e15, "read live, not pinned");
    }

    function test_Launch_PullsExactlyTheLiveFeeInWeth() public {
        uint256 wethBefore = weth.balanceOf(strategy);
        // Approve far more than the fee: the adapter must still pull only the fee.
        _approve(strategy, address(quote), QUOTE_IN, FEE * 10);
        vm.prank(strategy);
        adapter.launch(_params(address(quote), QUOTE_IN, RESERVE, RESERVE));

        assertEq(wethBefore - weth.balanceOf(strategy), FEE, "exactly the fee, no more");
        assertEq(address(pad).balance, FEE, "fee paid to the venue as native");
        assertEq(weth.allowance(strategy, address(adapter)), FEE * 9, "remaining approval untouched");
        assertEq(address(adapter).balance, 0);
    }

    function test_Launch_WithZeroFeePullsNoWeth() public {
        pad.setLaunchFee(0);
        uint256 wethBefore = weth.balanceOf(strategy);
        _approve(strategy, address(quote), QUOTE_IN, 0);
        vm.prank(strategy);
        adapter.launch(_params(address(quote), QUOTE_IN, RESERVE, RESERVE));
        assertEq(weth.balanceOf(strategy), wethBefore, "no WETH pulled when the venue charges nothing");
    }

    function test_Launch_SweepsAttachedValueBackToTheCaller() public {
        vm.deal(strategy, 1 ether);
        _approve(strategy, address(quote), QUOTE_IN, FEE);
        uint256 nativeBefore = strategy.balance;
        vm.prank(strategy);
        adapter.launch{value: 0.3 ether}(_params(address(quote), QUOTE_IN, RESERVE, RESERVE));
        assertEq(strategy.balance, nativeBefore, "attached value returned in full");
        assertEq(address(adapter).balance, 0);
    }

    // ── receive() ──

    function test_RevertWhen_PlainNativeSendToAdapter() public {
        address sender = makeAddr("randomSender");
        vm.deal(sender, 1 ether);
        vm.prank(sender);
        (bool ok, bytes memory ret) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok, "plain native send refused");
        assertEq(
            bytes32(bytes4(ret)),
            bytes32(SushiLaunchAdapter.UnexpectedNativePayment.selector),
            "refused with the named error"
        );
    }

    function test_Receive_AcceptsTheWethUnwrap() public {
        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        assertTrue(ok, "the unwrap lane is open");
        assertEq(address(adapter).balance, 1 ether);
    }

    // ── fees ──

    function test_CollectFees_ReportsTheCreatorsDeltas() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        pad.setFeesOwed(res.token, 3 ether, 7 ether);

        uint256 quoteBefore = quote.balanceOf(strategy);
        uint256 tokenBefore = IERC20(res.token).balanceOf(strategy);

        // A permissionless keeper drives it; the venue still pays the creator.
        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);

        assertEq(quoteOut, 3 ether, "quote leg measured on the creator");
        assertEq(tokenOut, 7 ether, "token leg measured on the creator");
        assertEq(quote.balanceOf(strategy) - quoteBefore, 3 ether);
        assertEq(IERC20(res.token).balanceOf(strategy) - tokenBefore, 7 ether);
        assertEq(quote.balanceOf(keeper), 0, "keeper receives nothing");
        assertEq(IERC20(res.token).balanceOf(keeper), 0, "keeper receives nothing");
        assertEq(quote.balanceOf(address(adapter)), 0, "adapter receives nothing");
    }

    function test_CollectFees_ReturnsZeroesWhenNothingAccrued() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);
        assertEq(quoteOut, 0);
        assertEq(tokenOut, 0);
    }

    function test_CollectFees_ReturnsZeroesOnUnknownRefAndVenueRefusal() public {
        // Unknown ref: `launchInfo` reverts `UnknownToken` at the venue.
        (uint256 q, uint256 t) = adapter.collectFees(bytes32(uint256(uint160(makeAddr("neverIssued")))));
        assertEq(q, 0);
        assertEq(t, 0);

        // A venue that refuses to distribute must not strand a settlement.
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        pad.setFeesOwed(res.token, 3 ether, 7 ether);
        pad.setDistributeReverts(true);
        vm.prank(keeper);
        (q, t) = adapter.collectFees(res.launchRef);
        assertEq(q, 0, "no delta reported when the venue reverted");
        assertEq(t, 0);
    }

    function test_CollectFees_FollowsTheCreatorAfterTheSettleTimeHandoff() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();

        // `_settle` hands the creator role to the vault, straight at the venue —
        // the adapter supplies only the target address and the ref-is-the-token
        // keying. (Resolve the target BEFORE the prank: it is itself a call.)
        address target = adapter.launchTarget();
        vm.prank(strategy);
        ISushiLaunchpad(target).transferCreator(res.token, vault);
        assertEq(pad.launchInfo(res.token).creator, vault);

        pad.setFeesOwed(res.token, 2 ether, 4 ether);
        uint256 oldCreatorQuote = quote.balanceOf(strategy);
        uint256 oldCreatorToken = IERC20(res.token).balanceOf(strategy);

        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);

        assertEq(quoteOut, 2 ether, "reports the NEW creator's delta");
        assertEq(tokenOut, 4 ether);
        assertEq(quote.balanceOf(vault), 2 ether, "vault paid direct");
        assertEq(IERC20(res.token).balanceOf(vault), 4 ether);
        assertEq(quote.balanceOf(strategy), oldCreatorQuote, "old creator paid nothing");
        assertEq(IERC20(res.token).balanceOf(strategy), oldCreatorToken, "old creator paid nothing");
    }

    // ── wiring ──

    function test_LaunchTargetAndImmutables() public view {
        assertEq(adapter.launchTarget(), address(pad));
        assertEq(address(adapter.launchpad()), address(pad));
        assertEq(adapter.weth(), address(weth));
    }

    function test_RevertWhen_ConstructedWithACodelessLaunchpad() public {
        vm.expectRevert(SushiLaunchAdapter.InvalidLaunchpad.selector);
        new SushiLaunchAdapter(makeAddr("notAContract"));
        vm.expectRevert(SushiLaunchAdapter.InvalidLaunchpad.selector);
        new SushiLaunchAdapter(address(0));
    }

    function test_RevertWhen_LaunchpadReportsNoWeth() public {
        MockSushiLaunchpad badPad = new MockSushiLaunchpad(address(0));
        vm.expectRevert(SushiLaunchAdapter.InvalidWeth.selector);
        new SushiLaunchAdapter(address(badPad));
    }
}
