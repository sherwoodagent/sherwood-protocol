// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";

/// @notice PriceRouter mock. Mirrors the real `PriceRouter.valueStrategy`'s
///         `(0, false)` return once a strategy's positions are empty — the
///         strategy mock below calls `set(0, false)` itself once it is fully
///         drained, the same causal chain a real integrated PriceRouter +
///         strategy pair would produce (`positions()` reports empty ->
///         `valueStrategy` returns `(0, false)`).
contract MockRouterFor100 {
    uint256 public v;
    bool public ok;

    function set(uint256 v_, bool ok_) external {
        v = v_;
        ok = ok_;
    }

    function valueStrategy(address) external view returns (uint256, bool) {
        return (v, ok);
    }
}

/// @notice Strategy mock holding real vault-asset it delivers on demand, that
///         flips its own router entry to `(0, false)` the instant a pull
///         empties it — faithfully modelling why `_laneState()` can disagree
///         with itself across one `_withdraw` call.
contract MockDrainingStrategy {
    ERC20Mock immutable asset_;
    address immutable vault_;
    MockRouterFor100 immutable router;
    uint256 public liq;

    constructor(ERC20Mock asset__, address vaultAddr, MockRouterFor100 router_) {
        asset_ = asset__;
        vault_ = vaultAddr;
        router = router_;
    }

    function setLiquidity(uint256 l) external {
        liq = l;
    }

    function availableLiquidity() external view returns (uint256) {
        return liq;
    }

    function withdrawTo(uint256 assets) external {
        require(msg.sender == vault_, "not vault");
        require(assets <= liq, "over-request");
        liq = 0;
        asset_.transfer(vault_, assets);
        // THE CAUSAL LINK issue #100 is about: MANY real single-position
        // strategies (one Uniswap V3 NFT range, one Aave supply position,
        // ...) cannot service a PARTIAL withdrawal without fully unwinding —
        // there is no such thing as "remove $180k of a $200k concentrated LP
        // position and leave the rest live." One pull, of ANY size, empties
        // `positions()` entirely. That is exactly what flips a real
        // `PriceRouter.valueStrategy` from `(v, true)` to `(0, false)`
        // mid-`_withdraw` — not a knife-edge "pulled to exactly zero" case.
        router.set(0, false);
    }
}

/// @title Vault_withdrawLaneStateConsistency
/// @notice Issue #100 — `previewRedeem` evaluated `_laneState()` BEFORE
///         `_pullFromStrategy` and DEDUCTED `_exitFees(shares)` from the
///         payout. `_withdraw` re-evaluated `_laneState()` AFTER the pull and
///         only THEN CREDITED `_crystallizedMgmt`/`_crystallizedPerf`. The
///         deduction was unconditional on the pre-pull value; the credit was
///         conditional on the post-pull value, and nothing reconciled them.
///
/// @dev    Fixed by hoisting ONE `_laneState()` evaluation to the top of
///         `_withdraw`, before `_pullFromStrategy` can move anything, and
///         reusing that snapshot for both the pull-eligibility check and the
///         crystallization gate. Every test below was written against
///         unpatched `main` and reproduced there first: a full-supply exit
///         that unwinds a single-position strategy (realistic for many real
///         strategies — a Uniswap V3 NFT range or an Aave supply position
///         cannot service a partial withdrawal) flipped `laneA` false
///         mid-call, and the fee baked into the exiter's `assets` was never
///         credited anywhere.
contract VaultWithdrawLaneStateConsistencyTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockRouterFor100 router;
    MockDrainingStrategy strat;
    MockProposalStatus governor;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    uint256 constant PID = 1;

    uint256 constant DEPOSIT = 800_000e6; // $800,000, alice's whole position
    uint256 constant STRATEGY_GAIN = 200_000e6; // $200,000 live, unrealized gain

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MockRouterFor100();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        strat = new MockDrainingStrategy(usdc, address(vault), router);

        governor = new MockProposalStatus();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));

        usdc.mint(alice, DEPOSIT);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Alice deposits her whole position pre-proposal (seeding the mark at
    ///      pps == 1 unit), then a proposal locks with Lane A live and the
    ///      strategy carrying `STRATEGY_GAIN` of real, deliverable liquidity —
    ///      sized so a full exit needs every last wei of it.
    function _reachFullyPulledExitWindow() internal {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        governor.set(PID, 1, address(strat));
        router.set(STRATEGY_GAIN, true);
        usdc.mint(address(strat), STRATEGY_GAIN);
        strat.setLiquidity(STRATEGY_GAIN);

        assertEq(vault.totalAssets(), DEPOSIT + STRATEGY_GAIN, "float + live strategy value");
    }

    /// @notice THE FEE NO LONGER VANISHES. A full-supply exit still triggers
    ///         the same mid-call unwind — `laneA` still flips false during the
    ///         pull — but the crystallization gate now reads the SAME
    ///         pre-pull snapshot the deduction used, so the fee is booked
    ///         rather than lost.
    function test_fullExitDrainingTheStrategy_creditsTheFeeItCharged() public {
        _reachFullyPulledExitWindow();

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 previewedPayout = vault.previewRedeem(aliceShares);
        assertLt(previewedPayout, DEPOSIT + STRATEGY_GAIN, "the preview deducts a fee, as before");

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        uint256 delivered = usdc.balanceOf(alice) - aliceBefore;

        assertEq(delivered, previewedPayout, "alice still receives exactly the previewed, fee-deducted amount");
        // THE FIX: the deducted fee is now actually booked.
        assertGt(vault.crystallizedPerf(), 0, "the performance fee is now crystallized, not lost");

        // The mid-call flip still genuinely happens — the fix does not work
        // by avoiding it, but by no longer trusting a second read of it.
        assertEq(strat.liq(), 0, "the strategy still fully unwinds on this exit");
        assertFalse(router.ok(), "the router still flips to laneA=false mid-call");
    }

    /// @notice THE INVARIANT THE FIX ESTABLISHES: the sum of what leaves the
    ///         vault plus what stays crystallized as fees equals the FULL
    ///         pre-fee NAV entitlement — no value silently vanishes into
    ///         un-booked NAV. This is the property a future regression is
    ///         most likely to reintroduce by hoisting only ONE of the two
    ///         `_laneState()` call sites instead of both.
    function test_fullExitDrainingTheStrategy_noValueIsUnaccountedFor() public {
        _reachFullyPulledExitWindow();
        uint256 aliceShares = vault.balanceOf(alice);
        // The gross, pre-fee entitlement — the standard ERC-4626 conversion,
        // read BEFORE the redeem (it uses live totalAssets()/totalSupply(),
        // which the redeem itself changes).
        uint256 grossEntitlement = vault.convertToAssets(aliceShares);

        vm.prank(alice);
        uint256 delivered = vault.redeem(aliceShares, alice, alice);

        uint256 feesBooked = vault.crystallizedMgmt() + vault.crystallizedPerf();
        assertApproxEqAbs(
            delivered + feesBooked, grossEntitlement, 2, "delivered + booked fees accounts for the whole entitlement"
        );
    }
}
