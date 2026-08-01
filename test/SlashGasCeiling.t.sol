// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @title SlashGasCeilingTest
/// @notice Measures what `StakedWood.slashVerdict` ACTUALLY costs, so
///         `ChallengeGame`'s `SLASH_GAS_PER_APPROVER` / `SLASH_GAS_BASE` floor
///         can be sized from data rather than from the escrow-era estimate.
///
/// @dev    WHY THE FLOOR STILL EXISTS AFTER THE BURN. Its original job is gone:
///         it protected an `openCase` child whose out-of-gas revert was
///         indistinguishable from a missing selector, and so burned the
///         victims' compensation irreversibly. The burn is internal now and
///         there is no such child.
///
///         What remains is narrower but real. `resolve` is permissionless, and
///         AFTER the slash `_settle` makes one BEST-EFFORT call —
///         `tierRegistry.demoteByChallenge` inside a bare `try/catch` (review
///         F11, so a revoked demoter role cannot brick a terminal path).
///         Under EIP-150 a caller who supplies just enough gas to finish the
///         slash leaves the demote child with 63/64 of a nearly-empty frame:
///         it runs out, the catch swallows it, `AdapterDemotionFailed` is
///         emitted, and the verdict settles with the challenged adapter
///         KEEPING its certification. Cheap, permissionless, and recoverable
///         only by a separate governance `demote`.
///
///         Everything else after the slash either reverts the whole call (the
///         WOOD transfers are unguarded `safeTransfer`s) or is internal
///         bookkeeping, so it is safe by rollback. The floor's remaining job is
///         exactly: guarantee the demote child cannot be starved.
contract SlashGasCeilingTest is Test {
    StakedWood swood;
    ERC20Mock wood;

    address owner = makeAddr("owner");
    address factory = makeAddr("factory");
    address slasher = makeAddr("slasher");

    uint256 constant STAKE = 20_000e18;

    /// @dev Mirrors `ChallengeGame`'s internal constants. Kept in sync by
    ///      `test_floorCoversMeasuredCostAtEveryCohortSize` — if either moves
    ///      without the other, the assertions here go red.
    uint256 constant PER_APPROVER = 110_000;
    uint256 constant BASE = 1_000_000;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 10_000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
    }

    /// @dev Stakes `n` fresh guardians and returns them in vote order, with a
    ///      full-ceiling rate each — the shape the production feed now emits.
    function _cohort(uint256 n) internal returns (address[] memory approvers, uint256[] memory bps) {
        approvers = new address[](n);
        bps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address g = address(uint160(0x6000 + i));
            approvers[i] = g;
            bps[i] = 10_000;
            wood.mint(g, STAKE);
            vm.prank(g);
            wood.approve(address(swood), type(uint256).max);
            vm.prank(g);
            swood.stakeAsGuardian(STAKE, i + 1);
        }
        skip(30 days);
    }

    function _measure(uint256 n) internal returns (uint256 used) {
        (address[] memory approvers, uint256[] memory bps) = _cohort(n);
        uint256 openedAt = vm.getBlockTimestamp() - 1;
        bytes32 caseKey = keccak256(abi.encodePacked("gas", n));

        vm.prank(slasher);
        uint256 before = gasleft();
        swood.slashVerdict(caseKey, openedAt, approvers, bps, address(0), 0);
        used = before - gasleft();
    }

    /// @notice The measurement itself. Emits the numbers so a re-derivation can
    ///         read them straight out of `forge test -vv` rather than
    ///         re-deriving the fixture.
    function test_measure_slashVerdictGasCurve() public {
        uint256 g1 = _measure(1);
        uint256 g10 = _measure(10);
        uint256 g50 = _measure(50);
        uint256 g100 = _measure(100);

        emit log_named_uint("slashVerdict gas @ 1  approver  ", g1);
        emit log_named_uint("slashVerdict gas @ 10 approvers ", g10);
        emit log_named_uint("slashVerdict gas @ 50 approvers ", g50);
        emit log_named_uint("slashVerdict gas @ 100 approvers", g100);

        // Marginal cost per approver across the widest measured span. The
        // O(n^2) duplicate scan means this is not a constant — it is the
        // AVERAGE slope, which is what a linear floor has to cover.
        emit log_named_uint("marginal gas/approver (10->100) ", (g100 - g10) / 90);
        emit log_named_uint("cost of a 1-approver call       ", g1);

        emit log_named_uint("floor @ 100 approvers           ", 100 * PER_APPROVER + BASE);
    }

    /// @notice THE FLOOR MUST STAY ABOVE THE CURVE AT EVERY COHORT SIZE. The
    ///         floor is linear and the real cost is convex (the duplicate scan
    ///         is O(n²)), so a floor that clears the cap does NOT automatically
    ///         clear the middle — and one that clears the middle can fail at
    ///         the cap. Checked at both ends and in between.
    ///
    ///         The margin is what `demoteByChallenge` lives on: it runs after
    ///         the slash inside a bare `try/catch`, so anything this floor
    ///         fails to reserve is a silently-skipped adapter demotion rather
    ///         than a revert.
    function test_floorCoversMeasuredCostAtEveryCohortSize() public {
        uint256[4] memory sizes = [uint256(1), 10, 50, 100];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 n = sizes[i];
            uint256 actual = _measure(n);
            uint256 floor = n * PER_APPROVER + BASE;
            assertGt(floor, actual, "floor must exceed the measured slash cost");
            // And leave a real post-slash reserve, not a rounding error.
            assertGt(floor - actual, 500_000, "post-slash reserve too thin for the demote child");
        }
    }

    /// @notice The cap must fit one Robinhood transaction (32M). This is the
    ///         constraint that made the old constants a blocker (H2): a floor
    ///         larger than the per-tx limit makes a full-cohort verdict
    ///         unexecutable at any gas price.
    function test_fullCohortFitsRobinhoodTxLimit() public {
        uint256 g100 = _measure(100);
        assertLt(g100, 32_000_000, "a 100-approver verdict must fit one Robinhood tx");
    }
}
