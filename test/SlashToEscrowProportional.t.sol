// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";
import {CompensationEscrow} from "../src/CompensationEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";

/// @dev Vault stand-in exposing the ERC20Votes reads the escrow apportions
///      against. Mirrors `StakedWoodSlashToEscrow.t.sol`'s copy so the two
///      suites stay independently editable.
contract MockVotesVaultProp {
    mapping(address => mapping(uint256 => uint256)) public votesAt;
    mapping(uint256 => uint256) public totalAt;

    function setVotes(address holder, uint256 ts, uint256 v) external {
        votesAt[holder][ts] = v;
    }

    function setTotal(uint256 ts, uint256 v) external {
        totalAt[ts] = v;
    }

    function getPastVotes(address holder, uint256 ts) external view returns (uint256) {
        return votesAt[holder][ts];
    }

    function getPastTotalSupply(uint256 ts) external view returns (uint256) {
        return totalAt[ts];
    }
}

/// @dev Chainlink stub: $1.00, 8 decimals.
contract PropFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract PropVault {
    address public asset;

    constructor(address a) {
        asset = a;
    }
}

contract PropGovernor {
    address public vaultAddr;
    uint256 public coverage;

    constructor(address v) {
        vaultAddr = v;
    }

    function set(uint256 c) external {
        coverage = c;
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

/// @notice `slashToEscrow` takes ONE RATE PER APPROVER rather than one for the
///         batch. A guardian's liability is what they underwrote, which
///         `ExposureLedger` already books per guardian — before this the ledger
///         booked shares while the slasher took whole bonds, so booked coverage
///         could not net across concurrent convictions.
///
///         `StakedWoodSlashToEscrow.t.sol` covers the uniform-rate path (roles,
///         escrow wiring, snapshot bound). This suite covers only what the
///         per-approver array makes possible, or newly risks.
contract SlashToEscrowProportionalTest is Test {
    StakedWood internal swood;
    ERC20Mock internal wood;
    CompensationEscrow internal escrow;
    MockVotesVaultProp internal vault;

    address internal owner = address(0xA11CE);
    address internal factory = address(0xFAC10);
    address internal registry = address(0x9E915);
    address internal slasher = makeAddr("slasher");
    address internal backstop = makeAddr("backstop");
    address internal g1 = makeAddr("g1");
    address internal g2 = makeAddr("g2");
    address internal alice = makeAddr("alice");

    /// @dev Both guardians stake this, so any difference in slashed WOOD can
    ///      only come from the rate — never from a difference in the basis.
    uint256 internal constant STAKE = 20_000e18;

    uint256 internal constant MIN_SLASH_BPS = 1000;
    uint256 internal constant MAX_SLASH_BPS = 8000;

    uint256 internal openedAt;
    uint256 internal snapTs;

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
                    // 45d so a real ExposureLedger can sit over this sWOOD:
                    // its constructor enforces epochLength + challengeWindow
                    // <= coolDownPeriod (28 + 14 here). Nothing in this suite
                    // exercises unstake timing.
                    coolDownPeriod: 45 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: MIN_SLASH_BPS,
                    // Deliberately BELOW 100% so the ceiling is observable: at
                    // maxSlashBps 10_000 a cap test cannot tell a clamp from an
                    // uncapped pass-through.
                    maxSlashBps: MAX_SLASH_BPS,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(owner);
        swood.setRegistry(registry);

        escrow = new CompensationEscrow(owner, address(wood));
        vm.startPrank(owner);
        escrow.setAuthorizedFunder(address(swood));
        escrow.setBackstop(backstop);
        swood.setCompensationEscrow(address(escrow));
        swood.setAuthorizedSlasher(slasher);
        vm.stopPrank();

        vault = new MockVotesVaultProp();

        _stake(g1);
        _stake(g2);

        skip(30 days);
        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1);

        snapTs = vm.getBlockTimestamp() - 1 days;
        vault.setTotal(snapTs, 1_000e18);
        vault.setVotes(alice, snapTs, 1_000e18);
    }

    function _stake(address g) internal {
        wood.mint(g, 1_000_000e18);
        vm.startPrank(g);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(STAKE, 1);
        vm.stopPrank();
    }

    function _pair(address a, address b) internal pure returns (address[] memory xs) {
        xs = new address[](2);
        xs[0] = a;
        xs[1] = b;
    }

    function _rates(uint256 a, uint256 b) internal pure returns (uint256[] memory xs) {
        xs = new uint256[](2);
        xs[0] = a;
        xs[1] = b;
    }

    /// @notice THE HEADLINE. Two approvers, two rates, two different losses,
    ///         each proportional to the rate handed in. Under the old single
    ///         `slashBps` both took an identical fraction, so the ledger's
    ///         per-guardian commitments could not be honoured.
    function test_eachApproverIsSlashedAtTheirOwnRate() public {
        uint256 before1 = swood.guardianStake(g1);
        uint256 before2 = swood.guardianStake(g2);
        assertEq(before1, before2, "fixture: equal basis");

        vm.prank(slasher);
        swood.slashToEscrow(bytes32("case"), openedAt, _pair(g1, g2), _rates(5000, 2500), address(vault), snapTs);

        uint256 lost1 = before1 - swood.guardianStake(g1);
        uint256 lost2 = before2 - swood.guardianStake(g2);

        assertEq(lost1, (STAKE * 5000) / 10_000, "g1 slashed at its own 50%");
        assertEq(lost2, (STAKE * 2500) / 10_000, "g2 slashed at its own 25%");
        assertEq(lost1, lost2 * 2, "the ratio is the rate ratio, nothing else");
    }

    /// @notice REGRESSION. A zero rate means "this approver underwrote nothing"
    ///         — a commitment released by a vote change, or an approval that
    ///         landed after coverage was already met. It must NOT pass through
    ///         the severity envelope: `Math.max(0, minSlashBps)` would floor it
    ///         to `minSlashBps` and slash a guardian who owes nothing.
    function test_zeroRateApproverIsNotSlashedAtAll() public {
        uint256 before1 = swood.guardianStake(g1);
        uint256 before2 = swood.guardianStake(g2);

        vm.prank(slasher);
        swood.slashToEscrow(bytes32("case"), openedAt, _pair(g1, g2), _rates(0, 5000), address(vault), snapTs);

        assertEq(swood.guardianStake(g1), before1, "zero rate takes nothing, not minSlashBps");
        assertEq(before2 - swood.guardianStake(g2), (STAKE * 5000) / 10_000, "the other is untouched by the skip");
    }

    /// @notice The envelope still binds every NON-ZERO rate. A rate under the
    ///         floor is raised: the floor governs how lightly a guilty approver
    ///         may be let off, and per-approver rates must not become a way to
    ///         under-punish one member of a batch.
    function test_nonZeroRateBelowTheFloorIsRaisedToMinSlashBps() public {
        uint256 before1 = swood.guardianStake(g1);

        vm.prank(slasher);
        swood.slashToEscrow(bytes32("case"), openedAt, _pair(g1, g2), _rates(1, 0), address(vault), snapTs);

        assertEq(before1 - swood.guardianStake(g1), (STAKE * MIN_SLASH_BPS) / 10_000, "1 bp floored to the minimum");
    }

    /// @notice ...and a rate over the ceiling is capped, per element. Hoisting
    ///         the clamp out of the loop would let one approver's rate set the
    ///         envelope for the whole batch.
    function test_rateAboveTheCeilingIsCappedPerElement() public {
        uint256 before1 = swood.guardianStake(g1);
        uint256 before2 = swood.guardianStake(g2);

        vm.prank(slasher);
        swood.slashToEscrow(bytes32("case"), openedAt, _pair(g1, g2), _rates(10_000, 2000), address(vault), snapTs);

        assertEq(before1 - swood.guardianStake(g1), (STAKE * MAX_SLASH_BPS) / 10_000, "g1 capped at the ceiling");
        assertEq(before2 - swood.guardianStake(g2), (STAKE * 2000) / 10_000, "g2 keeps its own sub-ceiling rate");
    }

    /// @notice Positional alignment is the ONLY thing binding a guardian to
    ///         their rate, so a length mismatch is a caller bug rather than
    ///         something to absorb.
    function test_lengthMismatchReverts() public {
        uint256[] memory short = new uint256[](1);
        short[0] = 5000;

        vm.prank(slasher);
        vm.expectRevert(IStakedWood.SlashBpsLengthMismatch.selector);
        swood.slashToEscrow(bytes32("case"), openedAt, _pair(g1, g2), short, address(vault), snapTs);
    }

    // ── Option C: what the coverage number actually guarantees ────────────

    /// @notice THE §2 INEQUALITY, MEASURED RATHER THAN ASSERTED.
    ///
    ///         The review flagged that `slashableBondUsd` is documented as
    ///         "what a 100% verdict can reach" while no conviction path slashes
    ///         100%, so the booked number overstates recovery. Under the
    ///         per-approver rates this is no longer true, and the reason is a
    ///         discount asymmetry worth pinning down:
    ///
    ///           booked capacity = own + inbound * (C / 10_000)   <- DISCOUNTED
    ///           slash           = own * rate + inbound * min(rate, C)
    ///
    ///         The ledger values delegated stake at the cap `C`; the slash
    ///         applies `C` to the UNDISCOUNTED pool. So recovery meets or beats
    ///         the allocation, and the margin grows with delegation. This test
    ///         measures actual WOOD burned, values it at the ledger's own price,
    ///         and compares against what the ledger said each approver owed.
    ///
    ///         Both sides of the cap are exercised: g1 carries delegation (so
    ///         `rate` runs against the capped leg), g2 is own-stake only (the
    ///         degenerate case where recovery should land exactly on the
    ///         allocation, with no margin to hide a shortfall).
    function test_recoveryCoversEveryApproversAllocation() public {
        // ── A real ledger over the real sWOOD in this fixture.
        ExposureLedger ledger = new ExposureLedger(owner, address(swood), 28 days);
        address asset = makeAddr("propAsset");
        vm.mockCall(asset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        PropGovernor gov = new PropGovernor(address(new PropVault(asset)));
        address ledgerRegistry = makeAddr("ledgerRegistry");

        vm.startPrank(owner);
        ledger.setAssetFeed(asset, address(new PropFeed()), 365 days);
        ledger.setGuardianRegistry(ledgerRegistry);
        ledger.setWoodUsdPrice(0.05e8); // $0.05/WOOD
        vm.stopPrank();

        // ── g1 attracts delegation; g2 does not. Same own stake, so any
        //    difference in outcome is the delegated leg alone.
        vm.prank(owner);
        swood.setDelegationEnabled(true); // owner flag, off by default

        address delegator = makeAddr("delegator");
        wood.mint(delegator, 100_000e18);
        vm.startPrank(delegator);
        wood.approve(address(swood), type(uint256).max);
        swood.delegateStake(g1, 40_000e18);
        vm.stopPrank();
        assertGt(swood.delegatedInbound(g1), 0, "fixture: g1 really has inbound delegation");
        assertEq(swood.delegatedInbound(g2), 0, "fixture: g2 is own-stake only");

        // ── Coverage both must jointly back.
        gov.set(1_200e6); // $1,200
        vm.startPrank(ledgerRegistry);
        ledger.recordApproval(address(gov), 1, g1);
        ledger.recordApproval(address(gov), 1, g2);
        vm.stopPrank();

        uint256 owed1 = ledger.allocatedUsd(address(gov), 1, g1);
        uint256 owed2 = ledger.allocatedUsd(address(gov), 1, g2);
        assertGt(owed1, 0, "g1 carries a share");
        assertGt(owed2, 0, "g2 carries a share");

        // ── Convict, at the rates the ledger itself derived.
        (address[] memory accused, uint256[] memory rates) = ledger.slashBpsFor(address(gov), 1);
        uint256 own1Before = swood.guardianStake(g1);
        uint256 own2Before = swood.guardianStake(g2);
        uint256 pool1Before = swood.delegatedInbound(g1);

        vm.prank(slasher);
        swood.slashToEscrow(bytes32("verdict"), openedAt, accused, rates, address(vault), snapTs);

        // ── Value the WOOD actually taken at the ledger's own price.
        uint256 taken1 = (own1Before - swood.guardianStake(g1)) + (pool1Before - swood.delegatedInbound(g1));
        uint256 taken2 = own2Before - swood.guardianStake(g2);
        uint256 recovered1 = (taken1 * 0.05e8) / 1e8;
        uint256 recovered2 = (taken2 * 0.05e8) / 1e8;

        assertGe(recovered1, owed1, "delegated approver: recovery covers the allocation");
        assertGe(recovered2, owed2, "own-stake approver: recovery covers the allocation");

        // The margin is the discount asymmetry, and it shows up only where
        // delegation does — which is the mechanism, not a rounding artefact.
        assertGt(recovered1, owed1, "delegation creates genuine surplus");
    }

    /// @notice THE REASON THE CHANGE EXISTS. A partial rate leaves bond behind,
    ///         so a second concurrent conviction against the same guardian still
    ///         recovers. Under a flat ceiling slash the first case took
    ///         everything and every later case recovered nothing — which is why
    ///         booked coverage could not net across proposals.
    function test_partialRateLeavesBondForASecondConviction() public {
        uint256 start = swood.guardianStake(g1);

        vm.prank(slasher);
        (uint256 firstTotal,) =
            swood.slashToEscrow(bytes32("case-1"), openedAt, _pair(g1, g2), _rates(3000, 0), address(vault), snapTs);
        assertGt(firstTotal, 0, "first conviction recovers");

        uint256 afterFirst = swood.guardianStake(g1);
        assertGt(afterFirst, 0, "bond survives the first conviction");

        // A later verdict, anchored after the first settled. `vm.getBlockTimestamp()`
        // is re-read rather than cached: under this repo's optimizer settings a
        // local `uint256 t = block.timestamp` taken before a warp silently reads
        // the POST-warp value.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 secondOpenedAt = vm.getBlockTimestamp();

        vm.prank(slasher);
        (uint256 secondTotal,) = swood.slashToEscrow(
            bytes32("case-2"), secondOpenedAt, _pair(g1, g2), _rates(3000, 0), address(vault), snapTs
        );

        assertGt(secondTotal, 0, "the SECOND conviction also recovers -- coverage nets");
        assertLt(swood.guardianStake(g1), afterFirst, "and it came from the same guardian");
        assertLt(swood.guardianStake(g1), start, "cumulative loss across both cases");
    }
}
