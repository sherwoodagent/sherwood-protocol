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
    uint256 internal constant CHAIN_ROBINHOOD = 4663;

    LighterPerpStrategy internal template;
    LighterPerpStrategy internal strategy;
    ERC20Mock internal usdg;
    MockZkLighter internal zk;

    MockVaultForLighter internal vaultC;
    MockGovernorForLighter internal gov;
    address internal vault;
    address internal proposer = makeAddr("proposer");
    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant DEPOSIT = 20_000e6; // 20k USDG (6dp)
    uint8 internal constant API_KEY_INDEX = 2;
    uint256 internal constant DURATION = 100 days;

    function setUp() public {
        // The template constructor pins the venue chain (4663 mainnet / 9994663 fork).
        vm.chainId(CHAIN_ROBINHOOD);

        // Etch the mock USDG + mock zkLighter at the strategy's constant addresses.
        ERC20Mock usdgImpl = new ERC20Mock("USDG", "USDG", 6);
        vm.etch(USDG_ADDR, address(usdgImpl).code);
        usdg = ERC20Mock(USDG_ADDR);

        MockZkLighter zkImpl = new MockZkLighter(IERC20(USDG_ADDR));
        vm.etch(ZK, address(zkImpl).code);
        zk = MockZkLighter(ZK);

        template = new LighterPerpStrategy();

        gov = new MockGovernorForLighter();
        vaultC = new MockVaultForLighter(address(gov), owner);
        vault = address(vaultC);

        strategy = LighterPerpStrategy(Clones.clone(address(template)));
        strategy.initialize(vault, proposer, _initData(DEPOSIT));

        // Default: a live proposal bound to this strategy, executed now.
        gov.setActiveProposal(1);
        gov.setProposal(address(strategy), block.timestamp, DURATION);

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

    /// @dev Full happy-path unwind: close → queue the true balance → mature → settle.
    function _settleClean() internal {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();
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
        assertEq(strategy.queuedTicks(), 0);
        assertEq(strategy.returnedAssets(), 0);
        assertEq(strategy.shortfallAcknowledged(), false);
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

    // ── M2: unbounded / duplicated market list ──

    function test_initialize_marketsAtCap_ok() public {
        uint16[] memory m = new uint16[](16);
        for (uint16 i; i < 16; i++) {
            m[i] = i + 1;
        }
        LighterPerpStrategy s = _clone(abi.encode(_validPubKey(), API_KEY_INDEX, m, DEPOSIT));
        assertEq(s.markets(15), 16);
    }

    function test_initialize_tooManyMarkets_reverts() public {
        uint16[] memory m = new uint16[](17); // MAX_MARKETS + 1
        for (uint16 i; i < 17; i++) {
            m[i] = i + 1;
        }
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_validPubKey(), API_KEY_INDEX, m, DEPOSIT);
        vm.expectRevert(LighterPerpStrategy.TooManyMarkets.selector);
        s.initialize(vault, proposer, data);
    }

    /// @dev M2: a 254-entry list of the SAME market used to be legal and would
    ///      make `initiateReturn` emit 508 venue calls in one tx.
    function test_initialize_duplicateMarkets_reverts() public {
        uint16[] memory m = new uint16[](3);
        m[0] = 5;
        m[1] = 7;
        m[2] = 5; // dup
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_validPubKey(), API_KEY_INDEX, m, DEPOSIT);
        vm.expectRevert(LighterPerpStrategy.DuplicateMarket.selector);
        s.initialize(vault, proposer, data);
    }

    function test_initialize_marketZeroIsValid() public {
        uint16[] memory m = new uint16[](2);
        m[0] = 0;
        m[1] = 1;
        LighterPerpStrategy s = _clone(abi.encode(_validPubKey(), API_KEY_INDEX, m, DEPOSIT));
        assertEq(s.markets(0), 0);
    }

    function test_initialize_depositAboveUint64_reverts() public {
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_validPubKey(), API_KEY_INDEX, _markets(), uint256(type(uint64).max) + 1);
        vm.expectRevert(LighterPerpStrategy.DepositTooLarge.selector);
        s.initialize(vault, proposer, data);
    }

    // ==================== EXECUTE ====================

    function test_execute_pullsAndDepositsAndRegisters() public {
        _executeFirst();

        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Executed));
        assertEq(usdg.balanceOf(vault), 0);
        assertEq(usdg.balanceOf(address(strategy)), 0); // forwarded into zkLighter
        assertEq(usdg.balanceOf(ZK), DEPOSIT);
        assertEq(zk.depositCount(), 1);
        assertEq(zk.l2Balance(address(strategy)), DEPOSIT); // margin credited
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

    /// @dev Dynamic-all must respect the uint64 withdraw ceiling too — otherwise
    ///      the deposit could never be drained in one request.
    function test_execute_dynamicAll_aboveUint64_reverts() public {
        LighterPerpStrategy s = _clone(_initData(0));
        usdg.mint(vault, uint256(type(uint64).max) + 1);
        vm.prank(vault);
        usdg.approve(address(s), type(uint256).max);

        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.DepositTooLarge.selector);
        s.execute();
    }

    /// @dev Async registration: the venue defers account assignment, so the
    ///      strategy would hold capital in an account it cannot address. Execute
    ///      fails loudly and the funds stay in the vault.
    function test_execute_asyncRegistration_reverts() public {
        zk.setAsyncRegister(true);
        LighterPerpStrategy s = _clone(_initData(DEPOSIT));
        vm.prank(vault);
        usdg.approve(address(s), type(uint256).max);

        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.AccountNotRegistered.selector);
        s.execute();
        assertEq(usdg.balanceOf(vault), DEPOSIT); // rolled back
    }

    /// @dev Async registration that already landed out-of-band: execute succeeds
    ///      against the pre-assigned index and every venue path stays addressable.
    function test_execute_asyncRegistration_afterAccountLands_works() public {
        zk.setAsyncRegister(true);
        LighterPerpStrategy s = _clone(_initData(DEPOSIT));
        zk.registerAccount(address(s)); // async assignment arrives first
        vm.prank(vault);
        usdg.approve(address(s), type(uint256).max);

        vm.prank(vault);
        s.execute();

        assertEq(s.accountIndex(), 623);
        assertEq(zk.l2Balance(address(s)), DEPOSIT);
        vm.prank(proposer);
        s.registerAgentKey(); // venue paths work
        assertEq(zk.changePubKeyCount(), 1);
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

    /// @dev M3/H1: closing an UNLISTED market is deliberately allowed — the agent
    ///      key can trade any Lighter market, so this is the operator's only
    ///      remedy for a position opened outside `markets`.
    function test_updateParams_closeMarket_unlistedMarketAllowed() public {
        _executeFirst();
        bytes memory args = abi.encode(uint16(99), uint32(1), uint8(1)); // not in `markets`
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(2), args));
        (, uint16 market, uint48 baseAmount,,,) = zk.lastOrder();
        assertEq(market, 99);
        assertEq(baseAmount, 0); // can only close, never open
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

    /// @dev Action 4 (WITHDRAW) is retired in favour of `queueWithdraw`.
    function test_updateParams_retiredWithdrawAction_reverts() public {
        _executeFirst();
        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.InvalidAction.selector);
        strategy.updateParams(abi.encode(uint8(4), abi.encode(uint64(5_000e6))));
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

    function test_initiateReturn_closesBothSidesAndQueuesNothing() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.initiateReturn();

        // 2 markets × 2 sides (sell-close + buy-close) = 4 createOrder calls.
        assertEq(zk.createOrderCount(), 4);
        assertEq(zk.cancelAllCount(), 1);
        // C1: phase 1 no longer queues a withdrawal — the drain amount is only
        // knowable AFTER these closes fill.
        assertEq(zk.withdrawCount(), 0);
        assertEq(strategy.queuedTicks(), 0);
        assertEq(strategy.returnsInitiatedAt(), block.number);
    }

    /// @dev Re-callable by the proposer (e.g. the agent re-opened after the first
    ///      close) WITHOUT resetting the async-maturity clock.
    function test_initiateReturn_proposerReCallable_doesNotResetClock() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.initiateReturn();
        uint256 latched = strategy.returnsInitiatedAt();

        vm.roll(block.number + 5);
        vm.prank(proposer);
        strategy.initiateReturn();

        assertEq(zk.cancelAllCount(), 2); // really re-closed
        assertEq(zk.createOrderCount(), 8);
        assertEq(strategy.returnsInitiatedAt(), latched); // clock NOT reset
    }

    function test_initiateReturn_notExecuted_reverts() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.initiateReturn();
    }

    function test_initiateReturn_nonProposerBeforeDuration_reverts() public {
        _executeFirst();
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.initiateReturn();
    }

    function test_initiateReturn_anyoneAfterDuration_works() public {
        _executeFirst();
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        vm.prank(attacker);
        strategy.initiateReturn(); // permissionless after duration
        assertEq(strategy.returnsInitiatedAt(), block.number);
    }

    /// @dev The permissionless caller may only KICK OFF the unwind — repeats would
    ///      let a griefer spam venue priority requests every block.
    function test_initiateReturn_permissionlessRepeat_reverts() public {
        _executeFirst();
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        vm.prank(attacker);
        strategy.initiateReturn();

        vm.roll(block.number + 1);
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.AlreadyInitiated.selector);
        strategy.initiateReturn();
    }

    // ── M1: fail-open auth on the permissionless path ──

    /// @dev `getActiveProposal()` returns 0 once the governor cleared it (every
    ///      emergency-settle path does) while the strategy is still Executed.
    ///      `getProposal(0)` returns a ZEROED struct, so `0 + 0 <= now` used to
    ///      let anyone through.
    function test_initiateReturn_noActiveProposal_nonProposerReverts() public {
        _executeFirst();
        gov.setActiveProposal(0); // emergency settle cleared it
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.initiateReturn();
    }

    /// @dev A live proposal for a DIFFERENT strategy must not authorize this one.
    function test_initiateReturn_activeProposalForOtherStrategy_reverts() public {
        _executeFirst();
        // The other proposal is well past its own duration, so ONLY the
        // strategy-identity check can reject the caller here.
        uint256 otherExecutedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        gov.setProposal(address(0xBEEF), otherExecutedAt, DURATION);
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.initiateReturn();
    }

    /// @dev The proposer is unaffected by the governor read (short-circuit auth).
    function test_initiateReturn_proposerWorksWithNoActiveProposal() public {
        _executeFirst();
        gov.setActiveProposal(0);
        vm.prank(proposer);
        strategy.initiateReturn();
        assertEq(strategy.returnsInitiatedAt(), block.number);
    }

    // ==================== QUEUE WITHDRAW ====================

    function test_queueWithdraw_proposer() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.queueWithdraw(uint64(5_000e6));
        assertEq(zk.withdrawCount(), 1);
        assertEq(zk.lastWithdrawTicks(), 5_000e6);
        assertEq(strategy.queuedTicks(), 5_000e6);
        assertEq(zk.l2Balance(address(strategy)), DEPOSIT - 5_000e6);
    }

    function test_queueWithdraw_vaultOwner() public {
        _executeFirst();
        vm.prank(owner);
        strategy.queueWithdraw(uint64(1_000e6));
        assertEq(strategy.queuedTicks(), 1_000e6);
    }

    function test_queueWithdraw_attacker_reverts() public {
        _executeFirst();
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.queueWithdraw(uint64(DEPOSIT));
    }

    /// @dev Still proposer-gated once `strategyDuration` has elapsed — the
    ///      permissionless unwind path must never choose the drain amount (C2).
    function test_queueWithdraw_attackerAfterDuration_reverts() public {
        _executeFirst();
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.queueWithdraw(1);
    }

    function test_queueWithdraw_zeroTicks_reverts() public {
        _executeFirst();
        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.ZeroTicks.selector);
        strategy.queueWithdraw(0);
    }

    function test_queueWithdraw_beforeExecute_reverts() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.queueWithdraw(1);
    }

    function test_queueWithdraw_aboveL2Balance_revertsVenueSide() public {
        _executeFirst();
        vm.prank(proposer);
        vm.expectRevert(bytes("insufficient L2 balance"));
        strategy.queueWithdraw(uint64(DEPOSIT + 1));
    }

    function test_queueWithdraw_accumulates() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.queueWithdraw(uint64(1_000e6));
        strategy.queueWithdraw(uint64(2_000e6));
        vm.stopPrank();
        assertEq(strategy.queuedTicks(), 3_000e6);
        assertEq(zk.totalWithdrawTicks(), 3_000e6);
    }

    // ==================== SETTLE GUARD ====================

    function test_settle_beforeInitiate_reverts() public {
        _executeFirst();
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.ReturnsNotInitiated.selector);
        strategy.settle();
    }

    function test_settle_sameBlockAsInitiate_reverts() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));
        assertEq(strategy.returnsInitiatedAt(), block.number);
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.SettleTooSoon.selector);
        strategy.settle();
    }

    /// @dev C2: nothing was ever queued, so settling would book the whole
    ///      principal as an LP loss while it sits on the venue.
    function test_settle_nothingQueued_reverts() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.NothingQueued.selector);
        strategy.settle();
    }

    function test_settle_queuedButNotMatured_reverts() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        vm.roll(block.number + 1);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(LighterPerpStrategy.WithdrawalInFlight.selector, DEPOSIT, 0));
        strategy.settle();
    }

    function test_settle_partiallyMatured_reverts() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.maturePartial(address(strategy), DEPOSIT / 2);
        vm.roll(block.number + 1);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(LighterPerpStrategy.WithdrawalInFlight.selector, DEPOSIT, DEPOSIT / 2));
        strategy.settle();
    }

    /// @dev The OLD guard was `pending == 0 && bal == 0` — anyone could satisfy it
    ///      by donating 1 wei of USDG to the clone and then permissionlessly
    ///      settling the whole principal away as a loss.
    function test_settle_oneWeiDonation_cannotBypassGuard() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        vm.roll(block.number + 1);

        usdg.mint(address(strategy), 1); // the old bypass
        assertEq(usdg.balanceOf(address(strategy)), 1);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(LighterPerpStrategy.WithdrawalInFlight.selector, DEPOSIT, 1));
        strategy.settle();
    }

    /// @dev `returnedAssets` makes the guard monotone: a permissionless
    ///      `sweepToVault()` right before settle must not brick settlement.
    function test_settle_sweepBeforeSettle_doesNotBrick() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);

        // Anyone claims + forwards to the vault ahead of settle.
        vm.prank(attacker);
        strategy.recoverResiduals();
        assertEq(strategy.returnedAssets(), DEPOSIT);
        assertEq(usdg.balanceOf(address(strategy)), 0);
        assertEq(strategy.pendingBalance(), 0);

        vm.prank(vault);
        strategy.settle(); // still reachable
        assertEq(strategy.settled(), true);
        assertEq(usdg.balanceOf(vault), DEPOSIT);
    }

    function test_settle_claimsPendingAndPushes() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);

        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(vault);
        strategy.settle();

        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Settled));
        assertEq(strategy.settled(), true);
        assertEq(zk.claimCount(), 1);
        assertEq(usdg.balanceOf(vault) - vaultBefore, DEPOSIT); // clean round-trip
        assertEq(usdg.balanceOf(address(strategy)), 0);
        assertEq(strategy.returnedAssets(), DEPOSIT);
    }

    function test_settle_preClaimedByThirdParty_doesNotRevert() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);

        // A third party permissionlessly claims the matured balance INTO the strategy.
        vm.prank(attacker);
        zk.withdrawPendingBalance(address(strategy), 3, uint128(DEPOSIT));
        assertEq(usdg.balanceOf(address(strategy)), DEPOSIT);
        assertEq(strategy.pendingBalance(), 0);

        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(vault);
        strategy.settle(); // pending==0 but held bal covers queuedTicks → proceeds
        assertEq(usdg.balanceOf(vault) - vaultBefore, DEPOSIT);
        assertEq(zk.claimCount(), 1); // settle did not re-claim
    }

    function test_settle_notVault_reverts() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.settle();
    }

    /// @dev Venue under-fill: the drain was queued in full but the venue only
    ///      ever matures part of it (partial batch execution / haircut), so
    ///      `accounted` can never reach `queuedTicks` and the guard would hold
    ///      settle shut forever. The proposer acknowledges the shortfall and the
    ///      vault unlocks — this is the anti-brick escape hatch.
    function test_settle_acknowledgeShortfall_unblocksUnderFill() public {
        _executeFirst();
        zk.debitL2(address(strategy), 5_000e6); // trading loss on the venue
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT - 5_000e6));
        vm.stopPrank();
        zk.maturePartial(address(strategy), DEPOSIT - 10_000e6); // venue under-fills
        vm.roll(block.number + 1);

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                LighterPerpStrategy.WithdrawalInFlight.selector, DEPOSIT - 5_000e6, DEPOSIT - 10_000e6
            )
        );
        strategy.settle();

        vm.prank(proposer);
        strategy.acknowledgeShortfall();
        assertTrue(strategy.shortfallAcknowledged());

        vm.prank(vault);
        strategy.settle();
        assertEq(strategy.settled(), true);
        assertEq(usdg.balanceOf(vault), DEPOSIT - 10_000e6);
    }

    function test_acknowledgeShortfall_vaultOwner() public {
        _executeFirst();
        vm.prank(owner);
        strategy.acknowledgeShortfall();
        assertTrue(strategy.shortfallAcknowledged());
    }

    function test_acknowledgeShortfall_attacker_reverts() public {
        _executeFirst();
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.acknowledgeShortfall();
    }

    // ==================== C1 REGRESSION (under-withdraw) ====================

    /// @dev C1 PoC, permanently pinned.
    ///
    ///      Pre-fix: `initiateReturn(ticks)` closed positions AND queued the
    ///      withdrawal in one tx, so `ticks` was necessarily read BEFORE the
    ///      closes' PnL existed. Under-stating stranded the remainder forever:
    ///      `_settle` succeeded on any pending, flipped state to `Settled`, and
    ///      `updateParams` — the only route to `ZK_LIGHTER.withdraw` — was gated
    ///      on `Executed`. `recoverResiduals()` could only CLAIM already-queued
    ///      pending, never QUEUE a new withdrawal.
    ///
    ///      Post-fix: `queueWithdraw` is a top-level function that works in the
    ///      `Settled` state, so the residue is fully recoverable.
    function test_C1_underWithdraw_isRecoverableAfterSettle() public {
        _executeFirst();
        assertEq(zk.l2Balance(address(strategy)), DEPOSIT);

        // Unwind, then under-state the drain by 4 orders of magnitude.
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(1); // 1 tick of 20_000_000_000
        vm.stopPrank();

        zk.mature(address(strategy));
        vm.roll(block.number + 1);

        vm.prank(vault);
        strategy.settle();

        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Settled));
        assertEq(usdg.balanceOf(vault), 1); // ~the entire principal is stranded
        uint256 stranded = DEPOSIT - 1;
        assertEq(zk.l2Balance(address(strategy)), stranded);

        // THE FIX: `queueWithdraw` still works post-settle.
        vm.prank(proposer);
        strategy.queueWithdraw(uint64(stranded));
        zk.mature(address(strategy));

        vm.prank(attacker); // recovery is permissionless
        strategy.recoverResiduals();

        assertEq(usdg.balanceOf(vault), DEPOSIT); // fully recovered
        assertEq(zk.l2Balance(address(strategy)), 0);
        assertEq(strategy.returnedAssets(), DEPOSIT);
    }

    /// @dev The vault owner can drive the same recovery if the proposer key dies.
    function test_C1_ownerCanRecoverAfterSettle() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(1);
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();

        vm.prank(owner);
        strategy.queueWithdraw(uint64(DEPOSIT - 1));
        zk.mature(address(strategy));
        strategy.recoverResiduals();
        assertEq(usdg.balanceOf(vault), DEPOSIT);
    }

    // ==================== C2 REGRESSION (permissionless poisoning) ====================

    /// @dev C2 PoC, permanently pinned.
    ///
    ///      Pre-fix: after `strategyDuration` ANYONE could call
    ///      `initiateReturn(1)`; the second call silently returned, so the
    ///      poisoned amount could not be corrected. 1 tick matured, the settle
    ///      presence check passed, and `settleProposal` (also permissionless
    ///      after the duration) booked the entire principal as an LP loss —
    ///      two txs, no capital.
    ///
    ///      Post-fix: the permissionless path cannot choose ANY amount, and
    ///      settle refuses while nothing has been queued.
    function test_C2_attackerCannotPoisonWithdrawalAmount() public {
        _executeFirst();
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);

        // Step 1 of the old attack still works — it is only a position close.
        vm.prank(attacker);
        strategy.initiateReturn();
        assertEq(zk.withdrawCount(), 0); // nothing queued
        assertEq(strategy.queuedTicks(), 0);

        // Step 2 is gone: the attacker cannot choose the drain amount.
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.queueWithdraw(1);

        // Step 3 is gone: settle refuses to book the principal as a loss.
        vm.roll(block.number + 1);
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.NothingQueued.selector);
        strategy.settle();

        // The proposer still completes the honest unwind afterwards.
        vm.prank(proposer);
        strategy.queueWithdraw(uint64(DEPOSIT));
        zk.mature(address(strategy));
        vm.prank(vault);
        strategy.settle();
        assertEq(usdg.balanceOf(vault), DEPOSIT);
    }

    /// @dev And the attacker cannot even hold settlement open by re-closing.
    function test_C2_attackerCannotStallSettleByReInitiating() public {
        _executeFirst();
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        vm.prank(attacker);
        strategy.initiateReturn();
        uint256 latched = strategy.returnsInitiatedAt();

        vm.prank(proposer);
        strategy.queueWithdraw(uint64(DEPOSIT));
        zk.mature(address(strategy));
        vm.roll(block.number + 1);

        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.AlreadyInitiated.selector);
        strategy.initiateReturn();
        assertEq(strategy.returnsInitiatedAt(), latched);

        vm.prank(vault);
        strategy.settle();
        assertEq(usdg.balanceOf(vault), DEPOSIT);
    }

    // ==================== H-4: RECOVERY WITHOUT strategy.settle() ====================

    /// @dev A proposal resolved through `finalizeEmergencySettle` executes
    ///      owner-supplied calls and finishes settlement in the GOVERNOR without
    ///      ever calling `strategy.settle()`. The old `settled == true` gate on
    ///      the recovery paths bricked them in exactly that case.
    function test_H4_recoveryWorksWithoutStrategySettle() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));

        // Governor emergency-settled: strategy state is still Executed, `settled`
        // is still false.
        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Executed));
        assertEq(strategy.settled(), false);

        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(attacker); // permissionless
        strategy.recoverResiduals();

        assertEq(usdg.balanceOf(vault) - vaultBefore, DEPOSIT);
        assertEq(strategy.returnedAssets(), DEPOSIT);
    }

    function test_H4_sweepToVaultWorksBeforeSettle() public {
        _executeFirst();
        usdg.mint(address(strategy), 250e6); // stray USDG lands mid-strategy

        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(attacker);
        strategy.sweepToVault();
        assertEq(usdg.balanceOf(vault) - vaultBefore, 250e6);
        assertEq(strategy.returnedAssets(), 250e6);
    }

    // ==================== RESIDUAL RECOVERY ====================

    function test_recoverResiduals_claimsLateMaturityToVault() public {
        _settleClean();
        // A late tranche matures after settlement.
        usdg.mint(ZK, 500e6); // fund the venue for the extra claim
        zk.creditL2(address(strategy), 500e6);
        vm.prank(proposer);
        strategy.queueWithdraw(500e6);
        zk.mature(address(strategy));

        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(attacker); // permissionless
        strategy.recoverResiduals();

        assertEq(usdg.balanceOf(vault) - vaultBefore, 500e6);
        assertEq(strategy.returnedAssets(), DEPOSIT + 500e6);
    }

    function test_sweepToVault_pushesHeldBalance() public {
        _settleClean();
        // USDG lands directly on the strategy (e.g. a third party claimed here).
        usdg.mint(address(strategy), 250e6);

        uint256 vaultBefore = usdg.balanceOf(vault);
        strategy.sweepToVault();
        assertEq(usdg.balanceOf(vault) - vaultBefore, 250e6);
        assertEq(strategy.returnedAssets(), DEPOSIT + 250e6);
        assertEq(usdg.balanceOf(address(strategy)), 0);
    }

    function test_sweepToVault_zeroBalance_isNoOp() public {
        _settleClean();
        uint256 vaultBefore = usdg.balanceOf(vault);
        strategy.sweepToVault();
        assertEq(usdg.balanceOf(vault), vaultBefore);
    }

    // ==================== CHAIN GUARD ====================

    function test_template_wrongChain_reverts() public {
        vm.chainId(1); // Ethereum mainnet
        vm.expectRevert(LighterPerpStrategy.UnsupportedChain.selector);
        new LighterPerpStrategy();
    }

    function test_template_forkChain_ok() public {
        vm.chainId(9994663); // Robinhood-mainnet fork
        LighterPerpStrategy t = new LighterPerpStrategy();
        assertEq(t.name(), "LighterPerp");
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

        // Phase 1: close everything. Amount is NOT chosen here.
        vm.prank(proposer);
        strategy.initiateReturn();

        // Trading profit realized by the closes, read off-chain AFTER they fill.
        usdg.mint(ZK, 1_500e6);
        zk.creditL2(address(strategy), 1_500e6);

        // Phase 2: queue the true post-close balance.
        vm.prank(proposer);
        strategy.queueWithdraw(uint64(DEPOSIT + 1_500e6));

        zk.mature(address(strategy));
        vm.roll(block.number + 1);

        vm.prank(vault);
        strategy.settle();

        assertEq(strategy.settled(), true);
        assertEq(usdg.balanceOf(vault), DEPOSIT + 1_500e6); // profit round-trips
        assertEq(zk.l2Balance(address(strategy)), 0);
    }
}

// ── Minimal mocks for the initiateReturn auth path ──

contract MockVaultForLighter {
    address public governor;
    address public owner;

    constructor(address gov_, address owner_) {
        governor = gov_;
        owner = owner_;
    }
}

contract MockGovernorForLighter {
    uint256 internal _activeProposal;
    address internal _strategy;
    uint256 internal _executedAt;
    uint256 internal _duration;

    function setActiveProposal(uint256 pid) external {
        _activeProposal = pid;
    }

    function setProposal(address strategy_, uint256 executedAt_, uint256 duration_) external {
        _strategy = strategy_;
        _executedAt = executedAt_;
        _duration = duration_;
    }

    function getActiveProposal() external view returns (uint256) {
        return _activeProposal;
    }

    /// @dev Mirrors the real governor: a nonexistent id returns a ZEROED struct
    ///      rather than reverting — the exact behaviour M1 exploits.
    function getProposal(uint256 pid) external view returns (ISyndicateGovernor.StrategyProposal memory p) {
        if (pid == 0) return p;
        p.strategy = _strategy;
        p.executedAt = _executedAt;
        p.strategyDuration = _duration;
    }
}
