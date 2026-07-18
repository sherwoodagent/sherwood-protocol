// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {TokenVesting} from "../../src/vesting/TokenVesting.sol";
import {VestingFactory} from "../../src/vesting/VestingFactory.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract VestingFactoryTest is Test {
    VestingFactory internal factory;
    ERC20Mock internal token;

    address internal owner = makeAddr("owner");
    address internal beneficiary = makeAddr("beneficiary");

    uint64 internal start;
    uint64 internal constant CLIFF = 180 days;
    uint64 internal constant DURATION = 365 days;
    uint256 internal constant GRANT = 1_000_000e18;

    function setUp() public {
        factory = new VestingFactory();
        token = new ERC20Mock("Wood", "WOOD", 18);
        token.mint(address(this), 10 * GRANT);
        token.approve(address(factory), type(uint256).max);
        start = uint64(vm.getBlockTimestamp());
    }

    function test_createVesting_deploysInitializedFundedClone() public {
        address wallet = factory.createVesting(owner, beneficiary, address(token), start, CLIFF, DURATION, true, GRANT);
        TokenVesting v = TokenVesting(wallet);
        assertEq(v.owner(), owner);
        assertEq(v.beneficiary(), beneficiary);
        assertEq(v.cliff(), start + CLIFF);
        assertTrue(v.cancelable());
        assertEq(token.balanceOf(wallet), GRANT);
        assertEq(v.totalAllocation(), GRANT);
    }

    function test_createVesting_registersWalletPerBeneficiary() public {
        address w1 = factory.createVesting(owner, beneficiary, address(token), start, CLIFF, DURATION, true, GRANT);
        address w2 = factory.createVesting(owner, beneficiary, address(token), start, 0, DURATION, false, GRANT);
        address[] memory wallets = factory.walletsOf(beneficiary);
        assertEq(wallets.length, 2);
        assertEq(wallets[0], w1);
        assertEq(wallets[1], w2);
        assertEq(factory.walletsOf(makeAddr("nobody")).length, 0);
    }

    function test_createVesting_emitsEvent() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(true, true, true, true);
        emit VestingFactory.VestingCreated(
            predicted, beneficiary, address(token), address(this), owner, GRANT, start, CLIFF, DURATION, true
        );
        address wallet = factory.createVesting(owner, beneficiary, address(token), start, CLIFF, DURATION, true, GRANT);
        assertEq(wallet, predicted);
    }

    function test_createVesting_revertsWithoutFunds() public {
        address broke = makeAddr("broke");
        vm.startPrank(broke);
        token.approve(address(factory), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, broke, 0, GRANT));
        factory.createVesting(owner, beneficiary, address(token), start, CLIFF, DURATION, true, GRANT);
        vm.stopPrank();
    }

    function test_createVesting_invalidParamsBubbleUp() public {
        vm.expectRevert(TokenVesting.CliffExceedsDuration.selector);
        factory.createVesting(owner, beneficiary, address(token), start, DURATION + 1, DURATION, true, GRANT);
    }

    function test_clone_isIndependentOfImplementation() public {
        address wallet = factory.createVesting(owner, beneficiary, address(token), start, 0, DURATION, true, GRANT);
        vm.warp(start + DURATION);
        TokenVesting(wallet).release();
        assertEq(token.balanceOf(beneficiary), GRANT);
        // Implementation itself holds no state/funds.
        assertEq(token.balanceOf(factory.implementation()), 0);
    }

    function test_implementation_cannotBeInitialized() public {
        // Hoist the view call: expectRevert applies to the NEXT call.
        TokenVesting impl = TokenVesting(factory.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner, beneficiary, address(token), start, CLIFF, DURATION, true);
    }

    function test_createVesting_zeroAmountIsUnfundedShell() public {
        address wallet = factory.createVesting(owner, beneficiary, address(token), start, CLIFF, DURATION, true, 0);
        TokenVesting v = TokenVesting(wallet);
        assertEq(token.balanceOf(wallet), 0);
        assertEq(v.totalAllocation(), 0);
        // Plain transfer funds the shell; allocation is balance-derived.
        token.mint(wallet, GRANT);
        assertEq(v.totalAllocation(), GRANT);
    }

    function test_createVesting_zeroAmountSkipsTransferFrom() public {
        // Discriminating: assert transferFrom is never called at all (count 0),
        // not merely that a zero-value pull happens to succeed.
        vm.expectCall(address(token), abi.encodeWithSelector(token.transferFrom.selector), 0);
        address stranger = makeAddr("stranger"); // never approved the factory
        vm.prank(stranger);
        address wallet = factory.createVesting(owner, beneficiary, address(token), start, 0, DURATION, true, 0);
        assertEq(token.balanceOf(wallet), 0);
    }
}
