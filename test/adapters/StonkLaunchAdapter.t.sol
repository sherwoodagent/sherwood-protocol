// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StonkLaunchAdapter} from "../../src/adapters/StonkLaunchAdapter.sol";
import {ILaunchAdapter} from "../../src/interfaces/ILaunchAdapter.sol";
import {IStonkSafeLaunchpadV2} from "../../src/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";
import {MockStonkPad} from "../mocks/MockStonkPad.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Stands in for `TokenizeFundStrategy`: the `launch` caller, the clone
///         owner, and the address the custody invariant says must end up
///         holding the reserve.
/// @dev It still exposes `state()` and `vault()`, but the adapter no longer
///      reads EITHER. They are kept precisely so the tests can move the owner
///      through settlement and assert that nothing about the fee destination
///      changes — that indifference is the whole point of naming the recipient
///      at launch.
contract MockFundStrategy {
    uint8 public stateValue; // 0 Pending, 1 Executed, 2 Settled
    address public vaultAddress;

    constructor(address vault_) {
        vaultAddress = vault_;
    }

    function state() external view returns (uint8) {
        return stateValue;
    }

    function vault() external view returns (address) {
        return vaultAddress;
    }

    function setState(uint8 value) external {
        stateValue = value;
    }
}

/// @notice An owner contract that answers NEITHER `state()` nor `vault()`.
/// @dev Formerly the fail-closed adversary for `forwardToVault`'s owner reads.
///      Those reads are gone, so it now proves something stronger: an owner
///      that answers nothing at all cannot influence where a fund's fees go,
///      or whether they move.
contract MuteOwner {}

/// @notice Reverts loudly on ANY call, including its fallback.
/// @dev The forged-ref probe. If a ref-taking verb ever calls the address it
///      was handed instead of rejecting it on ERC-1167 introspection, the test
///      sees this revert instead of a clean `None`/`(0, 0)`.
contract LoudTrap {
    error TrapCalled();

    fallback() external payable {
        revert TrapCalled();
    }
}

contract StonkLaunchAdapterTest is Test {
    StonkLaunchAdapter internal adapter;
    MockStonkPad internal wethPad;
    MockStonkPad internal stonkPad;
    ERC20Mock internal weth;
    ERC20Mock internal stonk;
    ERC20Mock internal wood;
    address internal lens = makeAddr("lens");

    MockFundStrategy internal strategy;
    address internal vault = makeAddr("vault");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant RESERVE = 100_000 ether; // 10% of supply
    uint256 internal constant QUOTE_IN = 10 ether;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        stonk = new ERC20Mock("Stonk", "STONK", 18);
        wood = new ERC20Mock("Wood", "WOOD", 18);

        wethPad = new MockStonkPad(address(weth));
        stonkPad = new MockStonkPad(address(stonk));
        // The lens is held, never called — a codeful address is all it needs.
        vm.etch(lens, hex"600160005260206000f3");

        adapter = new StonkLaunchAdapter(_quotes(), _pads(), lens);

        strategy = new MockFundStrategy(vault);
        weth.mint(address(strategy), QUOTE_IN * 10);
        // The pad needs quote on hand to pay creator fees out of.
        weth.mint(address(wethPad), 1_000 ether);
    }

    // ── helpers ──

    function _quotes() internal view returns (address[] memory q) {
        q = new address[](2);
        q[0] = address(weth);
        q[1] = address(stonk);
    }

    function _pads() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(wethPad);
        p[1] = address(stonkPad);
    }

    /// @dev A windowed (not open-ended) launch: `startTaxBps / decay * 60 = 600`
    ///      seconds, which is the venue's `minWindowSecs`.
    function _venueData() internal pure returns (bytes memory) {
        return abi.encode(
            StonkLaunchAdapter.VenueData({
                supply: SUPPLY,
                startMcapUsd8: 1e11,
                gradMcapUsd8: 5e12,
                startTaxBps: 1000,
                taxDecayPerMinuteBps: 100,
                sellsEnabled: true,
                bufferSecs: 60,
                unsoldMode: 0,
                openEnded: false,
                postTaxBps: 0,
                bondVenue: 0,
                maxBuyPpm: 10_000
            })
        );
    }

    /// @dev The open-ended shape: zero tax, no closing deadline at all.
    function _openEndedVenueData() internal pure returns (bytes memory) {
        return abi.encode(
            StonkLaunchAdapter.VenueData({
                supply: SUPPLY,
                startMcapUsd8: 1e11,
                gradMcapUsd8: 5e12,
                startTaxBps: 0,
                taxDecayPerMinuteBps: 0,
                sellsEnabled: true,
                bufferSecs: 0,
                unsoldMode: 0,
                openEnded: true,
                postTaxBps: 300,
                bondVenue: 0,
                maxBuyPpm: 10_000
            })
        );
    }

    /// @dev The production shape: the fund's VAULT is the fee recipient, named
    ///      by the launch. The owning strategy is the RESERVE's destination,
    ///      which is a different address on a different lane.
    function _params(address quoteToken, uint256 quoteIn, uint256 minOut, uint256 reserve, bytes memory venueData)
        internal
        view
        returns (ILaunchAdapter.LaunchParams memory)
    {
        return _paramsTo(quoteToken, quoteIn, minOut, reserve, venueData, vault);
    }

    function _paramsTo(
        address quoteToken,
        uint256 quoteIn,
        uint256 minOut,
        uint256 reserve,
        bytes memory venueData,
        address feeRecipient
    ) internal view returns (ILaunchAdapter.LaunchParams memory) {
        return ILaunchAdapter.LaunchParams({
            name: "Fund Token",
            symbol: "FUND",
            quoteToken: quoteToken,
            quoteIn: quoteIn,
            minTokensOut: minOut,
            reserveAmount: reserve,
            deadline: uint64(block.timestamp + 1 hours),
            feeRecipient: feeRecipient,
            venueData: venueData
        });
    }

    function _launch(uint256 quoteIn, uint256 minOut, uint256 reserve)
        internal
        returns (ILaunchAdapter.LaunchResult memory res)
    {
        vm.prank(address(strategy));
        weth.approve(address(adapter), quoteIn);
        vm.prank(address(strategy));
        res = adapter.launch(_params(address(weth), quoteIn, minOut, reserve, _venueData()));
    }

    function _clone(ILaunchAdapter.LaunchResult memory res) internal pure returns (StonkLaunchAdapter) {
        return StonkLaunchAdapter(address(uint160(uint256(res.launchRef))));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // custody invariant — spec "Reserve withheld before arming"
    // ─────────────────────────────────────────────────────────────────────────

    function test_Launch_ReserveWithheldAndRemainderArmed() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        uint256 id = clone.launchId();

        assertEq(IERC20(res.token).balanceOf(address(strategy)), RESERVE, "strategy holds the reserve");
        assertEq(res.reserveHeld, RESERVE, "reported reserve is what landed on the owner");
        assertEq(wethPad.getLaunch(id).loadedSupply, SUPPLY - RESERVE, "curve armed with supply - reserve");
        assertEq(IERC20(res.token).balanceOf(address(clone)), 0, "clone holds nothing but the creator role");
        assertEq(wethPad.getLaunch(id).creator, address(clone), "the clone is the creator");
        assertEq(IERC20(res.token).totalSupply(), SUPPLY, "the declared supply, in full");
    }

    function test_Launch_FairLaunchShapeSpendsNoQuote() public {
        uint256 before = weth.balanceOf(address(strategy));
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);

        assertEq(res.quoteSpent, 0, "a pure fair launch spends nothing");
        assertEq(weth.balanceOf(address(strategy)), before, "no quote left the strategy");
        assertEq(wethPad.getLaunch(_clone(res).launchId()).buyCount, 0, "no dev buy happened");
    }

    function test_Launch_DevBuyIsDeliveredStraightToTheStrategy() public {
        ILaunchAdapter.LaunchResult memory res = _launch(QUOTE_IN, QUOTE_IN, RESERVE);
        StonkLaunchAdapter clone = _clone(res);

        // rate 1e18: 10 quote -> 10 tokens, delivered by the pad to the owner.
        assertEq(res.reserveHeld, RESERVE + QUOTE_IN, "reserve + dev buy, both on the strategy");
        assertEq(IERC20(res.token).balanceOf(address(strategy)), RESERVE + QUOTE_IN);
        assertEq(res.quoteSpent, QUOTE_IN, "the pad consumed the buy in full");
        assertEq(wethPad.getLaunch(clone.launchId()).buyCount, 1, "the buy is on the curve");
        assertEq(IERC20(res.token).balanceOf(address(clone)), 0, "no bought token rests on the clone");
        assertEq(weth.balanceOf(address(clone)), 0, "no quote rests on the clone");
        assertEq(weth.balanceOf(address(adapter)), 0, "the implementation never holds the quote");
    }

    function test_Launch_NeverSetsEoaOnly() public {
        ILaunchAdapter.LaunchResult memory res = _launch(QUOTE_IN, 0, RESERVE);
        assertFalse(wethPad.modesOf(_clone(res).launchId()).eoaOnly, "eoaOnly is never set");
        // And it is not a parameter the caller could smuggle in: `VenueData`
        // carries no such field.
    }

    function test_Launch_RefIsTheCloneAndTheCloneIsOurs() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        address clone = address(uint160(uint256(res.launchRef)));
        assertTrue(adapter.isClone(clone), "the ref is an ERC-1167 clone of this implementation");
        assertEq(uint256(res.launchRef) >> 160, 0, "the ref carries no dirty high bits");
        assertEq(StonkLaunchAdapter(clone).owner(), address(strategy), "owned by the calling strategy");
        assertEq(StonkLaunchAdapter(clone).pad(), address(wethPad), "bound to the lane's pad");
        assertEq(StonkLaunchAdapter(clone).feeRecipient(), vault, "and pinned to the launch's fee recipient");
    }

    /// @dev The clone must remain the VENUE's creator — `arm` and `abort` are
    ///      creator-only levers it genuinely needs — so "fees go to the vault"
    ///      is achieved by forwarding, not by naming the vault at the pad.
    function test_Launch_CloneIsTheVenueCreatorButTheVaultIsTheFeeRecipient() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);

        assertEq(wethPad.getLaunch(clone.launchId()).creator, address(clone), "the venue creator is the clone");
        assertEq(clone.feeRecipient(), vault, "the fee destination is the vault");
        assertTrue(clone.feeRecipient() != clone.owner(), "and it is not the owning strategy");
    }

    /// @dev Per-launch, not implementation-wide: each clone carries its own.
    function test_Launch_FeeRecipientIsPerClone() public {
        address vaultA = makeAddr("vaultA");
        vm.prank(address(strategy));
        ILaunchAdapter.LaunchResult memory a =
            adapter.launch(_paramsTo(address(weth), 0, 0, RESERVE, _venueData(), vaultA));
        ILaunchAdapter.LaunchResult memory b = _launch(0, 0, RESERVE);

        assertEq(_clone(a).feeRecipient(), vaultA);
        assertEq(_clone(b).feeRecipient(), vault);

        wethPad.creditCreatorQuote(_clone(a).launchId(), 3 ether);
        vm.prank(keeper);
        adapter.collectFees(a.launchRef);
        assertEq(weth.balanceOf(vaultA), 3 ether, "each clone pays its own recipient");
        assertEq(weth.balanceOf(vault), 0);
    }

    function test_RevertWhen_FeeRecipientIsZero_NoFundsMove() public {
        uint256 before = weth.balanceOf(address(strategy));
        vm.prank(address(strategy));
        weth.approve(address(adapter), QUOTE_IN);

        vm.prank(address(strategy));
        vm.expectRevert(StonkLaunchAdapter.ZeroFeeRecipient.selector);
        adapter.launch(_paramsTo(address(weth), QUOTE_IN, 0, RESERVE, _venueData(), address(0)));

        assertEq(weth.balanceOf(address(strategy)), before, "no quote pulled");
    }

    function test_RevertWhen_ReserveIsTheWholeSupply() public {
        vm.prank(address(strategy));
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.ReserveExceedsSupply.selector, SUPPLY, SUPPLY));
        adapter.launch(_params(address(weth), 0, 0, SUPPLY, _venueData()));
    }

    function test_RevertWhen_MinOutWithoutABuy() public {
        vm.prank(address(strategy));
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.MinOutWithoutBuy.selector, 1));
        adapter.launch(_params(address(weth), 0, 1, RESERVE, _venueData()));
    }

    function test_RevertWhen_DeadlineHasPassed() public {
        ILaunchAdapter.LaunchParams memory p = _params(address(weth), 0, 0, RESERVE, _venueData());
        vm.warp(uint256(p.deadline) + 1);
        vm.prank(address(strategy));
        vm.expectRevert(
            abi.encodeWithSelector(StonkLaunchAdapter.DeadlineExpired.selector, p.deadline, block.timestamp)
        );
        adapter.launch(p);
    }

    function test_RevertWhen_NativeValueAttached() public {
        vm.deal(address(strategy), 1 ether);
        vm.prank(address(strategy));
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.NativeValueRejected.selector, 1 wei));
        adapter.launch{value: 1 wei}(_params(address(weth), 0, 0, RESERVE, _venueData()));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // lane gating — spec "Pad set cannot be re-pointed"
    // ─────────────────────────────────────────────────────────────────────────

    function test_QuoteSupported_WoodHasNoLaneAndNeverWill() public {
        assertTrue(adapter.quoteSupported(address(weth)), "WETH lane");
        assertTrue(adapter.quoteSupported(address(stonk)), "STONK lane");
        assertFalse(adapter.quoteSupported(address(wood)), "WOOD has no pad");
        assertFalse(adapter.quoteSupported(address(0)), "zero quote");
        assertFalse(adapter.quoteSupported(makeAddr("random")), "unknown quote");
    }

    function test_RevertWhen_LaunchingAgainstAnUnservedLane_NoFundsMove() public {
        uint256 before = wood.balanceOf(address(strategy));
        wood.mint(address(strategy), QUOTE_IN);
        vm.prank(address(strategy));
        wood.approve(address(adapter), QUOTE_IN);

        vm.prank(address(strategy));
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.UnsupportedQuote.selector, address(wood)));
        adapter.launch(_params(address(wood), QUOTE_IN, 0, RESERVE, _venueData()));

        assertEq(wood.balanceOf(address(strategy)), before + QUOTE_IN, "no WOOD pulled");
    }

    function test_PadSetHash_MatchesTheConstructorEncoding() public view {
        assertEq(adapter.padSetHash(), keccak256(abi.encode(_quotes(), _pads())), "hash over the ordered pairs");

        (address[] memory q, address[] memory p) = adapter.lanes();
        assertEq(keccak256(abi.encode(q, p)), adapter.padSetHash(), "lanes() is the preimage");
        assertEq(q.length, 2);
        assertEq(q[0], address(weth));
        assertEq(p[0], address(wethPad));
        assertEq(q[1], address(stonk));
        assertEq(p[1], address(stonkPad));
    }

    /// @dev The spec's claim is "no such entry point exists". The ABI is the
    ///      real proof; this asserts the plausible shapes are all unreachable
    ///      and the map is unchanged after trying them.
    function test_PadMapHasNoSetter() public {
        string[5] memory candidates = [
            "setPad(address,address)",
            "setLane(address,address)",
            "addLane(address,address)",
            "setPadOf(address,address)",
            "setQuotePad(address,address)"
        ];
        for (uint256 i; i < candidates.length; ++i) {
            (bool ok,) = address(adapter)
                .call(abi.encodeWithSelector(bytes4(keccak256(bytes(candidates[i]))), address(wood), address(stonkPad)));
            assertFalse(ok, candidates[i]);
        }
        assertEq(adapter.padOf(address(weth)), address(wethPad), "map unchanged");
        assertFalse(adapter.quoteSupported(address(wood)), "no lane was added");
    }

    function test_RevertWhen_ConstructorPadDisagreesAboutItsQuote() public {
        address[] memory q = new address[](1);
        address[] memory p = new address[](1);
        q[0] = address(wood); // the WOOD lane...
        p[0] = address(wethPad); // ...wired to a pad that says WETH.
        vm.expectRevert(
            abi.encodeWithSelector(
                StonkLaunchAdapter.PadQuoteMismatch.selector, address(wethPad), address(wood), address(weth)
            )
        );
        new StonkLaunchAdapter(q, p, lens);
    }

    function test_RevertWhen_ConstructorLaneSetIsMalformed() public {
        address[] memory q = new address[](2);
        address[] memory p = new address[](1);
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.InvalidLaneSet.selector, 2, 1));
        new StonkLaunchAdapter(q, p, lens);

        address[] memory empty = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.InvalidLaneSet.selector, 0, 0));
        new StonkLaunchAdapter(empty, empty, lens);
    }

    function test_RevertWhen_ConstructorRepeatsAQuote() public {
        address[] memory q = new address[](2);
        address[] memory p = new address[](2);
        q[0] = address(weth);
        p[0] = address(wethPad);
        q[1] = address(weth);
        p[1] = address(wethPad);
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.DuplicateQuote.selector, address(weth)));
        new StonkLaunchAdapter(q, p, lens);
    }

    function test_RevertWhen_ConstructorPadIsCodeless() public {
        address[] memory q = new address[](1);
        address[] memory p = new address[](1);
        q[0] = address(weth);
        p[0] = makeAddr("notAContract");
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.InvalidLane.selector, 0, address(weth), p[0]));
        new StonkLaunchAdapter(q, p, lens);
    }

    function test_RevertWhen_ConstructorLensIsUnusable() public {
        vm.expectRevert(StonkLaunchAdapter.InvalidLens.selector);
        new StonkLaunchAdapter(_quotes(), _pads(), address(0));
        vm.expectRevert(StonkLaunchAdapter.InvalidLens.selector);
        new StonkLaunchAdapter(_quotes(), _pads(), makeAddr("codelessLens"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // phase
    // ─────────────────────────────────────────────────────────────────────────

    function test_Phase_CurveThenClosingThenLive() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        uint256 id = _clone(res).launchId();

        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Curve), "armed curve");

        wethPad.setGraduatable(true);
        vm.prank(keeper);
        wethPad.graduate(id);
        assertEq(
            uint256(adapter.phase(res.launchRef)),
            uint256(ILaunchAdapter.LaunchPhase.Closing),
            "graduated, LP not minted"
        );

        vm.prank(keeper);
        wethPad.bond(id);
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Live), "bonded");
    }

    function test_Phase_AbortedIsFailed() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        vm.prank(address(strategy));
        _clone(res).abort();
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Failed));
    }

    /// @dev The PROVISIONAL branch — see `clonePhase`'s natspec and task 0.1.
    function test_Phase_ClosedWindowWithoutGraduationIsFailed() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        uint256 deadline = wethPad.getLaunch(_clone(res).launchId()).deadline;
        vm.warp(deadline);
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Curve), "at the deadline");
        vm.warp(deadline + 1);
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Failed), "past it");
    }

    function test_Phase_OpenEndedCurveNeverCloses() public {
        vm.prank(address(strategy));
        ILaunchAdapter.LaunchResult memory res =
            adapter.launch(_params(address(weth), 0, 0, RESERVE, _openEndedVenueData()));
        vm.warp(block.timestamp + 3650 days);
        assertEq(
            uint256(adapter.phase(res.launchRef)),
            uint256(ILaunchAdapter.LaunchPhase.Curve),
            "an open-ended curve has no closing deadline"
        );
    }

    function test_Phase_UnknownRefsReturnNoneWithoutReverting() public {
        assertEq(uint256(adapter.phase(bytes32(0))), uint256(ILaunchAdapter.LaunchPhase.None), "zero ref");
        assertEq(
            uint256(adapter.phase(bytes32(type(uint256).max))), uint256(ILaunchAdapter.LaunchPhase.None), "dirty ref"
        );
        assertEq(
            uint256(adapter.phase(bytes32(uint256(uint160(address(adapter)))))),
            uint256(ILaunchAdapter.LaunchPhase.None),
            "the implementation is not one of its own clones"
        );
        assertEq(
            uint256(adapter.phase(bytes32(uint256(uint160(makeAddr("eoa")))))),
            uint256(ILaunchAdapter.LaunchPhase.None),
            "a codeless address"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // forged refs — spec "Forged launch ref"
    // ─────────────────────────────────────────────────────────────────────────

    function test_ForgedRef_IsNeverCalled() public {
        LoudTrap trap = new LoudTrap();
        bytes32 ref = bytes32(uint256(uint160(address(trap))));

        assertFalse(adapter.isClone(address(trap)), "not an ERC-1167 clone");
        assertEq(uint256(adapter.phase(ref)), uint256(ILaunchAdapter.LaunchPhase.None), "phase answers None");

        (uint256 q, uint256 t) = adapter.collectFees(ref);
        assertEq(q, 0);
        assertEq(t, 0);

        // A no-op, not a revert: settlement calls this unconditionally.
        adapter.finalize(ref);
    }

    /// @dev A hand-written 45-byte contract that merely CONTAINS the
    ///      implementation address must not pass — the prefix and suffix pin
    ///      the delegatecall semantics, not just the embedded address.
    function test_ForgedRef_LookalikeRuntimeIsRejected() public {
        address impostor = makeAddr("impostor");
        bytes memory fake =
            abi.encodePacked(hex"00000000000000000000", bytes20(address(adapter)), hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(fake.length, 45, "same length as a minimal proxy");
        vm.etch(impostor, fake);

        assertFalse(adapter.isClone(impostor), "wrong prefix");
        assertEq(uint256(adapter.phase(bytes32(uint256(uint160(impostor))))), uint256(ILaunchAdapter.LaunchPhase.None));
    }

    /// @dev A real minimal proxy pointing at SOMEONE ELSE's implementation.
    function test_ForgedRef_CloneOfAnotherImplementationIsRejected() public {
        StonkLaunchAdapter other = new StonkLaunchAdapter(_quotes(), _pads(), lens);
        vm.prank(address(strategy));
        ILaunchAdapter.LaunchResult memory res = other.launch(_params(address(weth), 0, 0, RESERVE, _venueData()));

        assertTrue(other.isClone(address(uint160(uint256(res.launchRef)))), "it is a clone of the other adapter");
        assertFalse(adapter.isClone(address(uint160(uint256(res.launchRef)))), "but not of this one");
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.None));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // keeper-driven verbs — spec "Keeper drives a clone's permissionless verbs"
    // ─────────────────────────────────────────────────────────────────────────

    function test_Finalize_KeeperDrivesGraduateAndBond() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        uint256 id = _clone(res).launchId();
        wethPad.setGraduatable(true);

        vm.prank(keeper);
        adapter.finalize(res.launchRef);

        assertTrue(wethPad.getLaunch(id).graduated, "graduated");
        assertTrue(wethPad.getLaunch(id).bonded, "and bonded, in one call");
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Live));
        assertEq(IERC20(res.token).balanceOf(keeper), 0, "keeper receives nothing");
        assertEq(weth.balanceOf(keeper), 0, "keeper receives nothing");
    }

    function test_Finalize_ToleratesAnUnGraduatableCurve() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        // `graduatable` is false: the venue refuses both legs.
        vm.prank(keeper);
        adapter.finalize(res.launchRef);
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Curve), "still on the curve");

        // ...and it stays callable, forever, by anyone.
        wethPad.setGraduatable(true);
        vm.prank(keeper);
        adapter.finalize(res.launchRef);
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Live));
    }

    function test_CollectFees_PaysTheFeeRecipientAndNeverTheStrategyOrCaller() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        wethPad.creditCreatorQuote(clone.launchId(), 3 ether);
        // A token leg too, so both legs are exercised.
        deal(res.token, address(clone), 4 ether, true);

        uint256 strategyQuoteBefore = weth.balanceOf(address(strategy));
        uint256 strategyTokenBefore = IERC20(res.token).balanceOf(address(strategy));

        vm.expectEmit(true, false, false, true, address(clone));
        emit StonkLaunchAdapter.FeesCollected(vault, 3 ether, 4 ether);
        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);

        assertEq(quoteOut, 3 ether, "the delta that actually landed on the fee recipient");
        assertEq(tokenOut, 4 ether, "the token leg, likewise measured where it landed");
        assertEq(weth.balanceOf(vault), quoteOut, "reported == moved, quote leg");
        assertEq(IERC20(res.token).balanceOf(vault), tokenOut, "reported == moved, token leg");
        assertEq(weth.balanceOf(address(strategy)), strategyQuoteBefore, "fees never transit strategy custody");
        assertEq(
            IERC20(res.token).balanceOf(address(strategy)), strategyTokenBefore, "fees never transit strategy custody"
        );
        assertEq(weth.balanceOf(keeper), 0, "keeper receives nothing");
        assertEq(IERC20(res.token).balanceOf(keeper), 0, "keeper receives nothing");
        assertEq(weth.balanceOf(address(clone)), 0, "the clone forwarded everything it was paid");
        assertEq(IERC20(res.token).balanceOf(address(clone)), 0, "the clone forwarded everything it was paid");
        assertEq(weth.balanceOf(address(adapter)), 0, "the implementation holds nothing");
    }

    /// @dev The same lane, driven by the OWNER instead of a keeper: who calls
    ///      changes nothing, because the payee is a pinned storage slot.
    function test_CollectFees_SameDestinationWhoeverCalls() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        wethPad.creditCreatorQuote(clone.launchId(), 2 ether);

        uint256 strategyQuoteBefore = weth.balanceOf(address(strategy));
        vm.prank(address(strategy));
        (uint256 quoteOut,) = adapter.collectFees(res.launchRef);

        assertEq(quoteOut, 2 ether);
        assertEq(weth.balanceOf(vault), 2 ether, "still the vault");
        assertEq(weth.balanceOf(address(strategy)), strategyQuoteBefore, "the owner calling is paid nothing");
    }

    function test_CollectFees_ReturnsZeroesWhenNothingAccrued() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);
        assertEq(quoteOut, 0);
        assertEq(tokenOut, 0);
    }

    /// @dev THE SIMPLIFICATION'S WHOLE POINT, asserted directly: a LIVE owner
    ///      and a SETTLED owner produce the SAME destination, from the same
    ///      permissionless call, in the same test. This replaces the pair
    ///      `test_CollectFees_PaysTheOwner...` /
    ///      `test_CollectFees_PostSettlementPaysTheVault...`, which existed to
    ///      pin a destination SWITCH there is no longer any code for.
    ///
    ///      The lock lever those tests guarded is gone rather than guarded:
    ///      value never lands in strategy custody in any phase, so there is no
    ///      arrival for a permissionless `SyndicateVault.collectResidue` to
    ///      convert into a fresh 7-day deposit lock.
    function test_CollectFees_SameDestinationWhetherTheOwnerIsLiveOrSettled() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        address passerby = makeAddr("passerby");
        uint256 strategyQuoteBefore = weth.balanceOf(address(strategy));
        uint256 strategyTokenBefore = IERC20(res.token).balanceOf(address(strategy));

        // ── leg 1: the owner is LIVE (Executed) ──
        strategy.setState(1);
        wethPad.creditCreatorQuote(clone.launchId(), 5 ether);
        deal(res.token, address(clone), 7 ether, true);

        vm.prank(passerby);
        (uint256 liveQuote, uint256 liveToken) = adapter.collectFees(res.launchRef);

        assertEq(liveQuote, 5 ether);
        assertEq(liveToken, 7 ether);
        assertEq(weth.balanceOf(vault), 5 ether, "live owner: the vault is paid");
        assertEq(IERC20(res.token).balanceOf(vault), 7 ether);

        // ── leg 2: the owner is SETTLED. Same call, same destination. ──
        strategy.setState(2);
        wethPad.creditCreatorQuote(clone.launchId(), 5 ether);
        deal(res.token, address(clone), 7 ether, true);

        vm.prank(passerby);
        (uint256 settledQuote, uint256 settledToken) = adapter.collectFees(res.launchRef);

        assertEq(settledQuote, liveQuote, "settlement changes nothing about the amount");
        assertEq(settledToken, liveToken, "settlement changes nothing about the amount");
        assertEq(weth.balanceOf(vault), 10 ether, "settled owner: the same vault is paid");
        assertEq(IERC20(res.token).balanceOf(vault), 14 ether);

        // In neither leg did value transit the strategy or reach the caller.
        assertEq(weth.balanceOf(address(strategy)), strategyQuoteBefore, "no fee ever transits strategy custody");
        assertEq(
            IERC20(res.token).balanceOf(address(strategy)), strategyTokenBefore, "no fee ever transits strategy custody"
        );
        assertEq(weth.balanceOf(passerby), 0, "the caller receives nothing");
        assertEq(IERC20(res.token).balanceOf(passerby), 0, "the caller receives nothing");
        assertEq(weth.balanceOf(address(clone)), 0, "the clone is emptied");
        assertEq(IERC20(res.token).balanceOf(address(clone)), 0, "the clone is emptied");
    }

    /// @dev An owner that answers NEITHER `state()` nor `vault()`. Under the
    ///      old destination switch this was the fail-closed edge that decided
    ///      between two lanes; now the owner is not read at all, so it cannot
    ///      stall, redirect or gate the fee stream. This replaces
    ///      `test_CollectFees_SettledWithUnreadableVaultMovesNothingAndStrandsNothing`,
    ///      whose `(0, 0)` no-op branch has been deleted.
    function test_CollectFees_UnreadableOwnerCannotAffectTheDestination() public {
        MuteOwner mute = new MuteOwner();
        vm.prank(address(mute));
        ILaunchAdapter.LaunchResult memory res = adapter.launch(_params(address(weth), 0, 0, RESERVE, _venueData()));
        StonkLaunchAdapter clone = _clone(res);

        wethPad.creditCreatorQuote(clone.launchId(), 6 ether);
        deal(res.token, address(clone), 9 ether, true);

        uint256 ownerTokenBefore = IERC20(res.token).balanceOf(address(mute));

        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);

        assertEq(quoteOut, 6 ether, "delivered in full on the first call");
        assertEq(tokenOut, 9 ether, "delivered in full on the first call");
        assertEq(weth.balanceOf(vault), 6 ether);
        assertEq(IERC20(res.token).balanceOf(vault), 9 ether);
        assertEq(weth.balanceOf(address(mute)), 0, "the unreadable owner is never a destination");
        assertEq(IERC20(res.token).balanceOf(address(mute)), ownerTokenBefore, "it keeps only its reserve");
        assertEq(weth.balanceOf(address(clone)), 0, "nothing is left behind");
        assertEq(IERC20(res.token).balanceOf(address(clone)), 0, "nothing is left behind");
    }

    /// @dev The deleted `forwardToVault()` was the post-settlement sweep lane.
    ///      Its job is now covered by `collectFees` itself, which is
    ///      permissionless and moves the clone's ENTIRE balance of both assets
    ///      — not just what this call flushed — so nothing can rest on a clone.
    ///      This replaces the four `forwardToVault` tests.
    function test_CollectFees_SweepsAnyCloneHeldBalance_NothingCanBeStranded() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);

        // Balances that arrived by no venue flush at all: a donation of quote,
        // and launch token pushed onto the clone.
        weth.mint(address(clone), 11 ether);
        deal(res.token, address(clone), 13 ether, true);
        // Plus a real accrual, unflushed.
        wethPad.creditCreatorQuote(clone.launchId(), 2 ether);

        strategy.setState(2); // and it makes no difference

        vm.prank(makeAddr("anyone"));
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(res.launchRef);

        assertEq(quoteOut, 13 ether, "flushed accrual plus the resting donation");
        assertEq(tokenOut, 13 ether, "the whole resting token balance");
        assertEq(weth.balanceOf(vault), 13 ether);
        assertEq(IERC20(res.token).balanceOf(vault), 13 ether);
        assertEq(weth.balanceOf(address(clone)), 0, "the clone cannot hold quote after this");
        assertEq(IERC20(res.token).balanceOf(address(clone)), 0, "nor launch token");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // owner-only verbs — spec "Foreign caller on a clone"
    // ─────────────────────────────────────────────────────────────────────────

    function test_Abort_OwnerRecoversTheArmedSupply() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);

        vm.prank(address(strategy));
        clone.abort();

        assertEq(IERC20(res.token).balanceOf(address(strategy)), SUPPLY, "the whole supply is back with the owner");
        assertEq(IERC20(res.token).balanceOf(address(clone)), 0, "nothing left on the clone");
        assertEq(uint256(adapter.phase(res.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Failed));
    }

    function test_RevertWhen_ForeignCallerAborts() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.NotOwner.selector, keeper, address(strategy)));
        clone.abort();
    }

    function test_RevertWhen_AbortIsRefusedByTheVenue() public {
        ILaunchAdapter.LaunchResult memory res = _launch(QUOTE_IN, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        // A buy happened, so the venue bars the recovery lever — and the owner
        // gets the venue's answer rather than a silent no-op.
        vm.prank(address(strategy));
        vm.expectRevert(MockStonkPad.HasBuys.selector);
        clone.abort();
    }

    /// @dev `abort` recovers the launch's SUPPLY, which — like the reserve — is
    ///      the strategy's to distribute, not a fee. It stays owner-only and
    ///      keeps paying the owner; only the fee ROLE moved to the vault.
    function test_Abort_ReturnsSupplyToTheOwnerNotTheFeeRecipient() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);

        vm.prank(address(strategy));
        clone.abort();

        assertEq(IERC20(res.token).balanceOf(address(strategy)), SUPPLY, "supply back with the owner");
        assertEq(IERC20(res.token).balanceOf(vault), 0, "the fee recipient is not the supply's destination");
        assertEq(IERC20(res.token).balanceOf(address(clone)), 0, "and nothing rests on the clone");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // stock-lane oracle gap — spec "Stock-lane oracle gap"
    // ─────────────────────────────────────────────────────────────────────────

    function test_RevertWhen_StockLaneOracleIsStale_SurfacedUnchanged() public {
        stonk.mint(address(strategy), QUOTE_IN);
        stonkPad.setStale(true);

        vm.prank(address(strategy));
        stonk.approve(address(adapter), QUOTE_IN);
        vm.prank(address(strategy));
        // The venue's own revert, not one of ours: no bypass, no stale-priced retry.
        vm.expectRevert(MockStonkPad.StalePrice.selector);
        adapter.launch(_params(address(stonk), QUOTE_IN, 0, RESERVE, _venueData()));
    }

    function test_Launch_OnTheStockLaneOnceTheOracleRecovers() public {
        stonk.mint(address(strategy), QUOTE_IN);
        vm.prank(address(strategy));
        stonk.approve(address(adapter), QUOTE_IN);
        vm.prank(address(strategy));
        ILaunchAdapter.LaunchResult memory res =
            adapter.launch(_params(address(stonk), QUOTE_IN, QUOTE_IN, RESERVE, _venueData()));

        assertEq(_clone(res).pad(), address(stonkPad), "routed to the STONK lane");
        assertEq(IERC20(res.token).balanceOf(address(strategy)), RESERVE + QUOTE_IN);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // native fee
    // ─────────────────────────────────────────────────────────────────────────

    function test_NativeFeeSource_IsZeroWhileTheVenueChargesNothing() public view {
        (address token, uint256 amount) = adapter.nativeFeeSource();
        assertEq(token, address(0), "no token can pay a native fee here");
        assertEq(amount, 0, "and the venue charges none");
    }

    function test_NativeFeeSource_ReportsAFeeAppearingOnAnyLane() public {
        stonkPad.setLaunchFeeWei(7 wei);
        (address token, uint256 amount) = adapter.nativeFeeSource();
        assertEq(token, address(0), "still names no payable token (the stated limitation)");
        assertEq(amount, 7 wei, "the maximum across lanes, so no lane can hide one");
    }

    function test_RevertWhen_TheVenueStartsChargingANativeFee() public {
        wethPad.setLaunchFeeWei(5e14);
        vm.prank(address(strategy));
        vm.expectRevert(
            abi.encodeWithSelector(StonkLaunchAdapter.NativeFeeUnsupported.selector, address(wethPad), 5e14)
        );
        adapter.launch(_params(address(weth), 0, 0, RESERVE, _venueData()));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // role separation
    // ─────────────────────────────────────────────────────────────────────────

    function test_RevertWhen_InitializingTheImplementation() public {
        vm.expectRevert(StonkLaunchAdapter.AlreadyInitialized.selector);
        vm.prank(address(adapter));
        adapter.initialize(address(strategy), address(wethPad), address(weth), vault);

        // ...and from anyone else it fails one step earlier.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.NotImplementation.selector, keeper));
        adapter.initialize(address(strategy), address(wethPad), address(weth), vault);
    }

    function test_RevertWhen_ForeignCallerInitializesAClone() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.NotImplementation.selector, keeper));
        clone.initialize(keeper, address(wethPad), address(weth), vault);
    }

    function test_RevertWhen_ReLaunchingThroughAnExistingClone() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        vm.prank(address(adapter));
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.AlreadyLaunched.selector, res.token));
        clone.executeLaunch(_params(address(weth), 0, 0, RESERVE, _venueData()));
    }

    function test_RevertWhen_LaunchIsCalledOnAClone() public {
        ILaunchAdapter.LaunchResult memory res = _launch(0, 0, RESERVE);
        StonkLaunchAdapter clone = _clone(res);
        vm.prank(address(strategy));
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.WrongRole.selector, address(clone), address(adapter)));
        clone.launch(_params(address(weth), 0, 0, RESERVE, _venueData()));
    }

    function test_CloneVerbsOnTheImplementationFailClosed() public {
        assertEq(uint256(adapter.clonePhase()), uint256(ILaunchAdapter.LaunchPhase.None), "no launch here");
        adapter.cloneFinalize(); // silent no-op
        (uint256 q, uint256 t) = adapter.cloneCollectFees();
        assertEq(q, 0);
        assertEq(t, 0);
        vm.expectRevert(StonkLaunchAdapter.NotInitialized.selector);
        adapter.abort();
    }

    /// @dev A clone anyone can mint from public code, but never initialize —
    ///      it passes introspection and is a fail-closed no-op everywhere.
    function test_UninitializedCloneIsInert() public {
        address rogue = _mintRawClone(address(adapter));
        assertTrue(adapter.isClone(rogue), "it really is a clone of this implementation");
        assertEq(StonkLaunchAdapter(rogue).owner(), address(0), "but it was never initialized");

        bytes32 ref = bytes32(uint256(uint160(rogue)));
        assertEq(uint256(adapter.phase(ref)), uint256(ILaunchAdapter.LaunchPhase.None));
        (uint256 q, uint256 t) = adapter.collectFees(ref);
        assertEq(q, 0);
        assertEq(t, 0);
        adapter.finalize(ref);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.NotImplementation.selector, keeper));
        StonkLaunchAdapter(rogue).initialize(keeper, address(wethPad), address(weth), vault);
    }

    // ── wiring ──

    function test_ImplementationWiringAndLaunchTarget() public view {
        assertEq(adapter.implementation(), address(adapter), "the implementation is itself");
        assertEq(adapter.lens(), lens, "the lens is held...");
        assertEq(adapter.launchTarget(), address(0), "...and is deliberately NOT the launch target");
    }

    function test_LaunchTargetZeroMeansSettlementSkipsTheCreatorHandoff() public view {
        // `TokenizeFundStrategy._settle` only calls `transferCreator` when
        // `launchTarget()` is nonzero; this venue has no such selector, and it
        // needs none — the clone has been forwarding to the launch's
        // `feeRecipient` since the first block, so settlement has no fee lane
        // left to open.
        assertEq(adapter.launchTarget(), address(0));
    }

    /// @dev Mint a bare ERC-1167 clone without going through `launch`.
    function _mintRawClone(address impl) internal returns (address instance) {
        bytes memory creation = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", bytes20(impl), hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            instance := create(0, add(creation, 0x20), mload(creation))
        }
        require(instance != address(0), "clone failed");
    }
}
