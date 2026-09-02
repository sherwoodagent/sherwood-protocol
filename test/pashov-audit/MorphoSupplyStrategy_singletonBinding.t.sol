// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockMorpho, MockIrm} from "../mocks/MockMorpho.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {Id, MarketParams, Market, Position} from "../../src/vendor/morpho/IMorpho.sol";

/// @notice A hostile "Morpho singleton". It answers every question
///         `MorphoSupplyStrategy._initialize` used to rely on with whatever the
///         attacker needs:
///           - `market(id).lastUpdate != 0` for ANY id, so `MarketNotCreated`
///             never fires (the check asks the attacker about the attacker);
///           - `supply` accepts the transfer and keeps the tokens;
///           - `position` / `market` then report a ZERO position, so
///             `_deliverableNow` returns nothing and `_settle` completes
///             "cleanly" with the vault booking the entire supply as a loss.
///         `marketParams.loanToken` is not under this contract's control at
///         all — the proposer simply names the real vault asset, which is why
///         `LoanAssetMismatch` is no obstacle either.
contract HostileMorpho {
    function market(Id) external pure returns (Market memory m) {
        // Any nonzero `lastUpdate` reads as "this market exists".
        m.lastUpdate = 1;
    }

    function position(Id, address) external pure returns (Position memory p) {
        p; // all-zero: nothing owed back
    }

    /// @dev Keeps whatever it is approved for. Uses `transferFrom` so the
    ///      `forceApprove` in `_execute` is the only thing standing between the
    ///      vault's float and this contract.
    function supply(MarketParams memory mp, uint256 assets, uint256, address, bytes memory)
        external
        returns (uint256, uint256)
    {
        IERC20(mp.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, assets);
    }
}

/// @notice Vault stand-in exposing the two selectors the strategy walks:
///         `asset()` (ERC4626) and `governor()` (the tier-binding path and
///         `BaseStrategy.execute`'s active-proposal binding).
contract BindingVaultStub {
    address internal immutable _assetToken;
    address public governor;

    constructor(address assetToken_, address governor_) {
        _assetToken = assetToken_;
        governor = governor_;
    }

    function asset() external view returns (address) {
        return _assetToken;
    }

    function isAgent(address) external pure returns (bool) {
        return true;
    }

    function setGovernor(address g) external {
        governor = g;
    }
}

/// @notice Governor stand-in: `tierRegistry()` for the binding walk plus a
///         permissive `IProposalStatus` pair so `BaseStrategy.execute()`'s
///         active-proposal binding is not what this suite is testing.
contract BindingGovernorStub {
    address public tierRegistry;

    constructor(address registry_) {
        tierRegistry = registry_;
    }

    function setTierRegistry(address r) external {
        tierRegistry = r;
    }

    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function strategyOf(uint256) external view returns (address) {
        return msg.sender;
    }
}

/// @notice A governor with code but NO `tierRegistry()` selector — the walk's
///         staticcall reverts, which `_readAddress` must read as "unresolved".
contract GovernorNoRegistryGetter {
    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function strategyOf(uint256) external view returns (address) {
        return msg.sender;
    }
}

/// @notice Registry stand-in: owner-settable per-address allowlist.
contract BindingTierRegistry {
    mapping(address => bool) public allowed;

    function setAllowed(address a, bool v) external {
        allowed[a] = v;
    }

    function isAdapterAllowed(address a) external view returns (bool) {
        return allowed[a];
    }

    /// @dev The CALLEE axis (`_guardBatchCalls` PART 2a), split out of
    ///      `isAdapterAllowed` per pashov finding #14. Mirrors the adapter axis:
    ///      the demotion asymmetry is exercised against the real registry in
    ///      `test/pashov-final/Registry_demoteKeepsCalleeStanding.t.sol`, so
    ///      mirroring keeps every binding case here unchanged.
    ///
    ///      Present at all because the vault's PART 2a call is TYPED: a stand-in
    ///      missing this selector reverts in the CALLER's frame with empty
    ///      returndata. `MuteTierRegistry` below deliberately stays bare — being
    ///      unable to answer is the whole point of that fixture.
    function isCallableTarget(address a) external view returns (bool) {
        return allowed[a];
    }

    /// @dev SHE-209: no class concept in this stand-in — every address is a
    ///      non-member, so the vault's class-binding check never fires.
    function classOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice A registry with code but no `isAdapterAllowed` selector: RESOLVED
///         but unable to vouch. Must fail CLOSED.
contract MuteTierRegistry {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/**
 * @title MorphoSupplyStrategy_singletonBindingTest
 * @notice pashov 2026-08 finding 12. `MorphoSupplyStrategy._initialize` decoded
 *         the Morpho singleton straight out of proposer init data behind a bare
 *         zero-address check. The two apparent validations validate nothing
 *         against a hostile singleton: `mp.loanToken != vaultAsset` compares two
 *         proposer-supplied values against a real one (name the real asset and
 *         it passes) and `market(id).lastUpdate == 0` asks the attacker's own
 *         contract whether the attacker's market exists.
 *
 *         The fix binds `morpho_` to the governance-owned `TierRegistry` through
 *         the same `vault() -> governor() -> tierRegistry() ->
 *         isAdapterAllowed` walk `PortfolioStrategy` uses for its swap adapter,
 *         at `_initialize` and again at `_execute`.
 */
contract MorphoSupplyStrategy_singletonBindingTest is Test {
    uint256 constant SUPPLY = 100_000e6;

    ERC20Mock usdg;
    MockIrm irm;
    MockMorpho realMorpho;
    MarketParams mp;

    BindingTierRegistry registry;
    BindingGovernorStub governor;
    BindingVaultStub vaultStub;
    MorphoSupplyStrategy template;

    address proposer = makeAddr("proposer");

    function setUp() public {
        usdg = new ERC20Mock("USDG", "USDG", 6);
        irm = new MockIrm();
        irm.setRate(0);
        realMorpho = new MockMorpho();

        mp = MarketParams({
            loanToken: address(usdg),
            collateralToken: makeAddr("collateral"),
            oracle: makeAddr("oracle"),
            irm: address(irm),
            lltv: 0.86e18
        });
        realMorpho.createMarket(mp);

        registry = new BindingTierRegistry();
        governor = new BindingGovernorStub(address(registry));
        vaultStub = new BindingVaultStub(address(usdg), address(governor));
        usdg.mint(address(vaultStub), SUPPLY);

        template = new MorphoSupplyStrategy();
    }

    function _init(address morpho_, MarketParams memory params) internal returns (MorphoSupplyStrategy s) {
        s = MorphoSupplyStrategy(Clones.clone(address(template)));
        s.initialize(address(vaultStub), proposer, abi.encode(morpho_, params, SUPPLY));
    }

    /// @dev Assert that INITIALIZE reverts with `err`. The clone and the
    ///      `abi.encode` are hoisted deliberately: `vm.expectRevert` is a
    ///      one-shot that binds to the very NEXT call, and `Clones.clone` is a
    ///      CREATE — arming the cheatcode before it makes the cheatcode
    ///      intercept the deployment, and every negative init test then fails
    ///      with `FailedDeployment()` no matter what the contract does.
    function _expectInitRevert(bytes4 err, address morpho_, MarketParams memory params) internal {
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(morpho_, params, SUPPLY);
        address v = address(vaultStub);
        vm.expectRevert(err);
        s.initialize(v, proposer, data);
    }

    // ── The attack ──

    /// @notice THE FINDING. A hostile singleton satisfies both pre-existing
    ///         checks — it self-attests that the market exists, and the proposer
    ///         names the real vault asset as `loanToken`. Only the allowlist
    ///         binding stops it.
    function test_init_hostileSingletonSelfAttestsButIsRejected() public {
        HostileMorpho evil = new HostileMorpho();
        MarketParams memory evilParams = mp;
        // The attacker's own market id — never created anywhere real.
        evilParams.lltv = 0.123e18;

        // Both legacy checks pass against this contract, proving they are not
        // the thing doing the work.
        assertEq(evilParams.loanToken, address(usdg), "loanToken names the real vault asset");
        assertTrue(evil.market(Id.wrap(keccak256(abi.encode(evilParams)))).lastUpdate != 0, "self-attested as created");

        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(evil), evilParams, SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyStrategy.MorphoNotAllowed.selector, address(evil), address(registry))
        );
        s.initialize(address(vaultStub), proposer, initData);
    }

    /// @notice The full drain the binding prevents, demonstrated end to end by
    ///         allowlisting the hostile singleton: execute moves the vault's
    ///         whole float into it, and settle reports success while the vault
    ///         gets nothing back. This is what the revert above is worth.
    function test_hostileSingletonDrainsTheVaultWhenAllowlisted() public {
        HostileMorpho evil = new HostileMorpho();
        MarketParams memory evilParams = mp;
        evilParams.lltv = 0.123e18;
        registry.setAllowed(address(evil), true);

        MorphoSupplyStrategy s = _init(address(evil), evilParams);

        vm.prank(address(vaultStub));
        usdg.approve(address(s), SUPPLY);
        vm.prank(address(vaultStub));
        s.execute();

        assertEq(usdg.balanceOf(address(evil)), SUPPLY, "attacker took the whole supply");
        assertEq(usdg.balanceOf(address(vaultStub)), 0, "vault drained");

        vm.prank(address(vaultStub));
        s.settle(); // completes "cleanly"

        assertEq(usdg.balanceOf(address(vaultStub)), 0, "settlement returned nothing");
    }

    // ── Init-time binding ──

    function test_init_revertsWhenSingletonNotAllowlisted() public {
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(realMorpho), mp, SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSupplyStrategy.MorphoNotAllowed.selector, address(realMorpho), address(registry)
            )
        );
        s.initialize(address(vaultStub), proposer, initData);
    }

    function test_init_succeedsWhenSingletonAllowlisted() public {
        registry.setAllowed(address(realMorpho), true);
        MorphoSupplyStrategy s = _init(address(realMorpho), mp);
        assertEq(address(s.morpho()), address(realMorpho));
    }

    /// @notice A RESOLVED registry that cannot answer `isAdapterAllowed` fails
    ///         CLOSED — a registry that cannot vouch has not vouched.
    function test_init_failsClosedWhenResolvedRegistryCannotAnswer() public {
        MuteTierRegistry mute = new MuteTierRegistry();
        governor.setTierRegistry(address(mute));

        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(realMorpho), mp, SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyStrategy.MorphoNotAllowed.selector, address(realMorpho), address(mute))
        );
        s.initialize(address(vaultStub), proposer, initData);
    }

    /// @notice An UNRESOLVED walk fails CLOSED at init.
    /// @dev    This suite originally asserted the opposite — that an unresolved
    ///         walk SKIPS the check, "the same fail-open-only-here posture as
    ///         `PortfolioStrategy`". That reading was wrong, and adversarial
    ///         review caught it: `PortfolioStrategy._initialize` carries a
    ///         SEPARATE `if (_resolveTierRegistry() == address(0)) revert`
    ///         above its per-adapter call, under a note that says in terms "Do
    ///         not make these symmetric." The skip belongs to the per-call
    ///         re-certification, where blocking would strand deployed capital.
    ///         It does not belong at bind time.
    ///
    ///         The gap that made this load-bearing rather than stylistic:
    ///         `SyndicateFactory` documents a zero factory `tierRegistry` as
    ///         "Optional — address(0) means governors created by this factory
    ///         keep the safe tier-2 default", so EVERY governor created before
    ///         `setTierRegistry`/`pushWiring` resolves to nothing. Fail-open
    ///         left finding #12 unmitigated for that entire population, with no
    ///         allowlist step needed by the attacker.
    function test_init_failsClosedWhenGovernorHasNoRegistryGetter() public {
        GovernorNoRegistryGetter blind = new GovernorNoRegistryGetter();
        vaultStub.setGovernor(address(blind));

        _expectInitRevert(MorphoSupplyStrategy.TierRegistryUnresolved.selector, address(realMorpho), mp);
    }

    /// @notice The governor population the factory explicitly permits: wired,
    ///         but with `tierRegistry() == 0`. Must also refuse at bind time.
    function test_init_failsClosedWhenRegistryUnset() public {
        governor.setTierRegistry(address(0));
        _expectInitRevert(MorphoSupplyStrategy.TierRegistryUnresolved.selector, address(realMorpho), mp);
    }

    // ── Execute-time re-certification ──

    /// @notice A singleton demoted between clone-init and execute must not
    ///         receive `forceApprove` of the whole supply. Blocking `execute()`
    ///         strands nothing: the proposal simply expires with the vault
    ///         untouched.
    function test_execute_revertsWhenSingletonDemotedAfterInit() public {
        registry.setAllowed(address(realMorpho), true);
        MorphoSupplyStrategy s = _init(address(realMorpho), mp);

        registry.setAllowed(address(realMorpho), false);

        vm.prank(address(vaultStub));
        usdg.approve(address(s), SUPPLY);
        vm.prank(address(vaultStub));
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSupplyStrategy.MorphoNotAllowed.selector, address(realMorpho), address(registry)
            )
        );
        s.execute();

        assertEq(usdg.balanceOf(address(vaultStub)), SUPPLY, "vault float untouched");
        assertEq(usdg.allowance(address(s), address(realMorpho)), 0, "no approval granted");
    }

    /// @notice The exit path is NOT gated: a demotion after execute must not be
    ///         able to freeze deployed capital inside the clone.
    function test_settle_notGatedByAllowlist() public {
        registry.setAllowed(address(realMorpho), true);
        MorphoSupplyStrategy s = _init(address(realMorpho), mp);

        vm.prank(address(vaultStub));
        usdg.approve(address(s), SUPPLY);
        vm.prank(address(vaultStub));
        s.execute();

        // Demote AFTER the capital is deployed.
        registry.setAllowed(address(realMorpho), false);

        vm.prank(address(vaultStub));
        s.settle();

        assertEq(usdg.balanceOf(address(vaultStub)), SUPPLY, "capital returned despite demotion");
    }
}
