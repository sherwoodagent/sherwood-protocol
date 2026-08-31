// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILaunchAdapter} from "../../src/interfaces/ILaunchAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/**
 * @title MockLaunchAdapter
 * @notice `ILaunchAdapter` stand-in for Foundry unit tests — not for
 *         production. Every venue behaviour the strategy must survive is a
 *         switch here: an unsupported quote lane, a live native launch fee in
 *         an arbitrary token, an under-delivered reserve, a supply that does
 *         not match what the proposer declared, a reverting `collectFees`, and
 *         a `launchTarget()` that does or does not implement
 *         `transferCreator`.
 *
 *   `launch` deploys a fresh `ERC20Mock` per call, mints `mintToCaller` to
 *   `msg.sender` (the strategy) and the remainder of `mintTotal` to itself, so
 *   `totalSupply()` is exactly `mintTotal`.
 */
contract MockLaunchAdapter is ILaunchAdapter {
    using SafeERC20 for IERC20;

    /// @notice Quote lanes this "venue" accepts.
    mapping(address => bool) public supportedQuote;

    /// @notice Live native-fee source, mirroring `nativeFeeSource()`.
    address public feeToken;
    uint256 public feeAmount;

    /// @notice Total supply the "venue" mints, and how much of it lands on the
    ///         calling strategy. Set per test so both the custody check and the
    ///         declared-supply check can be exercised independently.
    uint256 public mintTotal;
    uint256 public mintToCaller;
    /// @notice When true, `mintToCaller` is used verbatim; otherwise the
    ///         adapter honours `p.reserveAmount`.
    bool public overrideReserve;

    /// @notice The venue contract `launchTarget()` reports.
    address public target;

    /// @notice Toggles for the settle-time tolerated-failure legs.
    bool public collectFeesReverts;

    /// @notice OPT-IN, DEFAULT OFF: reproduce the destination switch
    ///         `ILaunchAdapter.collectFees` makes normative and
    ///         `StonkLaunchAdapter` implements — pay the owning strategy while
    ///         it is live, and that strategy's VAULT once it has settled.
    ///
    /// @dev    Off by default so every pre-existing test keeps meaning exactly
    ///         what it meant: the flat "always pays the owner" behaviour. The
    ///         switch is what makes the settle-time lane observable in a unit
    ///         test, and that lane is the reason the strategy's in-window
    ///         `collectFees()` exists at all.
    bool public payVaultWhenOwnerSettled;

    /// @notice Fee accrual `collectFees` delivers to the launch's owner.
    uint256 public feeQuoteOut;
    uint256 public feeTokenOut;

    LaunchPhase public reportedPhase = LaunchPhase.Live;

    /// @notice Last launch this adapter issued.
    address public lastToken;
    bytes32 public lastRef;
    address public ownerOf;
    address public lastQuoteToken;
    uint256 public lastQuoteIn;
    uint256 public lastMinTokensOut;
    uint256 public lastReserveAmount;
    uint64 public lastDeadline;
    bytes public lastVenueData;

    error CollectFeesBroken();

    // ── Configuration ──

    function setQuoteSupported(address quote, bool ok) external {
        supportedQuote[quote] = ok;
    }

    function setNativeFee(address token, uint256 amount) external {
        feeToken = token;
        feeAmount = amount;
    }

    function setMint(uint256 total, uint256 toCaller, bool override_) external {
        mintTotal = total;
        mintToCaller = toCaller;
        overrideReserve = override_;
    }

    function setTarget(address target_) external {
        target = target_;
    }

    function setCollectFeesReverts(bool v) external {
        collectFeesReverts = v;
    }

    function setFeeAccrual(uint256 quoteOut, uint256 tokenOut) external {
        feeQuoteOut = quoteOut;
        feeTokenOut = tokenOut;
    }

    function setPhase(LaunchPhase p) external {
        reportedPhase = p;
    }

    function setPayVaultWhenOwnerSettled(bool v) external {
        payVaultWhenOwnerSettled = v;
    }

    // ── ILaunchAdapter ──

    /// @inheritdoc ILaunchAdapter
    function launch(LaunchParams calldata p) external payable returns (LaunchResult memory) {
        if (p.quoteIn != 0) IERC20(p.quoteToken).safeTransferFrom(msg.sender, address(this), p.quoteIn);
        if (feeAmount != 0) IERC20(feeToken).safeTransferFrom(msg.sender, address(this), feeAmount);

        ERC20Mock token = new ERC20Mock(p.name, p.symbol, 18);
        uint256 toCaller = overrideReserve ? mintToCaller : p.reserveAmount;
        uint256 total = mintTotal;
        token.mint(msg.sender, toCaller);
        if (total > toCaller) token.mint(address(this), total - toCaller);

        lastToken = address(token);
        lastRef = bytes32(uint256(uint160(address(token))));
        ownerOf = msg.sender;
        lastQuoteToken = p.quoteToken;
        lastQuoteIn = p.quoteIn;
        lastMinTokensOut = p.minTokensOut;
        lastReserveAmount = p.reserveAmount;
        lastDeadline = p.deadline;
        lastVenueData = p.venueData;

        return LaunchResult({token: address(token), launchRef: lastRef, reserveHeld: toCaller, quoteSpent: p.quoteIn});
    }

    /// @inheritdoc ILaunchAdapter
    function phase(bytes32) external view returns (LaunchPhase) {
        return reportedPhase;
    }

    /// @inheritdoc ILaunchAdapter
    function finalize(bytes32) external {}

    /// @inheritdoc ILaunchAdapter
    /// @dev NEVER PAYS THE CALLER. The destination is the owning strategy, or —
    ///      when `payVaultWhenOwnerSettled` is on and that strategy reports
    ///      `Settled` — the strategy's vault.
    function collectFees(bytes32) external returns (uint256 quoteOut, uint256 tokenOut) {
        if (collectFeesReverts) revert CollectFeesBroken();
        quoteOut = feeQuoteOut;
        tokenOut = feeTokenOut;
        address destination = _destination();
        if (quoteOut != 0) IERC20(lastQuoteToken).safeTransfer(destination, quoteOut);
        if (tokenOut != 0) IERC20(lastToken).safeTransfer(destination, tokenOut);
    }

    /// @dev `BaseStrategy.State.Settled == 2`, read by raw staticcall the way a
    ///      real adapter must: the owner is not necessarily a `BaseStrategy`,
    ///      and an unreadable answer means "not settled" (fail-closed toward
    ///      the pre-settlement lane).
    function _destination() private view returns (address) {
        if (!payVaultWhenOwnerSettled) return ownerOf;
        (bool ok, bytes memory ret) = ownerOf.staticcall(abi.encodeWithSignature("state()"));
        if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != 2) return ownerOf;
        (bool vOk, bytes memory vRet) = ownerOf.staticcall(abi.encodeWithSignature("vault()"));
        if (!vOk || vRet.length != 32) return ownerOf;
        return abi.decode(vRet, (address));
    }

    /// @inheritdoc ILaunchAdapter
    function quoteSupported(address quote) external view returns (bool) {
        return supportedQuote[quote];
    }

    /// @inheritdoc ILaunchAdapter
    function nativeFeeSource() external view returns (address, uint256) {
        return (feeToken, feeAmount);
    }

    /// @inheritdoc ILaunchAdapter
    function launchTarget() external view returns (address) {
        return target;
    }
}

/// @notice A venue that implements Sushi's transferable creator role.
contract MockCreatorVenue {
    address public lastToken;
    address public lastCreator;
    uint256 public calls;

    function transferCreator(address token, address newCreator) external {
        lastToken = token;
        lastCreator = newCreator;
        calls++;
    }
}

/// @notice A venue whose `transferCreator` reverts — the tolerated-failure leg.
contract MockRevertingCreatorVenue {
    error CreatorTransferBroken();

    function transferCreator(address, address) external pure {
        revert CreatorTransferBroken();
    }
}

/// @notice A venue with NO `transferCreator` selector at all (StonkBrokers
///         shape). The strategy's fixed-selector call simply no-ops.
contract MockNoCreatorVenue {
    function ping() external pure returns (uint256) {
        return 1;
    }
}
