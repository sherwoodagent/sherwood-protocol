// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PonsLaunchAdapter} from "../../src/adapters/PonsLaunchAdapter.sol";
import {ILaunchAdapter} from "../../src/interfaces/ILaunchAdapter.sol";
import {IPonsLaunchFactory} from "../../src/vendor/pons/IPonsLaunch.sol";
import {MockPonsFactory} from "../mocks/MockPonsFactory.sol";
import {MockPonsLocker} from "../mocks/MockPonsLocker.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal WETH9: the adapter's declared native-fee source AND, on this
///         venue, the launch quote itself — both legs are unwrapped here.
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

/// @notice Force-sends its balance to `target`. The one native transfer no
///         `receive()` guard can refuse — post-EIP-6780 `selfdestruct` still
///         moves the ether even when the account is not deleted.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @notice Stands in for a `LaunchpadStrategy` clone: a CONTRACT that declares
///         NO `receive()` and NO `fallback()`, because no contract under
///         `src/strategies/` declares either. That is what calls `launch` in
///         production, and it is the reason the adapter's native sweep must not
///         be able to revert a launch — an EOA caller accepts native and so
///         cannot exhibit this class of bug at all.
contract StrategyStub {
    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function launch(address adapter, ILaunchAdapter.LaunchParams calldata p)
        external
        returns (ILaunchAdapter.LaunchResult memory)
    {
        return ILaunchAdapter(adapter).launch(p);
    }

    function launchWithValue(address adapter, uint256 value, ILaunchAdapter.LaunchParams calldata p)
        external
        returns (ILaunchAdapter.LaunchResult memory)
    {
        return ILaunchAdapter(adapter).launch{value: value}(p);
    }

    /// @dev Kept only to PROVE the strategy has no lever of its own: it is not
    ///      the launch's deployer, so the venue refuses it.
    function setFeeRedirect(address locker, address token, address wallet) external {
        MockPonsLocker(locker).setFeeRedirect(token, wallet);
    }
}

/// @notice Same caller shape, but able to accept native — used only where the
///         test is about value flowing BACK to the caller.
contract PayableStrategyStub is StrategyStub {
    receive() external payable {}
}

contract PonsLaunchAdapterTest is Test {
    MockWETH internal weth;
    MockPonsFactory internal padFactory;
    MockPonsLocker internal locker;
    PonsLaunchAdapter internal adapter;
    ERC20Mock internal usdg;

    StrategyStub internal stub;
    PayableStrategyStub internal payableStub;
    address internal strategy;

    address internal vault = makeAddr("vault");
    address internal keeper = makeAddr("keeper");
    address internal protocolFeeRecipient = makeAddr("ponsProtocolFeeRecipient");
    address internal swapRouter = makeAddr("swapRouter");

    uint256 internal constant FEE = 5e14; // the live venue's `launchFee()`
    uint256 internal constant QUOTE_IN = 1 ether;
    uint256 internal constant SUPPLY = 1e27; // config 0's `supply`
    uint256 internal constant RESERVE = 0.5 ether; // at rate 1e18, 1 quote -> 1 token

    function setUp() public {
        weth = new MockWETH();
        locker = new MockPonsLocker(protocolFeeRecipient);
        padFactory = new MockPonsFactory(address(locker));
        locker.initialize(address(padFactory));

        usdg = new ERC20Mock("Gold", "USDG", 6);

        // Config 0 and dex 0, exactly as read off 4663.
        padFactory.addLaunchConfig(
            IPonsLaunchFactory.LaunchConfig({
                pairToken: address(weth),
                graduationThreshold: 4.2e18,
                initialTick: -204_200,
                supply: SUPPLY,
                maxWalletBps: 500,
                maxTxBps: 550,
                restrictionBlocks: 2,
                reservedFee: 0,
                enabled: true,
                routerRequiresDeadline: false
            })
        );
        padFactory.addDexConfig(
            IPonsLaunchFactory.DexConfig({
                name: "uniswap v3",
                factory: makeAddr("v3Factory"),
                positionManager: makeAddr("positionManager"),
                swapRouter: swapRouter,
                poolFee: 10_000,
                tickSpacing: 200,
                enabled: true
            })
        );
        padFactory.setLaunchFee(FEE);
        // The mainnet gate is CLOSED; the unit suite opens it so every other
        // behaviour is reachable. `test_RevertWhen_VenueGateIsClosed` closes it
        // again to prove the gate is real.
        padFactory.setWhitelistedLauncher(address(0), false);

        adapter = new PonsLaunchAdapter(address(padFactory), address(weth));
        padFactory.setLaunchEnabled(true);

        stub = new StrategyStub();
        payableStub = new PayableStrategyStub();
        strategy = address(stub);

        _fund(strategy, (QUOTE_IN + FEE) * 10);
        _fund(address(payableStub), (QUOTE_IN + FEE) * 10);
    }

    // ── helpers ──

    function _fund(address who, uint256 wethAmount) internal {
        vm.deal(who, wethAmount);
        vm.prank(who);
        weth.deposit{value: wethAmount}();
    }

    function _venueData(uint256 configId, uint256 dexId, bytes32 salt) internal pure returns (bytes memory) {
        return abi.encode(PonsLaunchAdapter.VenueData({launchConfigId: configId, dexId: dexId, salt: salt}));
    }

    /// @dev The production shape: the fund's VAULT is the fee recipient, named
    ///      by the launch itself. The strategy is only ever the reserve's
    ///      destination, which is a different address on a different lane.
    function _params(address quoteToken, uint256 quoteIn, uint256 minOut, uint256 reserve)
        internal
        pure
        returns (ILaunchAdapter.LaunchParams memory)
    {
        return _paramsFull(quoteToken, quoteIn, minOut, reserve, address(0), _venueData(0, 0, bytes32(0)));
    }

    function _paramsFull(
        address quoteToken,
        uint256 quoteIn,
        uint256 minOut,
        uint256 reserve,
        address feeRecipientOverride,
        bytes memory venueData
    ) internal pure returns (ILaunchAdapter.LaunchParams memory) {
        return ILaunchAdapter.LaunchParams({
            name: "Fund Token",
            symbol: "FUND",
            quoteToken: quoteToken,
            quoteIn: quoteIn,
            minTokensOut: minOut,
            reserveAmount: reserve,
            deadline: 0,
            feeRecipient: feeRecipientOverride,
            venueData: venueData
        });
    }

    function _toVault(ILaunchAdapter.LaunchParams memory p) internal view returns (ILaunchAdapter.LaunchParams memory) {
        p.feeRecipient = vault;
        return p;
    }

    function _approve(address who, uint256 amount) internal {
        vm.prank(who);
        weth.approve(address(adapter), amount);
    }

    /// @dev Goes through the CONTRACT stub, not a prank: production's caller is
    ///      a strategy clone, and the difference is load-bearing for the native
    ///      sweep.
    function _launchAsStrategy() internal returns (ILaunchAdapter.LaunchResult memory res) {
        _approve(strategy, QUOTE_IN + FEE);
        res = stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));
    }

    // ── THE CRUX: two destinations, and they are not the same one ──

    /// @dev The whole reason this adapter exists in the shape it does. Pons ties
    ///      the dev buy's recipient and the fee redirect to ONE `feeWallet`
    ///      field; `launch` names the STRATEGY there so the reserve lands on the
    ///      fund, then re-points the locker at the VAULT in the same
    ///      transaction. Both halves are asserted here, and so is the fact that
    ///      they are different addresses.
    function test_Launch_ReserveOnTheCallerFeesOnTheFeeRecipient() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();

        // 1 ── the reserve is the CALLER's.
        assertEq(res.reserveHeld, QUOTE_IN, "reserve = dev buy output");
        assertGe(res.reserveHeld, RESERVE, "reserve floor honoured");
        assertEq(IERC20(res.token).balanceOf(strategy), res.reserveHeld, "strategy holds the reserve");
        assertEq(IERC20(res.token).balanceOf(vault), 0, "the fee recipient gets no reserve");

        // 2 ── the fee stream is the FEE RECIPIENT's, in this same transaction.
        assertEq(locker.feeRedirects(res.token), vault, "redirect must be the vault, not the strategy");
        assertTrue(locker.feeRedirects(res.token) != strategy, "the strategy must not hold the fee stream");
        assertTrue(locker.feeRedirects(res.token) != address(adapter), "nor the adapter");

        // 3 ── and the venue still records the ADAPTER as the deployer, which is
        //      the standing that made step 2 possible at all.
        assertEq(padFactory.getLaunchedToken(res.token).deployer, address(adapter), "adapter is the deployer");
        assertEq(padFactory.getLaunchedToken(res.token).pairedToken, address(weth), "paired against the quote");

        assertEq(res.quoteSpent, QUOTE_IN, "the buy consumed the whole quote");
        assertEq(res.launchRef, bytes32(uint256(uint160(res.token))), "the ref IS the token");
    }

    function test_Launch_AdapterEndsClean() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();

        assertEq(IERC20(res.token).balanceOf(address(adapter)), 0, "no launch token on adapter");
        assertEq(weth.balanceOf(address(adapter)), 0, "no quote/fee WETH on adapter");
        assertEq(address(adapter).balance, 0, "no native on adapter");
        assertEq(weth.allowance(address(adapter), address(padFactory)), 0, "no standing allowance");
        assertEq(weth.allowance(address(adapter), address(locker)), 0, "no standing allowance");
        // The fee genuinely left as native, and the buy funded the venue.
        assertEq(protocolFeeRecipient.balance, FEE, "the launch fee was paid in native");
        assertEq(address(padFactory).balance, QUOTE_IN, "the dev buy reached the venue as native");
    }

    /// @dev The recipient is per-launch, not adapter-wide: a shared singleton
    ///      that pinned one fee destination would be a shared custody surface.
    function test_Launch_FeeRecipientIsPerLaunch() public {
        address vaultA = makeAddr("vaultA");
        address vaultB = makeAddr("vaultB");
        _approve(strategy, (QUOTE_IN + FEE) * 2);

        ILaunchAdapter.LaunchResult memory a = stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, vaultA, _venueData(0, 0, bytes32(uint256(1))))
        );
        ILaunchAdapter.LaunchResult memory b = stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, vaultB, _venueData(0, 0, bytes32(uint256(2))))
        );

        assertEq(locker.feeRedirects(a.token), vaultA);
        assertEq(locker.feeRedirects(b.token), vaultB);
        assertTrue(a.token != b.token, "distinct salts give distinct tokens");
    }

    /// @dev THE RESIDUAL POWER, BOUNDED. The adapter is `launched.deployer`
    ///      forever and the venue would let a deployer re-point fees at will —
    ///      the invariant holds only because this contract exposes no path to
    ///      do it. Asserted three ways: the adapter has no such function, the
    ///      strategy is not the deployer, and an outsider is neither.
    function test_NoExternalPathRepointsTheFeeRedirectAfterLaunch() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        address attacker = makeAddr("attacker");

        // 1 ── the adapter exposes nothing that reaches `setFeeRedirect`. Every
        //      external/public function of the adapter is enumerated here; only
        //      `launch` touches the locker's redirect, and only for a token it
        //      is minting in that same call.
        vm.startPrank(attacker);
        adapter.finalize(res.launchRef);
        adapter.collectFees(res.launchRef);
        adapter.phase(res.launchRef);
        adapter.quoteSupported(address(weth));
        adapter.nativeFeeSource();
        adapter.launchTarget();
        vm.stopPrank();
        assertEq(locker.feeRedirects(res.token), vault, "no adapter verb moved the redirect");

        // 2 ── a fresh `launch` cannot re-point an EXISTING launch either: it
        //      only ever redirects the token it just minted.
        _approve(strategy, QUOTE_IN + FEE);
        ILaunchAdapter.LaunchResult memory second = stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, attacker, _venueData(0, 0, bytes32(uint256(0xbeef))))
        );
        assertTrue(second.token != res.token, "a second launch mints its own token");
        assertEq(locker.feeRedirects(res.token), vault, "the first launch's redirect is untouched");

        // 3 ── nobody outside the adapter holds the lever: the strategy is not
        //      the deployer, and neither is an attacker.
        vm.expectRevert(MockPonsLocker.NotDeployer.selector);
        stub.setFeeRedirect(address(locker), res.token, strategy);

        vm.prank(attacker);
        vm.expectRevert(MockPonsLocker.NotDeployer.selector);
        locker.setFeeRedirect(res.token, attacker);

        assertEq(locker.feeRedirects(res.token), vault, "still the vault");
    }

    // ── rejections that must happen before any capital moves ──

    function test_RevertWhen_FeeRecipientIsZero_NoFundsMove() public {
        uint256 before = weth.balanceOf(strategy);
        _approve(strategy, QUOTE_IN + FEE);

        vm.expectRevert(PonsLaunchAdapter.ZeroFeeRecipient.selector);
        stub.launch(address(adapter), _params(address(weth), QUOTE_IN, RESERVE, RESERVE));

        assertEq(weth.balanceOf(strategy), before, "no quote or fee pulled");
        assertEq(weth.balanceOf(address(adapter)), 0, "nothing reached the adapter");
    }

    function test_RevertWhen_UnsupportedQuote_NoFundsMove() public {
        uint256 before = weth.balanceOf(strategy);
        _approve(strategy, QUOTE_IN + FEE);

        vm.expectRevert(abi.encodeWithSelector(PonsLaunchAdapter.UnsupportedQuote.selector, address(usdg)));
        stub.launch(address(adapter), _toVault(_params(address(usdg), QUOTE_IN, RESERVE, RESERVE)));

        assertEq(weth.balanceOf(strategy), before, "no quote or fee pulled");
        assertEq(weth.balanceOf(address(adapter)), 0);
    }

    function test_RevertWhen_ZeroQuoteIn() public {
        _approve(strategy, QUOTE_IN + FEE);
        vm.expectRevert(PonsLaunchAdapter.ZeroQuoteIn.selector);
        stub.launch(address(adapter), _toVault(_params(address(weth), 0, RESERVE, RESERVE)));
    }

    function test_RevertWhen_MinTokensOutBelowReserve() public {
        _approve(strategy, QUOTE_IN + FEE);
        vm.expectRevert(
            abi.encodeWithSelector(PonsLaunchAdapter.ReserveFloorBelowReserve.selector, RESERVE - 1, RESERVE)
        );
        stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE - 1, RESERVE)));
    }

    function test_RevertWhen_VenueDataMalformed() public {
        _approve(strategy, QUOTE_IN + FEE);
        ILaunchAdapter.LaunchParams memory p =
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, vault, abi.encode(uint256(0), uint256(0)));
        vm.expectRevert(abi.encodeWithSelector(PonsLaunchAdapter.InvalidVenueData.selector, uint256(64)));
        stub.launch(address(adapter), p);
    }

    function test_RevertWhen_LaunchConfigOutOfRangeOrDisabled() public {
        _approve(strategy, (QUOTE_IN + FEE) * 2);

        vm.expectRevert(abi.encodeWithSelector(PonsLaunchAdapter.LaunchConfigUnusable.selector, uint256(7)));
        stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, vault, _venueData(7, 0, bytes32(0)))
        );

        // A DISABLED config must be named explicitly to be reachable: with the
        // only WETH config off, `quoteSupported` already answers false and the
        // launch is refused one check earlier. So add a second, live WETH
        // config, disable the first, and name the first.
        padFactory.addLaunchConfig(
            IPonsLaunchFactory.LaunchConfig({
                pairToken: address(weth),
                graduationThreshold: 4.2e18,
                initialTick: -204_200,
                supply: SUPPLY,
                maxWalletBps: 500,
                maxTxBps: 550,
                restrictionBlocks: 2,
                reservedFee: 0,
                enabled: true,
                routerRequiresDeadline: false
            })
        );
        padFactory.setLaunchConfigEnabled(0, false);
        assertTrue(adapter.quoteSupported(address(weth)), "WETH is still pairable through config 1");

        vm.expectRevert(abi.encodeWithSelector(PonsLaunchAdapter.LaunchConfigUnusable.selector, uint256(0)));
        stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));

        // ...and the live one still works, so this is the config gate and not a
        // blanket refusal.
        ILaunchAdapter.LaunchResult memory res = stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, vault, _venueData(1, 0, bytes32(0)))
        );
        assertEq(IERC20(res.token).balanceOf(strategy), res.reserveHeld);
    }

    /// @dev A config the venue owner re-points between propose and execute must
    ///      not pair the fund against an asset the vote never named.
    function test_RevertWhen_ConfigPairTokenDoesNotMatchTheProposalsQuote() public {
        // A second, enabled config paired against USDG. `quoteSupported` still
        // answers false for USDG (the adapter can only fund a native buy), but
        // the mismatch guard is what catches naming WETH against config 1.
        padFactory.addLaunchConfig(
            IPonsLaunchFactory.LaunchConfig({
                pairToken: address(usdg),
                graduationThreshold: 4.2e18,
                initialTick: -204_200,
                supply: SUPPLY,
                maxWalletBps: 500,
                maxTxBps: 550,
                restrictionBlocks: 2,
                reservedFee: 0,
                enabled: true,
                routerRequiresDeadline: false
            })
        );
        _approve(strategy, QUOTE_IN + FEE);
        vm.expectRevert(
            abi.encodeWithSelector(
                PonsLaunchAdapter.LaunchConfigQuoteMismatch.selector, uint256(1), address(usdg), address(weth)
            )
        );
        stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, vault, _venueData(1, 0, bytes32(0)))
        );
    }

    function test_RevertWhen_DexOutOfRangeDisabledOrRouterless() public {
        _approve(strategy, (QUOTE_IN + FEE) * 3);

        vm.expectRevert(abi.encodeWithSelector(PonsLaunchAdapter.DexConfigUnusable.selector, uint256(3)));
        stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, vault, _venueData(0, 3, bytes32(0)))
        );

        padFactory.setDexEnabled(0, false);
        vm.expectRevert(abi.encodeWithSelector(PonsLaunchAdapter.DexConfigUnusable.selector, uint256(0)));
        stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));

        padFactory.setDexEnabled(0, true);
        padFactory.setDexSwapRouter(0, address(0));
        vm.expectRevert(abi.encodeWithSelector(PonsLaunchAdapter.DexConfigUnusable.selector, uint256(0)));
        stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));
    }

    /// @dev THE LIVE BLOCKER, in miniature. Mainnet's `launchEnabled` is false
    ///      and no launcher is whitelisted, so every launch reverts at the
    ///      venue until Pons acts. The fork suite proves the same thing against
    ///      the real factory.
    function test_RevertWhen_VenueGateIsClosed() public {
        padFactory.setLaunchEnabled(false);
        _approve(strategy, QUOTE_IN + FEE);
        vm.expectRevert(MockPonsFactory.NotWhitelisted.selector);
        stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));

        // Whitelisting the ADAPTER — not the strategy — is what opens it, which
        // is why the adapter has to be a singleton.
        padFactory.setWhitelistedLauncher(address(adapter), true);
        ILaunchAdapter.LaunchResult memory res =
            stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));
        assertEq(IERC20(res.token).balanceOf(strategy), res.reserveHeld, "whitelisting the adapter opens the venue");
    }

    // ── reserve enforcement: the adapter is the ONLY floor here ──

    /// @dev The venue passes `amountOutMinimum: 0`, so nothing behind this
    ///      check enforces the proposal's floor. Contrast Sushi, where the
    ///      venue's own `InsufficientInitialBuyOutput` fired first.
    function test_RevertWhen_BuyUnderDeliversAgainstTheProposalsFloor() public {
        padFactory.setRate(1e17); // 0.1 token per native -> 0.1e18 out
        _approve(strategy, QUOTE_IN + FEE);
        vm.expectRevert(abi.encodeWithSelector(PonsLaunchAdapter.SlippageFloorNotMet.selector, QUOTE_IN / 10, RESERVE));
        stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));
    }

    function test_Launch_VenueEnforcesNoFloorOfItsOwn() public {
        // With `minTokensOut` set to what the venue will actually deliver, a
        // 10x under-price sails through the VENUE — proving the venue is not
        // the guard and the adapter's check is load-bearing.
        padFactory.setRate(1e17);
        _approve(strategy, QUOTE_IN + FEE);
        ILaunchAdapter.LaunchResult memory res = stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, QUOTE_IN / 10, QUOTE_IN / 10, vault, _venueData(0, 0, bytes32(0)))
        );
        assertEq(res.reserveHeld, QUOTE_IN / 10, "the venue settled a 10x-worse price without complaint");
    }

    // ── phase / finalize ──

    function test_Phase_UnknownRefReturnsNoneWithoutReverting() public {
        assertEq(uint256(adapter.phase(bytes32(0))), uint256(ILaunchAdapter.LaunchPhase.None), "zero ref");
        assertEq(
            uint256(adapter.phase(bytes32(uint256(uint160(makeAddr("neverIssued")))))),
            uint256(ILaunchAdapter.LaunchPhase.None),
            "never issued"
        );
        assertEq(
            uint256(adapter.phase(bytes32(type(uint256).max))), uint256(ILaunchAdapter.LaunchPhase.None), "dirty ref"
        );
        assertEq(
            uint256(adapter.phase(bytes32(uint256(uint160(address(padFactory)))))),
            uint256(ILaunchAdapter.LaunchPhase.None),
            "codeful non-launch"
        );
    }

    function test_Phase_IssuedLaunchIsLive() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Live));
    }

    /// @dev A Pons launch some OTHER deployer made is `None` here: this adapter
    ///      reports only on launches it issued, and holds no deployer power
    ///      over the rest.
    function test_Phase_ForeignLaunchIsNone() public {
        address outsider = makeAddr("outsider");
        padFactory.setWhitelistedLauncher(outsider, true);
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        address foreign = padFactory.launchToken{value: FEE}(
            IPonsLaunchFactory.TokenParams({
                name: "Rival",
                symbol: "RIVAL",
                logo: "",
                description: "",
                socials: IPonsLaunchFactory.Socials({
                    twitter: "", telegram: "", discord: "", website: "", farcaster: ""
                }),
                feeWallet: outsider
            }),
            0,
            0,
            bytes32(uint256(99))
        );
        assertTrue(padFactory.getLaunchedToken(foreign).exists, "the venue issued it");
        assertEq(
            uint256(adapter.phase(bytes32(uint256(uint160(foreign))))),
            uint256(ILaunchAdapter.LaunchPhase.None),
            "but this adapter did not"
        );
    }

    function test_Finalize_IsANoOpInEveryPhase() public {
        adapter.finalize(bytes32(0));
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        adapter.finalize(res.launchRef);
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Live));
    }

    // ── quote gating ──

    function test_QuoteSupported_NeverReverts() public {
        assertTrue(adapter.quoteSupported(address(weth)), "the configured pairing");
        assertFalse(adapter.quoteSupported(address(0)), "zero quote");
        assertFalse(adapter.quoteSupported(makeAddr("notAContract")), "non-contract quote");
        assertFalse(adapter.quoteSupported(address(usdg)), "not a configured pairing");

        // Disabling the config flips it, with no change here.
        padFactory.setLaunchConfigEnabled(0, false);
        assertFalse(adapter.quoteSupported(address(weth)), "disabled config");
        padFactory.setLaunchConfigEnabled(0, true);
        assertTrue(adapter.quoteSupported(address(weth)), "re-enabled");
    }

    /// @dev The two gates are different kinds of limit and both are asserted: a
    ///      pairing Pons ADDS becomes visible to the config scan, but the
    ///      adapter still refuses it because it cannot fund a native dev buy
    ///      against a non-wrapped-native quote.
    function test_QuoteSupported_ConfiguredNonNativePairIsStillRefused() public {
        padFactory.addLaunchConfig(
            IPonsLaunchFactory.LaunchConfig({
                pairToken: address(usdg),
                graduationThreshold: 4.2e18,
                initialTick: -204_200,
                supply: SUPPLY,
                maxWalletBps: 500,
                maxTxBps: 550,
                restrictionBlocks: 2,
                reservedFee: 0,
                enabled: true,
                routerRequiresDeadline: false
            })
        );
        assertFalse(adapter.quoteSupported(address(usdg)), "configured, but not the wrapped native");
        assertTrue(adapter.quoteSupported(address(weth)), "still the one live pairing");
    }

    // ── native fee source ──

    function test_NativeFeeSource_ReportsWethAndTheLiveFee() public {
        (address token, uint256 amount) = adapter.nativeFeeSource();
        assertEq(token, address(weth), "fee source is WETH");
        assertEq(amount, FEE);

        padFactory.setLaunchFee(2e15);
        (, amount) = adapter.nativeFeeSource();
        assertEq(amount, 2e15, "read live, not pinned");
    }

    function test_Launch_PullsExactlyTheQuotePlusTheLiveFee() public {
        uint256 before = weth.balanceOf(strategy);
        _approve(strategy, (QUOTE_IN + FEE) * 5); // approve far more than needed
        stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));

        assertEq(before - weth.balanceOf(strategy), QUOTE_IN + FEE, "exactly quote + fee, no more");
        assertEq(
            weth.allowance(strategy, address(adapter)),
            (QUOTE_IN + FEE) * 5 - (QUOTE_IN + FEE),
            "remaining approval untouched"
        );
        assertEq(address(adapter).balance, 0);
    }

    function test_Launch_WithZeroFeePullsOnlyTheQuote() public {
        padFactory.setLaunchFee(0);
        uint256 before = weth.balanceOf(strategy);
        _approve(strategy, QUOTE_IN);
        stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));
        assertEq(before - weth.balanceOf(strategy), QUOTE_IN, "no fee pulled when the venue charges nothing");
    }

    function test_Launch_SweepsAttachedValueBackToTheCaller() public {
        address caller = address(payableStub);
        vm.deal(caller, 1 ether);
        _approve(caller, QUOTE_IN + FEE);
        uint256 nativeBefore = caller.balance;
        payableStub.launchWithValue(
            address(adapter), 0.3 ether, _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE))
        );
        assertEq(caller.balance, nativeBefore, "attached value returned in full");
        assertEq(address(adapter).balance, 0);
    }

    // ── native force-send: the sweep must never brick a shared singleton ──

    function test_Launch_ThroughANonReceivingStrategyContractSucceeds() public {
        assertEq(address(adapter).balance, 0, "no dust to start");
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();

        assertEq(IERC20(res.token).balanceOf(strategy), res.reserveHeld, "reserve delivered to the contract caller");
        assertEq(locker.feeRedirects(res.token), vault, "redirect handed to the fee recipient in-tx");
        assertEq(address(adapter).balance, 0, "adapter holds no native");

        assertEq(strategy.balance, 0, "the strategy holds no native");
        vm.deal(address(this), 1);
        (bool ok,) = strategy.call{value: 1}("");
        assertFalse(ok, "the strategy clone shape rejects native");
    }

    /// @dev ONE FORCE-SENT WEI MUST NOT BRICK THE SINGLETON. The caller is a
    ///      contract that cannot accept a send, and this sweep is the only path
    ///      moving native off a shared, certified adapter — one that on this
    ///      venue would also need a fresh Pons whitelist entry to replace.
    function test_Launch_SurvivesNativeForceSentToTheAdapter() public {
        new ForceSender{value: 1}(payable(address(adapter)));
        assertEq(address(adapter).balance, 1, "no `receive()` guard can refuse a force-send");

        _approve(strategy, (QUOTE_IN + FEE) * 2);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit PonsLaunchAdapter.NativeSweepSkipped(strategy, 1);
        ILaunchAdapter.LaunchResult memory res =
            stub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));

        assertEq(res.quoteSpent, QUOTE_IN, "buy consumed in full");
        assertEq(IERC20(res.token).balanceOf(strategy), res.reserveHeld, "reserve still delivered");
        assertEq(locker.feeRedirects(res.token), vault, "redirect still applied");
        assertEq(weth.balanceOf(address(adapter)), 0, "token sweeps still assert clean");
        assertEq(address(adapter).balance, 1, "unsendable wei left in place, not reverted over");

        // And it is not a one-shot: the adapter keeps serving, launch after launch.
        ILaunchAdapter.LaunchResult memory res2 = stub.launch(
            address(adapter),
            _paramsFull(address(weth), QUOTE_IN, RESERVE, RESERVE, vault, _venueData(0, 0, bytes32(uint256(2))))
        );
        assertTrue(res2.token != res.token, "a second launch still goes through");
        assertEq(address(adapter).balance, 1);
    }

    function test_Launch_ForceSentNativeIsSweptByACallerThatCanReceive() public {
        new ForceSender{value: 1}(payable(address(adapter)));
        address caller = address(payableStub);
        uint256 nativeBefore = caller.balance;
        _approve(caller, QUOTE_IN + FEE);
        payableStub.launch(address(adapter), _toVault(_params(address(weth), QUOTE_IN, RESERVE, RESERVE)));

        assertEq(caller.balance, nativeBefore + 1, "stranded wei goes to the next caller that can take it");
        assertEq(address(adapter).balance, 0, "adapter clean again");
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
            bytes32(PonsLaunchAdapter.UnexpectedNativePayment.selector),
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

    /// @dev The locker keeps `protocolFeeShare` of the gross, so the RECIPIENT's
    ///      deltas and the locker's return tuple are different numbers. The
    ///      adapter must report the former.
    function test_CollectFees_ReportsTheRecipientsDeltasNotTheGross() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        _stageFees(res.token, 10 ether, 20 ether);

        uint256 stratWethBefore = weth.balanceOf(strategy);
        uint256 stratTokenBefore = IERC20(res.token).balanceOf(strategy);

        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);

        // 30% protocol share on the live locker.
        assertEq(quoteOut, 7 ether, "quote leg is the recipient's NET, not the gross 10");
        assertEq(tokenOut, 14 ether, "token leg is the recipient's NET, not the gross 20");
        assertEq(weth.balanceOf(vault), 7 ether, "vault paid direct by the locker");
        assertEq(IERC20(res.token).balanceOf(vault), 14 ether);
        assertEq(weth.balanceOf(protocolFeeRecipient), 3 ether, "and Pons keeps its share");

        assertEq(weth.balanceOf(strategy), stratWethBefore, "the strategy receives no fees, ever");
        assertEq(IERC20(res.token).balanceOf(strategy), stratTokenBefore, "the strategy receives no fees, ever");
        assertEq(weth.balanceOf(keeper), 0, "the caller is paid nothing for calling");
        assertEq(IERC20(res.token).balanceOf(keeper), 0);
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter receives nothing");
        assertEq(IERC20(res.token).balanceOf(address(adapter)), 0);
    }

    /// @dev Permissionless ON OUR SIDE, though the venue gates it: the locker
    ///      would refuse the keeper directly, and admits the adapter only
    ///      because the adapter is the deployer.
    function test_CollectFees_KeeperCannotCallTheLockerDirectlyButCanDriveTheAdapter() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        _stageFees(res.token, 10 ether, 0);

        vm.prank(keeper);
        vm.expectRevert(MockPonsLocker.NotAuthorized.selector);
        locker.collectFees(res.token);

        vm.prank(keeper);
        (uint256 quoteOut,) = adapter.collectFees(res.launchRef);
        assertEq(quoteOut, 7 ether, "the same keeper gets it done through the adapter");
        assertEq(weth.balanceOf(vault), 7 ether, "and the payee is unchanged");
    }

    function test_CollectFees_ReturnsZeroesWhenNothingAccrued() public {
        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);
        assertEq(quoteOut, 0, "NoFeesToCollect is tolerated, not propagated");
        assertEq(tokenOut, 0);
    }

    function test_CollectFees_ReturnsZeroesOnUnknownRefAndVenueRefusal() public {
        (uint256 q, uint256 t) = adapter.collectFees(bytes32(uint256(uint160(makeAddr("neverIssued")))));
        assertEq(q, 0);
        assertEq(t, 0);
        (q, t) = adapter.collectFees(bytes32(0));
        assertEq(q, 0);
        assertEq(t, 0);

        ILaunchAdapter.LaunchResult memory res = _launchAsStrategy();
        _stageFees(res.token, 10 ether, 20 ether);
        locker.setCollectReverts(true);
        vm.prank(keeper);
        (q, t) = adapter.collectFees(res.launchRef);
        assertEq(q, 0, "no delta reported when the venue reverted");
        assertEq(t, 0);
        assertEq(weth.balanceOf(vault), 0, "and nothing moved");
    }

    // ── wiring ──

    function test_LaunchTargetAndImmutables() public view {
        assertEq(adapter.launchTarget(), address(padFactory));
        assertEq(address(adapter.factory()), address(padFactory));
        assertEq(address(adapter.locker()), address(locker), "locker read off the factory");
        assertEq(adapter.weth(), address(weth));
    }

    function test_RevertWhen_ConstructedWithACodelessFactory() public {
        vm.expectRevert(PonsLaunchAdapter.InvalidFactory.selector);
        new PonsLaunchAdapter(makeAddr("notAContract"), address(weth));
        vm.expectRevert(PonsLaunchAdapter.InvalidFactory.selector);
        new PonsLaunchAdapter(address(0), address(weth));
    }

    /// @dev A locker bound to some OTHER factory would reject every
    ///      `setFeeRedirect` this adapter makes — after a launch had already
    ///      happened. The round trip refuses it at deploy.
    function test_RevertWhen_LockerDisownsTheFactory() public {
        MockPonsLocker orphan = new MockPonsLocker(protocolFeeRecipient);
        orphan.initialize(makeAddr("someOtherFactory"));
        MockPonsFactory mismatched = new MockPonsFactory(address(orphan));
        vm.expectRevert(PonsLaunchAdapter.InvalidLocker.selector);
        new PonsLaunchAdapter(address(mismatched), address(weth));
    }

    function test_RevertWhen_WrappedNativeIsNotALivePairing() public {
        vm.expectRevert(PonsLaunchAdapter.InvalidWeth.selector);
        new PonsLaunchAdapter(address(padFactory), address(usdg));
        vm.expectRevert(PonsLaunchAdapter.InvalidWeth.selector);
        new PonsLaunchAdapter(address(padFactory), address(0));
        vm.expectRevert(PonsLaunchAdapter.InvalidWeth.selector);
        new PonsLaunchAdapter(address(padFactory), makeAddr("notAContract"));

        padFactory.setLaunchConfigEnabled(0, false);
        vm.expectRevert(PonsLaunchAdapter.InvalidWeth.selector);
        new PonsLaunchAdapter(address(padFactory), address(weth));
    }

    // ── helpers ──

    /// @dev Stages REAL locker balances so `collectFees` moves tokens rather
    ///      than bookkeeping. `pairedAmount`/`tokenAmount` are the GROSS.
    function _stageFees(address token, uint256 pairedAmount, uint256 tokenAmount) internal {
        if (tokenAmount != 0) padFactory.sendLockedTokens(token, address(locker), tokenAmount);
        if (pairedAmount != 0) {
            vm.deal(address(this), pairedAmount);
            weth.deposit{value: pairedAmount}();
            weth.transfer(address(locker), pairedAmount);
        }
        locker.setFeesOwed(token, pairedAmount, tokenAmount);
    }
}
