// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../../src/SyndicateVault.sol";
import {ISyndicateGovernor} from "../../../src/interfaces/ISyndicateGovernor.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";

/// @notice Router mock: `valueStrategy` returns the strategy's live mark and a
///         Lane-A-eligible flag the handler toggles.
contract MockRouterH {
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

/// @notice Strategy mock holding real USDC it can return on demand.
contract MockLiquidStrategyH {
    ERC20Mock immutable usdc;
    address immutable vaultAddr;
    uint256 public liq;

    constructor(ERC20Mock usdc_, address vault_) {
        usdc = usdc_;
        vaultAddr = vault_;
    }

    function setLiquidity(uint256 l) external {
        liq = l;
    }

    function availableLiquidity() external view returns (uint256) {
        return liq;
    }

    function withdrawTo(uint256 assets) external {
        require(msg.sender == vaultAddr, "not vault");
        usdc.transfer(vaultAddr, assets);
    }

    function pushAll() external {
        usdc.transfer(vaultAddr, usdc.balanceOf(address(this)));
    }
}

/// @notice Drives random instant deposit / instant withdraw / strategy-yield /
///         Lane-A toggle / settle sequences across execute→settle cycles.
///         Ground-truths the injected strategy PnL so the invariant can assert
///         the governor's `balance − snapshot − interimNetFlow` formula isolates
///         it (mid-proposal LP principal flows must cancel out).
contract InstantLiquidityHandler is Test {
    SyndicateVault public vault;
    ERC20Mock public usdc;
    MockRouterH public router;
    MockLiquidStrategyH public strat;
    address public mockGovernor;

    address[] public actors;

    bool public locked;
    bool public laneAOn;
    uint256 public pidCounter;
    uint256 public activePid;

    // Ground truth for the active proposal.
    uint256 public ghostSnapshot; // vault float at execute
    int256 public ghostStrategyPnl; // cumulative yield injected while active

    uint256 public settleAsserts;

    constructor(SyndicateVault vault_, ERC20Mock usdc_, MockRouterH router_, MockLiquidStrategyH strat_, address gov_) {
        vault = vault_;
        usdc = usdc_;
        router = router_;
        strat = strat_;
        mockGovernor = gov_;
        for (uint256 i; i < 3; i++) {
            address a = makeAddr(string.concat("il_actor", vm.toString(i)));
            actors.push(a);
            deal(address(usdc), a, 1_000_000e6);
            vm.prank(a);
            usdc.approve(address(vault), type(uint256).max);
        }
        _setLock(false, 0);
    }

    function _setLock(bool l, uint256 pid) internal {
        vm.mockCall(mockGovernor, abi.encodeWithSignature("getActiveProposal()"), abi.encode(l ? pid : uint256(0)));
        vm.mockCall(
            mockGovernor, abi.encodeWithSignature("openProposalCount()"), abi.encode(l ? uint256(1) : uint256(0))
        );
        if (l) {
            ISyndicateGovernor.StrategyProposal memory p;
            p.id = pid;
            p.vault = address(vault);
            p.strategy = address(strat);
            vm.mockCall(
                mockGovernor, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, pid), abi.encode(p)
            );
        }
    }

    /// @dev Keep the router mark and strategy on-demand liquidity in sync with
    ///      the strategy's real USDC holdings so live NAV and capacity are
    ///      consistent. Lane A eligibility is `laneAOn && locked`.
    function _syncStrategyMark() internal {
        uint256 held = usdc.balanceOf(address(strat));
        strat.setLiquidity(held);
        router.set(held, laneAOn && locked);
    }

    // ── actions ──

    function instantDeposit(uint256 actorSeed, uint256 amount) external {
        if (locked && !laneAOn) return; // deposit closed without Lane A
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 100_000e6);
        if (usdc.balanceOf(a) < amount) return;
        vm.prank(a);
        try vault.deposit(amount, a) {} catch {}
    }

    function instantWithdraw(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        uint256 mw = vault.maxWithdraw(a);
        if (mw == 0) return;
        amount = bound(amount, 1, mw);
        vm.prank(a);
        try vault.withdraw(amount, a, a) {} catch {}
        _syncStrategyMark();
    }

    function execute(uint256 amount) external {
        if (locked) return;
        activePid = ++pidCounter;
        ghostSnapshot = usdc.balanceOf(address(vault));
        ghostStrategyPnl = 0;
        // Deploy a bounded slice of float to the strategy (stand-in for the
        // governor execute batch), then lock + turn Lane A on.
        uint256 float = usdc.balanceOf(address(vault));
        if (float != 0) {
            uint256 amt = bound(amount, 0, float);
            vm.prank(address(vault));
            usdc.transfer(address(strat), amt);
        }
        locked = true;
        laneAOn = true;
        _setLock(true, activePid);
        _syncStrategyMark();
    }

    function strategyYield(int256 delta) external {
        if (!locked) return;
        uint256 held = usdc.balanceOf(address(strat));
        // `uint256(delta)`'s bits are just bound entropy; the sign routes
        // gain vs loss. Avoids int/uint mixing and int256-min negation.
        if (delta >= 0) {
            uint256 gain = bound(uint256(delta), 0, 50_000e6);
            deal(address(usdc), address(strat), held + gain);
            ghostStrategyPnl += int256(gain);
        } else {
            uint256 loss = bound(uint256(delta), 0, held);
            deal(address(usdc), address(strat), held - loss);
            ghostStrategyPnl -= int256(loss);
        }
        _syncStrategyMark();
    }

    function toggleLaneA(bool on) external {
        laneAOn = on;
        _syncStrategyMark();
    }

    function settle() external {
        if (!locked) return;
        // Read interim BEFORE unwind/reset; strategy returns everything (full unwind).
        int256 interim = vault.interimNetFlow();
        strat.pushAll();
        uint256 float = usdc.balanceOf(address(vault));

        // The governor's realized-PnL formula must isolate the injected yield:
        // deploy / Lane-A-deposit / instant-exit / strategy-pull terms all cancel.
        int256 pnl = int256(float) - int256(ghostSnapshot) - interim;
        assertEq(pnl, ghostStrategyPnl, "INV-IL1: settlement pnl != ground-truth strategy pnl");
        settleAsserts++;

        locked = false;
        laneAOn = false;
        _setLock(false, 0);
        _syncStrategyMark();
        vm.prank(mockGovernor);
        vault.onProposalSettled(activePid);
    }

    // ── views for invariants ──

    function lockedWithoutLaneA() external view returns (bool) {
        return locked && !laneAOn;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
