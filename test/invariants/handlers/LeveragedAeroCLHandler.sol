// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase, IAggregatorV3} from "../../integration/strategies/LeveragedAeroForkBase.sol";
import {BaseAddresses} from "../../integration/strategies/BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroValuation} from "../../../src/strategies/LeveragedAeroValuation.sol";
import {IMoonwellMarket, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {INonfungiblePositionManager} from "../../../src/interfaces/ISlipstream.sol";
import {TickMath} from "../../../src/libraries/TickMath.sol";
import {LiquidityAmounts} from "../../../src/libraries/LiquidityAmounts.sol";

/// @notice Minimal share-ledger vault used by the leveraged-Aero strategy under test.
///         Mirrors `MockVaultForRedeem` from the redeem fork test: ERC20 approve /
///         transferFrom + strategyMint / strategyBurn + totalSupply / balanceOf.
contract MockVaultShares {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(address initialHolder, uint256 initialShares) {
        balanceOf[initialHolder] = initialShares;
        totalSupply = initialShares;
    }

    /// @dev L7: strategy reads vault().asset() at init — must equal the configured USDC.
    function asset() external pure returns (address) {
        return BaseAddresses.USDC;
    }

    /// @dev #421: strategy resolves protocol-fee params via vault().factory().protocolConfig();
    ///      factory()==0 ⇒ no protocol fee. Mock must track ISyndicateVault (CLAUDE.md MockRegistryMinimal lesson).
    function factory() external pure returns (address) {
        return address(0);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ERC20InsufficientAllowance");
        allowance[from][msg.sender] -= amount;
        require(balanceOf[from] >= amount, "ERC20InsufficientBalance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20InsufficientBalance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function strategyMint(address to, uint256 shares) external {
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function strategyBurn(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "insufficient balance");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
    }
}

/// @title  LeveragedAeroCLHandler
/// @notice Invariant handler driving random deposit / redeem / deployIdle / compound /
///         rerange / adjustLeverage / deleverage / tick-shove sequences against a real
///         leveraged Aerodrome-CL book on a Base fork.
///
///         Design goals (per task 3.12b):
///           • MOSTLY SUCCEED — bounded deposits/redeems gated to funded/held amounts,
///             proposer-only ops pranked from the proposer, AERO dealt before `compound`.
///           • Each op is bracketed by the manipulation-immune per-share ORACLE NAV
///             (oracle-implied sqrtP + Chainlink, NO calm-gate — the §7 arbiter). A drop
///             beyond a per-op slack budget flips `conservationViolated` (invariant d).
///           • Health (Chainlink basis, == `_assertHealthy`) is checked after every
///             successful non-deleverage op → `healthViolated` (invariant b).
///           • Ghost mint/burn + fair-payout accounting back invariants (c) and (a).
///
///         All heavy fork reads happen HERE (during fuzzing); the invariant_* assertions
///         in the test contract are trivial flag/ghost checks (the standard pattern).
contract LeveragedAeroCLHandler is LeveragedAeroForkBase {
    // ── system under test ──
    LeveragedAerodromeCLStrategy public strategy;
    MockVaultShares public vaultShares;
    address public proposer;
    address public stayer; // depositorA — never transacts (the continuous stayer)
    address public feeRecipient;
    bool public live;
    uint256 public minHealth;

    // ── actors (2 transacting LPs) ──
    address[] public actors;

    // ── bounds ──
    uint256 internal constant MIN_DEP = 100e6;
    uint256 internal constant MAX_DEP = 20_000e6;
    uint256 internal constant ACTOR_FUNDING = 750_000e6;

    // ── per-op conservation slack (bps). Tight where a redeem-skim would manifest;
    //    generous for swap-bearing ops whose legitimate cost is NOT a skim. ──
    uint256 internal constant SLACK_DEPOSIT = 20; // deposit mints at oracle mark → flat
    uint256 internal constant SLACK_REDEEM = 20; // §7: stayer dust-flat across partial redeem
    uint256 internal constant SLACK_RERANGE = 20; // no-swap recenter → principal conserved
    uint256 internal constant SLACK_SHOVE = 10; // pure pool move → oracle NAV immune
    uint256 internal constant SLACK_DEPLOY = 300; // borrow+add rounding / tiny cost
    uint256 internal constant SLACK_LEVER = 300; // lever-down residual rebalance swap
    uint256 internal constant SLACK_COMPOUND = 300; // realizes yield (↑) — slack only for the add leg

    // ── invariant flags + diagnostics ──
    bool public conservationViolated;
    string public consOp;
    uint256 public consPre;
    uint256 public consPost;
    uint256 public consSlack;

    bool public healthViolated;
    string public healthOp;
    uint256 public healthVal;

    // ── ghosts (invariants c + a) ──
    uint256 public ghostMinted; // Σ shares minted to actors via deposit (return value)
    uint256 public ghostBurned; // Σ shares burned via redeem (the redeemed amount)
    uint256 public ghostPaidOut; // Σ USDC paid to redeemers
    uint256 public ghostFairOut; // Σ oracle-fair entitlement of those redeems

    // ── call counters (non-vacuity + reporting) ──
    uint256 public opCount;
    uint256 public depositOk;
    uint256 public redeemOk;
    uint256 public deployOk;
    uint256 public compoundOk;
    uint256 public rerangeOk;
    uint256 public leverOk;
    uint256 public deleverageOk;
    uint256 public shoveOk;

    constructor(
        LeveragedAerodromeCLStrategy strategy_,
        MockVaultShares vaultShares_,
        address proposer_,
        address stayer_,
        address feeRecipient_,
        bool live_
    ) {
        strategy = strategy_;
        vaultShares = vaultShares_;
        proposer = proposer_;
        stayer = stayer_;
        feeRecipient = feeRecipient_;
        live = live_;

        actors.push(makeAddr("aero_lp_0"));
        actors.push(makeAddr("aero_lp_1"));

        if (live_) {
            minHealth = uint256(strategy_.layout().minHealthBps);
            for (uint256 i; i < actors.length; i++) {
                _fundUSDC(actors[i], ACTOR_FUNDING);
                vm.prank(actors[i]);
                IERC20(USDC).approve(address(strategy_), type(uint256).max);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Handler actions
    // ─────────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amtSeed) external {
        if (!live) return;
        opCount++;
        address a = actors[actorSeed % actors.length];
        uint256 amt = bound(amtSeed, MIN_DEP, MAX_DEP);
        if (IERC20(USDC).balanceOf(a) < amt) return;
        uint256 pre = _safePerShare();
        vm.prank(a);
        try strategy.deposit(amt, 0) returns (uint256 shares) {
            ghostMinted += shares;
            depositOk++;
            _postOp("deposit", pre, SLACK_DEPOSIT, true);
        } catch {}
    }

    /// @dev Exercises the oracle-free proportional-unwind mechanics (IL self-funding, stayer-safety)
    ///      through the ESCROWED async path — `requestRedeem` (actor) → `fulfillRedeem` (proposer) —
    ///      since the everyday `redeem` was demoted to the LTV-gated oracle-priced fast path. The
    ///      conservation/health brackets and ghost accounting are unchanged; the redeemer's payout is
    ///      measured via its USDC-balance delta (fulfill returns the amount only via event).
    function redeem(uint256 actorSeed, uint256 shareSeed) external {
        if (!live) return;
        opCount++;
        address a = actors[actorSeed % actors.length];
        uint256 bal = vaultShares.balanceOf(a);
        if (bal == 0) return;
        uint256 s = bound(shareSeed, 1, bal);

        uint256 supply = vaultShares.totalSupply();
        uint256 pre = _safePerShare();
        uint256 fair = _safeFair(s, supply);
        uint256 usdcBefore = IERC20(USDC).balanceOf(a);

        vm.prank(a);
        vaultShares.approve(address(strategy), s);
        vm.prank(a);
        try strategy.requestRedeem(s, 0) returns (uint256 id) {
            vm.prank(proposer);
            try strategy.fulfillRedeem(id) {
                ghostBurned += s;
                ghostPaidOut += IERC20(USDC).balanceOf(a) - usdcBefore;
                ghostFairOut += fair;
                redeemOk++;
                _postOp("redeem", pre, SLACK_REDEEM, true);
            } catch {
                // Fulfill failed (e.g. IL under a shove) — return the escrowed shares so the escrow
                // never strands them (keeps the totalSupply/holder-sum invariant intact).
                vm.prank(a);
                strategy.cancelRedeem(id);
            }
        } catch {}
    }

    function deployIdle(uint256 amtSeed) external {
        if (!live) return;
        opCount++;
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        if (idle < MIN_DEP) return;
        uint256 amt = bound(amtSeed, 1e6, idle);
        uint256 pre = _safePerShare();
        vm.prank(proposer);
        try strategy.deployIdle(amt, 0) {
            deployOk++;
            _postOp("deployIdle", pre, SLACK_DEPLOY, true);
        } catch {}
    }

    function compound(uint256 aeroSeed) external {
        if (!live) return;
        opCount++;
        // Frozen-clock fork accrues ~0 gauge AERO; seed a bounded amount so the swap+redeploy
        // path actually executes (task: "compound funds AERO via deal").
        uint256 aero = bound(aeroSeed, 1e18, 100e18);
        address aeroTok = ICLGaugeReward(GAUGE).rewardToken();
        deal(aeroTok, address(strategy), aero);
        uint256 pre = _safePerShare();
        vm.prank(proposer);
        // L8: minUsdcOut must be nonzero (ZeroMinOut floor); 1 is a near-zero floor the seeded
        // AERO swap clears, keeping the compound→swap→redeploy path live in the invariant.
        try strategy.compound(1, 0) {
            compoundOk++;
            _postOp("compound", pre, SLACK_COMPOUND, true);
        } catch {}
    }

    function rerange() external {
        if (!live) return;
        opCount++;
        uint256 pre = _safePerShare();
        vm.prank(proposer);
        try strategy.rerange(4000, 0, 0) {
            rerangeOk++;
            _postOp("rerange", pre, SLACK_RERANGE, true);
        } catch {}
    }

    function adjustLeverage(uint256 ltvSeed) external {
        if (!live) return;
        opCount++;
        uint16 maxLtv = strategy.layout().maxLtvBps;
        uint16 target = uint16(bound(ltvSeed, 3000, uint256(maxLtv)));
        uint256 pre = _safePerShare();
        vm.prank(proposer);
        try strategy.adjustLeverage(target, 0, 0) {
            leverOk++;
            _postOp("adjustLeverage", pre, SLACK_LEVER, true);
        } catch {}
    }

    function deleverage() external {
        if (!live) return;
        opCount++;
        uint256 pre = _safePerShare();
        // Permissionless; in the no-mock mixed fuzz the book stays healthy so this reverts
        // (HealthyNoDeleverage) — caught. Health is EXCLUDED for a successful deleverage.
        try strategy.deleverage(0) {
            deleverageOk++;
            _postOp("deleverage", pre, SLACK_LEVER, false);
        } catch {}
    }

    function shove(uint256 dirSeed, uint256 amtSeed) external {
        if (!live) return;
        opCount++;
        bool zeroForOne = (dirSeed % 2) == 0; // sell WETH (down) vs sell cbBTC (up)
        uint256 amt = zeroForOne ? bound(amtSeed, 1e18, 25e18) : bound(amtSeed, 5e6, 5e8);
        uint256 pre = _safePerShare();
        // _shoveTick touches only the pool (separate swapper) — strategy position/debt/collateral
        // are untouched, so the oracle NAV (and per-share) must be EXACTLY flat (immunity check).
        try this.externalShove(amt, zeroForOne) {
            shoveOk++;
            _postOp("shove", pre, SLACK_SHOVE, true);
        } catch {}
    }

    /// @dev External wrapper so a reverting swap (e.g. price-limit hit) is caught, not bubbled.
    function externalShove(uint256 amt, bool zeroForOne) external {
        require(msg.sender == address(this), "self");
        _shoveTick(amt, zeroForOne);
    }

    // ─────────────────────────────────────────────────────────────
    // Post-op bracket: conservation (d) + health (b)
    // ─────────────────────────────────────────────────────────────

    function _postOp(string memory op, uint256 pre, uint256 slackBps, bool checkHealth) internal {
        // (d) per-share oracle NAV non-decreasing within this op's slack budget.
        uint256 post = _safePerShare();
        if (pre > 0 && post > 0 && !conservationViolated) {
            uint256 floor = (pre * (10000 - slackBps)) / 10000;
            if (post < floor) {
                conservationViolated = true;
                consOp = op;
                consPre = pre;
                consPost = post;
                consSlack = slackBps;
            }
        }
        // (b) health on the Chainlink basis (== _assertHealthy). Skip when flat-book (no debt) or
        // when excluded (deleverage). No price is mocked in the mixed fuzz, so a successful op must
        // leave health >= minHealthBps.
        if (checkHealth && !healthViolated && strategy.layout().tokenId != 0) {
            uint256 h = _safeHealth();
            if (h < minHealth) {
                healthViolated = true;
                healthOp = op;
                healthVal = h;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Manipulation-immune oracle NAV (the §7 arbiter) + health basis
    // ─────────────────────────────────────────────────────────────

    /// @notice Per-share oracle NAV (1e18-scaled): oracle-implied sqrtP + Chainlink, NO calm-gate.
    function perShareNoGate() public view returns (uint256) {
        uint256 supply = vaultShares.totalSupply();
        if (supply == 0) return 0;
        return (oracleNavNoGate() * 1e18) / supply;
    }

    /// @notice Whole-book oracle NAV (USDC 6dp). Mirrors `LeveragedAeroValuation.netEquityUsdc`
    ///         term-for-term minus the calm-gate, so it stays computable at a shoved tick and is
    ///         immune to tick manipulation. Pool token0 == WETH (fork-confirmed).
    function oracleNavNoGate() public view returns (uint256) {
        (, int256 btc,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_BTC_USD).latestRoundData();
        (, int256 eth,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_ETH_USD).latestRoundData();
        (, int256 usd,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_USDC_USD).latestRoundData();
        uint256 pBTC = uint256(btc);
        uint256 pETH = uint256(eth);
        uint256 pUsdc = uint256(usd);
        address strat = address(strategy);

        uint256 assets = IERC20(USDC).balanceOf(strat);
        uint256 cBal = ICToken(MUSDC).balanceOf(strat);
        if (cBal > 0) assets += (cBal * ICToken(MUSDC).exchangeRateStored()) / 1e18;

        uint256 tid = strategy.layout().tokenId;
        if (tid != 0) {
            (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = INonfungiblePositionManager(NPM).positions(tid);
            if (liq > 0) {
                uint160 sqrtP = LeveragedAeroValuation.oracleSqrtPriceX96(pETH, 18, pBTC, 8);
                (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtP, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liq
                );
                assets += _usdcV(a0, 18, pETH, pUsdc); // WETH leg
                assets += _usdcV(a1, 8, pBTC, pUsdc); // cbBTC leg
            }
        }
        // idle (out-of-position) borrowed legs — the rerange remainder lives here
        assets += _usdcV(IERC20(CBBTC).balanceOf(strat), 8, pBTC, pUsdc);
        assets += _usdcV(IERC20(WETH).balanceOf(strat), 18, pETH, pUsdc);

        uint256 debt = _usdcV(IMoonwellMarket(MCBBTC).borrowBalanceStored(strat), 8, pBTC, pUsdc)
            + _usdcV(IMoonwellMarket(MWETH).borrowBalanceStored(strat), 18, pETH, pUsdc);

        return assets > debt ? assets - debt : 0;
    }

    /// @notice Health in bps on the same hardened-Chainlink basis as `_assertHealthy`
    ///         (`collateralUsdc × 1e4 / debtUsdc`). type(uint256).max when debt-free.
    function healthBps() public view returns (uint256) {
        address strat = address(strategy);
        uint256 cBal = ICToken(MUSDC).balanceOf(strat);
        uint256 c = (cBal * ICToken(MUSDC).exchangeRateStored()) / 1e18;
        uint256 cbDebt = IMoonwellMarket(MCBBTC).borrowBalanceStored(strat);
        uint256 wethDebt = IMoonwellMarket(MWETH).borrowBalanceStored(strat);
        if (cbDebt == 0 && wethDebt == 0) return type(uint256).max;
        (, int256 btc,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_BTC_USD).latestRoundData();
        (, int256 eth,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_ETH_USD).latestRoundData();
        (, int256 usd,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_USDC_USD).latestRoundData();
        uint256 d = _usdcV(cbDebt, 8, uint256(btc), uint256(usd)) + _usdcV(wethDebt, 18, uint256(eth), uint256(usd));
        return d == 0 ? type(uint256).max : (c * 10000) / d;
    }

    // ── safe (revert-tolerant) wrappers for the bracket ──
    function _safePerShare() internal view returns (uint256) {
        try this.perShareNoGate() returns (uint256 p) {
            return p;
        } catch {
            return 0;
        }
    }

    function _safeHealth() internal view returns (uint256) {
        try this.healthBps() returns (uint256 h) {
            return h;
        } catch {
            return type(uint256).max; // unreadable feed → don't false-flag health
        }
    }

    function _safeFair(uint256 shares, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return 0;
        try this.oracleNavNoGate() returns (uint256 n) {
            return (n * shares) / supply;
        } catch {
            return 0;
        }
    }

    function _usdcV(uint256 amount, uint8 dec, uint256 pTok, uint256 pUsdc) private pure returns (uint256) {
        if (amount == 0 || pTok == 0 || pUsdc == 0) return 0;
        return (((amount * pTok) / (10 ** uint256(dec))) * 1e6) / pUsdc;
    }

    // ─────────────────────────────────────────────────────────────
    // Views for invariant assertions
    // ─────────────────────────────────────────────────────────────

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

/// @dev Minimal gauge reward-token reader (avoids importing the full ICLGauge surface here).
interface ICLGaugeReward {
    function rewardToken() external view returns (address);
}
