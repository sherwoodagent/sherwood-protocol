// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {GenericCallStrategy} from "../../src/strategies/GenericCallStrategy.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {
    MockCallVenue,
    MockCallVenueV2,
    RevertingVenue,
    NoZeroApproveToken,
    NoZeroTransferToken,
    MockNFT,
    MockNftMarket,
    GCRegistryStub,
    GCGovernorStub,
    GCVaultStub
} from "../mocks/GenericCallMocks.sol";

abstract contract GenericCallFixture is Test {
    uint256 constant PULL = 1_000e6;
    uint256 constant VAULT_FUNDS = 10_000e6;

    ERC20Mock usdg;
    GCRegistryStub registry;
    GCGovernorStub gov;
    GCVaultStub vault;
    address syndicateFactory = makeAddr("syndicateFactory");
    address strategyFactory = makeAddr("strategyFactory");
    MockCallVenue venue;
    GenericCallStrategy template;

    address proposer = makeAddr("proposer");
    address stranger = makeAddr("stranger");

    function setUp() public virtual {
        usdg = new ERC20Mock("USDG", "USDG", 6);
        registry = new GCRegistryStub();
        registry.setStrategyFactory(strategyFactory);
        gov = new GCGovernorStub(address(registry));
        vault = new GCVaultStub(address(usdg), address(gov), syndicateFactory);
        venue = new MockCallVenue();
        template = new GenericCallStrategy();
        usdg.mint(address(vault), VAULT_FUNDS);
    }

    function _call(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _one(BatchExecutorLib.Call memory c) internal pure returns (BatchExecutorLib.Call[] memory a) {
        a = new BatchExecutorLib.Call[](1);
        a[0] = c;
    }

    function _two(BatchExecutorLib.Call memory c0, BatchExecutorLib.Call memory c1)
        internal
        pure
        returns (BatchExecutorLib.Call[] memory a)
    {
        a = new BatchExecutorLib.Call[](2);
        a[0] = c0;
        a[1] = c1;
    }

    function _none() internal pure returns (BatchExecutorLib.Call[] memory) {
        return new BatchExecutorLib.Call[](0);
    }

    function _noSweep() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /// @dev Default plan: deposit the pull into the venue, withdraw it at settle.
    function _depositLeg(uint256 amount) internal view returns (BatchExecutorLib.Call[] memory) {
        return _two(
            _call(address(usdg), abi.encodeCall(IERC20.approve, (address(venue), amount))),
            _call(address(venue), abi.encodeCall(MockCallVenue.deposit, (address(usdg), amount)))
        );
    }

    function _withdrawLeg(uint256 amount) internal view returns (BatchExecutorLib.Call[] memory) {
        return _one(_call(address(venue), abi.encodeCall(MockCallVenue.withdraw, (address(usdg), amount))));
    }

    function _clone() internal returns (GenericCallStrategy) {
        return GenericCallStrategy(Clones.clone(address(template)));
    }

    function _init(
        uint256 pull,
        BatchExecutorLib.Call[] memory e,
        BatchExecutorLib.Call[] memory s,
        address[] memory sweep
    ) internal returns (GenericCallStrategy c) {
        c = _clone();
        c.initialize(address(vault), proposer, abi.encode(pull, e, s, sweep));
        gov.setActiveStrategy(address(c));
    }

    function _defaultClone() internal returns (GenericCallStrategy) {
        return _init(PULL, _depositLeg(PULL), _withdrawLeg(PULL), _noSweep());
    }

    function _expectInitRevert(
        bytes memory err,
        uint256 pull,
        BatchExecutorLib.Call[] memory e,
        BatchExecutorLib.Call[] memory s,
        address[] memory sweep
    ) internal {
        GenericCallStrategy c = _clone();
        bytes memory data = abi.encode(pull, e, s, sweep);
        vm.expectRevert(err);
        c.initialize(address(vault), proposer, data);
    }

    function _execute(GenericCallStrategy c, uint256 approveAmount) internal {
        vm.prank(address(vault));
        usdg.approve(address(c), approveAmount);
        vm.prank(address(vault));
        c.execute();
    }

    function _settle(GenericCallStrategy c) internal {
        vm.prank(address(vault));
        c.settle();
    }
}

contract GenericCallStrategyInitTest is GenericCallFixture {
    /// @notice Getters return the decoded plan and `configHash` is the canonical hash of it.
    function test_init_storesPlanAndCanonicalHash() public {
        BatchExecutorLib.Call[] memory e = _depositLeg(PULL);
        BatchExecutorLib.Call[] memory s = _withdrawLeg(PULL);
        address[] memory sweep = new address[](1);
        sweep[0] = makeAddr("bonus");
        GenericCallStrategy c = _init(PULL, e, s, sweep);

        assertEq(c.name(), "Generic Call");
        assertEq(c.asset(), address(usdg));
        assertEq(c.pullAmount(), PULL);
        assertEq(c.sweepTokens(), sweep);
        assertEq(keccak256(abi.encode(c.executeCalls())), keccak256(abi.encode(e)), "execute calls");
        assertEq(keccak256(abi.encode(c.settleCalls())), keccak256(abi.encode(s)), "settle calls");
        assertEq(
            c.configHash(),
            keccak256(abi.encode(c.pullAmount(), c.executeCalls(), c.settleCalls(), c.sweepTokens())),
            "config hash recomputes from getters"
        );
        assertEq(c.pinnedCodehash(address(venue)), address(venue).codehash);
        assertEq(c.pinnedCodehash(address(usdg)), address(usdg).codehash);
        GenericCallStrategy.Grant[] memory g = c.grants();
        assertEq(g.length, 1);
        assertEq(g[0].token, address(usdg));
        assertEq(g[0].spender, address(venue));
        assertFalse(g[0].forAll);
        assertEq(uint256(c.state()), uint256(BaseStrategy.State.Pending));
    }

    /// @notice Every lifecycle contract, the clone and zero are refused in both legs.
    function test_init_refusesForbiddenTargets() public {
        address[6] memory fixedTargets =
            [address(0), address(vault), address(gov), syndicateFactory, address(registry), strategyFactory];
        for (uint8 leg; leg < 2; ++leg) {
            for (uint256 k; k < fixedTargets.length; ++k) {
                BatchExecutorLib.Call[] memory bad = _one(_call(fixedTargets[k], hex"12345678"));
                bytes memory err =
                    abi.encodeWithSelector(GenericCallStrategy.ForbiddenTarget.selector, leg, 0, fixedTargets[k]);
                if (leg == 0) _expectInitRevert(err, PULL, bad, _none(), _noSweep());
                else _expectInitRevert(err, PULL, _none(), bad, _noSweep());
            }
            // The clone itself.
            GenericCallStrategy c = _clone();
            BatchExecutorLib.Call[] memory self = _one(_call(address(c), abi.encodeCall(BaseStrategy.settle, ())));
            bytes memory data =
                leg == 0 ? abi.encode(0, self, _none(), _noSweep()) : abi.encode(0, _none(), self, _noSweep());
            vm.expectRevert(abi.encodeWithSelector(GenericCallStrategy.ForbiddenTarget.selector, leg, 0, address(c)));
            c.initialize(address(vault), proposer, data);
        }
    }

    function test_init_refusesCodelessTarget() public {
        address eoa = makeAddr("eoa");
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.TargetHasNoCode.selector, uint8(1), 0, eoa),
            PULL,
            _none(),
            _one(_call(eoa, hex"")),
            _noSweep()
        );
    }

    function test_init_refusesNativeValue() public {
        BatchExecutorLib.Call memory c = _call(address(venue), hex"");
        c.value = 1;
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.NativeValueUnsupported.selector, uint8(0), 1),
            PULL,
            _two(_call(address(venue), hex""), c),
            _none(),
            _noSweep()
        );
    }

    /// @notice The vault's allowance to the clone cannot be widened: `transferFrom` from the vault is refused.
    function test_init_refusesAssetTransferFrom() public {
        bytes memory data = abi.encodeCall(IERC20.transferFrom, (address(vault), stranger, 1));
        _expectInitRevert(
            abi.encodeWithSelector(
                GenericCallStrategy.AssetCallNotAllowed.selector, uint8(0), 0, IERC20.transferFrom.selector
            ),
            PULL,
            _one(_call(address(usdg), data)),
            _none(),
            _noSweep()
        );
    }

    /// @notice Only `approve` and `transfer` pass on the asset; every other selector is refused.
    function testFuzz_init_assetSelectorRule(bytes4 sel) public {
        bytes memory data = abi.encodePacked(sel, uint256(uint160(address(venue))), uint256(1));
        GenericCallStrategy c = _clone();
        bytes memory init = abi.encode(0, _one(_call(address(usdg), data)), _none(), _noSweep());
        if (sel == IERC20.approve.selector || sel == IERC20.transfer.selector) {
            c.initialize(address(vault), proposer, init);
        } else {
            vm.expectRevert(abi.encodeWithSelector(GenericCallStrategy.AssetCallNotAllowed.selector, uint8(0), 0, sel));
            c.initialize(address(vault), proposer, init);
        }
    }

    function test_init_refusesShortAssetCall() public {
        bytes memory short_ = abi.encodePacked(IERC20.approve.selector, uint256(uint160(address(venue))));
        _expectInitRevert(
            abi.encodeWithSelector(
                GenericCallStrategy.AssetCallNotAllowed.selector, uint8(1), 0, IERC20.approve.selector
            ),
            PULL,
            _none(),
            _one(_call(address(usdg), short_)),
            _noSweep()
        );
    }

    function test_init_failsClosedOnUnresolvedProtocol() public {
        vault.setFactory(address(0));
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.ProtocolAddressUnresolved.selector),
            PULL,
            _depositLeg(PULL),
            _none(),
            _noSweep()
        );
        vault.setFactory(syndicateFactory);
        registry.setStrategyFactory(address(0));
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.ProtocolAddressUnresolved.selector),
            PULL,
            _depositLeg(PULL),
            _none(),
            _noSweep()
        );
        registry.setStrategyFactory(strategyFactory);
        vault.setGovernor(makeAddr("codelessGovernor"));
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.ProtocolAddressUnresolved.selector),
            PULL,
            _depositLeg(PULL),
            _none(),
            _noSweep()
        );
    }

    function test_init_capsCallsPerLeg() public {
        BatchExecutorLib.Call[] memory many = new BatchExecutorLib.Call[](17);
        for (uint256 i; i < many.length; ++i) {
            many[i] = _call(address(venue), hex"");
        }
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.TooManyCalls.selector, uint8(0)), 0, many, _none(), _noSweep()
        );
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.TooManyCalls.selector, uint8(1)), 0, _none(), many, _noSweep()
        );
        // 16 is accepted.
        assembly ("memory-safe") {
            mstore(many, 16)
        }
        _init(0, many, many, _noSweep());
    }

    function test_init_capsCalldataPerLeg() public {
        BatchExecutorLib.Call[] memory atCap =
            _two(_call(address(venue), new bytes(8_192)), _call(address(venue), new bytes(8_192)));
        _init(0, atCap, atCap, _noSweep());
        BatchExecutorLib.Call[] memory over =
            _two(_call(address(venue), new bytes(8_192)), _call(address(venue), new bytes(8_193)));
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.CalldataTooLarge.selector, uint8(1)),
            0,
            _none(),
            over,
            _noSweep()
        );
    }

    function test_init_capsAndChecksSweepTokens() public {
        address[] memory sweep = new address[](17);
        for (uint256 i; i < sweep.length; ++i) {
            sweep[i] = address(uint160(i + 1));
        }
        _expectInitRevert(
            abi.encodeWithSelector(GenericCallStrategy.TooManySweepTokens.selector), 0, _none(), _none(), sweep
        );
        address[] memory zero = new address[](1);
        _expectInitRevert(abi.encodeWithSelector(BaseStrategy.ZeroAddress.selector), 0, _none(), _none(), zero);
    }

    function test_init_isOneShot() public {
        GenericCallStrategy c = _defaultClone();
        bytes memory data = abi.encode(0, _none(), _none(), _noSweep());
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        c.initialize(address(vault), stranger, data);
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        template.initialize(address(vault), proposer, data);
    }

    /// @notice An uncertified clone prices at tier 2, full notional, in a real TierRegistry.
    function test_tier_uncertifiedCloneIsTier2FullNotional() public {
        GenericCallStrategy c = _defaultClone();
        TierRegistry tr = new TierRegistry(address(this));
        (uint8 tier, uint16 bound) = tr.tierOf(address(c), BaseStrategy.execute.selector);
        assertEq(tier, 2);
        assertEq(bound, 10_000);
    }
}

contract GenericCallStrategyLifecycleUnitTest is GenericCallFixture {
    function test_onlyVault_onEveryCustodyEntryPoint() public {
        GenericCallStrategy c = _defaultClone();
        vm.startPrank(stranger);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        c.execute();
        vm.expectRevert(BaseStrategy.NotVault.selector);
        c.settle();
        vm.expectRevert(BaseStrategy.NotVault.selector);
        c.rescueTo(address(usdg));
        vm.expectRevert(BaseStrategy.NotVault.selector);
        c.rescueERC721To(address(usdg), 1);
        vm.stopPrank();
    }

    function test_updateParams_neverTunes() public {
        GenericCallStrategy c = _defaultClone();
        _execute(c, PULL);
        vm.prank(proposer);
        vm.expectRevert(GenericCallStrategy.NoTunableParams.selector);
        c.updateParams(abi.encode(uint256(0)));
        vm.prank(stranger);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        c.updateParams("");
    }

    /// @notice Execute pulls exactly `pullAmount`, runs the leg and leaves no allowance open.
    function test_execute_pullsRunsAndRevokes() public {
        // The leg approves the venue twice what it deposits, so an allowance is left to revoke.
        BatchExecutorLib.Call[] memory e = _two(
            _call(address(usdg), abi.encodeCall(IERC20.approve, (address(venue), 2 * PULL))),
            _call(address(venue), abi.encodeCall(MockCallVenue.deposit, (address(usdg), PULL)))
        );
        GenericCallStrategy c = _init(PULL, e, _withdrawLeg(PULL), _noSweep());
        _execute(c, 3 * PULL);

        assertEq(usdg.balanceOf(address(vault)), VAULT_FUNDS - PULL, "vault paid exactly the pull");
        assertEq(venue.deposited(address(usdg), address(c)), PULL);
        assertEq(usdg.allowance(address(c), address(venue)), 0, "venue allowance revoked");
        assertTrue(c.executed());

        vm.expectRevert();
        venue.pull(address(usdg), address(c), 1);
    }

    /// @notice Zero pull never calls `transferFrom` on the vault, so a token that refuses zero transfers still works.
    function test_execute_zeroPullSkipsThePull() public {
        NoZeroTransferToken asset_ = new NoZeroTransferToken();
        GCVaultStub v = new GCVaultStub(address(asset_), address(gov), syndicateFactory);
        ERC20Mock straggler = new ERC20Mock("STR", "STR", 18);
        BatchExecutorLib.Call[] memory e = _two(
            _call(address(straggler), abi.encodeCall(IERC20.approve, (address(venue), 5e18))),
            _call(address(venue), abi.encodeCall(MockCallVenue.deposit, (address(straggler), 5e18)))
        );
        GenericCallStrategy c = _clone();
        c.initialize(address(v), proposer, abi.encode(0, e, _none(), _noSweep()));
        gov.setActiveStrategy(address(c));
        straggler.mint(address(c), 5e18);
        vm.prank(address(v));
        c.execute();
        assertEq(venue.deposited(address(straggler), address(c)), 5e18);
    }

    /// @notice A failing inner call reverts the execute with its index and the venue's own error data.
    function test_execute_failedCallBubblesWithIndex() public {
        RevertingVenue bad = new RevertingVenue();
        BatchExecutorLib.Call[] memory e = _two(
            _call(address(venue), abi.encodeCall(venue.deposited, (address(usdg), address(0)))),
            _call(address(bad), abi.encodeCall(RevertingVenue.fail, (7)))
        );
        GenericCallStrategy c = _init(PULL, e, _none(), _noSweep());
        vm.prank(address(vault));
        usdg.approve(address(c), PULL);
        vm.prank(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(
                GenericCallStrategy.CallFailed.selector,
                uint8(0),
                1,
                abi.encodeWithSelector(RevertingVenue.Boom.selector, 7)
            )
        );
        c.execute();
    }

    /// @notice A settle-leg target whose code changed after init stops the execute before any pull.
    function test_execute_refusesChangedTargetCode() public {
        GenericCallStrategy c = _defaultClone();
        vm.etch(address(venue), type(MockCallVenueV2).runtimeCode);
        vm.prank(address(vault));
        usdg.approve(address(c), PULL);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(GenericCallStrategy.TargetCodeChanged.selector, address(venue)));
        c.execute();
        assertEq(usdg.balanceOf(address(vault)), VAULT_FUNDS);
    }

    /// @notice Settle does not re-check code: a change after execute cannot wedge the return of capital.
    function test_settle_ignoresChangedTargetCode() public {
        GenericCallStrategy c = _defaultClone();
        _execute(c, PULL);
        vm.etch(address(venue), type(MockCallVenueV2).runtimeCode);
        _settle(c);
        assertEq(usdg.balanceOf(address(vault)), VAULT_FUNDS);
        assertEq(uint256(c.state()), uint256(BaseStrategy.State.Settled));
    }

    /// @notice Settle returns the asset and every declared sweep token, and empties the clone.
    function test_settle_returnsAssetAndSweepTokens() public {
        ERC20Mock bonus = new ERC20Mock("BONUS", "BNS", 18);
        BatchExecutorLib.Call[] memory s = _one(
            _call(
                address(venue),
                abi.encodeCall(MockCallVenue.withdrawWithBonus, (address(usdg), PULL, address(bonus), 3e18))
            )
        );
        address[] memory sweep = new address[](1);
        sweep[0] = address(bonus);
        GenericCallStrategy c = _init(PULL, _depositLeg(PULL), s, sweep);
        _execute(c, PULL);
        _settle(c);

        assertEq(usdg.balanceOf(address(vault)), VAULT_FUNDS);
        assertEq(bonus.balanceOf(address(vault)), 3e18, "sweep token delivered");
        assertEq(usdg.balanceOf(address(c)), 0);
        assertEq(bonus.balanceOf(address(c)), 0);
        assertEq(uint256(c.state()), uint256(BaseStrategy.State.Settled));
    }

    /// @notice An empty settle leg still pushes the asset home.
    function test_settle_emptyLegPushesBalances() public {
        GenericCallStrategy c = _init(PULL, _none(), _none(), _noSweep());
        _execute(c, PULL);
        assertEq(usdg.balanceOf(address(c)), PULL);
        _settle(c);
        assertEq(usdg.balanceOf(address(vault)), VAULT_FUNDS);
    }

    function test_settle_failedCallBubbles() public {
        RevertingVenue bad = new RevertingVenue();
        GenericCallStrategy c =
            _init(PULL, _none(), _one(_call(address(bad), abi.encodeCall(RevertingVenue.fail, (9)))), _noSweep());
        _execute(c, PULL);
        vm.prank(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(
                GenericCallStrategy.CallFailed.selector,
                uint8(1),
                0,
                abi.encodeWithSelector(RevertingVenue.Boom.selector, 9)
            )
        );
        c.settle();
    }

    /// @notice An approval the settle leg grants is revoked after settle too.
    function test_settle_revokesItsOwnGrant() public {
        BatchExecutorLib.Call[] memory s =
            _one(_call(address(usdg), abi.encodeCall(IERC20.approve, (address(venue), type(uint256).max))));
        GenericCallStrategy c = _init(PULL, _none(), s, _noSweep());
        _execute(c, PULL);
        _settle(c);
        assertEq(usdg.allowance(address(c), address(venue)), 0);
    }

    /// @notice Operator approvals granted by a leg are revoked after it.
    function test_revoke_operatorApproval() public {
        MockNFT nft = new MockNFT();
        BatchExecutorLib.Call[] memory e =
            _one(_call(address(nft), abi.encodeCall(IERC721.setApprovalForAll, (address(venue), true))));
        GenericCallStrategy c = _init(0, e, _none(), _noSweep());
        GenericCallStrategy.Grant[] memory g = c.grants();
        assertTrue(g[0].forAll);
        vm.prank(address(vault));
        c.execute();
        assertFalse(nft.isApprovedForAll(address(c), address(venue)));
    }

    /// @notice An ERC-721 `approve(to, id)` shares the ERC-20 selector; its revoke read fails and is skipped.
    function test_revoke_erc721ApproveCollisionDoesNotWedge() public {
        MockNFT nft = new MockNFT();
        BatchExecutorLib.Call[] memory e =
            _one(_call(address(nft), abi.encodeCall(IERC721.approve, (address(venue), 42))));
        GenericCallStrategy c = _init(0, e, _none(), _noSweep());
        nft.mint(address(c), 42);
        vm.prank(address(vault));
        c.execute();
        assertEq(nft.getApproved(42), address(venue), "not revoked: the documented residual");
    }

    /// @notice A token that refuses the revoke emits `RevokeFailed` and the leg still completes.
    function test_revoke_failureIsIgnored() public {
        NoZeroApproveToken weird = new NoZeroApproveToken();
        BatchExecutorLib.Call[] memory e =
            _one(_call(address(weird), abi.encodeCall(IERC20.approve, (address(venue), 1e18))));
        GenericCallStrategy c = _init(0, e, _none(), _noSweep());
        vm.expectEmit(address(c));
        emit GenericCallStrategy.RevokeFailed(address(weird), address(venue));
        vm.prank(address(vault));
        c.execute();
        assertTrue(c.executed());
    }

    /// @notice A venue delivering with `safeTransferFrom` succeeds, and the vault can pull the NFT home.
    function test_nft_safeDeliveryAndRescue() public {
        MockNFT nft = new MockNFT();
        MockNftMarket market = new MockNftMarket(nft, usdg);
        nft.mint(address(market), 7);
        BatchExecutorLib.Call[] memory e = _two(
            _call(address(usdg), abi.encodeCall(IERC20.approve, (address(market), PULL))),
            _call(address(market), abi.encodeCall(MockNftMarket.buy, (7, PULL)))
        );
        GenericCallStrategy c = _init(PULL, e, _none(), _noSweep());
        _execute(c, PULL);
        assertEq(nft.ownerOf(7), address(c));

        vm.prank(address(vault));
        c.rescueERC721To(address(nft), 7);
        assertEq(nft.ownerOf(7), address(vault));
    }

    /// @notice With a hostile leg the vault loses exactly the pull, whatever allowance it granted.
    function testFuzz_vaultLossBoundedByPull(uint256 pull, uint256 extraAllowance) public {
        pull = bound(pull, 1, VAULT_FUNDS);
        extraAllowance = bound(extraAllowance, 0, VAULT_FUNDS);
        address attacker = makeAddr("attacker");
        BatchExecutorLib.Call[] memory e = _one(_call(address(usdg), abi.encodeCall(IERC20.transfer, (attacker, pull))));
        GenericCallStrategy c = _init(pull, e, _none(), _noSweep());
        _execute(c, pull + extraAllowance);
        assertEq(usdg.balanceOf(address(vault)), VAULT_FUNDS - pull);
        assertEq(usdg.balanceOf(attacker), pull);
        assertEq(usdg.balanceOf(address(c)), 0);
    }

    function test_onERC721Received_returnsSelector() public {
        GenericCallStrategy c = _defaultClone();
        assertEq(
            bytes32(c.onERC721Received(address(0), address(0), 0, "")),
            bytes32(GenericCallStrategy.onERC721Received.selector)
        );
    }

    /// @notice The clone refuses native value: it has no receive or fallback.
    function test_rejectsNativeValue() public {
        GenericCallStrategy c = _defaultClone();
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(c).call{value: 1}("");
        assertFalse(ok);
    }
}
