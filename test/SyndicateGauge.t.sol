// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGauge} from "../src/SyndicateGauge.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @title SyndicateGauge unit tests
/// @notice Coverage for the gauge that receives WOOD emissions, splits them
///         into vault-rewards and LP-rewards, and forwards the vault slice to
///         `VaultRewardsDistributor.depositRewards`. V1 disables the LP slice
///         (`getLPRewardPercentage` always returns 0; `_calculateLPReward`
///         always returns 0); the LP-bootstrap branch and the
///         `rescueStuckLPRewards` recovery path are still tested for the
///         bytecode that exists.
contract SyndicateGaugeTest is Test {
    SyndicateGauge gauge;
    ERC20Mock wood;
    MockVoter voter;
    MockDistributor distributor;

    address constant SYNDICATE_VAULT = address(0xBEEF);
    address constant UNI_POOL = address(0xC0FE);
    address minter = makeAddr("minter");
    address owner = makeAddr("owner");
    address randomLP = makeAddr("randomLP");

    uint256 constant SYNDICATE_ID = 7;
    uint256 constant LP_TOKEN_ID = 99;

    event EmissionReceived(uint256 indexed epoch, uint256 amount, address indexed from);
    event EmissionDistributed(uint256 indexed epoch, uint256 vaultRewards, uint256 lpRewards, uint256 totalDistributed);
    event LPRewardsClaimed(address indexed lp, uint256 amount, uint256 epoch);

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        voter = new MockVoter();
        distributor = new MockDistributor(address(wood));

        gauge = new SyndicateGauge({
            _syndicateId: SYNDICATE_ID,
            _syndicateVault: SYNDICATE_VAULT,
            _vaultRewardsDistributor: address(distributor),
            _uniswapPool: UNI_POOL,
            _lpTokenId: LP_TOKEN_ID,
            _wood: address(wood),
            _voter: address(voter),
            _minter: minter,
            _owner: owner
        });

        // Fund the minter so it can transferFrom into the gauge.
        wood.mint(minter, 10_000_000e18);
        vm.prank(minter);
        wood.approve(address(gauge), type(uint256).max);
    }

    // ──────────────────────── constructor / immutables ────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(gauge.syndicateId(), SYNDICATE_ID);
        assertEq(gauge.syndicateVault(), SYNDICATE_VAULT);
        assertEq(gauge.vaultRewardsDistributor(), address(distributor));
        assertEq(gauge.uniswapPool(), UNI_POOL);
        assertEq(gauge.lpTokenId(), LP_TOKEN_ID);
        assertEq(address(gauge.wood()), address(wood));
        assertEq(address(gauge.voter()), address(voter));
        assertEq(gauge.minter(), minter);
        assertEq(gauge.owner(), owner);
        assertEq(gauge.LP_BOOTSTRAP_EPOCHS(), 12);
    }

    // ──────────────────────── receiveEmission ────────────────────────

    function test_receiveEmission_onlyMinter() public {
        vm.prank(randomLP);
        vm.expectRevert(SyndicateGauge.NotAuthorized.selector);
        gauge.receiveEmission(1, 1_000e18);
    }

    function test_receiveEmission_zeroAmountReverts() public {
        vm.prank(minter);
        vm.expectRevert(SyndicateGauge.NoEmissionToDistribute.selector);
        gauge.receiveEmission(1, 0);
    }

    function test_receiveEmission_pullsTokensAndStoresSplit() public {
        uint256 amount = 1_000e18;
        uint256 epoch = 5;

        vm.expectEmit(true, true, false, true, address(gauge));
        emit EmissionReceived(epoch, amount, minter);

        vm.prank(minter);
        gauge.receiveEmission(epoch, amount);

        assertEq(wood.balanceOf(address(gauge)), amount, "tokens pulled");
        SyndicateGauge.EmissionDistribution memory d = gauge.getEmissionDistribution(epoch);
        assertEq(d.totalReceived, amount);
        // V1: getLPRewardPercentage returns 0 — vault gets 100%, LPs get 0.
        assertEq(d.vaultRewards, amount, "100% to vault under V1 LP-disabled");
        assertEq(d.lpRewards, 0, "0% to LPs under V1");
        assertEq(d.epoch, epoch);
        assertFalse(d.distributed);
        assertEq(gauge.getTotalEmissionsReceived(), amount, "total accumulator updated");
    }

    function test_receiveEmission_doubleReceiveOnDistributedEpochReverts() public {
        vm.prank(minter);
        gauge.receiveEmission(1, 1_000e18);
        gauge.distributeEmission(1);

        vm.prank(minter);
        vm.expectRevert(SyndicateGauge.DistributionAlreadyExecuted.selector);
        gauge.receiveEmission(1, 500e18);
    }

    function test_receiveEmission_acrossMultipleEpochsAccumulatesTotal() public {
        vm.startPrank(minter);
        gauge.receiveEmission(1, 100e18);
        gauge.receiveEmission(2, 200e18);
        gauge.receiveEmission(3, 300e18);
        vm.stopPrank();
        assertEq(gauge.getTotalEmissionsReceived(), 600e18);
    }

    // ──────────────────────── distributeEmission ────────────────────────

    function test_distributeEmission_forwardsVaultSliceToDistributor() public {
        uint256 amount = 1_000e18;
        vm.prank(minter);
        gauge.receiveEmission(1, amount);

        vm.expectEmit(true, false, false, true, address(gauge));
        emit EmissionDistributed(1, amount, 0, amount);

        gauge.distributeEmission(1);

        assertEq(wood.balanceOf(address(distributor)), amount, "full slice landed at distributor");
        assertEq(distributor.lastEpoch(), 1);
        assertEq(distributor.lastAmount(), amount);
        SyndicateGauge.EmissionDistribution memory d = gauge.getEmissionDistribution(1);
        assertTrue(d.distributed);
    }

    function test_distributeEmission_idempotentReverts() public {
        vm.prank(minter);
        gauge.receiveEmission(1, 1_000e18);
        gauge.distributeEmission(1);

        vm.expectRevert(SyndicateGauge.DistributionAlreadyExecuted.selector);
        gauge.distributeEmission(1);
    }

    function test_distributeEmission_emptyEpochReverts() public {
        vm.expectRevert(SyndicateGauge.NoEmissionToDistribute.selector);
        gauge.distributeEmission(42);
    }

    // ──────────────────────── claimLPRewards (always reverts in V1, T-C1) ────────────────────────

    function test_claimLPRewards_revertsDuringBootstrap_zeroLPSliceUnderV1() public {
        // Bootstrap window active (epoch 1 <= 12), but lpRewards == 0 under V1
        // so the call hits the NoEmissionToDistribute branch.
        voter.setEpoch(1);
        vm.prank(minter);
        gauge.receiveEmission(1, 1_000e18);
        gauge.distributeEmission(1);

        vm.prank(randomLP);
        vm.expectRevert(SyndicateGauge.NoEmissionToDistribute.selector);
        gauge.claimLPRewards(1);
    }

    function test_claimLPRewards_revertsAfterBootstrap_invalidEpochGate() public {
        voter.setEpoch(13); // past LP bootstrap
        vm.prank(minter);
        gauge.receiveEmission(13, 1_000e18);
        gauge.distributeEmission(13);

        vm.prank(randomLP);
        vm.expectRevert(SyndicateGauge.InvalidEpoch.selector);
        gauge.claimLPRewards(13);
    }

    function test_claimLPRewards_revertsBeforeDistribute() public {
        voter.setEpoch(1);
        vm.prank(minter);
        gauge.receiveEmission(1, 1_000e18);

        vm.prank(randomLP);
        // Branch reached: distribution.distributed == false → DistributionAlreadyExecuted
        // (the contract reuses the error here despite the misleading name).
        vm.expectRevert(SyndicateGauge.DistributionAlreadyExecuted.selector);
        gauge.claimLPRewards(1);
    }

    // ──────────────────────── rescueStuckLPRewards ────────────────────────

    function test_rescueStuckLPRewards_onlyOwner() public {
        vm.prank(randomLP);
        vm.expectRevert();
        gauge.rescueStuckLPRewards(1, randomLP);
    }

    function test_rescueStuckLPRewards_zeroRecipientReverts() public {
        vm.prank(owner);
        vm.expectRevert(SyndicateGauge.NotAuthorized.selector);
        gauge.rescueStuckLPRewards(1, address(0));
    }

    function test_rescueStuckLPRewards_zeroAmountReverts() public {
        // No emission received for this epoch → lpRewards == 0.
        vm.prank(owner);
        vm.expectRevert(SyndicateGauge.NoEmissionToDistribute.selector);
        gauge.rescueStuckLPRewards(1, owner);
    }

    function test_rescueStuckLPRewards_drainsSlice() public {
        // Production: receiveEmission routes 100% to vault under V1
        // (getLPRewardPercentage returns 0), so no live path produces a
        // non-zero lpRewards slice. This test models an already-stuck slice
        // that landed under a prior bootstrap schedule.
        //
        // EmissionDistribution struct layout (5 slots):
        //   +0 totalReceived  +1 vaultRewards  +2 lpRewards  +3 epoch  +4 distributed
        //
        // We locate the `_distributions` mapping base layout-resiliently by
        // searching for the unique `totalReceived` value we just wrote, then
        // mutate the +2 (lpRewards) slot. This avoids hardcoding the
        // mapping's storage slot ordinal, which shifts whenever
        // SyndicateGauge's inheritance chain or storage layout changes.
        uint256 epoch = 1;
        vm.prank(minter);
        gauge.receiveEmission(epoch, 1_000e18);
        gauge.distributeEmission(epoch);
        wood.mint(address(gauge), 100e18); // back the synthetic stuck slice

        bytes32 mappingBase;
        for (uint256 s = 0; s < 50; s++) {
            bytes32 candidate = keccak256(abi.encode(epoch, s));
            if (vm.load(address(gauge), candidate) == bytes32(uint256(1_000e18))) {
                mappingBase = candidate;
                break;
            }
        }
        require(mappingBase != bytes32(0), "couldn't locate _distributions mapping slot");
        vm.store(address(gauge), bytes32(uint256(mappingBase) + 2), bytes32(uint256(100e18)));

        // Sanity: rescue path now sees the synthetic slice.
        SyndicateGauge.EmissionDistribution memory d = gauge.getEmissionDistribution(epoch);
        assertEq(d.lpRewards, 100e18, "synthetic stuck slice present");

        uint256 ownerBalBefore = wood.balanceOf(owner);
        vm.expectEmit(true, false, false, true, address(gauge));
        emit LPRewardsClaimed(owner, 100e18, epoch);
        vm.prank(owner);
        gauge.rescueStuckLPRewards(epoch, owner);

        assertEq(wood.balanceOf(owner) - ownerBalBefore, 100e18, "rescued amount transferred");
        d = gauge.getEmissionDistribution(epoch);
        assertEq(d.lpRewards, 0, "lpRewards zeroed after rescue (idempotent guard)");

        // Re-rescue reverts because slice is now zero.
        vm.prank(owner);
        vm.expectRevert(SyndicateGauge.NoEmissionToDistribute.selector);
        gauge.rescueStuckLPRewards(epoch, owner);
    }

    // ──────────────────────── views ────────────────────────

    function test_isLPBootstrappingActive_boundary() public {
        voter.setEpoch(12);
        assertTrue(gauge.isLPBootstrappingActive());
        voter.setEpoch(13);
        assertFalse(gauge.isLPBootstrappingActive());
    }

    function test_getLPRewardPercentage_alwaysZeroV1() public view {
        assertEq(gauge.getLPRewardPercentage(0), 0);
        assertEq(gauge.getLPRewardPercentage(1), 0);
        assertEq(gauge.getLPRewardPercentage(12), 0);
        assertEq(gauge.getLPRewardPercentage(1000), 0);
    }

    function test_getPendingLPRewards_alwaysZeroV1() public {
        vm.prank(minter);
        gauge.receiveEmission(1, 1_000e18);
        gauge.distributeEmission(1);
        // V1: _calculateLPReward returns 0 unconditionally.
        assertEq(gauge.getPendingLPRewards(randomLP, 1), 0);
    }
}

contract MockVoter {
    uint256 private _epoch = 1;

    function setEpoch(uint256 e) external {
        _epoch = e;
    }

    function currentEpoch() external view returns (uint256) {
        return _epoch;
    }
}

contract MockDistributor {
    address public immutable wood;
    uint256 public lastEpoch;
    uint256 public lastAmount;

    constructor(address _wood) {
        wood = _wood;
    }

    function depositRewards(uint256 epoch, uint256 amount) external {
        lastEpoch = epoch;
        lastAmount = amount;
        // Simulate transferFrom.
        // The gauge approves first, then calls. We pull the tokens.
        (bool ok,) = wood.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
        );
        require(ok, "transferFrom failed");
    }
}
