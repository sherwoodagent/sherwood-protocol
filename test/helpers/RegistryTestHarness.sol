// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "../mocks/MockGovernorMinimal.sol";
import {MockLedgerFullLocks} from "../mocks/MockLedgerFullLocks.sol";

/// @notice Shared test harness for the post-split `GuardianRegistry` +
///         `StakedWood` (sWOOD) pair. After the sWOOD staking split the
///         registry holds zero WOOD and reads vote weight from sWOOD. Review /
///         emergency / reward tests must therefore deploy BOTH contracts and
///         wire them: the registry is `initialize`d with the sWOOD address and
///         sWOOD's set-once `setRegistry` is pointed back at the registry.
///
///         Guardians stake through `swood.stakeAsGuardian`, not the registry.
///         `_stakeGuardian` is the canonical helper review tests use to build
///         a cohort.
abstract contract RegistryTestHarness is Test {
    GuardianRegistry internal registry;
    StakedWood internal swood;
    ERC20Mock internal wood;
    MockGovernorMinimal internal governor;

    address internal regOwner = address(0xA11CE);
    address internal regFactory = address(0xFAC10);
    /// @dev Stand-in vault for the mock governor's `vaultOf` registration. Named
    ///      rather than `address(this)` so it reads as a deliberate sentinel and
    ///      never as a real bonded vault.
    address internal constant HARNESS_VAULT_SENTINEL = address(0xFA017);

    /// @dev Deploys WOOD, a governor mock, sWOOD, and the registry, then wires
    ///      sWOOD ↔ registry. Call from a test's `setUp`.
    function _deployRegistryAndSwood(uint256 reviewPeriod, uint256 blockQuorumBps) internal {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        governor = new MockGovernorMinimal();

        // sWOOD first — the registry's `initialize` takes the sWOOD address.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: regOwner,
                    wood: address(wood),
                    factory: regFactory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (regOwner, regFactory, address(swood), reviewPeriod, blockQuorumBps)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));

        // Resolve the registry ↔ sWOOD circular dependency.
        vm.prank(regOwner);
        swood.setRegistry(address(registry));

        // Authorize the mock governor on the composite-key registry (the factory
        // does this in production via createSyndicate).
        vm.prank(regFactory);
        // `vaultOf` IS load-bearing: the emergency path resolves its owner-bond
        // slash target from it. `MockGovernorMinimal` serves no real vault, so
        // this harness registers an explicit sentinel — a suite that exercises
        // an owner-bond slash MUST re-register the governor against the vault it
        // actually bonded (see GuardianRegistry.t.sol), or the slash silently
        // targets an address with no stake and no-ops.
        registry.addGovernor(address(governor), HARNESS_VAULT_SENTINEL);
    }

    /// @dev The whole-stake ledger stand-in, once `_wireFullLockLedger` ran.
    MockLedgerFullLocks internal fullLockLedger;

    /// @dev Declared coverage locks: `GuardianRegistry._reviewSlashRates`
    ///      multiplies each approver's LOCK RATE (from the wired ledger) by the
    ///      review severity, and with NO ledger wired every rate is zero — a
    ///      blocked review then burns nothing. Suites that pin severity
    ///      arithmetic on real `StakedWood` balances call this from `setUp` to
    ///      wire a ledger under which every approver has locked its whole
    ///      stake (rate 10_000), which is exactly the pre-lock slash shape.
    function _wireFullLockLedger() internal {
        fullLockLedger = new MockLedgerFullLocks();
        fullLockLedger.setGuardianRegistry(address(registry));
        vm.prank(regOwner);
        registry.setExposureLedger(address(fullLockLedger));
    }

    /// @dev Pushes a proposal's review window into the registry AS the mock
    ///      governor. Post-refactor the registry reads the window from this
    ///      stored registration (via `registerReview`) instead of calling back
    ///      into the governor's removed `getProposalView`.
    function _registerReview(uint256 proposalId, uint256 voteEnd, uint256 reviewEnd) internal {
        vm.prank(address(governor));
        registry.registerReview(proposalId, voteEnd, reviewEnd);
    }

    /// @dev Mints WOOD to `g`, approves sWOOD, and stakes `amount` as a
    ///      guardian. Guardian is active afterwards.
    function _stakeGuardian(address g, uint256 amount, uint256 agentId) internal {
        wood.mint(g, amount);
        vm.startPrank(g);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(amount, agentId);
        vm.stopPrank();
    }
}
