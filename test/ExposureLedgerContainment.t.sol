// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {StakedWood} from "src/StakedWood.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockWoodTwapOracle} from "test/mocks/MockWoodTwapOracle.sol";
import {MockFeed, MockGovernorForLedger, MockVaultForLedger} from "test/ExposureLedger.t.sol";

/// @title ExposureLedgerContainment
/// @notice The spec's "Exposure cap multiplier" scenarios, driven against the
///         REAL `StakedWood` so the conviction is the verdict path itself —
///         `slashVerdict` fed the rates `slashBpsFor` returns — rather than a
///         `setStake` standing in for a burn.
///
///         CONTAINMENT AT k = 1. Capacity is `kNumerator x stake - open
///         exposure`, so at k = 1 the sum of a guardian's live locks never
///         exceeds its stake. A conviction on proposal A burns `min(lock_A,
///         basis)`, which leaves `stake - lock_A >= sum of the other locks`:
///         every other proposal the guardian backs is still fully covered by
///         what remains. This is the property that replaced the booking/pledge
///         model's shared-stake arithmetic, and it is what makes one guardian's
///         bad approval stay that guardian's own problem.
///
///         LEVERAGE AT k > 1 is the documented cost of the setting: the same
///         conviction leaves the other proposals under-covered by EXACTLY the
///         excess the multiplier admitted. The test pins that arithmetic so a
///         future operator raising `k` for capital efficiency sees the number.
contract ExposureLedgerContainmentTest is Test {
    ERC20Mock internal wood;
    StakedWood internal swood;
    ExposureLedger internal ledger;
    MockWoodTwapOracle internal twap;
    MockGovernorForLedger internal govA;
    MockGovernorForLedger internal govB;

    address internal owner = makeAddr("owner");
    address internal registry = makeAddr("registry"); // ledger-side record/release authority
    address internal guardian = makeAddr("guardian");
    address internal usdgAsset;

    uint256 internal constant STAKE = 100_000e18; // $5,000 at $0.05
    uint256 internal constant MARKET_X8 = 0.05e8;
    uint256 internal constant CAP_X8 = 0.1e8;

    function setUp() public {
        wood = new ERC20Mock("Sherwood", "WOOD", 18);

        StakedWood impl = new StakedWood();
        bytes memory init = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 45 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 10_000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), init)));
        // The registry pointer is only consulted by the review-path slash;
        // this suite drives the verdict path, whose gate is the slasher role.
        vm.startPrank(owner);
        swood.setRegistry(registry);
        swood.setAuthorizedSlasher(address(this));
        vm.stopPrank();

        wood.mint(guardian, STAKE);
        vm.startPrank(guardian);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(STAKE, 1);
        vm.stopPrank();

        ledger = new ExposureLedger(owner, address(swood), 28 days);
        twap = new MockWoodTwapOracle(MARKET_X8);
        usdgAsset = makeAddr("usdgAsset");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockFeed feed = new MockFeed(1e8, 8);
        govA = new MockGovernorForLedger(address(new MockVaultForLedger(usdgAsset)));
        govB = new MockGovernorForLedger(address(new MockVaultForLedger(usdgAsset)));
        vm.startPrank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        ledger.setWoodTwapOracle(address(twap));
        ledger.setAssetFeed(usdgAsset, address(feed), 365 days);
        ledger.setGuardianRegistry(registry);
        vm.stopPrank();
        assertEq(ledger.woodPriceX8(), MARKET_X8, "fixture prices off the market");

        // Both proposals need $1,000 and settle a few days out.
        govA.set(1_000e6);
        govA.setSchedule(block.timestamp + 1 days, 3 days);
        govB.set(1_000e6);
        govB.setSchedule(block.timestamp + 1 days, 3 days);

        // The stake checkpoint must sit strictly before the anchor a verdict
        // reads at (`slashableStakeAt(g, executedAt)` looks up `executedAt - 1`).
        vm.warp(block.timestamp + 1);
    }

    function _lock(MockGovernorForLedger gov, uint256 wood_) internal {
        vm.prank(registry);
        ledger.recordApproval(address(gov), 1, guardian, wood_);
    }

    /// @dev The verdict path, byte for byte: execute A, read the ledger's own
    ///      rates for it, and hand them to `slashVerdict` anchored at
    ///      `executedAt`. Returns the WOOD burned.
    function _convictA() internal returns (uint256 burned) {
        govA.setExecutedAt(block.timestamp);
        uint256 executedAt = block.timestamp;
        vm.warp(block.timestamp + 1);
        (address[] memory approvers, uint256[] memory bps) = ledger.slashBpsFor(address(govA), 1);
        assertEq(approvers.length, 1, "fixture: one accused approver");
        assertEq(approvers[0], guardian);
        burned = swood.slashVerdict(keccak256("case-A"), executedAt, approvers, bps);
        assertGt(burned, 0, "control: the conviction really burned something");
    }

    /// @notice Spec scenario "Containment at the default": k = 1, the guardian
    ///         backs A and B, A is convicted, and B's coverage from that
    ///         guardian is unchanged — lock intact, priced exactly as before.
    function test_containment_atKEqualsOne_convictionOnADoesNotTouchB() public {
        assertEq(ledger.kNumerator(), 1, "fixture: the default multiplier");
        _lock(govA, 40_000e18);
        _lock(govB, 60_000e18); // the whole remaining budget
        assertEq(ledger.openExposure(guardian), STAKE, "sum of locks == stake at k = 1");
        assertEq(ledger.lockOf(address(govB), 1, guardian), 60_000e18);
        assertEq(ledger.coverageUsdOf(address(govB), 1, guardian), 3_000e18, "B priced at its full lock before");

        (, uint256[] memory rateA) = ledger.slashBpsFor(address(govA), 1);
        assertEq(rateA[0], 4_000, "A's rate is its lock over the stake");

        uint256 burned = _convictA();

        // The burn is A's lock and nothing else — under an envelope that does
        // not bind (4,000 bps sits inside [1,000, 10,000]).
        assertEq(burned, 40_000e18, "burned exactly A's lock");
        assertEq(swood.guardianStake(guardian), 60_000e18, "what remains is exactly B's lock");

        // B: untouched. Same lock, same price, same recoverable coverage.
        assertEq(ledger.lockOf(address(govB), 1, guardian), 60_000e18, "B's lock is intact");
        assertEq(ledger.coverageUsdOf(address(govB), 1, guardian), 3_000e18, "B's coverage from the guardian unchanged");
        (, uint256[] memory rateB) = ledger.slashBpsFor(address(govB), 1);
        assertEq(rateB[0], 10_000, "and B is still fully collectable: its lock equals the remaining stake");
        assertEq(ledger.liabilityUsd(address(govB), 1), 1_000e18, "B's recoverable liability still meets its need");
    }

    /// @notice Spec scenario "Leverage is legible": k = 2 lets the guardian lock
    ///         more than it holds, and a conviction on A leaves B under-covered
    ///         by EXACTLY the excess the multiplier admitted.
    function test_leverage_atKEqualsTwo_convictionOnAUnderCoversBByTheExcess() public {
        vm.prank(owner);
        ledger.setKNumerator(2);
        _lock(govA, 80_000e18);
        _lock(govB, 80_000e18);
        uint256 excess = 160_000e18 - STAKE; // 60,000 WOOD locked beyond the stake
        assertEq(ledger.openExposure(guardian), 160_000e18, "locks exceed the stake by the excess");
        assertEq(ledger.coverageUsdOf(address(govB), 1, guardian), 4_000e18, "B priced at its full lock before");

        uint256 burned = _convictA();
        assertEq(burned, 80_000e18, "A's whole lock burns (the stake covered it)");
        assertEq(swood.guardianStake(guardian), 20_000e18);

        // B still HOLDS its lock, but only `stake - lock_A` is left behind it.
        assertEq(ledger.lockOf(address(govB), 1, guardian), 80_000e18, "B's lock record is intact...");
        uint256 coverageAfter = ledger.coverageUsdOf(address(govB), 1, guardian);
        assertEq(coverageAfter, 1_000e18, "...but only 20,000 WOOD of it is still collectable");
        uint256 shortfallWood = 80_000e18 - 20_000e18;
        assertEq(shortfallWood, excess, "under-covered by exactly the leverage excess");
        assertEq(4_000e18 - coverageAfter, (excess * MARKET_X8) / 1e8, "the same excess, priced");
    }
}
