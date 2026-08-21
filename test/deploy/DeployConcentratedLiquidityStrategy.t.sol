// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    DeployConcentratedLiquidityStrategy
} from "../../script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol";
import {MockPermissiveTierRegistry} from "../mocks/MockPermissiveTierRegistry.sol";

/// @dev The gate is `internal view` on the script, which is the right place for
///      it — this only lifts it into reach. Reading the decision through a
///      harness rather than staging a `chains/<id>.json` on disk keeps the test
///      about the RULE instead of about file layout.
contract DeployCLHarness is DeployConcentratedLiquidityStrategy {
    function exposed_requireFactoryVouchedBy(address registry, address uniswapFactory) external view {
        _requireFactoryVouchedBy(registry, uniswapFactory);
    }

    function exposed_requireBookIsComplete(bool hasRegistry, bool hasFactory) external pure {
        _requireBookIsComplete(hasRegistry, hasFactory);
    }
}

/// @notice A registry answering the selector with something that is not a
///         32-byte word — a wrong address in the book, or a registry predating
///         the counterparty axis.
contract MuteRegistry {
    fallback() external {}
}

/// @title DeployConcentratedLiquidityStrategy — the factory allowlist gate
///
/// @notice Since the finding-4 fix, `ConcentratedLiquidityStrategy._initialize`
///         binds `uniswapFactory` through the tier registry, because the pool's
///         provenance is settled by asking that factory `getPool` and an
///         authority the proposer picked is no authority. An unlisted factory
///         therefore does not degrade the template — it makes it INERT. The
///         ceremony completes, `DeployStrategyFactory` allowlists the template,
///         and every proposal reverts at clone-init a governance cycle later.
///
/// @dev    These tests exist because the alternative — documenting the grant as
///         an operator action in prose, which is what `DeployMorphoStrategy`
///         does — has a recorded failure mode in this repo. `Deploy.s.sol` notes
///         a mainnet ceremony that handed five contracts to the Safe and left
///         the certification authority on the deployer key, "with no assertion
///         anywhere to notice".
contract DeployConcentratedLiquidityStrategyTest is Test {
    DeployCLHarness internal harness;
    MockPermissiveTierRegistry internal registry;

    address internal uniswapFactory = makeAddr("uniswapFactory");

    function setUp() public {
        harness = new DeployCLHarness();
        registry = new MockPermissiveTierRegistry();
    }

    function test_gate_passesWhenTheFactoryIsAllowlisted() public view {
        harness.exposed_requireFactoryVouchedBy(address(registry), uniswapFactory);
    }

    /// @notice THE POINT OF THE GATE. A ceremony that skips the grant must fail
    ///         here, not in every proposal that follows.
    function test_gate_failsWhenTheFactoryIsNotAllowlisted() public {
        registry.setDenied(uniswapFactory, true);
        vm.expectRevert(bytes(_unlistedMessage()));
        harness.exposed_requireFactoryVouchedBy(address(registry), uniswapFactory);
    }

    /// @notice A registry that cannot be asked has not vouched — the same
    ///         reading `ConcentratedLiquidityStrategy._readAllowed` gives the
    ///         identical silence at runtime.
    function test_gate_failsWhenTheRegistryCannotAnswer() public {
        MuteRegistry mute = new MuteRegistry();
        vm.expectRevert(bytes(_unanswerableMessage()));
        harness.exposed_requireFactoryVouchedBy(address(mute), uniswapFactory);
    }

    /// @notice An address in the book that holds no code is the same failure as
    ///         a mute one, and must not be read as a pass.
    function test_gate_failsWhenTheRegistryAddressHoldsNoCode() public {
        vm.expectRevert(bytes(_unanswerableMessage()));
        harness.exposed_requireFactoryVouchedBy(makeAddr("notARegistry"), uniswapFactory);
    }

    /// @notice The ONE tolerated skip: the core phase never ran, so there is no
    ///         registry to ask. Tolerated because it cannot be evaluated, not
    ///         because it is inconvenient.
    function test_gate_skipsWhenTheBookNamesNoRegistry() public view {
        harness.exposed_requireFactoryVouchedBy(address(0), uniswapFactory);
    }

    /// @notice THE SKIP MUST NOT DISARM THE GATE. A book naming `SYNDICATE_FACTORY`
    ///         has had the core phase run, and that phase writes `TIER_REGISTRY`
    ///         in the same block of `_patchAddress` calls — so a book with one
    ///         and not the other is broken or hand-edited. Reading that silence
    ///         as "nothing to verify" is the same mistake as reading an
    ///         unanswerable registry as a grant.
    function test_book_failsWhenCoreRanButNamesNoRegistry() public {
        vm.expectRevert(bytes(_incompleteBookMessage()));
        harness.exposed_requireBookIsComplete(false, true);
    }

    /// @notice The tolerated case, unchanged: no core, so nothing to verify.
    function test_book_allowsAPreCoreBook() public view {
        harness.exposed_requireBookIsComplete(false, false);
    }

    /// @notice And a complete book passes regardless of what else is in it.
    function test_book_allowsACompleteBook() public view {
        harness.exposed_requireBookIsComplete(true, true);
    }

    function _incompleteBookMessage() private pure returns (string memory) {
        return string.concat(
            "address book names SYNDICATE_FACTORY but no TIER_REGISTRY - the core phase writes both, ",
            "so this book is incomplete and the factory allowlist cannot be verified"
        );
    }

    function _unlistedMessage() private pure returns (string memory) {
        return string.concat(
            "UNISWAP_V3_FACTORY is not counterparty-allowlisted: the registry owner must call ",
            "setCounterpartyAllowed(UNISWAP_V3_FACTORY, true) or every CL clone-init reverts CounterpartyNotAllowed"
        );
    }

    function _unanswerableMessage() private pure returns (string memory) {
        return string.concat(
            "TIER_REGISTRY cannot answer isCounterpartyAllowed - wrong address, ",
            "or a registry predating the counterparty axis"
        );
    }
}
