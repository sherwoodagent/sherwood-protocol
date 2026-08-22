// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {DeployMorphoStrategy} from "../../script/robinhood-mainnet/DeployMorphoStrategy.s.sol";
import {DeployStrategyFactory} from "../../script/DeployStrategyFactory.s.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockMorpho, MockIrm} from "../mocks/MockMorpho.sol";
import {MockPermissiveTierRegistry} from "../mocks/MockPermissiveTierRegistry.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";
import {Id, MarketParams} from "../../src/vendor/morpho/IMorpho.sol";

/// @notice Minimal vault stand-in — the strategy's `_initialize` reads only
///         `asset()`. Mirrors `test/strategies/MorphoSupplyStrategy.t.sol`.
contract VaultStub {
    address internal immutable _assetToken;
    address public governor;

    constructor(address assetToken_, address governor_) {
        _assetToken = assetToken_;
        governor = governor_;
    }

    function isAgent(address) external pure returns (bool) {
        return true;
    }

    function asset() external view returns (address) {
        return _assetToken;
    }
}

/// @dev `_templateKeys()` is `internal pure`, and it IS the allowlist — a
///      template missing from it can never be proposed, because
///      `StrategyFactory`'s approval map starts empty and nothing else
///      populates it. Exposing it is the only way to pin that set.
contract DeployStrategyFactoryHarness is DeployStrategyFactory {
    function exposed_templateKeys() external pure returns (string[] memory) {
        return _templateKeys();
    }
}

/// @title DeployMorphoStrategy — the template deploy step
///
/// @notice `MorphoSupplyStrategy` shipped in `src/strategies/` with NO deploy
///         script and NO entry in `DeployStrategyFactory._templateKeys()`, so
///         it was unreachable in both directions at once: nothing produced the
///         template, and nothing would have allowlisted it if something had.
///         That matters on Robinhood specifically — Morpho Blue is the only
///         lending venue on chain 4663.
///
/// @dev    The strategy's own behaviour is covered by
///         `test/strategies/MorphoSupplyStrategy.t.sol`. This suite is about
///         the DEPLOY STEP: that the script yields a locked, clonable template
///         and that the factory's key list actually names it.
contract DeployMorphoStrategyTest is Test {
    DeployMorphoStrategy internal script;
    ERC20Mock internal usdg;
    MockMorpho internal mockMorpho;
    MockIrm internal irm;
    VaultStub internal vaultStub;
    MarketParams internal mp;

    address internal proposer = makeAddr("proposer");

    function setUp() public {
        script = new DeployMorphoStrategy();

        usdg = new ERC20Mock("USDG", "USDG", 6);
        irm = new MockIrm();
        mockMorpho = new MockMorpho();
        mp = MarketParams({
            loanToken: address(usdg),
            collateralToken: makeAddr("collateral"),
            oracle: makeAddr("oracle"),
            irm: address(irm),
            lltv: 0.86e18
        });
        mockMorpho.createMarket(mp);

        // `_initialize` fails CLOSED when `vault() -> governor() -> tierRegistry()`
        // yields nothing, so the governor stand-in must seat a registry.
        MockProposalStatus status = new MockProposalStatus();
        status.setTierRegistry(address(new MockPermissiveTierRegistry()));
        vaultStub = new VaultStub(address(usdg), address(status));
    }

    // ── The template ──

    function test_deploy_producesTheStrategyTemplate() public {
        MorphoSupplyStrategy template = script.deploy();

        assertEq(template.name(), "Morpho Supply", "name");
        assertEq(template.vault(), address(0), "a template binds no vault");
        assertEq(address(template.morpho()), address(0), "no Morpho singleton is seated at deploy");
    }

    /// @dev THE TEMPLATE MUST BE LOCKED. `BaseStrategy`'s constructor sets
    ///      `_initialized = true` on the template itself, so the clone source
    ///      can never be driven directly — only clones, which start unset. A
    ///      template that could be initialized would let anyone seize the
    ///      contract every proposal clones from.
    function test_deploy_templateCannotBeInitializedDirectly() public {
        MorphoSupplyStrategy template = script.deploy();

        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        template.initialize(address(vaultStub), proposer, abi.encode(address(mockMorpho), mp, uint256(1)));
    }

    /// @dev The complement, and the property the ceremony actually needs: a
    ///      clone of the deployed template initializes and seats its market.
    ///      Deploying a template nothing can clone would satisfy the test above
    ///      while leaving the strategy just as unreachable.
    function test_deploy_templateIsClonableAndInitializes() public {
        MorphoSupplyStrategy template = script.deploy();

        MorphoSupplyStrategy clone = MorphoSupplyStrategy(Clones.clone(address(template)));
        clone.initialize(address(vaultStub), proposer, abi.encode(address(mockMorpho), mp, uint256(100_000e6)));

        assertEq(clone.vault(), address(vaultStub), "clone binds the vault");
        assertEq(address(clone.morpho()), address(mockMorpho), "clone seats the Morpho singleton");
        assertEq(clone.asset(), address(usdg), "clone seats the loan asset");
        assertEq(clone.supplyAmount(), 100_000e6, "clone seats the supply amount");
    }

    // ── The allowlist ──

    /// @dev THE DEPLOY STEP IS HALF THE FIX. A template the factory never
    ///      approves is as unreachable as one that was never deployed —
    ///      `DeployStrategyFactory`'s loop SKIPS absent keys and only requires
    ///      `approved > 0`, so a missing entry degrades silently rather than
    ///      failing the run.
    function test_templateKeys_nameTheMorphoTemplate() public {
        string[] memory keys = new DeployStrategyFactoryHarness().exposed_templateKeys();

        bool found;
        for (uint256 i; i < keys.length; ++i) {
            if (keccak256(bytes(keys[i])) == keccak256("MORPHO_SUPPLY_TEMPLATE")) found = true;
        }
        assertTrue(found, "MORPHO_SUPPLY_TEMPLATE must be in the factory allowlist");
    }

    /// @dev THE DEPRECATED FOUR ARE GONE, pinned so they cannot drift back in.
    ///      None had a contract left in `src/strategies/`, so every chain's run
    ///      skipped all four while the list implied the protocol could propose
    ///      them. Asserting the exact set is what keeps the list honest.
    function test_templateKeys_holdExactlyTheLiveTemplates() public {
        string[] memory keys = new DeployStrategyFactoryHarness().exposed_templateKeys();

        assertEq(keys.length, 3, "exactly the live templates");
        assertEq(keys[0], "PORTFOLIO_TEMPLATE", "portfolio");
        assertEq(keys[1], "MORPHO_SUPPLY_TEMPLATE", "morpho");
        assertEq(keys[2], "CONCENTRATED_LIQUIDITY_TEMPLATE", "concentrated liquidity");
    }
}
