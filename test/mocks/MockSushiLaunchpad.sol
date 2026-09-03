// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISushiLaunchpad} from "../../src/vendor/sushi/ISushiLaunchpad.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  MockSushiLaunchpad
/// @notice Faithful-enough double for Sushi Launchpad V1 (`0x104f…a7ed` on
///         Robinhood 4663). It reproduces the behaviours `SushiLaunchAdapter`
///         actually depends on and nothing else:
///           - fixed supply minted to the LAUNCHPAD; the creator gets zero, so
///             the initial buy is the only source of launch tokens;
///           - a NATIVE launch fee taken from `msg.value`;
///           - an owner-managed `quoteTokenPriceFeed` registry, settable here so
///             a test can simulate the venue owner whitelisting WOOD;
///           - a transferable creator role, and a PERMISSIONLESS
///             `distributeFees` that pays the CURRENT creator in both legs;
///           - `launchInfo` REVERTING `UnknownToken` for an unissued token —
///             the behaviour that forces the adapter's raw staticcalls.
///         Test knobs (`setRate`, `setLaunchFee`, `setFeesOwed`,
///         `setDistributeReverts`, `setDistributeBurnsGas`) exist to drive the
///         adapter's edges; the real venue prices the buy off its V3 pool
///         instead.
contract MockSushiLaunchpad {
    /// @notice The venue's fixed supply: 1e9 tokens, 18 decimals.
    uint256 public constant SUPPLY = 1e9 * 1e18;
    /// @notice `protocolReserveBps = 300` on the live venue.
    uint256 public constant PROTOCOL_RESERVE_BPS = 300;

    address public immutable WETH;

    uint256 public launchFee;
    /// @notice Launch tokens delivered per 1e18 of quote. Lower it to force
    ///         under-delivery against `amountOutMinimum`.
    uint256 public rate = 1e18;
    bool public distributeReverts;
    /// @notice Make `distributeFees` BURN EVERY UNIT OF GAS it is forwarded and
    ///         return no data — the EIP-150 63/64 shape observed on 4663, where
    ///         the outer `collectFees` succeeded, moved nothing, and logged
    ///         nothing at all.
    bool public distributeBurnsGas;
    /// @notice Disables this mock's own `amountOutMinimum` floor, so a test can
    ///         stage a venue that under-delivers and prove the adapter's own
    ///         belt-and-braces reserve assert is what catches it.
    bool public skipOutputFloor;

    mapping(address => address) public quoteTokenPriceFeed;
    mapping(address => bool) public isLaunch;
    mapping(address => ISushiLaunchpad.LaunchInfo) internal _launches;
    mapping(address => uint256) public quoteFeeOwed;
    mapping(address => uint256) public tokenFeeOwed;

    error ZeroInitialBuyAmount();
    error PartialInitialBuy();
    error InsufficientInitialBuyOutput();
    error UnsupportedQuoteToken();
    error InvalidInitialBuyRecipient();
    error InsufficientLaunchFee();
    error UnknownToken();
    error NotCreator();
    error DistributeFailed();

    constructor(address weth_) {
        WETH = weth_;
    }

    // ── venue-owner knobs (test-side stand-ins for the real setters) ──

    function setQuoteTokenPriceFeed(address quoteToken, address feed) external {
        quoteTokenPriceFeed[quoteToken] = feed;
    }

    function setLaunchFee(uint256 fee) external {
        launchFee = fee;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setFeesOwed(address token, uint256 quoteAmount, uint256 tokenAmount) external {
        quoteFeeOwed[token] = quoteAmount;
        tokenFeeOwed[token] = tokenAmount;
    }

    function setDistributeReverts(bool value) external {
        distributeReverts = value;
    }

    function setDistributeBurnsGas(bool value) external {
        distributeBurnsGas = value;
    }

    function setSkipOutputFloor(bool value) external {
        skipOutputFloor = value;
    }

    // ── venue surface ──

    function launchAndBuy(
        ISushiLaunchpad.TokenConfig calldata tokenConfig,
        address quoteToken,
        uint64,
        ISushiLaunchpad.InitialBuy calldata initialBuy
    ) external payable returns (address token, address pool, uint256 positionId, uint256 amountOut) {
        if (quoteTokenPriceFeed[quoteToken] == address(0)) revert UnsupportedQuoteToken();
        if (initialBuy.amountIn == 0) revert ZeroInitialBuyAmount();
        if (initialBuy.recipient == address(this)) revert InvalidInitialBuyRecipient();
        if (msg.value < launchFee) revert InsufficientLaunchFee();

        ERC20Mock launched = new ERC20Mock(tokenConfig.name, tokenConfig.symbol, 18);
        launched.mint(address(this), SUPPLY);
        token = address(launched);

        // The venue consumes the buy in full or reverts `PartialInitialBuy`.
        IERC20(quoteToken).transferFrom(msg.sender, address(this), initialBuy.amountIn);
        amountOut = (initialBuy.amountIn * rate) / 1e18;
        if (!skipOutputFloor && amountOut < initialBuy.amountOutMinimum) revert InsufficientInitialBuyOutput();
        launched.transfer(initialBuy.recipient, amountOut);

        pool = address(uint160(uint256(keccak256(abi.encode(token, quoteToken)))));
        positionId = uint256(uint160(token));

        isLaunch[token] = true;
        _launches[token] = ISushiLaunchpad.LaunchInfo({
            creator: msg.sender,
            quoteToken: quoteToken,
            pool: pool,
            reserveUnlockAt: uint64(block.timestamp + 365 days),
            reserveWithdrawn: false,
            reserveAmount: (SUPPLY * PROTOCOL_RESERVE_BPS) / 10_000
        });
    }

    /// @dev Permissionless, and pays the CURRENT creator — never the caller.
    function distributeFees(address token)
        external
        returns (uint256 quoteCollected, uint256 tokenCollected, uint256 quoteToSushi, uint256 tokenToSushi)
    {
        // `INVALID` consumes every unit of gas the caller forwarded and returns
        // no data — the exact signature of a child frame that ran out of gas
        // under the 63/64 rule, which a raw `call` cannot tell from a revert.
        if (distributeBurnsGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (!isLaunch[token]) revert UnknownToken();
        if (distributeReverts) revert DistributeFailed();

        address creator = _launches[token].creator;
        quoteCollected = quoteFeeOwed[token];
        tokenCollected = tokenFeeOwed[token];
        quoteFeeOwed[token] = 0;
        tokenFeeOwed[token] = 0;

        if (quoteCollected != 0) IERC20(_launches[token].quoteToken).transfer(creator, quoteCollected);
        if (tokenCollected != 0) IERC20(token).transfer(creator, tokenCollected);

        // The live venue keeps `defaultSushiFeeBps = 3000` of the gross; the
        // adapter reads only the creator's deltas, so the split is reported but
        // not modelled.
        quoteToSushi = 0;
        tokenToSushi = 0;
    }

    function transferCreator(address token, address newCreator) external {
        if (!isLaunch[token]) revert UnknownToken();
        if (msg.sender != _launches[token].creator) revert NotCreator();
        _launches[token].creator = newCreator;
    }

    /// @dev REVERTS for a token this venue never issued — the whole reason the
    ///      adapter reads this by length-checked raw staticcall.
    function launchInfo(address token) external view returns (ISushiLaunchpad.LaunchInfo memory) {
        if (!isLaunch[token]) revert UnknownToken();
        return _launches[token];
    }
}
