// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LighterPerpStrategy} from "../src/strategies/LighterPerpStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {MockZkLighter} from "./mocks/MockZkLighter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";

contract LighterPerpStrategyTest is Test {
    // Constant venue addresses hardcoded in the strategy (4663 + fork share them).
    address internal constant ZK = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;
    address internal constant USDG_ADDR = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    LighterPerpStrategy internal template;
    LighterPerpStrategy internal strategy;
    ERC20Mock internal usdg;
    MockZkLighter internal zk;

    address internal vault = makeAddr("vault");
    address internal proposer = makeAddr("proposer");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant DEPOSIT = 20_000e6; // 20k USDG (6dp)
    uint8 internal constant API_KEY_INDEX = 2;

    function setUp() public {
        // Etch the mock USDG + mock zkLighter at the strategy's constant addresses.
        ERC20Mock usdgImpl = new ERC20Mock("USDG", "USDG", 6);
        vm.etch(USDG_ADDR, address(usdgImpl).code);
        usdg = ERC20Mock(USDG_ADDR);

        MockZkLighter zkImpl = new MockZkLighter(IERC20(USDG_ADDR));
        vm.etch(ZK, address(zkImpl).code);
        zk = MockZkLighter(ZK);

        template = new LighterPerpStrategy();
        strategy = LighterPerpStrategy(Clones.clone(address(template)));
        strategy.initialize(vault, proposer, _initData(DEPOSIT));

        usdg.mint(vault, DEPOSIT);
        vm.prank(vault);
        usdg.approve(address(strategy), type(uint256).max);
    }

    // ── helpers ──

    function _validPubKey() internal pure returns (bytes memory) {
        // Exactly 40 bytes: 32 + 8.
        return abi.encodePacked(bytes32(uint256(0x1111)), bytes8(uint64(0x2222)));
    }

    function _markets() internal pure returns (uint16[] memory m) {
        m = new uint16[](2);
        m[0] = 1;
        m[1] = 2;
    }

    function _initData(uint256 depositAmt) internal pure returns (bytes memory) {
        return abi.encode(_validPubKey(), API_KEY_INDEX, _markets(), depositAmt);
    }

    function _clone(bytes memory data) internal returns (LighterPerpStrategy s) {
        s = LighterPerpStrategy(Clones.clone(address(template)));
        s.initialize(vault, proposer, data);
    }

    function _executeFirst() internal {
        vm.prank(vault);
        strategy.execute();
    }

    // ==================== INITIALIZATION ====================

    function test_initialize() public view {
        assertEq(strategy.vault(), vault);
        assertEq(strategy.proposer(), proposer);
        assertEq(strategy.apiKeyPubKey(), _validPubKey());
        assertEq(strategy.apiKeyIndex(), API_KEY_INDEX);
        assertEq(strategy.markets(0), 1);
        assertEq(strategy.markets(1), 2);
        assertEq(strategy.depositAmount(), DEPOSIT);
        assertEq(strategy.settled(), false);
        assertEq(strategy.returnsInitiatedAt(), 0);
        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Pending));
        assertEq(strategy.name(), "LighterPerp");
    }

    function test_initialize_twice_reverts() public {
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        strategy.initialize(vault, proposer, _initData(DEPOSIT));
    }

    function test_initialize_badPubKeyLen_reverts() public {
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(bytes(hex"1234"), API_KEY_INDEX, _markets(), DEPOSIT);
        vm.expectRevert(LighterPerpStrategy.InvalidPubKey.selector);
        s.initialize(vault, proposer, data);
    }

    function test_initialize_apiKeyIndexTooLow_reverts() public {
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_validPubKey(), uint8(1), _markets(), DEPOSIT);
        vm.expectRevert(LighterPerpStrategy.InvalidApiKeyIndex.selector);
        s.initialize(vault, proposer, data);
    }

    function test_initialize_apiKeyIndexTooHigh_reverts() public {
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_validPubKey(), uint8(255), _markets(), DEPOSIT);
        vm.expectRevert(LighterPerpStrategy.InvalidApiKeyIndex.selector);
        s.initialize(vault, proposer, data);
    }

    function test_initialize_emptyMarkets_reverts() public {
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_validPubKey(), API_KEY_INDEX, new uint16[](0), DEPOSIT);
        vm.expectRevert(LighterPerpStrategy.NoMarkets.selector);
        s.initialize(vault, proposer, data);
    }

    function test_initialize_marketTooHigh_reverts() public {
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        uint16[] memory m = new uint16[](1);
        m[0] = 300; // > 254
        bytes memory data = abi.encode(_validPubKey(), API_KEY_INDEX, m, DEPOSIT);
        vm.expectRevert(LighterPerpStrategy.InvalidMarket.selector);
        s.initialize(vault, proposer, data);
    }

    function test_initialize_zeroDeposit_allowsDynamicAll() public {
        LighterPerpStrategy s = _clone(_initData(0));
        assertEq(s.depositAmount(), 0);
    }

    // ==================== EXECUTE ====================

    function test_execute_pullsAndDepositsAndRegisters() public {
        _executeFirst();

        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Executed));
        assertEq(usdg.balanceOf(vault), 0);
        assertEq(usdg.balanceOf(address(strategy)), 0); // forwarded into zkLighter
        assertEq(usdg.balanceOf(ZK), DEPOSIT);
        assertEq(zk.depositCount(), 1);
        assertTrue(strategy.accountIndex() != 0); // synchronous registration
        assertEq(strategy.accountIndex(), 623);
    }

    function test_execute_notVault_reverts() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.execute();
    }

    function test_execute_twice_reverts() public {
        _executeFirst();
        vm.prank(vault);
        vm.expectRevert(BaseStrategy.AlreadyExecuted.selector);
        strategy.execute();
    }

    function test_execute_dynamicAll_usesFullVaultBalance() public {
        // The main `strategy` (from setUp) never executed, so ZK starts empty and
        // the vault still holds its full DEPOSIT; dynamic-all pulls all of it.
        LighterPerpStrategy s = _clone(_initData(0));
        usdg.mint(vault, 5_000e6);
        uint256 vaultBal = usdg.balanceOf(vault); // DEPOSIT + 5_000e6
        vm.prank(vault);
        usdg.approve(address(s), type(uint256).max);

        vm.prank(vault);
        s.execute();

        assertEq(usdg.balanceOf(vault), 0);
        assertEq(usdg.balanceOf(ZK), vaultBal);
        assertEq(s.depositAmount(), 0); // dynamic mode is sticky
    }

    function test_execute_belowMinDeposit_reverts() public {
        LighterPerpStrategy s = _clone(_initData(0));
        // Drain the vault, then leave under 1 USDG. Read the balance BEFORE
        // pranking — an arg-position call would otherwise consume the prank.
        uint256 bal = usdg.balanceOf(vault);
        vm.prank(vault);
        usdg.transfer(address(0xdead), bal);
        usdg.mint(vault, 0.5e6); // < 1 USDG
        vm.prank(vault);
        usdg.approve(address(s), type(uint256).max);

        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.DepositTooSmall.selector);
        s.execute();
    }

    // ==================== REGISTER AGENT KEY ====================

    function test_registerAgentKey_beforeRegistration_reverts() public {
        // No execute yet ⇒ account index still 0.
        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.AccountNotRegistered.selector);
        strategy.registerAgentKey();
    }

    function test_registerAgentKey_afterExecute_works() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.registerAgentKey();
        assertEq(zk.changePubKeyCount(), 1);
        assertEq(zk.lastPubKey(), _validPubKey());
    }

    function test_registerAgentKey_notProposer_reverts() public {
        _executeFirst();
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.registerAgentKey();
    }

    function test_registerAgentKey_idempotent() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.registerAgentKey();
        strategy.registerAgentKey();
        vm.stopPrank();
        assertEq(zk.changePubKeyCount(), 2);
    }

    // ==================== UPDATE PARAMS (guardrails) ====================

    function test_updateParams_cancelAll() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(1), bytes("")));
        assertEq(zk.cancelAllCount(), 1);
    }

    function test_updateParams_closeMarket() public {
        _executeFirst();
        bytes memory args = abi.encode(uint16(1), uint32(1), uint8(1));
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(2), args));
        assertEq(zk.createOrderCount(), 1);
        (uint48 acct, uint16 market, uint48 baseAmount, uint32 price, uint8 isAsk, uint8 orderType) = zk.lastOrder();
        assertEq(acct, 623);
        assertEq(market, 1);
        assertEq(baseAmount, 0); // full-position close
        assertEq(price, 1);
        assertEq(isAsk, 1);
        assertEq(orderType, 1); // Market
    }

    function test_updateParams_rotateKey() public {
        _executeFirst();
        bytes memory newKey = abi.encodePacked(bytes32(uint256(0x9999)), bytes8(uint64(0x8888)));
        bytes memory args = abi.encode(newKey);
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(3), args));
        assertEq(zk.changePubKeyCount(), 1);
        assertEq(zk.lastPubKey(), newKey);
        assertEq(strategy.apiKeyPubKey(), newKey); // stored key updated
    }

    function test_updateParams_rotateKey_badLen_reverts() public {
        _executeFirst();
        bytes memory args = abi.encode(bytes(hex"1234"));
        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.InvalidPubKey.selector);
        strategy.updateParams(abi.encode(uint8(3), args));
    }

    function test_updateParams_withdraw() public {
        _executeFirst();
        bytes memory args = abi.encode(uint64(5_000e6));
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(4), args));
        assertEq(zk.withdrawCount(), 1);
        assertEq(zk.lastWithdrawTicks(), 5_000e6);
    }

    function test_updateParams_registerKey() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(5), bytes("")));
        assertEq(zk.changePubKeyCount(), 1);
    }

    function test_updateParams_invalidAction_reverts() public {
        _executeFirst();
        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.InvalidAction.selector);
        strategy.updateParams(abi.encode(uint8(99), bytes("")));
    }

    function test_updateParams_notProposer_reverts() public {
        _executeFirst();
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.updateParams(abi.encode(uint8(1), bytes("")));
    }

    function test_updateParams_notExecuted_reverts() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.updateParams(abi.encode(uint8(1), bytes("")));
    }

    // ==================== INITIATE RETURN ====================

    function test_initiateReturn_closesBothSidesAndWithdraws() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.initiateReturn(uint64(DEPOSIT));

        // 2 markets × 2 sides (sell-close + buy-close) = 4 createOrder calls.
        assertEq(zk.createOrderCount(), 4);
        assertEq(zk.cancelAllCount(), 1);
        assertEq(zk.withdrawCount(), 1);
        assertEq(zk.lastWithdrawTicks(), uint64(DEPOSIT));
        assertEq(strategy.returnsInitiatedAt(), block.number);
    }

    function test_initiateReturn_zeroTicks_skipsWithdraw() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.initiateReturn(0);
        assertEq(zk.withdrawCount(), 0);
        assertEq(strategy.returnsInitiatedAt(), block.number);
    }

    function test_initiateReturn_idempotent() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn(uint64(DEPOSIT));
        strategy.initiateReturn(uint64(DEPOSIT)); // no-op
        vm.stopPrank();
        assertEq(zk.cancelAllCount(), 1); // not re-run
    }

    function test_initiateReturn_notExecuted_reverts() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.initiateReturn(uint64(DEPOSIT));
    }

    function test_initiateReturn_nonProposerBeforeDuration_reverts() public {
        (LighterPerpStrategy s,,) = _deployWithMockVault(block.timestamp, 100 days);
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        s.initiateReturn(uint64(DEPOSIT));
    }

    function test_initiateReturn_anyoneAfterDuration_works() public {
        (LighterPerpStrategy s,,) = _deployWithMockVault(block.timestamp, 100 days);
        vm.warp(block.timestamp + 100 days + 1);
        vm.prank(attacker);
        s.initiateReturn(uint64(DEPOSIT)); // permissionless after duration
        assertEq(s.returnsInitiatedAt(), block.number);
    }

    // ==================== SETTLE (two-phase) ====================

    function _initiateFirst() internal {
        _executeFirst();
        vm.prank(proposer);
        strategy.initiateReturn(uint64(DEPOSIT));
    }

    function test_settle_beforeInitiate_reverts() public {
        _executeFirst();
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.ReturnsNotInitiated.selector);
        strategy.settle();
    }

    function test_settle_sameBlockAsInitiate_reverts() public {
        _initiateFirst();
        assertEq(strategy.returnsInitiatedAt(), block.number);
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.SettleTooSoon.selector);
        strategy.settle();
    }

    function test_settle_bothZero_reverts() public {
        // Initiated, a block later, but nothing matured and nothing held.
        _initiateFirst();
        vm.roll(block.number + 1);
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.NothingToSettle.selector);
        strategy.settle();
    }

    function test_settle_claimsPendingAndPushes() public {
        _initiateFirst();
        zk.setPendingBalance(address(strategy), uint128(DEPOSIT)); // simulate maturity
        vm.roll(block.number + 1);

        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(vault);
        strategy.settle();

        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Settled));
        assertEq(strategy.settled(), true);
        assertEq(zk.claimCount(), 1);
        assertEq(usdg.balanceOf(vault) - vaultBefore, DEPOSIT); // clean round-trip
        assertEq(usdg.balanceOf(address(strategy)), 0);
    }

    function test_settle_preClaimedByThirdParty_doesNotRevert() public {
        _initiateFirst();
        zk.setPendingBalance(address(strategy), uint128(DEPOSIT));
        vm.roll(block.number + 1);

        // A third party permissionlessly claims the matured balance INTO the strategy.
        vm.prank(attacker);
        zk.withdrawPendingBalance(address(strategy), 3, uint128(DEPOSIT));
        assertEq(usdg.balanceOf(address(strategy)), DEPOSIT);
        assertEq(strategy.pendingBalance(), 0);

        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(vault);
        strategy.settle(); // pending==0 but bal>0 → proceeds
        assertEq(usdg.balanceOf(vault) - vaultBefore, DEPOSIT);
        assertEq(zk.claimCount(), 1); // settle did not re-claim
    }

    function test_settle_notVault_reverts() public {
        _initiateFirst();
        vm.roll(block.number + 1);
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.settle();
    }

    // ==================== RESIDUAL RECOVERY ====================

    function _settleClean() internal {
        _initiateFirst();
        zk.setPendingBalance(address(strategy), uint128(DEPOSIT));
        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();
    }

    function test_recoverResiduals_beforeSettle_reverts() public {
        _executeFirst();
        vm.expectRevert(LighterPerpStrategy.NotSweepable.selector);
        strategy.recoverResiduals();
    }

    function test_recoverResiduals_claimsLateMaturityToVault() public {
        _settleClean();
        // A late withdrawal matures after settlement.
        usdg.mint(ZK, 500e6); // fund the venue for the extra claim
        zk.setPendingBalance(address(strategy), 500e6);

        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(attacker); // permissionless
        strategy.recoverResiduals();

        assertEq(usdg.balanceOf(vault) - vaultBefore, 500e6);
        assertEq(strategy.cumulativeSwept(), 500e6);
    }

    function test_sweepToVault_beforeSettle_reverts() public {
        _executeFirst();
        vm.expectRevert(LighterPerpStrategy.NotSweepable.selector);
        strategy.sweepToVault();
    }

    function test_sweepToVault_pushesHeldBalance() public {
        _settleClean();
        // USDG lands directly on the strategy (e.g. a third party claimed here).
        usdg.mint(address(strategy), 250e6);

        uint256 vaultBefore = usdg.balanceOf(vault);
        strategy.sweepToVault();
        assertEq(usdg.balanceOf(vault) - vaultBefore, 250e6);
        assertEq(strategy.cumulativeSwept(), 250e6);
        assertEq(usdg.balanceOf(address(strategy)), 0);
    }

    function test_sweepToVault_zeroBalance_isNoOp() public {
        _settleClean();
        uint256 vaultBefore = usdg.balanceOf(vault);
        strategy.sweepToVault();
        assertEq(usdg.balanceOf(vault), vaultBefore);
    }

    // ==================== FULL LIFECYCLE ====================

    function test_fullLifecycle() public {
        vm.prank(vault);
        strategy.execute();

        vm.prank(proposer);
        strategy.registerAgentKey();

        // Agent trades off-chain; proposer trims risk on-chain.
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(2), abi.encode(uint16(1), uint32(1), uint8(1))));

        vm.prank(proposer);
        strategy.initiateReturn(uint64(DEPOSIT));

        zk.setPendingBalance(address(strategy), uint128(DEPOSIT));
        vm.roll(block.number + 1);

        vm.prank(vault);
        strategy.settle();

        assertEq(strategy.settled(), true);
        assertEq(usdg.balanceOf(vault), DEPOSIT); // round-trips to the vault
    }

    // ── auth-path scaffolding ──

    function _deployWithMockVault(uint256 executedAt, uint256 duration)
        internal
        returns (LighterPerpStrategy s, MockVaultForLighter mv, MockGovernorForLighter mg)
    {
        mg = new MockGovernorForLighter();
        mg.setProposal(executedAt, duration);
        mv = new MockVaultForLighter(address(mg));

        s = LighterPerpStrategy(Clones.clone(address(template)));
        s.initialize(address(mv), proposer, _initData(DEPOSIT));

        usdg.mint(address(mv), DEPOSIT);
        vm.prank(address(mv));
        usdg.approve(address(s), type(uint256).max);
        vm.prank(address(mv));
        s.execute();
    }
}

// ── Minimal mocks for the initiateReturn auth path ──

contract MockVaultForLighter {
    address public governor;

    constructor(address gov) {
        governor = gov;
    }
}

contract MockGovernorForLighter {
    uint256 internal _executedAt;
    uint256 internal _duration;

    function setProposal(uint256 executedAt_, uint256 duration_) external {
        _executedAt = executedAt_;
        _duration = duration_;
    }

    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function getProposal(uint256) external view returns (ISyndicateGovernor.StrategyProposal memory p) {
        p.executedAt = _executedAt;
        p.strategyDuration = _duration;
    }
}
