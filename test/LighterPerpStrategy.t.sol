// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LighterPerpStrategy} from "../src/strategies/LighterPerpStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {MockZkLighter} from "./mocks/MockZkLighter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";

/// @dev SPLIT INTO TWO TEST CONTRACTS, ON PURPOSE AND NOT FOR TASTE. A single
///      contract carrying every case in this file plus everything `forge-std`'s
///      `Test` inherits pushes the compiled test contract past the point where
///      solc's legacy tag encoding runs out of reserved space, and the build dies
///      with `Internal compiler error ... Tag too large for reserved space` —
///      which names neither the contract nor the cause. The fixtures live here;
///      the cases live in the two contracts below.
abstract contract LighterPerpStrategyBase is Test {
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
    MockTierRegistryForLighter internal tiers;
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
        vaultC = new MockVaultForLighter(address(gov), owner, USDG_ADDR);
        vault = address(vaultC);
        // `onlyProposer` re-reads the vault's live agent set on every call.
        vaultC.setAgent(proposer, true);

        // `_initialize` binds ZK_LIGHTER through
        // `vault() -> governor() -> tierRegistry() -> isCounterpartyAllowed`.
        tiers = new MockTierRegistryForLighter();
        tiers.setCounterpartyAllowed(ZK, true);
        gov.setTierRegistry(address(tiers));

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

    /// @dev Re-seats the mock governor's active proposal on the NEW clone.
    ///      `BaseStrategy.execute` requires `strategyOf(activePid) == msg.target`,
    ///      so a clone the governor does not name can never execute. No test here
    ///      wants the active proposal pointed elsewhere at clone time; the ones
    ///      that do (`initiateReturn` auth) re-point it explicitly afterwards.
    function _clone(bytes memory data) internal returns (LighterPerpStrategy s) {
        s = LighterPerpStrategy(Clones.clone(address(template)));
        s.initialize(vault, proposer, data);
        gov.setProposal(address(s), block.timestamp, DURATION);
    }

    function _executeFirst() internal {
        vm.prank(vault);
        strategy.execute();
    }

    /// @dev The real recovery path: `SyndicateVault.collectResidue(strategy)` is
    ///      permissionless and dispatches `sweep()` (selector 0x35faa416) from the
    ///      VAULT, measuring the arrival as a balance delta. Every test that used
    ///      to call `sweepToVault()` directly goes through here instead, because
    ///      that direct door is exactly what was removed.
    function _collectResidue() internal returns (uint256) {
        return _collectResidue(strategy);
    }

    function _collectResidue(LighterPerpStrategy s) internal returns (uint256) {
        vm.prank(attacker); // permissionless at the vault
        return vaultC.collectResidue(address(s));
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

    /// @dev Drives the strategy to a REAL, currently-observable shortfall: the
    ///      unwind is initiated, a drain was queued, and the venue matured less
    ///      than that.
    function _armedShortfall() internal {
        _executeFirst();
        zk.debitL2(address(strategy), 5_000e6); // trading loss on the venue
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT - 5_000e6));
        vm.stopPrank();
        zk.maturePartial(address(strategy), DEPOSIT - 10_000e6); // venue under-fills
        vm.roll(block.number + 1);
    }
}

contract LighterPerpStrategyTest is LighterPerpStrategyBase {
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

    /// @dev The "dynamic-all" mode (`depositAmount == 0` ⇒ pull the vault's whole
    ///      USDG balance at execute) is GONE. It could not satisfy the post-audit
    ///      `executeGovernorBatch` per-call caps, and a batch whose pull size is
    ///      only knowable at execute time cannot be checked against
    ///      `QueueReserveBreached` / `BufferBreached` when the proposal is voted.
    function test_initialize_zeroDeposit_reverts() public {
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        vm.expectRevert(LighterPerpStrategy.DepositTooSmall.selector);
        s.initialize(vault, proposer, _initData(0));
    }

    function test_initialize_belowMinDeposit_reverts() public {
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        vm.expectRevert(LighterPerpStrategy.DepositTooSmall.selector);
        s.initialize(vault, proposer, _initData(0.5e6)); // < 1 USDG
    }

    function test_initialize_minDepositExactly_ok() public {
        LighterPerpStrategy s = _clone(_initData(1e6));
        assertEq(s.depositAmount(), 1e6);
    }

    /// @dev The venue asset is a `constant` in this template, so a vault whose
    ///      ERC-4626 asset is anything else would have every pull and every push
    ///      denominated in a token the vault does not account for. Bound at init,
    ///      matching `MorphoSupplyStrategy`'s `LoanAssetMismatch`.
    function test_initialize_assetMismatch_reverts() public {
        vaultC.setAsset(makeAddr("someOtherToken"));
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        vm.expectRevert(LighterPerpStrategy.AssetMismatch.selector);
        s.initialize(vault, proposer, _initData(DEPOSIT));
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

    /// @dev The pull size is FIXED at init and never re-read from the vault's
    ///      balance. A surplus float left in the vault stays there, which is what
    ///      makes the pull size predictable at propose time — the property the
    ///      per-call caps and the buffer/queue-reserve guards need.
    function test_execute_pullsExactlyDepositAmount_ignoringSurplus() public {
        usdg.mint(vault, 5_000e6); // vault now holds DEPOSIT + 5_000e6
        _executeFirst();

        assertEq(usdg.balanceOf(vault), 5_000e6); // surplus untouched
        assertEq(usdg.balanceOf(ZK), DEPOSIT);
        assertEq(strategy.depositAmount(), DEPOSIT);
    }

    /// @dev The vault cannot cover the fixed pull: the ERC20 transferFrom fails
    ///      and the whole execute rolls back with the float still in the vault.
    function test_execute_vaultCannotCoverDeposit_reverts() public {
        uint256 bal = usdg.balanceOf(vault);
        vm.prank(vault);
        usdg.transfer(address(0xdead), bal - 1e6); // leaves 1 USDG, needs 20k

        vm.prank(vault);
        vm.expectRevert();
        strategy.execute();
        assertEq(usdg.balanceOf(vault), 1e6);
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
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.registerAgentKey();
    }

    /// @dev The owner's second key on the agent-key path — see
    ///      `test_liveness_ownerKeepsGuardrailsAfterRemoveAgent`.
    function test_registerAgentKey_vaultOwner_works() public {
        _executeFirst();
        vm.prank(owner);
        strategy.registerAgentKey();
        assertEq(zk.changePubKeyCount(), 1);
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

    /// @dev `returnedAssets` makes the guard monotone: a `collectResidue` sweep
    ///      right before settle must not brick settlement.
    function test_settle_sweepBeforeSettle_doesNotBrick() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);

        // Anyone drives the vault's permissionless door ahead of settle.
        assertEq(_collectResidue(), DEPOSIT);
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
        _armedShortfall();
        vm.prank(owner);
        strategy.acknowledgeShortfall();
        assertTrue(strategy.shortfallAcknowledged());
    }

    function test_acknowledgeShortfall_attacker_reverts() public {
        _armedShortfall();
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.acknowledgeShortfall();
    }

    // ============ R3 REGRESSION (acknowledgeShortfall pre-arm bypass) ============

    /// @dev R3 PoC, permanently pinned.
    ///
    ///      Pre-fix: `acknowledgeShortfall()` had NO precondition — it could be
    ///      armed the instant the strategy went `Executed`, before any close and
    ///      before any drain was requested, and it permanently waived BOTH settle
    ///      guards. Four calls booked the entire principal as a 100% loss with
    ///      the funds still sitting at the venue:
    ///
    ///        execute -> acknowledgeShortfall -> initiateReturn -> roll -> settle
    ///
    ///      i.e. exactly the `NothingQueued` case the guard exists to prevent.
    ///      The stranding itself is recoverable (C1); the damage is the Lane-B
    ///      price stamp. `_finishSettlement` computes PnL from the vault's USDG
    ///      balance and `onProposalSettled` FREEZES the per-proposal redeem price
    ///      at that deflated NAV, so a later `queueWithdraw` + `recoverResiduals`
    ///      top-up lands after the stamp: queued redeemers are paid the haircut
    ///      and the recovery accrues to whoever stayed.
    ///
    ///      Post-fix: arming requires an initiated return, a nonzero
    ///      `queuedTicks`, and a shortfall that is actually observable now.
    function test_R3_acknowledgeShortfall_cannotPreArmBeforeUnwind() public {
        _executeFirst();
        assertEq(zk.l2Balance(address(strategy)), DEPOSIT);

        // Step 1 of the PoC is gone: nothing has been closed or requested.
        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.ReturnsNotInitiated.selector);
        strategy.acknowledgeShortfall();

        // Still gone after the closes — no drain has been requested yet.
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.NothingQueued.selector);
        strategy.acknowledgeShortfall();

        // The vault owner cannot pre-arm it either.
        vm.prank(owner);
        vm.expectRevert(LighterPerpStrategy.NothingQueued.selector);
        strategy.acknowledgeShortfall();

        // So settle still refuses to book the principal as a loss.
        vm.roll(block.number + 1);
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.NothingQueued.selector);
        strategy.settle();

        assertEq(strategy.shortfallAcknowledged(), false);
        assertEq(zk.l2Balance(address(strategy)), DEPOSIT); // principal untouched
    }

    /// @dev The waiver cannot be armed against a drain that has fully arrived —
    ///      there is no shortfall to acknowledge and `_settle` passes unaided.
    function test_R3_acknowledgeShortfall_noShortfall_reverts() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy)); // everything asked for is claimable

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(LighterPerpStrategy.NoShortfall.selector, uint256(DEPOSIT), uint256(DEPOSIT))
        );
        strategy.acknowledgeShortfall();

        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle(); // no waiver needed
        assertEq(usdg.balanceOf(vault), DEPOSIT);
    }

    /// @dev Liveness: arming must stay legal while `accounted == 0` (nothing has
    ///      matured yet), otherwise the venue-under-fill escape hatch would be
    ///      unreachable in exactly the case it exists for.
    function test_R3_acknowledgeShortfall_armableBeforeAnyMaturity() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();

        vm.prank(proposer);
        strategy.acknowledgeShortfall();
        assertTrue(strategy.shortfallAcknowledged());
    }

    /// @dev Positive control: a legitimately-armed shortfall carries through to
    ///      `settle()`, and the residue stays recoverable afterwards.
    function test_R3_armedShortfall_carriesThroughSettle() public {
        _armedShortfall();
        vm.prank(proposer);
        strategy.acknowledgeShortfall();

        vm.prank(vault);
        strategy.settle();
        assertEq(strategy.settled(), true);
        assertEq(usdg.balanceOf(vault), DEPOSIT - 10_000e6);

        // The 5k the venue never matured is still drainable post-settle.
        zk.mature(address(strategy));
        assertEq(_collectResidue(), 5_000e6);
        assertEq(usdg.balanceOf(vault), DEPOSIT - 5_000e6);
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

        // Recovery stays permissionless — it just runs through the vault's own
        // `collectResidue` door now, so the arrival is measured once.
        assertEq(_collectResidue(), stranded);

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
        _collectResidue();
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
        assertEq(_collectResidue(), DEPOSIT);

        assertEq(usdg.balanceOf(vault) - vaultBefore, DEPOSIT);
        assertEq(strategy.returnedAssets(), DEPOSIT);
    }

    /// @dev H-4, restated for the renamed door: `sweep()` is NOT gated on
    ///      `State.Settled` (both sibling templates are), because an
    ///      emergency-settled Lighter clone stays `Executed` forever while still
    ///      holding USDG the vault cannot see.
    function test_H4_sweepWorksBeforeSettle() public {
        _executeFirst();
        usdg.mint(address(strategy), 250e6); // stray USDG lands mid-strategy

        uint256 vaultBefore = usdg.balanceOf(vault);
        assertEq(_collectResidue(), 250e6);
        assertEq(usdg.balanceOf(vault) - vaultBefore, 250e6);
        assertEq(strategy.returnedAssets(), 250e6);
        assertEq(uint8(strategy.state()), uint8(BaseStrategy.State.Executed));
    }

    // ==================== RESIDUAL RECOVERY ====================

    /// @dev CLAIM-ONLY. `recoverResiduals` stays permissionless — that is the
    ///      H-4 property — but it now lands the USDG on the CLONE and never
    ///      pushes. Pushing directly was a second door onto the balance delta
    ///      `SyndicateVault._recoverResidueVia` measures, which would credit the
    ///      exited redeem cohort nothing and lift the stayers' price instead.
    function test_recoverResiduals_claimsToCloneNotVault() public {
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

        assertEq(usdg.balanceOf(vault), vaultBefore); // NOT pushed
        assertEq(usdg.balanceOf(address(strategy)), 500e6); // claimed onto the clone
        assertEq(strategy.returnedAssets(), DEPOSIT); // unchanged: nothing delivered
        assertEq(strategy.pendingBalance(), 0);

        // The single measured door then delivers it.
        assertEq(_collectResidue(), 500e6);
        assertEq(usdg.balanceOf(vault) - vaultBefore, 500e6);
        assertEq(strategy.returnedAssets(), DEPOSIT + 500e6);
    }

    /// @dev `sweep()` claims AND pushes, so `collectResidue` alone recovers a
    ///      matured tranche in one call — no separate `recoverResiduals` needed.
    function test_sweep_claimsAndPushesInOneCall() public {
        _settleClean();
        usdg.mint(ZK, 500e6);
        zk.creditL2(address(strategy), 500e6);
        vm.prank(proposer);
        strategy.queueWithdraw(500e6);
        zk.mature(address(strategy));

        uint256 vaultBefore = usdg.balanceOf(vault);
        assertEq(_collectResidue(), 500e6);
        assertEq(usdg.balanceOf(vault) - vaultBefore, 500e6);
        assertEq(strategy.pendingBalance(), 0);
    }

    function test_sweep_pushesHeldBalance() public {
        _settleClean();
        // USDG lands directly on the strategy (e.g. a third party claimed here).
        usdg.mint(address(strategy), 250e6);

        uint256 vaultBefore = usdg.balanceOf(vault);
        assertEq(_collectResidue(), 250e6);
        assertEq(usdg.balanceOf(vault) - vaultBefore, 250e6);
        assertEq(strategy.returnedAssets(), DEPOSIT + 250e6);
        assertEq(usdg.balanceOf(address(strategy)), 0);
    }

    function test_sweep_zeroBalance_isNoOp() public {
        _settleClean();
        uint256 vaultBefore = usdg.balanceOf(vault);
        assertEq(_collectResidue(), 0);
        assertEq(usdg.balanceOf(vault), vaultBefore);
    }

    /// @dev THE POINT OF THE RENAME. `sweep()` is `onlyVault` so the vault's
    ///      delta measurement stays the single door; a keeper calling it directly
    ///      is what breaks `_payCohortShare`, and it does not need an attacker.
    function test_sweep_nonVaultCaller_reverts() public {
        _settleClean();
        usdg.mint(address(strategy), 250e6);

        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.sweep();

        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.sweep();

        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.sweep();

        assertEq(usdg.balanceOf(address(strategy)), 250e6); // nothing moved
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

/// @notice The post-audit additions: the `IStrategyDelivery` residue probes, the
///         live-agent re-check on the proposer paths, the vault-owner liveness
///         doors, and the TierRegistry counterparty bind.
contract LighterPerpStrategyDeliveryTest is LighterPerpStrategyBase {
    // ==================== IStrategyDelivery (residue probes) ====================

    function test_delivery_pendingBeforeSettle_reportsNothing() public {
        _executeFirst();
        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));

        // Executed, holding a matured claim — and still silent, because the
        // vault is already gated by `openProposalCount() != 0` over this window.
        assertFalse(strategy.hasUndeliveredValue());
        assertEq(strategy.undeliveredValue(), 0);
        assertFalse(strategy.hasUnvaluedResidue());
    }

    function test_delivery_cleanSettle_reportsNothing() public {
        _settleClean();
        assertFalse(strategy.hasUndeliveredValue());
        assertEq(strategy.undeliveredValue(), 0);
        assertFalse(strategy.hasUnvaluedResidue());
    }

    /// @dev Matured-but-unclaimed ticks are undelivered value: `sweep()` would
    ///      move them, so the vault must not price a mint as if they were gone.
    function test_delivery_maturedPendingAfterSettle_isUndelivered() public {
        _settleClean();
        usdg.mint(ZK, 500e6);
        zk.creditL2(address(strategy), 500e6);
        vm.prank(proposer);
        strategy.queueWithdraw(500e6);
        zk.mature(address(strategy));

        assertTrue(strategy.hasUndeliveredValue());
        assertEq(strategy.undeliveredValue(), 500e6);

        _collectResidue();
        assertFalse(strategy.hasUndeliveredValue());
        assertEq(strategy.undeliveredValue(), 0);
    }

    /// @dev Idle USDG sitting on a settled clone counts the same way.
    function test_delivery_idleBalanceAfterSettle_isUndelivered() public {
        _settleClean();
        usdg.mint(address(strategy), 250e6);
        assertTrue(strategy.hasUndeliveredValue());
        assertEq(strategy.undeliveredValue(), 250e6);
    }

    /// @dev `RESIDUE_DUST` (1e3) floors the BOOL but not the AMOUNT — same shape
    ///      as both sibling templates. A 1-wei donation must not shut deposits.
    function test_delivery_dustDonation_doesNotTripTheLock() public {
        _settleClean();
        usdg.mint(address(strategy), 1);
        assertFalse(strategy.hasUndeliveredValue());
        assertEq(strategy.undeliveredValue(), 1);

        usdg.mint(address(strategy), 1_000); // now 1001 > RESIDUE_DUST
        assertTrue(strategy.hasUndeliveredValue());
    }

    /// @dev A post-settle top-up drain is value the clone cannot price: the
    ///      margin is still with the off-chain sequencer.
    function test_delivery_queuedButUnreturned_isUnvalued() public {
        _settleClean();
        assertFalse(strategy.hasUnvaluedResidue());

        usdg.mint(ZK, 500e6);
        zk.creditL2(address(strategy), 500e6);
        vm.prank(proposer);
        strategy.queueWithdraw(500e6);
        assertTrue(strategy.hasUnvaluedResidue()); // asked for, not back yet

        zk.mature(address(strategy));
        _collectResidue();
        assertFalse(strategy.hasUnvaluedResidue()); // returnedAssets caught up
    }

    /// @dev An acknowledged shortfall is the contract SAYING it could not verify
    ///      its own L2 balance, so it must declare the residue unvalued. This one
    ///      never clears on its own — the vault bounds the cost at
    ///      `UNVALUED_MAX_LOCK` and `pruneUnvaluedMark` burns the mark after.
    function test_delivery_acknowledgedShortfall_isUnvaluedForever() public {
        _armedShortfall();
        vm.prank(proposer);
        strategy.acknowledgeShortfall();
        vm.prank(vault);
        strategy.settle();

        assertTrue(strategy.hasUnvaluedResidue());

        // Even after draining everything the venue will ever pay.
        zk.mature(address(strategy));
        _collectResidue();
        assertTrue(strategy.hasUnvaluedResidue());
    }

    /// @dev Every probe must fit inside `SyndicateVault._PROBE_GAS` (150k) or the
    ///      vault reads it as unreadable and leaves the strategy counted forever.
    function test_delivery_probesFitTheVaultGasCap() public {
        _settleClean();
        usdg.mint(address(strategy), 250e6);

        uint256 g = gasleft();
        strategy.hasUndeliveredValue();
        uint256 usedBool = g - gasleft();

        g = gasleft();
        strategy.undeliveredValue();
        uint256 usedAmount = g - gasleft();

        g = gasleft();
        strategy.hasUnvaluedResidue();
        uint256 usedUnvalued = g - gasleft();

        assertLt(usedBool, 150_000);
        assertLt(usedAmount, 150_000);
        assertLt(usedUnvalued, 150_000);
    }

    // ==================== LIVE-AGENT RE-CHECK (pashov #9) ====================

    /// @dev `queueWithdraw` / `acknowledgeShortfall` / `initiateReturn` used to
    ///      compare `msg.sender == proposer()` by hand, which skipped the live
    ///      agent-set read `onlyProposer` performs — so `removeAgent` revoked
    ///      nothing on an already-deployed clone.
    function test_deregisteredAgent_losesQueueWithdraw() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.initiateReturn();

        vaultC.setAgent(proposer, false); // SyndicateVault.removeAgent

        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.queueWithdraw(1);
    }

    function test_deregisteredAgent_losesAcknowledgeShortfall() public {
        _armedShortfall();
        vaultC.setAgent(proposer, false);

        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.acknowledgeShortfall();
    }

    function test_deregisteredAgent_losesRegisterAgentKey() public {
        _executeFirst();
        vaultC.setAgent(proposer, false);

        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.registerAgentKey();
    }

    /// @dev The de-registered proposer keeps no PRIVILEGED `initiateReturn`
    ///      branch: it falls through to the permissionless one and is refused
    ///      until `strategyDuration` elapses, exactly like anyone else.
    function test_deregisteredAgent_losesPrivilegedInitiateReturn() public {
        _executeFirst();
        vaultC.setAgent(proposer, false);

        vm.prank(proposer);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.initiateReturn();

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(proposer); // now only as good as any other caller
        strategy.initiateReturn();
        assertTrue(strategy.returnsInitiatedAt() != 0);
    }

    // ==================== OWNER LIVENESS PATHS ====================

    /// @dev THE HOLE: every guardrail was `updateParams`-only, so `removeAgent`
    ///      killed the kill switch and pinned settlement until `strategyDuration`.
    function test_liveness_ownerKeepsGuardrailsAfterRemoveAgent() public {
        _executeFirst();
        vaultC.setAgent(proposer, false);

        // Proposer is gone; the owner still holds every lever.
        vm.startPrank(owner);
        strategy.guardrailAction(abi.encode(uint8(1), bytes("")));
        assertEq(zk.cancelAllCount(), 1);

        strategy.guardrailAction(abi.encode(uint8(2), abi.encode(uint16(1), uint32(1), uint8(1))));
        strategy.registerAgentKey();
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();

        assertTrue(strategy.returnsInitiatedAt() != 0);
        assertEq(strategy.queuedTicks(), DEPOSIT);
    }

    function test_guardrailAction_proposerAlsoWorks() public {
        _executeFirst();
        vm.prank(proposer);
        strategy.guardrailAction(abi.encode(uint8(1), bytes("")));
        assertEq(zk.cancelAllCount(), 1);
    }

    function test_guardrailAction_attacker_reverts() public {
        _executeFirst();
        vm.prank(attacker);
        vm.expectRevert(LighterPerpStrategy.NotAuthorized.selector);
        strategy.guardrailAction(abi.encode(uint8(1), bytes("")));
    }

    function test_guardrailAction_beforeExecute_reverts() public {
        vm.prank(owner);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.guardrailAction(abi.encode(uint8(1), bytes("")));
    }

    function test_guardrailAction_invalidAction_reverts() public {
        _executeFirst();
        vm.prank(owner);
        vm.expectRevert(LighterPerpStrategy.InvalidAction.selector);
        strategy.guardrailAction(abi.encode(uint8(4), bytes("")));
    }

    // ==================== COUNTERPARTY BINDING ====================

    /// @dev Init is FAIL-CLOSED on the counterparty axis, matching
    ///      `ConcentratedLiquidityStrategy`'s Uniswap-factory bind. This is the
    ///      owner's switch for making the template inert without touching the
    ///      StrategyFactory allowlist.
    function test_counterparty_notAllowedAtInit_reverts() public {
        tiers.setCounterpartyAllowed(ZK, false);
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        vm.expectRevert(abi.encodeWithSelector(LighterPerpStrategy.CounterpartyNotAllowed.selector, ZK, address(tiers)));
        s.initialize(vault, proposer, _initData(DEPOSIT));
    }

    /// @dev An unresolved registry is FATAL at init and only at init: a no-op
    ///      bind would read as armed while gating nothing.
    function test_counterparty_unresolvedRegistryAtInit_reverts() public {
        gov.setTierRegistry(address(0));
        LighterPerpStrategy s = LighterPerpStrategy(Clones.clone(address(template)));
        vm.expectRevert(LighterPerpStrategy.TierRegistryUnresolved.selector);
        s.initialize(vault, proposer, _initData(DEPOSIT));
    }

    /// @dev Re-certified at `_execute`: a venue demoted between clone-init and
    ///      execute must not receive `forceApprove` of the whole deposit.
    ///      Blocking here strands nothing — the float never leaves the vault.
    function test_counterparty_demotedBeforeExecute_blocksExecute() public {
        tiers.setCounterpartyAllowed(ZK, false);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(LighterPerpStrategy.CounterpartyNotAllowed.selector, ZK, address(tiers)));
        strategy.execute();
        assertEq(usdg.balanceOf(vault), DEPOSIT); // untouched
    }

    /// @dev NEVER on the exit path. A demotion — or an unreachable registry —
    ///      must not be able to freeze capital already at the venue.
    function test_counterparty_demotedAfterExecute_doesNotBlockTheExit() public {
        _executeFirst();
        tiers.setCounterpartyAllowed(ZK, false);

        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(DEPOSIT));
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);

        vm.prank(vault);
        strategy.settle();
        assertEq(usdg.balanceOf(vault), DEPOSIT);

        // And the residue door too.
        usdg.mint(address(strategy), 250e6);
        assertEq(_collectResidue(), 250e6);
    }

    /// @dev A registry unwired AFTER init degrades OPEN at execute, matching
    ///      `MorphoSupplyStrategy._requireAllowedMorpho` and the vault's own
    ///      "no registry ⇒ no batch guard" default.
    function test_counterparty_registryUnwiredAfterInit_executeStillRuns() public {
        gov.setTierRegistry(address(0));
        _executeFirst();
        assertEq(zk.l2Balance(address(strategy)), DEPOSIT);
    }
}

// ── Minimal mocks for the initiateReturn auth path ──

/// @notice The coverage-scaled deposit (`_execute` deploys what the proposal's
///         `effectiveMaxCapital` can actually cover, not the pinned
///         `depositAmount`). Its own contract for the same solc tag-space reason
///         the file is already split.
contract LighterPerpStrategyCoverageTest is LighterPerpStrategyBase {
    event Deposited(uint256 amount, uint48 accountIndex);

    /// @dev The pre-#27 governor shape: neither getter answers, so the pinned
    ///      amount is pulled verbatim. This is the ONLY safe degradation — such
    ///      a governor also never scales the per-call caps.
    function test_execute_legacyGovernor_pullsPinnedAmount() public {
        _executeFirst();
        assertEq(strategy.deployedAmount(), DEPOSIT, "deployedAmount");
        assertEq(zk.l2Balance(address(strategy)), DEPOSIT, "venue balance");
        assertEq(usdg.balanceOf(vault), 0, "vault float");
    }

    function test_execute_fullyCovered_pullsPinnedAmount() public {
        gov.setCapital(100_000e6, 100_000e6);
        _executeFirst();
        assertEq(strategy.deployedAmount(), DEPOSIT, "deployedAmount");
        assertEq(zk.l2Balance(address(strategy)), DEPOSIT, "venue balance");
    }

    /// @dev The vnet a3fb16 shape, exactly: a 100k envelope covered to 63%.
    ///      Pre-fix this reverted `CallCapExceeded` at the execute batch.
    function test_execute_underCovered_deploysScaledAmount() public {
        gov.setCapital(100_000e6, 63_000e6);
        uint256 expected = (DEPOSIT * 63_000e6) / 100_000e6; // 12_600e6

        // The `Deposited` amount must be the SCALED figure, not the declaration:
        // it is what an indexer reconstructs the position size from. Read off
        // the logs rather than `expectEmit`ed, because the venue picks the
        // account index and this assertion is about the amount.
        vm.recordLogs();
        _executeFirst();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(strategy) || logs[i].topics[0] != Deposited.selector) continue;
            (uint256 amount, uint48 acct) = abi.decode(logs[i].data, (uint256, uint48));
            assertEq(amount, expected, "Deposited.amount");
            assertEq(acct, strategy.accountIndex(), "Deposited.accountIndex");
            seen = true;
        }
        assertTrue(seen, "no Deposited event");

        assertEq(strategy.deployedAmount(), expected, "deployedAmount");
        assertEq(zk.l2Balance(address(strategy)), expected, "venue balance");
        assertEq(usdg.balanceOf(vault), DEPOSIT - expected, "surplus float stays in the vault");
        assertEq(strategy.depositAmount(), DEPOSIT, "the pinned declaration is untouched");
    }

    /// @dev FAIL CLOSED RATHER THAN DEPLOY DUST. A scaled amount under
    ///      `MIN_DEPOSIT` is not a smaller strategy, it is a strategy that
    ///      cannot be unwound for more than it cost in gas.
    function test_execute_scaledBelowMinDeposit_reverts() public {
        gov.setCapital(100_000e6, 4e6); // 20_000e6 * 4e6 / 100_000e6 = 800_000 < 1e6
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.DepositTooSmall.selector);
        strategy.execute();
    }

    /// @dev Coverage that floors to a zero envelope: `_deriveAndStoreEffectiveCapital`
    ///      accepts that outcome as a zero net-outflow cap, and the honest answer
    ///      here is to deploy nothing rather than to deploy zero.
    function test_execute_zeroEffectiveCapital_reverts() public {
        gov.setCapital(100_000e6, 0);
        vm.prank(vault);
        vm.expectRevert(LighterPerpStrategy.DepositTooSmall.selector);
        strategy.execute();
    }

    /// @dev A governor answering a ZERO declared envelope is not a scaling
    ///      signal — it is an unreadable one. Degrade to the pinned amount.
    function test_execute_zeroDeclaredEnvelope_pullsPinnedAmount() public {
        gov.setCapital(0, 0);
        _executeFirst();
        assertEq(strategy.deployedAmount(), DEPOSIT, "deployedAmount");
    }

    /// @dev No active proposal means nothing to scale against — but
    ///      `BaseStrategy.execute` refuses that case first, so the pull never
    ///      happens at all. Pinned here as the ordering it relies on.
    function test_execute_noActiveProposal_stillRefusedUpstream() public {
        gov.setActiveProposal(0);
        vm.prank(vault);
        vm.expectRevert(BaseStrategy.NotActiveProposalStrategy.selector);
        strategy.execute();
    }

    /// @dev THE ROUNDING EDGE, AND THE WHOLE REASON THE PULL IS RATIO-SCALED
    ///      RATHER THAN `min(depositAmount, effectiveMaxCapital)`. The governor
    ///      floors the per-call caps at `floor(cap_i * raised / required)`
    ///      (`_scaleCaps`) and the batch cap at
    ///      `floor(maxCapital * raised / required)` (`effectiveMaxCapital`).
    ///      The pull must be `<=` the FORMER, which is the smaller of the two
    ///      whenever `cap_i < maxCapital` — the bench's own shape (cap = the
    ///      deploy amount, maxCapital = the vault's whole TVL).
    function testFuzz_execute_neverExceedsTheScaledCallCap(uint256 raised, uint256 required, uint256 maxCapital)
        public
    {
        required = bound(required, 1, 1e30);
        raised = bound(raised, 1, required);
        maxCapital = bound(maxCapital, DEPOSIT, 1e30);

        uint256 effective = (maxCapital * raised) / required; // _deriveAndStoreEffectiveCapital
        uint256 scaledCallCap = (DEPOSIT * raised) / required; // _scaleCaps, on cap_i == DEPOSIT
        gov.setCapital(maxCapital, effective);

        uint256 expected = effective >= maxCapital ? DEPOSIT : (DEPOSIT * effective) / maxCapital;

        if (expected < 1e6) {
            vm.prank(vault);
            vm.expectRevert(LighterPerpStrategy.DepositTooSmall.selector);
            strategy.execute();
            return;
        }

        _executeFirst();
        assertEq(strategy.deployedAmount(), expected, "deployedAmount");
        assertLe(strategy.deployedAmount(), scaledCallCap, "pull exceeds the scaled per-call cap");
        assertLe(strategy.deployedAmount(), DEPOSIT, "pull exceeds the pinned declaration");
    }

    /// @dev The unwind accounts against what was DEPLOYED, not what was
    ///      declared: a scaled clone that queues its deployed amount settles
    ///      clean, with no shortfall waiver and no unvalued-residue mark.
    function test_scaledClone_settlesCleanAgainstDeployedAmount() public {
        gov.setCapital(100_000e6, 63_000e6);
        _executeFirst();
        uint256 deployed = strategy.deployedAmount();
        assertEq(deployed, 12_600e6);

        vm.startPrank(proposer);
        strategy.initiateReturn();
        strategy.queueWithdraw(uint64(deployed));
        vm.stopPrank();
        zk.mature(address(strategy));
        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();

        assertEq(strategy.returnedAssets(), deployed, "returnedAssets");
        assertFalse(strategy.hasUnvaluedResidue(), "clean settle marks nothing");
        assertEq(usdg.balanceOf(vault), DEPOSIT, "every USDG is home");
    }
}

contract MockVaultForLighter {
    address public governor;
    address public owner;
    /// @dev `_initialize` binds `USDG` against `IERC4626(vault()).asset()`.
    address public asset;

    /// @dev `BaseStrategy.onlyProposer` staticcalls this fail-closed (pashov
    ///      finding #9), so every proposer-gated path on a clone needs the vault
    ///      to answer. Default TRUE for the seeded proposer; `setAgent` is what
    ///      the de-registration tests flip.
    mapping(address => bool) private _agents;

    constructor(address gov_, address owner_, address asset_) {
        governor = gov_;
        owner = owner_;
        asset = asset_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setAgent(address who, bool ok) external {
        _agents[who] = ok;
    }

    function isAgent(address who) external view returns (bool) {
        return _agents[who];
    }

    /// @dev A faithful shrink of `SyndicateVault._recoverResidueVia`: measure the
    ///      vault's asset balance across a low-level, gas-capped `sweep()` into
    ///      the strategy and report the delta. Permissionless here exactly as it
    ///      is there, and the reason `sweep()` must be `onlyVault` — the real one
    ///      splits this delta with the exited redeem cohort, which is only a
    ///      complete measurement while `sweep()` is the single door.
    function collectResidue(address strategy) external returns (uint256 collected) {
        uint256 before = IERC20(asset).balanceOf(address(this));
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = strategy.call{gas: 1_500_000}(abi.encodeWithSelector(bytes4(0x35faa416)));
        ok; // result deliberately ignored, as in the vault
        return IERC20(asset).balanceOf(address(this)) - before;
    }
}

/// @notice The counterparty axis `LighterPerpStrategy._initialize` binds
///         `ZK_LIGHTER` through. Answers only `isCounterpartyAllowed`, which is
///         the single selector the strategy's raw staticcall asks for.
contract MockTierRegistryForLighter {
    mapping(address => bool) private _allowed;

    function setCounterpartyAllowed(address who, bool ok) external {
        _allowed[who] = ok;
    }

    function isCounterpartyAllowed(address who) external view returns (bool) {
        return _allowed[who];
    }
}

contract MockGovernorForLighter {
    uint256 internal _activeProposal;
    address internal _strategy;
    uint256 internal _executedAt;
    uint256 internal _duration;

    /// @dev Second hop of the `vault() -> governor() -> tierRegistry()` walk the
    ///      strategy uses to bind `ZK_LIGHTER` on the counterparty axis.
    address public tierRegistry;

    function setTierRegistry(address r) external {
        tierRegistry = r;
    }

    function setActiveProposal(uint256 pid) external {
        _activeProposal = pid;
    }

    /// @dev The coverage-scaling pair `_execute` reads. OFF BY DEFAULT and
    ///      deliberately so: both getters revert until `setCapital` is called,
    ///      which is exactly what a governor predating issue #27 does to a
    ///      staticcall for a selector it does not carry. Every other case in
    ///      this file therefore exercises the unscaled fallback.
    uint256 internal _maxCapital;
    uint256 internal _effectiveMaxCapital;
    bool internal _answersCapital;

    function setCapital(uint256 maxCapital_, uint256 effective_) external {
        _maxCapital = maxCapital_;
        _effectiveMaxCapital = effective_;
        _answersCapital = true;
    }

    function getRiskEnvelope(uint256) external view returns (uint256, uint16) {
        require(_answersCapital, "governor predates the risk envelope");
        return (_maxCapital, 10_000);
    }

    function getEffectiveMaxCapital(uint256) external view returns (uint256) {
        require(_answersCapital, "governor predates effectiveMaxCapital");
        return _effectiveMaxCapital;
    }

    function setProposal(address strategy_, uint256 executedAt_, uint256 duration_) external {
        _strategy = strategy_;
        _executedAt = executedAt_;
        _duration = duration_;
    }

    function getActiveProposal() external view returns (uint256) {
        return _activeProposal;
    }

    /// @dev `BaseStrategy.execute` requires `strategyOf(getActiveProposal())` to
    ///      name the calling clone (issue #150 clone-ratchet fix). Mirrors the
    ///      real governor: pid 0 is "no active proposal" and resolves to the zero
    ///      address, which is never a clone.
    function strategyOf(uint256 pid) external view returns (address) {
        if (pid == 0) return address(0);
        return _strategy;
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
