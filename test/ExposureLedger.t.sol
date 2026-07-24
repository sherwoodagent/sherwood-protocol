// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";

/// @dev Minimal sWOOD stub exposing exactly the reads the ledger consumes.
contract MockSwood {
    mapping(address => uint256) public guardianStake;
    mapping(address => uint256) public delegatedInbound;
    uint256 public maxDelegatedSlashBps = 2000;
    uint256 public coolDownPeriod = 45 days;

    function setStake(address g, uint256 own, uint256 inbound) external {
        guardianStake[g] = own;
        delegatedInbound[g] = inbound;
    }

    function setMaxDelegatedSlashBps(uint256 v) external {
        maxDelegatedSlashBps = v;
    }
}

contract MockFeed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockGovernorForLedger {
    address public vaultAddr;
    uint256 public coverage;

    constructor(address vault_) {
        vaultAddr = vault_;
    }

    function set(uint256 coverage_) external {
        coverage = coverage_;
    }

    function getRequiredCoverage(uint256) external view returns (uint256) {
        return coverage;
    }

    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
    }

    function getProposalView(uint256) external view returns (ProposalViewLite memory v) {
        v.vault = vaultAddr;
    }
}

contract MockVaultForLedger {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

/// @dev Registry stub returning a canned approver set for quorum tests.
contract MockRegistryForLedger {
    address[] internal _approvers;

    function setApprovers(address[] memory a) external {
        _approvers = a;
    }

    function getApproverWeights(address, uint256)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 total)
    {
        approvers = _approvers;
        weights = new uint128[](approvers.length);
        total = 0;
    }
}

contract ExposureLedgerTest is Test {
    ExposureLedger internal ledger;
    MockSwood internal swood;
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal registry = makeAddr("registry");
    MockGovernorForLedger internal mgov;
    address internal usdgAsset;

    function setUp() public {
        swood = new MockSwood();
        // epochLength 28d immutable; genesis = deploy timestamp.
        ledger = new ExposureLedger(owner, address(swood), 28 days);
        vm.prank(owner);
        ledger.setWoodUsdPrice(0.05e8); // $0.05, conservative haircut price
    }

    function test_slashableBondUsd_ownPlusCappedDelegated() public {
        // own 100k WOOD, inbound 200k WOOD, delegated cap 2000 bps (20%)
        swood.setStake(guardian, 100_000e18, 200_000e18);
        // slashable WOOD = 100k + 200k * 20% = 140k; at $0.05 => $7,000
        assertEq(ledger.slashableBondUsd(guardian), 7_000e18);
    }

    function test_slashableBondUsd_zeroWhenPriceUnset() public {
        ExposureLedger fresh = new ExposureLedger(owner, address(swood), 28 days);
        swood.setStake(guardian, 100_000e18, 0);
        // fail-closed: unset price values every bond at $0 (nothing can be approved)
        assertEq(fresh.slashableBondUsd(guardian), 0);
    }

    function test_setWoodUsdPrice_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        ledger.setWoodUsdPrice(1e8);
    }

    function test_currentEpoch_advances() public {
        uint256 e0 = ledger.currentEpoch();
        vm.warp(block.timestamp + 28 days);
        assertEq(ledger.currentEpoch(), e0 + 1);
    }

    function test_coverageUsd_6decAsset() public {
        MockFeed feed = new MockFeed(1e8, 8); // $1.00, 8-dec feed
        address usdg = makeAddr("usdg");
        vm.mockCall(usdg, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.prank(owner);
        ledger.setAssetFeed(usdg, address(feed), 1 days);
        // 2,000,000 USDG (6 dec) at $1 => $2,000,000 in USD-18
        assertEq(ledger.coverageUsd(usdg, 2_000_000e6), 2_000_000e18);
    }

    function test_coverageUsd_18decAssetNonUnitPrice() public {
        MockFeed feed = new MockFeed(2500e8, 8); // $2,500 (e.g. WETH)
        address weth = makeAddr("weth");
        vm.mockCall(weth, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.prank(owner);
        ledger.setAssetFeed(weth, address(feed), 1 days);
        assertEq(ledger.coverageUsd(weth, 2e18), 5_000e18);
    }

    function test_coverageUsd_revertsUnconfigured() public {
        vm.expectRevert(IExposureLedger.FeedNotConfigured.selector);
        ledger.coverageUsd(makeAddr("unknown"), 1e18);
    }

    function test_coverageUsd_revertsStale() public {
        MockFeed feed = new MockFeed(1e8, 8);
        address usdg = makeAddr("usdg2");
        vm.mockCall(usdg, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.prank(owner);
        ledger.setAssetFeed(usdg, address(feed), 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(IExposureLedger.StalePrice.selector);
        ledger.coverageUsd(usdg, 1e6);
    }

    function _wireRecording() internal {
        usdgAsset = makeAddr("usdgAsset");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockFeed feed = new MockFeed(1e8, 8);
        MockVaultForLedger vault = new MockVaultForLedger(usdgAsset);
        mgov = new MockGovernorForLedger(address(vault));
        vm.startPrank(owner);
        ledger.setAssetFeed(usdgAsset, address(feed), 365 days);
        ledger.setGuardianRegistry(registry);
        vm.stopPrank();
        swood.setStake(guardian, 100_000e18, 0); // slashableBondUsd = $5,000 at $0.05
    }

    function test_recordApproval_registryOnly() public {
        _wireRecording();
        mgov.set(1_000e6);
        vm.expectRevert(IExposureLedger.NotGuardianRegistry.selector);
        ledger.recordApproval(address(mgov), 1, guardian);
    }

    function test_recordApproval_booksExposure() public {
        _wireRecording();
        mgov.set(1_000e6); // $1,000
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18);
    }

    function test_recordApproval_capExceededReverts() public {
        _wireRecording();
        mgov.set(6_000e6); // $6,000 > $5,000 bond
        vm.prank(registry);
        vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
        ledger.recordApproval(address(mgov), 1, guardian);
    }

    function test_recordApproval_netsAcrossSequentialEpochs() public {
        _wireRecording();
        mgov.set(4_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // same guardian, next epoch + challenge window fully elapsed: budget recycled
        vm.warp(block.timestamp + 28 days + 14 days + 1);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian); // would exceed the cap if netted with #1
        assertEq(ledger.openExposureUsd(guardian), 4_000e18); // only the live epoch counts
    }

    function test_recordApproval_blocksSimultaneousOverExposure() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
        ledger.recordApproval(address(mgov), 2, guardian); // $3k + $3k > $5k — the batching attack
    }

    function test_releaseApproval_freesExactRecordedAmount() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 0);
    }

    function test_releaseApproval_idempotentNoUnderflow() public {
        _wireRecording();
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 99, guardian); // never recorded: no-op
        assertEq(ledger.openExposureUsd(guardian), 0);
    }

    /// Fuzz the stated invariant: any record/release interleaving leaves
    /// openExposureUsd == sum recorded-minus-released in unexpired buckets.
    function testFuzz_exposureAccountingConserved(uint96 c1, uint96 c2, bool releaseFirst) public {
        _wireRecording();
        swood.setStake(guardian, type(uint96).max, 0); // cap never binds in this fuzz
        vm.prank(owner);
        ledger.setWoodUsdPrice(1e8);
        uint256 u1 = uint256(c1) % 1_000_000e6 + 1;
        uint256 u2 = uint256(c2) % 1_000_000e6 + 1;
        mgov.set(u1);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        mgov.set(u2);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian);
        if (releaseFirst) {
            vm.prank(registry);
            ledger.releaseApproval(address(mgov), 1, guardian);
            assertEq(ledger.openExposureUsd(guardian), u2 * 1e12); // 6-dec asset at $1 → USD-18
        } else {
            vm.prank(registry);
            ledger.releaseApproval(address(mgov), 2, guardian);
            assertEq(ledger.openExposureUsd(guardian), u1 * 1e12);
        }
    }

    function test_coveredTvlCap_enforced() public {
        _wireRecording();
        vm.prank(owner);
        ledger.setCoveredTvlCapUsd(2_000e18);
        ledger.requireWithinCoveredTvlCap(usdgAsset, 1_500e6); // $1,500 <= $2,000: fine
        vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
        ledger.requireWithinCoveredTvlCap(usdgAsset, 2_500e6);
    }

    function test_coveredTvlCap_zeroCapFailsClosed() public {
        _wireRecording(); // cap never set => 0
        vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
        ledger.requireWithinCoveredTvlCap(usdgAsset, 1e6);
    }

    function test_approveQuorum_sumOfApproverBondsCoversCoverage() public {
        _wireRecording();
        MockRegistryForLedger mockReg = new MockRegistryForLedger();
        vm.prank(owner);
        ledger.setGuardianRegistry(address(mockReg));
        address g2 = makeAddr("g2");
        swood.setStake(guardian, 60_000e18, 0); // $3,000
        swood.setStake(g2, 60_000e18, 0); // $3,000
        address[] memory a = new address[](2);
        a[0] = guardian;
        a[1] = g2;
        mockReg.setApprovers(a);
        // $5,000 coverage vs $6,000 combined bonds: passes
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 5_000e6);
        // $7,000 coverage: fails
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 7_000e6);
    }

    function test_approveQuorum_zeroApproversFailsClosed() public {
        _wireRecording();
        MockRegistryForLedger mockReg = new MockRegistryForLedger();
        vm.prank(owner);
        ledger.setGuardianRegistry(address(mockReg));
        // spec §3.3a cold-start: no covering signer => coverage-consuming proposal
        // cannot execute — it expires instead of executing unreviewed.
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1e6);
    }

    function test_setChallengeWindow_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(0);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(28 days + 1); // > epochLength
        // epochLength + newWindow > coolDownPeriod: 28d + 18d = 46d > 45d
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(18 days);
        ledger.setChallengeWindow(7 days); // 28d + 7d = 35d <= 45d: valid
        vm.stopPrank();
        assertEq(ledger.challengeWindow(), 7 days);
    }

    function test_openExposure_exactExpiryBoundary() public {
        _wireRecording();
        uint256 genesis = block.timestamp; // no warp since deploy
        mgov.set(1_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // bucket 0 stays open until exactly genesis + epochLength + challengeWindow
        vm.warp(genesis + 28 days + 14 days - 1);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18);
        vm.warp(genesis + 28 days + 14 days);
        assertEq(ledger.openExposureUsd(guardian), 0);
    }

    function test_openExposure_carriesIntoNextEpochWithinWindow() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // into epoch 1, but epoch 0's challenge window (open until 28d + 14d) has not elapsed
        vm.warp(block.timestamp + 28 days + 1);
        assertEq(ledger.openExposureUsd(guardian), 3_000e18);
        // a second approval that would overflow the cap still reverts: $3k + $3k > $5k
        vm.prank(registry);
        vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
        ledger.recordApproval(address(mgov), 2, guardian);
    }

    function test_constructor_enforcesDefaultWindowInvariants() public {
        // epochLength 10d < default challengeWindow 14d: violates W <= L
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        new ExposureLedger(owner, address(swood), 10 days);
        // epochLength 40d: 40d + 14d = 54d > coolDownPeriod 45d
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        new ExposureLedger(owner, address(swood), 40 days);
    }

    function test_kNumerator_doublesHeadroom() public {
        _wireRecording();
        vm.prank(owner);
        ledger.setKNumerator(2);
        mgov.set(9_000e6); // $9,000 > $5,000 bond but <= 2 x $5,000
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 9_000e18);
    }

    function test_recordApproval_uint192OverflowGuardReverts() public {
        _wireRecording();
        // re-point the asset's feed to an absurd price so coverageUsd overflows uint192:
        // usd = 1e25 * 1e30 * 1e18 / 1e14 = 1e59 > type(uint192).max (~6.28e57)
        MockFeed hugeFeed = new MockFeed(1e30, 8);
        vm.prank(owner);
        ledger.setAssetFeed(usdgAsset, address(hugeFeed), 365 days);
        mgov.set(1e25);
        vm.prank(registry);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.recordApproval(address(mgov), 1, guardian);
    }
}
