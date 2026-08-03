// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Aerodrome Router swap interface
interface IAeroRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Venice staking contract interface
interface IVeniceStaking {
    function stake(address recipient, uint256 amount) external;
}

/// @notice The hops walked to resolve the governance-owned adapter allowlist
///         from this strategy: `vault()` → `governor()` → `tierRegistry()` →
///         `isAdapterAllowed(spender)`. The SAME registry, reached the same
///         way, that `SyndicateVault._guardBatchCalls` and `PortfolioStrategy`
///         (issue #147) gate the spender/recipient of vault-funded approvals
///         against.
/// @dev    Declared locally rather than imported: every hop is a
///         length-checked raw staticcall, so the strategy takes on no type
///         dependency and no hop can revert `_initialize`. This interface
///         exists to generate selectors, not to type the responses.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isAdapterAllowed(address adapter) external view returns (bool);
}

/**
 * @title VeniceInferenceStrategy
 * @notice Loan-model strategy: vault lends asset to an agent for Venice private
 *         inference. The agent stakes VVV for sVVV (their inference license),
 *         uses Venice to run off-chain strategies, and repays the vault in the
 *         vault's asset (principal + profit from their off-chain work).
 *
 *         sVVV is non-transferrable on Base — it stays with the agent permanently.
 *         The agent's proposal must justify the inference cost and repayment plan.
 *
 *   Execute: pull asset → [swap to VVV if needed] → stake → agent gets sVVV
 *   Settle:  agent repays vault in vault asset (principal + profit)
 *
 *   Two execution paths (determined by asset vs vvv):
 *     1. Direct: vault holds VVV → stake immediately
 *     2. Swap:   vault holds USDC → Aerodrome swap to VVV → stake
 *
 *   Batch calls from governor:
 *     Execute: [asset.approve(strategy, assetAmount), strategy.execute()]
 *     Settle:  [strategy.settle()]
 *
 *   Pre-requisite: agent must call asset.approve(strategy, repaymentAmount)
 *   before settlement. The agent earns off-chain and repays in vault asset.
 *
 *   Tunable params (updatable by proposer between execution and settlement):
 *     - repaymentAmount: total amount agent will repay (principal + profit)
 *     - minVVV: minimum VVV from swap (swap path only)
 *     - deadlineOffset: seconds for swap deadline (swap path only)
 */
contract VeniceInferenceStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ── Errors ──
    error InvalidAmount();
    error SwapFailed();
    error NoAgent();
    /// @notice repaymentAmount cannot drop below the loan's principal (`assetAmount`).
    error RepaymentBelowPrincipal();
    /// @notice `aeroRouter`/`sVVV` must be allowlisted in the vault's tier
    ///         registry — see `_requireAllowedAdapter`.
    error AdapterNotAllowed(address adapter, address registry);

    // ── Initialization parameters ──
    struct InitParams {
        address asset; // token pulled from vault (VVV for direct, or USDC etc. for swap)
        address weth; // intermediate token for multi-hop swap (ignored if direct or singleHop)
        address vvv; // VVV token
        address sVVV; // sVVV staking contract (also ERC-20)
        address aeroRouter; // Aerodrome router (address(0) if asset == vvv)
        address aeroFactory; // Aerodrome factory (address(0) if asset == vvv)
        address agent; // single agent wallet receiving sVVV (the proposer)
        uint256 assetAmount; // amount of asset to pull from vault (the "loan")
        uint256 minVVV; // min VVV output from swap (0 if asset == vvv)
        uint256 deadlineOffset; // seconds added to block.timestamp for swap deadline
        bool singleHop; // true for direct asset→VVV swap (no WETH hop)
    }

    // ── Storage (per-clone) ──
    address public asset;
    address public weth;
    address public vvv;
    address public sVVV;
    address public aeroRouter;
    address public aeroFactory;
    address public agent;

    uint256 public assetAmount;
    uint256 public minVVV;
    uint256 public deadlineOffset;
    bool public singleHop;

    uint256 public stakedAmount; // VVV staked during execute (for reference)
    uint256 public repaymentAmount; // amount agent must repay in vault asset (defaults to assetAmount)

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Venice Inference";
    }

    /// @notice Whether this clone swaps asset→VVV or receives VVV directly
    function needsSwap() public view returns (bool) {
        return asset != vvv;
    }

    /// @notice Decode: InitParams struct
    function _initialize(bytes calldata data) internal override {
        InitParams memory p = abi.decode(data, (InitParams));

        if (p.asset == address(0) || p.vvv == address(0) || p.sVVV == address(0)) revert ZeroAddress();
        if (p.agent == address(0)) revert NoAgent();
        if (p.assetAmount == 0) revert InvalidAmount();

        if (p.asset != p.vvv) {
            if (p.aeroRouter == address(0) || p.aeroFactory == address(0)) revert ZeroAddress();
            if (!p.singleHop && p.weth == address(0)) revert ZeroAddress();
            if (p.minVVV == 0) revert InvalidAmount();
            _requireAllowedAdapter(p.aeroRouter);
        }
        _requireAllowedAdapter(p.sVVV);

        asset = p.asset;
        weth = p.weth;
        vvv = p.vvv;
        sVVV = p.sVVV;
        aeroRouter = p.aeroRouter;
        aeroFactory = p.aeroFactory;
        agent = p.agent;
        assetAmount = p.assetAmount;
        minVVV = p.minVVV;
        deadlineOffset = p.deadlineOffset == 0 ? 300 : p.deadlineOffset;
        singleHop = p.singleHop;

        // Default repayment = principal (no profit). Agent updates via updateParams.
        repaymentAmount = p.assetAmount;
    }

    /// @notice Pull asset from vault → [swap to VVV if needed] → stake to agent
    function _execute() internal override {
        _pullFromVault(asset, assetAmount);

        uint256 vvvToStake;

        if (needsSwap()) {
            IERC20(asset).forceApprove(aeroRouter, assetAmount);

            IAeroRouter.Route[] memory routes;
            if (singleHop) {
                routes = new IAeroRouter.Route[](1);
                routes[0] = IAeroRouter.Route({from: asset, to: vvv, stable: false, factory: aeroFactory});
            } else {
                routes = new IAeroRouter.Route[](2);
                routes[0] = IAeroRouter.Route({from: asset, to: weth, stable: false, factory: aeroFactory});
                routes[1] = IAeroRouter.Route({from: weth, to: vvv, stable: false, factory: aeroFactory});
            }

            uint256[] memory amounts = IAeroRouter(aeroRouter)
                .swapExactTokensForTokens(assetAmount, minVVV, routes, address(this), block.timestamp + deadlineOffset);
            vvvToStake = amounts[amounts.length - 1];
            if (vvvToStake == 0) revert SwapFailed();
        } else {
            vvvToStake = assetAmount;
        }

        // sVVV is non-transferrable and stays with the agent
        IERC20(vvv).forceApprove(sVVV, vvvToStake);
        IVeniceStaking(sVVV).stake(agent, vvvToStake);
        stakedAmount = vvvToStake;

        if (needsSwap()) _pushAllToVault(asset);
        _pushAllToVault(vvv);
    }

    /// @notice Agent repays the vault in the vault's asset (principal + profit).
    /// @dev Requires the agent to have approved this strategy for `repaymentAmount` of `asset`.
    ///      sVVV stays with the agent as their inference license; the governor computes P&L
    ///      from the vault balance diff and distributes fees.
    ///
    ///      A malicious or unresponsive agent can block settlement by withholding or revoking
    ///      approval, or letting their asset balance fall below `repaymentAmount` — there is
    ///      no in-contract force-close. Recovery is external: `SyndicateGovernor`'s
    ///      `emergencySettleWithCalls` lets the owner multisig write off the principal and
    ///      transition `Executed` → `Settled` without agent cooperation. sVVV is non-transferrable,
    ///      so the vault has no claim on the staked VVV regardless.
    function _settle() internal override {
        address _vault = this.vault();
        IERC20(asset).safeTransferFrom(agent, _vault, repaymentAmount);
    }

    /**
     * @notice Update repayment amount and/or swap slippage params.
     * @dev Decode: (uint256 newRepayment, uint256 newMinVVV, uint256 newDeadlineOffset)
     *      Pass 0 to keep current value. Only proposer, only while Executed.
     *
     *      The agent should call this before settlement to set repaymentAmount
     *      to principal + profit earned from their off-chain strategy.
     */
    function _updateParams(bytes calldata data) internal override {
        (uint256 newRepayment, uint256 newMinVVV, uint256 newDeadlineOffset) =
            abi.decode(data, (uint256, uint256, uint256));
        if (newRepayment > 0) {
            // Blocks the proposer from reducing the agent's repayment below principal,
            // which would let the agent keep the borrowed capital after a token settlement.
            if (newRepayment < assetAmount) revert RepaymentBelowPrincipal();
            repaymentAmount = newRepayment;
        }
        if (newMinVVV > 0) minVVV = newMinVVV;
        if (newDeadlineOffset > 0) deadlineOffset = newDeadlineOffset;
    }

    // ── Lane B only ──
    // Inherits BaseStrategy's empty `positions()` default (queue-only). Loan
    // model — the vault's asset was transferred to the agent at execute, and
    // sVVV (held by the agent, non-transferrable) is not an asset this strategy
    // owns. There is no mid-strategy position on this contract to value.

    // ── Adapter binding (issue #155, mirrors PortfolioStrategy / issue #147) ──

    /// @dev Reverts unless `adapter` is allowlisted in the `TierRegistry` the
    ///      vault's own governor gates batch approvals against, resolved
    ///      `vault() → governor() → tierRegistry()`. Skips only when that
    ///      walk yields no registry — the same condition under which
    ///      `SyndicateVault._guardBatchCalls` disables itself, and one the
    ///      proposer cannot steer because no hop of the walk is proposer
    ///      input. A registry that IS resolved but whose `isAdapterAllowed`
    ///      is unreadable (wrong address wired, non-registry contract) fails
    ///      CLOSED: a registry that cannot vouch for the adapter has not
    ///      vouched for it. Every hop is a length-checked raw staticcall so a
    ///      codeless or hostile target reads as unresolved rather than
    ///      reverting some unrelated deployment.
    ///
    ///      Called from `_initialize` only, once per address that receives an
    ///      ERC-20 approval: `aeroRouter` (only when a swap is needed) and
    ///      `sVVV` (always). Not re-checked from `_execute`/`_settle` —
    ///      re-checking post-init would turn a post-execute demotion into a
    ///      capital hostage (the loan is already outstanding to the agent by
    ///      then).
    function _requireAllowedAdapter(address adapter) private view {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return;
        address registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
        if (registry == address(0)) return;
        if (!_isAdapterAllowed(registry, adapter)) revert AdapterNotAllowed(adapter, registry);
    }

    /// @dev Staticcall-safe `isAdapterAllowed`. Unreadable → `false` (see the
    ///      fail-closed rationale on `_requireAllowedAdapter`).
    function _isAdapterAllowed(address registry, address adapter) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) = registry.staticcall(abi.encodeCall(ITierBindingPath.isAdapterAllowed, (adapter)));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (bool));
    }

    /// @dev Staticcall-safe address read: codeless target, revert, short
    ///      return, or dirty upper bits all resolve to `address(0)`.
    function _readAddress(address target, bytes memory data) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length != 32) return address(0);
        uint256 word = abi.decode(ret, (uint256));
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }
}
